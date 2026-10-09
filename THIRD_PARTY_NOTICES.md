# Third-party software

FinderSearch's filename search is powered by **fsearch**, created by **Noah Dunnagan**.

- Upstream: https://github.com/noahdunnagan/fsearch
- Vendored revision: `76d612f5b23802eb24926b47e9c4f4ef26884014`
- License: [MIT](vendor/fsearch/LICENSE)

`vendor/fsearch` is the upstream source with these modifications:

- `src/server.rs`, `src/main.rs`: an `fsearch app` mode that runs the engine
  privately inside the app's helper process, answering on its stdin/stdout,
  with no socket, and exiting with the app. Its first line gives the index
  folder and encryption key.
- `src/seal.rs` (new), with calls from `src/index.rs`, `src/content.rs` and
  `src/engine.rs`: encryption at rest. With a key, the name index, content
  segments and skipped-folder list are sealed with AES-256-GCM; without one,
  files are written as upstream writes them. This adds the RustCrypto
  `aes-gcm` crate and its dependencies, all MIT OR Apache-2.0, to `Cargo.lock`.
- `src/walk.rs`, `src/live.rs`: other local drives in /Volumes are indexed (upstream
  stops at the startup volume), and changes reported on drives the index doesn't
  cover are ignored rather than applied and dropped again at the next compaction.
- `src/engine.rs`: without Full Disk Access, the guarded folders are skipped in every
  home folder under /Users, not only in $HOME.

Its copyright and license notice are included in every built app at
`Contents/Resources/fsearch-LICENSE`. `vendor/fsearch/Cargo.lock` records its Rust
dependencies; the build uses locked dependency resolution.

FinderSearch's native interface, browsing workflows, caching, and app integration
are separate from the upstream search engine. Engine benchmarks published by
fsearch do not measure FinderSearch's complete UI response time.
