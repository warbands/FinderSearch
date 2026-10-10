# FinderSearch

A native macOS file browser with fast fuzzy filename search, powered by
[fsearch](https://github.com/noahdunnagan/fsearch) by Noah Dunnagan.

FinderSearch brings indexed search into a familiar Finder-style interface:
sidebar navigation, four file views, tabs, Quick Look, and everyday file actions.
It is an early prototype, with incomplete Finder parity and no OS-shell replacement.

## Requirements

- macOS 15 or newer.
- Xcode 16 or newer, or compatible Command Line Tools with the macOS 15 SDK.
- Rust/Cargo with support for Rust edition 2024 (Rust 1.85 or newer).
- Python 3 only for optional engine verification and benchmarks.

The build produces an app for the host architecture. The current locally verified
build is Apple Silicon; Intel and clean second-Mac installation have not been verified.

## Build and run

After cloning this repository, run from its root:

```sh
./scripts/build.sh
open dist/FinderSearch.app
```

The script builds the vendored engine with its lockfile, builds the native app,
embeds the helper and upstream license, signs it and verifies the signature.
The first Rust build downloads dependencies. A separate fsearch installation
is not required.

If you rebuild often, run this once first:

```sh
./scripts/make-dev-cert.sh
```

It adds a self-signed "FinderSearch Local Dev" identity to your login keychain, and
`build.sh` signs with it from then on. macOS ties Full Disk Access and Keychain access
to the app's signature; an ad-hoc signature changes with every build, so without it
each rebuild asks for both again. It's for builds on your own Mac only; releases use
a Developer ID (see [RELEASING.md](RELEASING.md)).

Quit and reopen the app after rebuilding. `dist/` and build caches are generated
locally and excluded from version control. This project does not yet provide a
Developer ID-signed or notarized release.

## Permissions and indexing

For protected folders such as Documents, grant the app **Full Disk Access** in
System Settings → Privacy & Security → Full Disk Access, then quit and reopen it.
If the helper does not inherit the grant, add `FinderSearch.app/Contents/Helpers/fsearch`
as well. Permissions may need refreshing after a rebuild.

The first launch builds an index; searches become available as indexing progresses.
FinderSearch searches the startup drive and every local drive mounted in `/Volumes`.
Network drives, hidden mounts and Time Machine backups are left out.

Without Full Disk Access it skips the folders macOS guards (Desktop, Documents,
Downloads, iCloud Drive, other apps' data) and other drives, and never looks inside
them, so macOS doesn't ask about each one. On first launch FinderSearch explains how to
turn on Full Disk Access and notices by itself once it's on: the engine restarts and
scans what it skipped.

## Your search data

The index lists the names of your files and, for text files, what they contain. FinderSearch
protects it without anything to set up:

- **Encrypted on disk.** The index lives in `~/Library/Caches/FinderSearch` (readable only
  by you, and skipped by Time Machine) and is encrypted with AES-256-GCM. The key is made on
  first launch and kept in your login Keychain as "FinderSearch index key". Other apps can't
  read the index, and a damaged or altered index is rebuilt rather than trusted.
- **Private engine.** The search engine runs inside the app's own helper process and quits
  with the app. It opens no socket, so no other process can query it or borrow its Full
  Disk Access. The app does not install a login item.
- **Stays on your Mac.** Searches and file data are never uploaded.

**FinderSearch → Forget Search Data…** deletes the index and its key; a new index is built
straight away. Nothing is lost: the index only describes files that are still on disk.

While the app is open, the decrypted index is held in memory. Measured on one Mac with
4.8 million files and 96,000 text files: about 370 MB, peaking near 670 MB during the
first full build. It grows with the number of files you have. If the Keychain denies access to the key, the app
uses a key for that session only and rebuilds the index.

Protected folders, network volumes, unmounted drives, and cloud providers still
obey macOS permissions and availability. Thumbnails skip undownloaded cloud files;
opening or previewing a cloud file may trigger a provider download.

## Usage

- **Browse:** icons, sortable list, columns, and gallery via Command-1 through Command-4.
  Back/forward/up navigation, a path bar, favorites, mounted volumes, and iCloud's local folder.
- **Search:** Command-F; requests begin 300 ms after typing stops. Search This Mac or
  the current folder, with kind filters. Obsolete requests are cancelled and stale
  replies ignored. Up to 500 matches are shown; column-mode search uses the list.
- **Filters:** filename filters such as `ext:pdf` and `mtime:<7d` work. The UI does not
  yet support content-query syntax. Footer timing measures engine work, excluding
  debounce, IPC, and rendering.
- **Select and preview:** click, Command-click, or Shift-click; double-click or
  Command-O opens, Space/Command-Y uses Quick Look, and Return renames.
- **File actions:** Command-C copies file URLs, Command-V copies items, and
  Option-Command-V moves them. Folder drops move; Option-drag copies. Conflicts
  report an error without overwriting. Command-Shift-N creates a uniquely named folder.
- **Trash and undo:** Command-Delete moves selected files to recoverable Trash;
  while editing text it remains a text-editing command. Command-Z and
  Shift-Command-Z undo/redo file actions and tags. History is in memory per tab.
- **Other actions:** Get Info, Duplicate, Copy Path, tags, sharing, and revealing in Finder.
  Command-T creates a tab; Command-N creates a window; Command-Shift-G opens Go to Folder.
  Command-Shift-period toggles hidden files; Command-R refreshes.

Recents uses indexed files modified within 30 days, limited to 1,000 returned
candidates. Tags use Spotlight metadata and depend on its coverage. Search,
Recents, and tag results do not accept writes into an ambiguous destination.
File mutations run off the UI thread; additional writes are blocked while busy.
Partial failures retain undo for successful operations, and failed restores remain retryable.

## Responsiveness

Recent folder listings and their selections are cached per tab and refreshed in the
background. Clearing a search restores the browsing snapshot and sort immediately.
Uncached listings show inexpensive layout-matched skeletons until loading completes.
Each tab retains up to eight snapshots, evicting older entries above a 40,000-item
budget (a single larger view remains available).

List view uses reusable, fixed-height AppKit rows. Icons load on a background queue
with bounded concurrency and caching; gallery thumbnails load lazily and are cached.
Folder-event bursts are coalesced, and obsolete enumeration is cancelled cooperatively.
Engine cancellation abandons the request (its late reply is discarded); it does not
interrupt engine computation or a blocked filesystem call. Cold folders and slow volumes can still take time.

## Validation and contributions

```sh
swift test -c release
python3 scripts/verify_engine.py
```

Engine checks require a running `fsearch serve` daemon (the app no longer runs one)
and an indexed home folder; they create
and remove isolated fixtures. Swift tests cover file-operation safety, undo,
selection, debounce/cancellation, cached navigation, and native table restoration.
Performance budgets measure model/table update work, not universal frame rate or
complete paint latency.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for code layout, formatting, and verification.
[PRODUCT.md](../PRODUCT.md) records the product scope; [DESIGN.md](../DESIGN.md) records
native interface conventions.

## Known limitations

No Finder extensions, AirDrop integration, disclosure rows, advanced grouping,
batch rename, smart folders, cloud-management UI, or persistent session/undo state.
Column ancestors remain snapshots until revisited. New Folder/Rename use dialogs
rather than inline editing. Clipboard/drop conflicts have no merge/overwrite dialog.
Full keyboard/multi-drag parity and public release packaging remain in progress.

## Credits

The search engine is [fsearch](https://github.com/noahdunnagan/fsearch), created by
**Noah Dunnagan**, distributed under the MIT license and vendored unmodified at
`af9476d39ec98108552670adf6badbbd77331b0a`.
See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and [its license](../vendor/fsearch/LICENSE).
