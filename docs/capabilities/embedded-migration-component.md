---
title: "Embedded, checksummed migration component and composed plan"
type: Capability
description: "Ship Kioku's schema as a native pg-migrate component whose ordered SQL manifest is embedded and checksummed at compile time, composed with the Kiroku and Keiro components in validated dependency order, so a host applies one plan and a stray or unlisted file fails the build."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-13
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-migrations
  - kioku-migrate
interface:
  - Kioku.Migrations
evidence:
  - kind: test
    resource: kioku-migrations/test/Main.hs
    proves: "The full migration chain applies to a fresh database from the kiroku, keiro, and public search paths, the manifest is complete and valid, the component restores the host search path before later components run, and each migration's body is idempotent on re-application."
  - kind: test
    resource: kioku-core/test/Kioku/SchemaSpec.hs
    proves: "The constraints the migrations create actually hold: a memory with a kind and no ref is rejected, one with no memory space is rejected, and the expected indexes exist while redundant ones are gone."
  - kind: guide
    resource: docs/user/library-api.md
    proves: "How a downstream host composes kiokuMigrations with its own components, which schema Kioku owns, and the USAGE grant the runtime role needs."
  - kind: guide
    resource: docs/user/cli-reference.md
    proves: "The kioku-migrate command set — plan, list, check, status, verify, up, repair, new — and which commands need a database."
---

# Embedded, checksummed migration component and composed plan

Kioku owns the `kioku` PostgreSQL schema and everything in it: `memories`, `sessions`,
`turns`, `l1_watermarks`, `consolidation_decisions`, `scenes`, and `personas`. It does
**not** own an event store — it appends to the host's Kiroku streams and creates no
second one.

That schema ships as a native pg-migrate component. The ordered SQL manifest and every
file it lists are compilation dependencies, embedded and checksummed at compile time, so
a stray `.sql` file or a missing manifest entry fails the build with `UnlistedSqlFiles`
rather than silently shipping an incomplete component. `kiokuMigrations` is the component
named `kioku`, depending on `keiro`; `kiokuMigrationPlan` composes Kiroku, Keiro, and
Kioku in validated dependency order. A downstream host composes `kiokuMigrations` with its
own components instead.

Every statement Kioku issues names its own relations explicitly rather than resolving them
through `search_path`, so entries added to the store's `extraSearchPath` cannot change
which relations Kioku reads or writes — and the component restores the host's configured
search path before committing, so a later component in the same composed run resolves its
own unqualified names exactly as it did before.

`kioku-migrate` mounts the standard `plan`, `list`, `check`, `status`, `verify`, `up`,
`repair`, and `new` commands. `plan`, `list`, and `check` inspect the compiled plan and
need no database; `status` and `verify` are read-only. A successful `up` also runs
[read-model registry reconciliation (CAP-14)](read-model-registry-reconciliation.md).

## Shape

```haskell
import Kioku.Migrations (kiokuMigrationPlan)

plan <- either (fail . show) pure kiokuMigrationPlan
runMigrationPlan defaultRunOptions migrationSettings plan
```

```bash
DATABASE_URL="$PG_CONNECTION_STRING" cabal run kioku-migrate -- up
```

## Limits

- The plan is dependency-ordered and forward-only. pg-migrate treats applied history as
  immutable, so a migration whose DDL was conditional on an extension that was absent at
  the time is not re-run; Kioku ships a separate idempotent heal file for that case.
- Applying the plan is only half an upgrade for a library embedder: the read-model
  registry must be reconciled afterwards or every Kioku query stays down.
- The runtime database role needs `USAGE ON SCHEMA kioku` in addition to its table
  privileges.
- Adding a migration goes through `just new-migration <slug>`, which appends to the
  manifest atomically. Hand-created files are a build failure by design.
