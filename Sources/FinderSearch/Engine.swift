import Foundation
import Darwin

struct Hit: Decodable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let kind: String
    let size: UInt64
    let mtime: UInt64
    let score: Int64
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var parent: String {
        url.deletingLastPathComponent().path.replacingOccurrences(
            of: NSHomeDirectory(), with: "~", options: .anchored)
    }
}
struct Reply: Decodable {
    let ok: Bool
    let error: String?
    let hits: [Hit]?
    let took_us: UInt64?
    let entries: Int?
    let full_disk_access: Bool?
}

protocol SearchService: Sendable {
    func request(_ fields: [String: Any]) async throws -> Reply
}

/// The app's one private engine, in a helper process reached only through its
/// pipes (no socket another process could use), shared by every tab and window.
/// Requests carry an id so several can be in flight; a reader thread hands each
/// reply to its caller and drops replies nobody waits for any more.
final class Engine: SearchService, @unchecked Sendable {
    static let shared = Engine()
    /// Spawning and writing stay on this serial queue.
    private let queue = DispatchQueue(label: "FinderSearch.engine", qos: .userInitiated)
    private let binaryOverride: String?
    init(binary: String? = nil) {
        binaryOverride = binary
        signal(SIGPIPE, SIG_IGN)  // a dead helper fails the write instead of killing the app
    }
    private var process: Process?
    private var input: FileHandle?
    /// Callers waiting for a reply, by request id; guarded by `lock`.
    private let lock = NSLock()
    private var lastID: UInt64 = 0
    private var pending: [UInt64: CheckedContinuation<Reply, Error>] = [:]
    private struct Tag: Decodable { let id: UInt64? }
    enum Failure: LocalizedError, Equatable {
        case message(String), timedOut
        var errorDescription: String? {
            switch self {
            case .message(let message): return message
            case .timedOut: return "Search engine timed out. Try again."
            }
        }
    }
    private func connect() throws {
        if process?.isRunning == true { return }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/fsearch").path
        let candidates = [
            binaryOverride ?? "", bundled,
            ProcessInfo.processInfo.environment["FSEARCH_BINARY"] ?? "",
            NSHomeDirectory() + "/.local/bin/fsearch",
            FileManager.default.currentDirectoryPath + "/vendor/fsearch/target/release/fsearch",
        ]
        guard
            let binary = candidates.first(where: {
                !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0)
            })
        else {
            throw Failure.message("Search engine missing. Run scripts/build.sh to bundle fsearch.")
        }
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["app"]
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        try p.run()
        process = p; input = stdin.fileHandleForWriting
        let output = stdout.fileHandleForReading
        let reader = Thread { [weak self] in self?.read(output, from: p) }
        reader.qualityOfService = .userInitiated  // decodes every reply; keep it off efficiency cores
        reader.start()
    }
    /// Queue only.
    private func reset() {
        process?.terminate(); process = nil; input = nil
    }
    private func read(_ output: FileHandle, from p: Process) {
        var buffer = Data()
        while case let chunk = output.availableData, !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let id = (try? JSONDecoder().decode(Tag.self, from: line))?.id else { continue }
                finish(id, Result { try JSONDecoder().decode(Reply.self, from: line) })
            }
        }
        // The helper exited: fail whoever waits on it; the next request starts a new one.
        queue.sync {
            if process === p { reset() } else if process != nil { return }  // a newer helper's
            lock.lock(); let waiting = pending; pending.removeAll(); lock.unlock()
            for c in waiting.values { c.resume(throwing: Failure.message("Search engine stopped. Try again.")) }
        }
    }
    /// Resume the caller of `id`, unless it already gave up.
    private func finish(_ id: UInt64, _ result: Result<Reply, Error>) {
        lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
        c?.resume(with: result)
    }
    private final class Ticket: @unchecked Sendable { var id: UInt64 = 0; var cancelled = false }
    func request(_ fields: [String: Any]) async throws -> Reply {
        let ticket = Ticket()  // guarded by `lock`
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if ticket.cancelled {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                lastID += 1; ticket.id = lastID; pending[lastID] = continuation
                let id = lastID
                lock.unlock()
                queue.async {
                    do {
                        try self.connect()
                        var fields = fields
                        fields["id"] = id
                        let data = try JSONSerialization.data(withJSONObject: fields)
                        try self.input?.write(contentsOf: data + Data([10]))
                    } catch {
                        self.reset()
                        self.finish(id, .failure(error))
                    }
                }
                // A slow reply is dropped when it comes; the engine keeps running.
                queue.asyncAfter(deadline: .now() + 15) { self.finish(id, .failure(Failure.timedOut)) }
            }
        } onCancel: {
            lock.lock(); ticket.cancelled = true; let id = ticket.id; lock.unlock()
            if id != 0 { finish(id, .failure(CancellationError())) }
        }
    }
    deinit { process?.terminate() }
}
