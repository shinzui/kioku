# Changelog

## Unreleased

### Changed

- Replaced the Codd-backed migration runner functions with the native pg-migrate
  `kiokuMigrations` component and composed `kiokuMigrationPlan`. This is a breaking API change for
  consumers of the removed `runKiokuMigrations`, `runKiokuMigrationsNoCheck`, and
  `kiokuOwnMigrations` functions.
- Renamed Kioku's ten migration files to stable `NNNN-slug.sql` identities and made their explicit
  manifest the source of apply order.

### Added

- Added `Kioku.Migrations.History.Codd`, which lets downstream databases import the pinned
  30-migration Kiroku/Keiro/Kioku history into pg-migrate without replaying historical DDL.
- Shipped the reviewed Kiroku/Keiro ledger realignment and Keiro schema-relocation SQL used by the
  downstream cutover runbook under `codd-upgrade/`.
- Added pg-migrate-backed ephemeral database test support while preserving the existing
  `withKiokuMigratedDatabase` and `withBareDatabase` signatures.
