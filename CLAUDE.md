# FinderSearch (fork)

A native macOS file browser (SwiftUI + AppKit) with whole-disk name and content search.
This fork of [zeusinsight/FinderSearch](https://github.com/zeusinsight/FinderSearch)
hardens privacy: the search engine runs privately inside the app, the index is encrypted
at rest, and the app never touches folders macOS guards without Full Disk Access. The
engine is Noah Dunnagan's [fsearch](https://github.com/noahdunnagan/fsearch), vendored in
`vendor/fsearch` with modifications listed in `THIRD_PARTY_NOTICES.md`.

## Layout

- `Sources/FinderSearch/`: the app. `Engine.swift` (engine client, `IndexStore` key and
  folder), `Model.swift` (browser state, `DiskAccess`), `FileSystem.swift` (file ops,
  icons, `FullDiskAccess`, `ProtectedPlace`), `App.swift` (windows, menus, setup sheet,
  status line), `FileList.swift` (AppKit list view), `FileViews.swift`.
- `vendor/fsearch/src/`: the engine (Rust). `server.rs` (`fsearch app` mode),
  `seal.rs` (encryption), `engine.rs`, `walk.rs` (disk scan), `live.rs` (FSEvents
  updates), `index.rs` (name index), `content.rs` (content index), `query.rs`.
- `scripts/`: `build.sh`, `make-dev-cert.sh`, `make-icon.swift`; `tools/`: verification.
- `assets/`: compiled app icon (`Assets.car`, `AppIcon.icns`) and its source `AppIcon.icon`.
- `docs/USAGE.md` (users), `docs/RELEASING.md` (Developer ID release plan).

## Build, test, install

```sh
scripts/build.sh                      # → dist/FinderSearch.app
swift test -c release                 # app tests
(cd vendor/fsearch && cargo test --release --lib)   # engine tests (seal.rs)
```

- `build.sh` signs with `SIGN_IDENTITY` if set (Developer ID, release), else with the
  self-signed "FinderSearch Local Dev" identity if `scripts/make-dev-cert.sh` made one
  (keeps Full Disk Access across rebuilds), else ad-hoc. Hardened runtime always.
- Even with the local identity, the Keychain asks once after every rebuild (it only
  recognizes later builds as the same app with an Apple team ID). Expected; tell the user.
- Install: quit the app (`pkill -TERM -f '^/Applications/FinderSearch.app/Contents/MacOS/FinderSearch'`;
  closing its window doesn't quit it), replace `/Applications/FinderSearch.app` with
  `dist/FinderSearch.app`, then `touch` it and run `lsregister -f` on it so the icon refreshes.
- Rust needs edition 2024 (Rust 1.85+). Regenerating the icon needs Xcode (actool);
  building doesn't.

## How it fits together

- **Private engine.** The app starts `fsearch app` as a helper and talks JSON lines over its
  stdin/stdout. No socket: nothing else can query the engine or borrow its Full Disk
  Access. The first line is `{"dir": …, "key": <64 hex>}`; the engine refuses to start
  without it. Requests carry an `id`; replies may come out of order. `Engine.shared` serves
  every tab and window; a reader thread routes replies and drops ones for cancelled
  requests. The helper exits when the app closes its stdin.
- **Index.** `~/Library/Caches/FinderSearch` (0700, excluded from backups). The key is a
  random 256-bit value in the login Keychain (service "FinderSearch", account
  "index-key"). If the Keychain refuses, the app uses a session-only key and the index
  rebuilds; never block on it. "Forget Search Data…" deletes index and key.
- **Encryption** (`seal.rs`): AES-256-GCM in 1 MiB chunks bound to position and file name.
  Name index decrypted whole on load; content segments open lazily (`seal::Bytes`), every
  tag verified at open, chunks decrypted on first read. A file that fails to
  authenticate is treated as missing and rebuilt. Changing the format (`FSSEAL01`, chunk
  size) forces every user's index to rebuild.
- **Drives.** The scan covers the startup volume plus local, browsable volumes directly in
  `/Volumes` (`walk::crossable`); network, hidden and Time Machine volumes stay out.
  FSEvents for any other volume are ignored (`walk::indexed`). The full scan and the live
  updates must agree on this, or compaction loops (that bug rebuilt the index every few
  seconds).
- **Full Disk Access.** Apps can't request it; the setup sheet explains it and polls
  (`DiskAccess`, live check via the system TCC.db opening). When it changes, the engine
  restarts and rescans what it skipped.

## Rules

- Never reopen a socket or daemon path for the app, pass the key on the command line or in
  the environment, or let the app fall back to another `fsearch` binary (the CLI's
  `~/.local/bin/fsearch` doesn't speak this protocol and is writable by anything).
- Without Full Disk Access, never read inside a guarded place: Desktop, Documents,
  Downloads, iCloud Drive, other apps' containers, other volumes, photo libraries, in
  *any* home under `/Users`. Even drawing a folder's icon reads inside it
  (`ProtectedPlace`), and one read makes macOS prompt. `tools/no_prompts.sh` proves it.
- Tests must not start a real engine or touch the Keychain: models use
  `RecordingSearchEngine`, stand-in engines use `Engine(binary:setup: nil)`.
- Before merging upstream (`zeusinsight/FinderSearch` or `noahdunnagan/fsearch`), review the
  new commits. When changing `vendor/fsearch`, update `THIRD_PARTY_NOTICES.md`.

## Verifying

- Behaviour changes get a test that fails on the old code. UI flicker, for example:
  `testEnteringAFolderReplacesTheListingInPlace` asserts the listing in the same frame.
- Performance claims: run old and new on the same index alternately, at least twice; a
  busy Mac shifts every number (`tools/bench_content.py`).
- Icons: look at `tools/icon_compare.swift` output next to Preview's; bounding boxes alone
  miss the grey "legacy icon" plate.
- See `tools/README.md` for the rest.

## Git

- `origin` is the fork (warbands/FinderSearch), `upstream` the original. Work is on
  `encrypted-index` (stacked on `app-private-engine`); `main` mirrors upstream's history.
- Commit messages: a short imperative subject, then why the change was needed and what it
  does, with measurements when there are any.
