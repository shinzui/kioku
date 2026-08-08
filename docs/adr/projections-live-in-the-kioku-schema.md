---
type: Architecture Decision Record
title: Kioku shares the host's event store but owns its projections in a kioku schema
description: >-
  Kioku keeps appending to the host's Kiroku event store while every relation Kioku owns moves
  into a dedicated `kioku` PostgreSQL schema, named explicitly in SQL rather than resolved
  through the connection's search path.
timestamp: 2026-08-07T18:00:00Z
docId: ADR-10
status: accepted
date: 2026-08-07
---

# Kioku shares the host's event store but owns its projections in a kioku schema

## Status

Accepted, 2026-08-07. Implemented by
`kioku-migrations/migrations/0012-relocate-projections-to-kioku-schema.sql` and
`kioku-core/src/Kioku/Database/Schema.hs`.

## Context

Kioku is a library embedded in a host application's database, not the owner of a cluster. It
deliberately appends its events to the host's Kiroku event store: that sharing is the integration
boundary, and it is what lets one subscription pipeline serve both products. Until this decision,
though, Kioku also put its seven projection tables in Kiroku's own `kiroku` schema, named
`kioku_memories`, `kioku_sessions`, `kioku_turns`, `kioku_l1_watermarks`,
`kioku_consolidation_decisions`, `kioku_scenes`, and `kioku_personas`.

Two things went wrong with that. A host that already ran Kiroku found relations it did not own
appearing inside its event store's namespace, distinguishable only by a name prefix that nothing
enforces. And Kioku's SQL named those relations either unqualified — resolved through the Kiroku
connection's `search_path`, which puts `kiroku` first and then whatever `extraSearchPath` the host
configured — or hard-coded as `kiroku.kioku_*`, which spells another component's namespace in
Kioku's own queries.

Keiro had already made the same move for its framework tables, out of `kiroku` and into a
dedicated `keiro` schema, so the shape of the answer was established.

## Decision

Every relation Kioku owns lives in the `kioku` PostgreSQL schema, and every Kioku statement names
it explicitly. The event store stays exactly where it is.

Four rules follow, and they are the part worth remembering:

**Event-store sharing and projection ownership are different questions.** Kioku still appends to
the host's Kiroku streams, still uses the host's connection settings, and still creates no second
event store. Nothing about stream identity, event codecs, the event tables, the primary `kiroku`
schema, or `extraSearchPath` changes. What moved is only the set of tables Kioku alone writes and
reads.

**The schema supplies the namespace, so the table names drop their prefix.** `kiroku.kioku_memories`
became `kioku.memories`. Keeping the prefix inside a schema that already says "kioku" would be
redundant. Index and constraint names were deliberately *not* renamed: PostgreSQL carries them
along with `ALTER TABLE … SET SCHEMA` and `… RENAME TO` by object identity, so leaving them alone
means the relocation touches no catalog row it does not have to, and every existing assertion about
`kioku_memories_space_scope_idx` and its siblings keeps its meaning.

**Qualification is explicit, not a search-path effect.** One internal module,
`kioku-core/src/Kioku/Database/Schema.hs`, builds each relation reference once with
`Keiro.Connection.qualifyTable` and exports it as a constant; every statement concatenates that
constant. Relying on `search_path` instead would make relation ownership depend on a host-supplied
setting on a shared connection pool — the same reasoning that
[ADR-6](the-partition-is-a-column-not-a-schema.md) used to reject row-level security keyed on a
session GUC. The module stays in `other-modules`, because the physical layout is not a public API.

**The move is one transactional, forward-only migration with no compatibility layer.** Migration
`0012` accepts exactly two catalog states — seven source tables and no occupied targets, or no
sources and seven target tables — and raises before touching anything otherwise. There are no
compatibility views: Kioku inserts and upserts into these relations, so read-only aliases would not
serve, and writable views would create a second migration surface with its own failure modes.

## Consequences

**The deployment is migration-first and needs a quiesced window.** Old writers must stop, the
migration runs, then the new binary starts. This is enforced rather than documented: the read-model
identities advance in the same change (memory v2 → v3, session v4 → v5, turn v2 → v3, with matching
shape hashes), so a binary on the wrong side of the migration fails closed with
`ReadModelStaleSchema` instead of issuing SQL at relations that are no longer there. Keiro's
registry stores a logical name, version, and shape hash but no physical relation locator, which is
exactly why the version bump has to carry that signal.

