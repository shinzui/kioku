# Changelog

## 0.1.0.0 — 2026-07-14

### Added

- Added the initial ten-migration Kioku schema for memory and session event streams, read models,
  embeddings, distillation artifacts, timers, delegation, and durable awaiting state.
- Added schema hardening and repair migrations for supersession chains, session indexes, scope
  constraints, embedding columns, and collision-safe distillation identities.
- Added a checked migration manifest and a test that fails when compiled migration order falls out
  of sync with the files on disk.
- Added `Kioku.Migrations.History.Codd`, which lets downstream databases import the pinned
  30-migration Kiroku/Keiro/Kioku history into pg-migrate without replaying historical DDL.
- Shipped the reviewed Kiroku/Keiro ledger realignment and Keiro schema-relocation SQL used by the
  downstream cutover runbook under `codd-upgrade/`.
- Added pg-migrate-backed ephemeral database test support while preserving the existing
  `withKiokuMigratedDatabase` and `withBareDatabase` signatures.

### Fixed

- Made read-model registry migration logic locate `keiro_read_models` across supported cohort
  layouts.

### Changed

- Upgraded the framework dependency baseline to Keiki 0.2, Keiro 0.3, Kiroku Store 0.3,
  PGMQ 0.4, and pg-migrate 1.1. The project now resolves the released packages from Hackage and
  no longer carries Git source overrides or migration-era `allow-newer` exceptions.
- Adapted Kioku's inline read models to Keiro 0.3's explicit `StrongScope` contract. They retain
  `Eventual` consistency and declare `EntireLog` as the otherwise-unused strong-read scope.
- Added Kiroku 0.3's `KirokuStoreResource` to the application effect stack and write API
  constraints so Keiro's transactional command runners preserve configured event-enrichment
  hooks. `AppEnv.store` was replaced by `AppEnv.connectionSettings`; `runAppIO` now acquires the
  resource and interprets `Store` through `runStoreResource`.
- Registered every Kioku read model during application startup, as required by Keiro 0.3's
  explicit read-model lifecycle.
- Replaced the Codd-backed migration runner functions with the native pg-migrate
  `kiokuMigrations` component and composed `kiokuMigrationPlan`. This is a breaking API change for
  consumers of the removed `runKiokuMigrations`, `runKiokuMigrationsNoCheck`, and
  `kiokuOwnMigrations` functions.
- Renamed Kioku's ten migration files to stable `NNNN-slug.sql` identities and made their explicit
  manifest the source of apply order.
- Updated the composed migration plan to Keiro migrations 0.3, including Keiro migration 0018;
  the current plan contains 36 migrations (Kiroku 8, Keiro 18, Kioku 10).
