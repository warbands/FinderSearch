# Third-party software

FinderSearch's filename search is powered by **fsearch**, created by **Noah Dunnagan**.

- Upstream: https://github.com/noahdunnagan/fsearch
- Vendored revision: `76d612f5b23802eb24926b47e9c4f4ef26884014`
- License: [MIT](vendor/fsearch/LICENSE)

`vendor/fsearch` is the upstream source with these modifications:

- `src/server.rs`, `src/main.rs`: an `fsearch app` mode that runs the engine
  privately inside the app's helper process, answering on its stdin/stdout,
  with no socket, and exiting with the app.

Its copyright and license notice are included in every built app at
`Contents/Resources/fsearch-LICENSE`. `vendor/fsearch/Cargo.lock` records its Rust
dependencies; the build uses locked dependency resolution.

FinderSearch's native interface, browsing workflows, caching, and app integration
are separate from the upstream search engine. Engine benchmarks published by
fsearch do not measure FinderSearch's complete UI response time.