**Reconciliation is a required deployment step, not an optimisation.** `kioku-migrate up` calls
`Kioku.ReadModel.reconcileReadModelRegistry` for you. A host that applies the plan as a library must
call it itself before serving traffic, or every read stays failed-closed.

**The runtime role needs `USAGE ON SCHEMA kioku`.** Table-level grants move with each table, so
nothing else has to be re-granted, but schema usage is a separate privilege on a schema that did not
exist before.

**Rollback by restarting the old binary is not available.** Once `0012` commits, the old code still
names `kiroku.kioku_*`. Before any new write, recovery is a restore from the verified pre-migration
backup; after new writes, it is a reviewed forward repair. A reverse move must be a new migration,
never an edit to `0012` or to the pg-migrate ledger.

**The pgvector extension does not move.** Extensions are database-wide and may be shared with the
host, so `ALTER EXTENSION` is out of scope even as a recovery shortcut. The memory table keeps its
`vector` column and HNSW index by object identity, and the `to_regtype('vector')` probe keeps
resolving against the configured connection search path exactly as
`0009-kioku-embedding-schema-heal.sql` intended. What did change is the catalog probe: capability
detection now asks about schema `kioku`, table `memories`. The consequence for anyone changing
this later is that "where the table is" and "where the type resolves from" are two questions with
two different answers, and a change that conflates them will pass every test that does not have
pgvector — which, outside the project dev shell, is all of them: the suites detect an unreachable
extension and skip the vector cases rather than fail. Verify vector-touching work with
`nix develop -c cabal test all`.

**Adoption by an existing Kiroku host still works without replay, but only for a ledger that
contains nothing else.** Kioku's composed plan is `kiroku → keiro → kioku`, and pg-migrate's
identities are component-qualified, so a ledger holding exactly the Kiroku prefix verifies and skips
those rows and applies the rest. A host that also has its own migration component must compose
Kiroku, Keiro, Kioku, and its own into one complete plan and run that; standalone `kioku-migrate`
rejects the unknown component on purpose, and this change does not soften that.

## Alternatives rejected

**One PostgreSQL schema per memory space.** Already rejected by
[ADR-6](the-partition-is-a-column-not-a-schema.md), and this decision does not reopen it. One
package-owned schema whose tables are partitioned by a `memory_space_id` column is a different
thing from a schema per tenant: creating a memory space still requires no DDL, no migration, and no
privilege.

**Treating the new schema as an authorization boundary.**
[ADR-2](namespace-is-not-a-security-boundary.md) applies unchanged. `kioku` is an ownership and
collision boundary in the catalog. It grants nothing, isolates no tenant, and the memory-space
predicate on every statement remains the only thing that does.

**Leaving the tables in `kiroku` and relying on the `kioku_` prefix.** Rejected: a prefix is a
convention no catalog enforces, it makes a host's event-store schema look like it owns another
product's data, and it leaves `kiroku.` spelled inside Kioku's own queries.

**Compatibility views under the old names.** Rejected: the projections are written, not only read,
so views would have to be writable, and a writable compatibility layer is a second physical
interface that would need its own migration, its own tests, and its own removal plan. A short
planned outage yields one authoritative layout instead.

**Rewriting migrations `0001`–`0011` to create the tables in `kioku` directly.** Rejected: released
migrations and the pinned Codd cutover fixture are immutable history. A database that already
applied them must be moved forward, not have its past rewritten.

## References

- `kioku-migrations/migrations/0012-relocate-projections-to-kioku-schema.sql` — the schema, the
  strict state machine, and the seven moves
- `kioku-migrations/test/Main.hs` — fresh install, data-bearing upgrade with OID preservation,
  no-op rerun, and atomic rejection of every mixed layout
- `kioku-core/src/Kioku/Database/Schema.hs` — the qualified relation constants
- `kioku-core/test/Kioku/ReadModelReconcileSpec.hs` — the fail-closed guard and its repair
- [ADR-1](kioku-owns-memory-not-identity.md), [ADR-2](namespace-is-not-a-security-boundary.md),
  [ADR-6](the-partition-is-a-column-not-a-schema.md)
- Kiroku's own `docs/adr/0003-dedicated-kiroku-schema.md`, which established that Kiroku-owned
  relations belong in the dedicated Kiroku schema while application projections may use others.
  Its canonical project reference is `mori://shinzui/kiroku`; Mori does not yet expose an
  artifact-level ADR URI, so the project URI plus that project-relative path stands in pending ADR
  URI coverage.
