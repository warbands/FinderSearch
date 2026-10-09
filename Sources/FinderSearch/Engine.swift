import Foundation
import Darwin
import Security

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

/// Where the app's index lives, and the key it's sealed with on disk. The index
/// is a cache of what's on disk, so losing the key only costs a rebuild.
enum IndexStore {
    /// In Caches: rebuildable, so Time Machine skips it.
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinderSearch", isDirectory: true)
    }
    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "FinderSearch",
        kSecAttrAccount as String: "index-key",
    ]
    /// The engine's first line: its index folder and key.
    static func setup() throws -> [String: Any] {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = folder, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return ["dir": folder.path, "key": key().map { String(format: "%02x", $0) }.joined()]
    }
    /// The key from the Keychain, made and stored on first use. If the Keychain
    /// refuses (access denied), a key for this session only: the index is rebuilt.
    static func key() -> Data {
        var query = item
        query[kSecReturnData as String] = true
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecSuccess, let key = found as? Data, key.count == 32 { return key }
        var key = Data(count: 32)
        let made = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        precondition(made == errSecSuccess, "no random bytes for the index key")
        if status == errSecSuccess || status == errSecItemNotFound {
            SecItemDelete(item as CFDictionary)
            var add = item
            add[kSecValueData as String] = key
            add[kSecAttrLabel as String] = "FinderSearch index key"
            SecItemAdd(add as CFDictionary, nil)
        }
        return key
    }
    /// Delete the index and its key.
    static func forget() throws {
        SecItemDelete(item as CFDictionary)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }
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
    private let setup: (() throws -> [String: Any])?
    /// `setup` gives a new engine its index folder and key; nil sends nothing
    /// (for stand-in engines in tests).
    init(binary: String? = nil, setup: (() throws -> [String: Any])? = IndexStore.setup) {
        binaryOverride = binary
        self.setup = setup
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
            FileManager.default.currentDirectoryPath + "/vendor/fsearch/target/release/fsearch",
        ]
        guard
            let binary = candidates.first(where: {
                !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0)
            })
        else {
            throw Failure.message("Search engine missing. Run scripts/build.sh to bundle fsearch.")
        }
        let first = try setup.map { try JSONSerialization.data(withJSONObject: $0()) + Data([10]) }
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["app"]
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        try p.run()
        process = p; input = stdin.fileHandleForWriting
        if let first { try input?.write(contentsOf: first) }
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
    /// Stop the engine; the next request starts a new one, which sees
    /// permissions granted since and scans the folders the old one skipped.
    func restart() { queue.async { self.reset() } }
    /// Delete the index and its key. The next request starts a fresh engine,
    /// which rebuilds the index under a new key.
    func forget() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                let p = self.process
                self.reset()
                p?.waitUntilExit()  // so it can't write into the folder as it goes
                done.resume(with: Result { try IndexStore.forget() })
            }
        }
    }
    deinit { process?.terminate() }
}
