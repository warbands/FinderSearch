# Verification tools

Checks used while developing this fork. None of them touch your real index or
Keychain item; each uses a scratch folder and a throwaway key.

| Tool | What it proves | Run |
|---|---|---|
| `no_prompts.sh` | Without Full Disk Access, neither the engine nor the app reads inside Desktop, Documents or Downloads of any home under `/Users` (reading them is what makes macOS ask). Runs both under a sandbox that kills them on such a read. The app test opens a window for ~15 s. | `tools/no_prompts.sh [FinderSearch.app]` |
| `seal_check.py` | Index encryption end to end: everything holding names or contents is sealed with no plaintext leaking, the same key reloads, another key rebuilds, no key refuses to start. | `python3 -I tools/seal_check.py [engine]` |
| `bench_content.py` | Memory (at rest, after searches, peak) and content-search speed of one engine on one index. Compare engines by running each on the same index alternately. `--build` indexes your disk with this terminal's permissions, so delete the index afterwards. | `python3 -I tools/bench_content.py ENGINE INDEX_DIR KEY_FILE [--build]` |
| `icon_compare.swift` | How macOS draws app icons, side by side, with Apple's 824 px body outlined. Look at the picture: an outdated icon format is shrunk onto a grey plate that fills the same box. | `swift tools/icon_compare.swift out.png /System/Applications/Preview.app /Applications/FinderSearch.app` |

The engine is `FinderSearch.app/Contents/Helpers/fsearch`; tools default to the
`dist/` build where they take one. `swift test -c release` and
`cd vendor/fsearch && cargo test --release --lib` cover the unit tests.
