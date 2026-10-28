# Bundle Update Log

## 2026-10-28
* **Update**: FRIC-4 accepted: Archive consumer builds and runtime source parity pass with explicit component selection.
* **Update**: FRIC-3 accepted: Recorded the machine concurrency limit and successful full-suite workaround.
* **Update**: FRIC-2 accepted: Migration tests now use the supported public interface and immutable previous-release bytes.
* **Update**: FRIC-1 accepted: Documented exact project and artifact source isolation for baseline and archive builds.
* **Addition**: FRIC-4 records detour interface friction with https://github.com/haskell/cabal: Cabal all target excludes source archives
* **Addition**: FRIC-3 records detour environment friction with mori://shinzui/kioku: Default Tasty concurrency exhausts ephemeral PostgreSQL startup
* **Addition**: FRIC-2 records detour interface friction with mori://shinzui/pg-migrate/packages/pg-migrate: Planned pg-migrate component accessor is hidden in the release
* **Addition**: FRIC-1 records detour tooling friction with https://github.com/haskell/cabal: Cabal project file did not isolate baseline source paths
* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
