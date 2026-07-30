# Changelog

## Unreleased

### Breaking Changes

- Moved onto the Keiro 0.4 cohort through `kioku-core` and `kioku-migrations`. A database that was
  migrated by kioku 0.1.0.0 picks up exactly two migrations on the next `kioku-migrate up` —
  `keiro/0019-keiro-snapshots-state-shape-hash` and
  `keiro/0020-keiro-workflow-children-failure-reason` — and reports every other migration as
  already applied. Both add a column to a Keiro-owned table; no existing row is read or rewritten.
  After the upgrade `kioku-migrate verify` reports `applied=38 pending=0 unknown=0`.

### Deprecated

- The `kioku-migrate import` subcommand, which imports a codd ledger into pg-migrate, is
  deprecated. It remains fully supported for now. Removal is gated on the last codd-era downstream
  database crossing over; see `kioku-migrations/codd-upgrade/README.md` for the gate and the full
  list of what is removed together.

## 0.1.0.0 — 2026-07-14

### Added

- Added a pg-migrate administration executable for planning, listing, checking, inspecting,
  verifying, applying, repairing, and creating migrations.
- Added checked Codd-history import for the pinned Kiroku, Keiro, and Kioku migration cohort with
  text or JSON reports.
- Added automatic read-model registry reconciliation after successful migration application.

### Changed

- Updated the executable to pg-migrate 1.1 and the Keiro 0.3/Kiroku Store 0.3 application resource
  model.
