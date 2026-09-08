---
title: "Ephemeral-Postgres test support for the migrated schema"
type: Capability
description: "A published sublibrary that hands a test either a database with Kioku's whole composed plan already applied or a bare ephemeral server with nothing applied at all, so a consumer's integration tests run against the real schema without a shared database."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-16
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-migrations
interface:
  - Kioku.Migrations.TestSupport
requires:
  - CAP-13
evidence:
  - kind: module
    resource: kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs
    proves: "withKiokuMigratedDatabase applies the composed plan to an ephemeral server and hands back a connection string; withBareDatabase gives one with no migrations at all, not even the bootstrap."
  - kind: test
    resource: kioku-core/test/Kioku/SpaceIsolationSpec.hs
    proves: "A consumer-shaped integration suite built on the migrated-database helper, asserting partition behaviour against the real schema and its real indexes."
  - kind: test
    resource: kioku-migrations/test/Main.hs
    proves: "The bare-database helper in use: migrations are exercised against search-path layouts and ledger states the package is not itself compiled against."
---

# Ephemeral-Postgres test support for the migrated schema

`kioku-migrations` publishes a **public sublibrary**, `test-support`, holding the two
database fixtures Kioku's own suites are built on. A consumer depends on
`kioku-migrations:test-support` and gets the same ones.

`withKiokuMigratedDatabase` starts an ephemeral PostgreSQL server, applies
[the composed plan (CAP-13)](embedded-migration-component.md) to it, and hands the
callback a connection string. That is the fixture for any test that wants to exercise real
queries against the real schema — indexes, constraints, and all — rather than a hand-rolled
approximation of it.

`withBareDatabase` is the opposite: an ephemeral server with nothing applied, not even the
Keiro bootstrap. Tests that must build a schema layout by hand — to exercise a migration
against a cohort this package is not compiled against, or a ledger state that no forward
plan produces — start from there.

Both hand back a **connection string** rather than a live connection, deliberately, so
assertions cannot inherit the runner's session state: a test that changes `search_path`
in its own session cannot leak that into the fixture's.

## Shape

```haskell
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)

spec :: TestTree
spec = testCase "reads survive the real schema" do
  withKiokuMigratedDatabase \connectionString -> do
    ...
```

## Limits

- It needs a PostgreSQL server binary available to `ephemeral-pg` on the machine running
  the tests. This is a test-time dependency, not a runtime one.
- Each call starts and tears down a server. It is a per-suite fixture, not a per-case one.
- The plan it applies is whatever this version of `kioku-migrations` compiles in, so a
  test written against it is pinned to that cohort — which is the point, and why
  `withBareDatabase` exists for everything else.
