---
id: 31
slug: relocate-kioku-projections-into-a-dedicated-kioku-schema
title: "Relocate Kioku projections into a dedicated Kioku schema"
kind: exec-plan
created_at: 2026-08-08T03:05:51Z
intention: "intention_01kzfn4qtae1nrezpr3jg55hjj"
---

# Relocate Kioku projections into a dedicated Kioku schema

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kioku currently stores its event streams in Kiroku and also places all of its projection
tables inside Kiroku's PostgreSQL schema. That makes a host application which already uses
Kiroku appear to own Kioku relations and couples Kioku SQL to Kiroku's namespace. After this
change, Kioku still shares the host's Kiroku event store, while every relation owned by Kioku
lives in a dedicated `kioku` PostgreSQL schema.

An operator can see the result with `psql`: the shared `kiroku` schema still contains the
Kiroku event-store relations, the `kioku` schema contains `memories`, `sessions`, `turns`,
`l1_watermarks`, `consolidation_decisions`, `scenes`, and `personas`, and none of the former
`kiroku.kioku_*` tables remain. Existing projection rows, indexes, constraints, ownership,
and grants survive the move. Memory, session, recall, embedding, and distillation behavior
remains unchanged after the application reconciles its Keiro read-model registry.


## Progress

- [x] Record the durable schema-ownership decision in a local ADR and add migration tests
      that demonstrate fresh-install, Kiroku-only adoption, upgrade, collision, and Codd-import
      behavior. (2026-08-07) ADR-10 is `docs/adr/projections-live-in-the-kioku-schema.md`, listed
      in `docs/adr/log.md`. Eight new cases live in `kioku-migrations/test/Main.hs`.
- [x] Add forward migration `0012-relocate-projections-to-kioku-schema.sql` and adapt the
      historical-migration test harness without rewriting migrations `0001` through `0011`.
      (2026-08-07) `withPrePartitionDatabase` now reverses the relocation first via
      `undoSchemaRelocation`; migrations `0001`–`0011` and the Codd fixture are untouched.
- [x] Centralize qualified Kioku relation names and update all production SQL and diagnostics.
      (2026-08-07) `kioku-core/src/Kioku/Database/Schema.hs` is the single source; every
      statement in the memory and session read models, recall, the capability probe, the
      embedding worker, L1/L2/L3, and the CLI's dimension-mismatch message goes through it.
- [x] Advance the memory, session, and turn read-model identities and test fail-closed startup
      followed by successful reconciliation. (2026-08-07) memory v3, session v5, turn v3;
      `kioku-core/test/Kioku/ReadModelReconcileSpec.hs` covers the stale outage, the repair, the
      idempotent second pass, and an old binary refused against reconciled rows.
- [x] Update current user documentation and package changelogs with the layout and rollout
      contract. (2026-08-07) New guide `docs/user/upgrading-to-the-kioku-schema.md`, linked from
      `README.md`, `getting-started.md`, `troubleshooting.md`, `upgrading-to-memory-spaces.md`, and
      `upgrading-to-pg-migrate.md`; `concepts.md`, `distillation.md`, `recall.md`, and
      `library-api.md` follow the new layout. Unreleased entries in the root, `kioku-migrations`,
      `kioku-core`, `kioku-migrate`, and `kioku-cli` changelogs.
- [x] Run the package and repository validation suites, prove the catalog result on a disposable
      database, and distill implementation discoveries into the ADR and this plan. (2026-08-07)
      Evidence below; the disposable database was created, proven, and dropped by name.


## Surprises & Discoveries

- Two migration counts in the current documentation were already stale before this change, and the
  audit for this plan surfaced them. `docs/user/getting-started.md` claimed "36 migrations
  (kiroku 8, keiro 18, kioku 10)" and `docs/user/upgrading-to-pg-migrate.md` described "the six
  post-pin migrations" ending at 36. The real pre-`0012` numbers were 39 (kiroku 8, keiro 20,
  kioku 11) with ten forward migrations in the Codd suffix. Both pages now say 40 / kiroku 8,
  keiro 20, kioku 12, which is what the ledger reports on a fresh install.
  Date: 2026-08-07

- GHC's `MultilineStrings` drops *both* boundary newlines, not just the leading one. A block
  written as

  ```haskell
  """
  SELECT one
  FROM
  """
    <> table
  ```

  yields `"SELECT one\nFROM"` — no trailing newline — so concatenating the table straight onto it
  produced `FROMT`. Every junction between a multiline SQL chunk and a relation constant therefore
  carries an explicit `" "` or `"\n"` separator rather than relying on the literal's own
  whitespace, which also survives reformatting.
  Date: 2026-08-07

- The ephemeral databases the test suites spin up only have pgvector when the process runs inside
  the project dev shell. Outside it, `cabal test` reports `no reachable pgvector on this cluster`
  and quietly skips every vector case — including the ones this change needed to see. Run
  `nix develop -c cabal test all`; a bare `cabal test all` passes without exercising the vector
  path at all.
  Date: 2026-08-07

- The plan assumed the Codd rehearsal recognized thirty historical rows "before applying the
  native suffix" and that `Kioku.Migrations.History.Codd` itself would need editing. It does not.
  The mapping tables in that module describe pre-cutover history only, and `0012` is a forward
  migration, so the module compiled unchanged. What had to move were the rehearsal's forward
  expectations in `kioku-migrations/test/Main.hs`: `expectedForwardMigrationIds` gained
  `kioku/0012-relocate-projections-to-kioku-schema`, the applied and already-applied counts went
  from 39 to 40, and `forwardMigrationEffectCountStatement` went from five effects to six by
  adding `to_regclass('kioku.memories') IS NOT NULL AND to_regclass('kiroku.kioku_memories') IS
  NULL`. The state validators in `Codd.hs` still assert the *historical* session registry at v3,
  which stays correct: that is what migration `0006` left in a pre-cutover database, and
  reconciliation — not a migration — is what advances it afterwards.
  Date: 2026-08-07

- `ORDER BY 1 COLLATE "C"` does not mean "order by the first output column under the C
  collation". PostgreSQL reads the `1` as an integer literal and rejects the clause:

  ```text
  ServerError "42804" "collations are not supported by type integer"
  ```

  The ordinal form of `ORDER BY` only accepts a bare integer, so a collation has to be attached
  to a named column instead — which inside a `UNION ALL` means wrapping the whole set operation
  in a subquery and ordering the wrapper. Both row-count statements in
  `kioku-migrations/test/Main.hs` do that.
  Date: 2026-08-07


## Decision Log

- Decision: Kioku will continue to use the host application's Kiroku event store, but Kioku's
  projection tables will live in the `kioku` PostgreSQL schema.
  Rationale: Event-store sharing is the intended integration boundary. Projection storage is
  owned by Kioku and does not belong in Kiroku's infrastructure namespace.
  Date: 2026-08-07

- Decision: Preserve the component-qualified migration composition `kiroku -> keiro -> kioku`.
  A Kiroku-only ledger is an adoption input; a host with additional pg-migrate components must
  compose and run its complete application plan rather than weaken unknown-migration checks.
  Rationale: Existing Kiroku rows have the same component-qualified identities and checksums, so
  they can be verified and skipped. Rejecting genuinely unknown ledger rows protects host history
  from accidentally running an incomplete plan.
  Date: 2026-08-07

- Decision: Rename the moved tables from `kioku.kioku_*` to short, ownership-local names such
  as `kioku.memories`; preserve existing constraint and index names.
  Rationale: The schema already supplies the Kioku namespace, so retaining the prefix would be
  redundant. PostgreSQL moves dependent indexes and constraints with their table, and retaining
  their names avoids unrelated catalog churn.
  Date: 2026-08-07

- Decision: Implement the relocation as a new transactional, forward-only migration and reject
  every database layout other than "all old tables and no new tables" or "all new tables and no
  old tables."
  Rationale: Released migrations and the Codd cutover fixture are immutable history. Strict
  preconditions make partial upgrades and name collisions fail before any ambiguous mutation.
  Date: 2026-08-07

- Decision: Fully qualify all Kioku projection relations in application SQL through one internal
  module instead of relying on `search_path`.
  Rationale: A Kiroku connection puts `kiroku` first and allows host-controlled extra schemas.
  Explicit qualification makes relation ownership deterministic without changing the host's
  connection contract.
  Date: 2026-08-07

- Decision: Advance memory read models from v2 to v3, session read models from v4 to v5, and
  turn read models from v2 to v3, with matching shape hashes.
  Rationale: Keiro stores logical name, version, shape hash, and status, but not a physical
  schema/table locator. The version change makes an old binary fail closed with
  `ReadModelStaleSchema` after migration instead of issuing SQL against missing old relations.
  Date: 2026-08-07

- Decision: Require a quiesced, migration-first deployment and do not create compatibility views.
  Rationale: Kioku performs inserts and upserts, so read-only aliases are insufficient and
  writable compatibility views would create a second migration surface. A short planned outage
  gives one authoritative physical layout.
  Date: 2026-08-07

- Decision: Do not move or reinstall the `vector` extension as part of this work.
  Rationale: PostgreSQL extensions are database-wide dependencies that may be shared by the host.
  Moving the memory table preserves its vector column and HNSW index by object identity; the
  extension's actual schema remains governed by the existing search-path contract.
  Date: 2026-08-07


## Outcomes & Retrospective

The relocation shipped as planned: Kioku still shares the host's Kiroku event store, and the seven
relations it owns now live in a `kioku` schema under short names. Nothing in the plan had to be
redesigned; the corrections were all local (see Surprises & Discoveries).

### What was built

Migration `kioku-migrations/migrations/0012-relocate-projections-to-kioku-schema.sql` creates the
schema, comments it as Kioku-owned and pg-migrate-managed, classifies the whole catalog in one
pass, and only then moves anything. `kioku-core/src/Kioku/Database/Schema.hs` is the single place
a relation name is written down; every statement in the memory and session read models, recall,
the capability probe, the embedding worker, L1/L2/L3, and the CLI diagnostic goes through it. The
three read-model families advanced to memory v3, session v5, and turn v3. ADR-10
(`docs/adr/projections-live-in-the-kioku-schema.md`) holds the durable rule, and
`docs/user/upgrading-to-the-kioku-schema.md` holds the operator contract.

### Evidence

Every suite passes inside the dev shell, which is where pgvector is reachable:

```text
$ nix develop -c cabal test all --test-show-details=direct
All 119 tests passed (0.01s)     # kioku-api
All 18 tests passed (13.45s)     # kioku-migrations
All 50 tests passed (3.36s)      # kioku-cli
All 210 tests passed (49.00s)    # kioku-core
```

`nix flake check` reports `checks.aarch64-darwin.treefmt` and `checks.aarch64-darwin.pre-commit`
green, and `git diff --check` prints nothing.

A disposable database named `kioku_schema_relocation_acceptance` was confirmed absent, created,
migrated, inspected, and dropped by name. `kioku-migrate up` applied 40 migrations ending with
`applied kioku/0012-relocate-projections-to-kioku-schema`, and the ledger reported
`applied=40 not_applied=0`. The catalog held exactly the intended seven relations and nothing
under the old names:

```text
 table_schema |       table_name
--------------+-------------------------
 kioku        | consolidation_decisions
 kioku        | l1_watermarks
 kioku        | memories
 kioku        | personas
 kioku        | scenes
 kioku        | sessions
 kioku        | turns
(7 rows)
```

The event store, the Keiro registry, and the pgvector objects were all where they belong —
`kiroku_events | kiroku_streams | keiro_registry | hnsw_index` all `t`, with the `vector`
extension still in schema `kiroku` — and all nineteen registry rows read memory v3 /
`kioku-memory-v3`, session v5 / `kioku-session-v5`, turn v3 / `kioku-turn-v3`, status `live`.

The upgrade-preservation proof reversed the relocation by hand, seeded one row per table
(including a 1536-dimension embedding), and re-applied the shipped migration file. Every table OID
is identical on both sides, and so are the index counts, constraint counts, owner, and row counts:

```text
=== BEFORE (old layout) ===
        relation         | table_oid | indexes | constraints |  owner
-------------------------+-----------+---------+-------------+---------
 consolidation_decisions |     18693 |       3 |           4 | shinzui
 l1_watermarks           |     18708 |       1 |           2 | shinzui
 memories                |     18298 |      11 |           3 | shinzui
 personas                |     18681 |       2 |           4 | shinzui
 scenes                  |     18668 |       2 |           4 | shinzui
 sessions                |     18315 |       8 |           3 | shinzui
 turns                   |     18328 |       2 |           3 | shinzui

=== AFTER (new layout) ===
        relation         | table_oid | indexes | constraints |  owner
-------------------------+-----------+---------+-------------+---------
 consolidation_decisions |     18693 |       3 |           4 | shinzui
 l1_watermarks           |     18708 |       1 |           2 | shinzui
 memories                |     18298 |      11 |           3 | shinzui
 personas                |     18681 |       2 |           4 | shinzui
 scenes                  |     18668 |       2 |           4 | shinzui
 sessions                |     18315 |       8 |           3 | shinzui
 turns                   |     18328 |       2 |           3 | shinzui

 hnsw_index_present | embedded_rows
--------------------+---------------
 t                  |             1
```

Every table's row count was 1 before and after. Re-applying the migration a third time left all
seven OIDs unchanged, and moving one table back by hand produced the refusal, verbatim:

```text
ERROR:  P0001: refusing to relocate Kioku projections: expected either 7 ordinary kiroku.kioku_*
tables with no kioku.* target relation, or no kiroku.kioku_* relation with 7 ordinary kioku.*
tables; found 1 source relation(s) of which 1 ordinary, and 6 target relation(s) of which 6
ordinary
```

### Lessons

The strict two-state machine paid for itself immediately. Writing the catalog classification as a
counting pass before any `ALTER` meant the four rejection tests were cheap to add and each one
could assert that the catalog was untouched afterwards — which is the property an operator
actually needs, and which a migration that moves tables as it discovers them cannot offer.

Bumping the read-model version for a move that changes no column felt wrong at first and turned
out to be the load-bearing part of the design. Keiro's registry records identity but not location,
so the version is the only channel through which "the tables are not where your binary thinks"
can be signalled. Testing the guard in *both* directions — new code against an old registry, old
code against a reconciled one — is what makes the migration-first deployment order enforced rather
than merely documented.

Two documentation numbers had drifted before this plan started. Auditing every mention of the
physical layout, rather than only the ones this change touched, is what caught them; a narrower
search-and-replace would have left them.


## Context and Orientation

This repository is a multi-package Haskell project. `kioku-core` contains Kioku's runtime and
read models, `kioku-migrations` composes database migrations, `kioku-migrate` is the migration
executable, and `kioku-cli` contains worker commands and diagnostics. Run all commands in this
plan from `/Users/shinzui/Keikaku/bokuno/kioku` unless a step says otherwise.

Three uses of the word "schema" must remain distinct:

1. A PostgreSQL schema is a namespace such as `kiroku`, `keiro`, or the proposed `kioku`.
2. A Keiro read-model schema identity is the logical name, integer version, and shape hash
   checked before a read. It does not record a PostgreSQL relation name.
3. A Kioku memory space is the application partition represented by a `memory_space_id` column.
   It is not a PostgreSQL schema. Moving tables into one `kioku` schema does not change memory
   space isolation.

Kiroku, registered in Mori as `mori://shinzui/kiroku`, owns the event store. Its connection
settings place its configured primary schema (normally `kiroku`) first in `search_path`, followed
by host-supplied `extraSearchPath` entries and `pg_catalog`. Kioku deliberately appends events to
that store, so adoption by an existing Kiroku host means both products use the same Kiroku event
tables and migration ledger entries. The relocation does not create another event store.

The migration engine is `mori://shinzui/pg-migrate`. Its globally unique migration identity is a
component name plus a component-local migration name. `Kioku.Migrations.kiokuMigrationPlan`
composes the `kiroku`, `keiro`, and `kioku` components in dependency order. On a database whose
ledger contains only the matching Kiroku prefix, `kioku-migrate up` verifies and skips those rows,
then applies missing Keiro and Kioku rows; numeric local names do not collide across components.
If the same ledger also contains a host application's component, the standalone executable's
default unknown-migration policy correctly rejects the incomplete three-component plan. Such a
host must import `Kioku.Migrations.kiokuMigrations`, compose Kiroku, Keiro, Kioku, and host
components into one complete application plan, and run that plan. This relocation must not make
unknown-migration handling permissive.

Keiro, registered as `mori://shinzui/keiro`, runs typed read-model queries and guards them with
the logical identity described above. Its `ReadModel` contract requires application SQL to name
its physical projection relations. `Keiro.Connection.qualifyTable` is the dependency API for
building a safely quoted, schema-qualified relation reference. Keiro's own registry remains in
its existing schema.

The current and target physical relation layout is:

| Current relation | Target relation | Purpose |
| --- | --- | --- |
| `kiroku.kioku_memories` | `kioku.memories` | memory projection, full-text search, and optional embedding |
| `kiroku.kioku_sessions` | `kioku.sessions` | session projection and continuation state |
| `kiroku.kioku_turns` | `kioku.turns` | ordered session turns |
| `kiroku.kioku_l1_watermarks` | `kioku.l1_watermarks` | L1 distillation idempotency |
| `kiroku.kioku_consolidation_decisions` | `kioku.consolidation_decisions` | L2 consolidation decisions |
| `kiroku.kioku_scenes` | `kioku.scenes` | L3 scene projections |
| `kiroku.kioku_personas` | `kioku.personas` | L3 persona projections |

`kioku-migrations/migrations/manifest` currently ends at
`0011-kioku-memory-space-partition.sql`. Migrations `0001` through `0011` and
`kioku-migrations/test/fixtures/pre-cutover-schema.sql` are released history and must not be
rewritten. The composed fresh-install plan currently has 39 entries: eight Kiroku migrations,
twenty Keiro migrations, and eleven Kioku migrations. The new Kioku migration makes 40. The
Codd import path in `kioku-migrations/src/Kioku/Migrations/History/Codd.hs` recognizes thirty
historical rows before applying the native suffix; its assertions and expected final count must
advance for `0012`.

The relocation is a metadata operation. `ALTER TABLE ... SET SCHEMA` retains table object IDs,
data, indexes, constraints, ownership, and table grants; `ALTER TABLE ... RENAME TO` retains those
attachments. None of the seven tables has a sequence, trigger, or foreign key that requires
separate movement. The migration must still create the `kioku` schema and operators may need to
grant the runtime role `USAGE` on it.

`kioku-migrations/test/Main.hs` owns fresh-install, manifest, Codd-import, and memory-space upgrade
tests. Its memory-space tests currently migrate fully, manually reverse migration `0011`, and
then apply `0011` again. Once `0012` is in the full plan, that setup must first move and rename
the seven relations back to the historical `kiroku.kioku_*` layout inside the disposable test
database. This preserves the historical migration while still testing it in its original context.

Active SQL for the seven relations is distributed across:

- `kioku-core/src/Kioku/Memory/ReadModel.hs`
- `kioku-core/src/Kioku/Session/ReadModel.hs`
- `kioku-core/src/Kioku/Recall.hs`
- `kioku-core/src/Kioku/Recall/Capability.hs`
- `kioku-core/src/Kioku/Memory/Embedding/Worker.hs`
- `kioku-core/src/Kioku/Distill/L1.hs`
- `kioku-core/src/Kioku/Distill/L2.hs`
- `kioku-core/src/Kioku/Distill/L3.hs`
- `kioku-cli/src/Kioku/Cli/Commands/Worker.hs`

Tests containing setup SQL or expected SQL text also need to follow the target layout. Search the
whole repository for `kiroku.kioku_` during implementation so no production query, assertion, or
current user instruction is missed. Completed ExecPlans and MasterPlans are historical records;
do not rewrite them merely to update names.

Memory read-model declarations in `Kioku.Memory.ReadModel` are v2 with shape hash
`kioku-memory-v2`. Session declarations in `Kioku.Session.ReadModel` are v4 with
`kioku-session-v4`, and turn declarations are v2 with `kioku-turn-v2`.
Their `ReadModel.schema` and `ReadModel.tableName` fields still identify `kiroku` plus the
corresponding `kioku_*` table; those fields must move with the physical relations even though
Keiro's registry does not persist them.
`Kioku.ReadModel.reconcileReadModelRegistry` advances existing registry entries to the compiled
identities. `kioku-migrate up` already calls that reconciliation after migrations; an application
embedding the migration library must call it explicitly before serving traffic.

The memory projection may contain a pgvector `vector` column and HNSW index. Historical migration
`0009-kioku-embedding-schema-heal.sql` detects the extension's installed schema because an
existing host may have installed it outside `kiroku`. Moving the table and index does not require
or authorize `ALTER EXTENSION`. Capability probes should inspect schema `kioku` and table
`memories`, while the existing `to_regtype('vector')` and runtime cast behavior continues to use
the configured Kiroku connection search path.

The relevant accepted local decisions are:

- [ADR-1: Kioku owns memory, not identity](../../docs/adr/kioku-owns-memory-not-identity.md)
  establishes Kioku's ownership boundary; a dedicated projection schema makes that boundary
  visible in the catalog.
- [ADR-6: The partition is a column, not a schema](../../docs/adr/the-partition-is-a-column-not-a-schema.md)
  rejects one PostgreSQL schema per memory space. It does not reject one package-owned `kioku`
  schema containing tables partitioned by `memory_space_id`.
- [ADR-2: Namespace is not a security boundary](../../docs/adr/namespace-is-not-a-security-boundary.md)
  means the new PostgreSQL namespace is an ownership and collision boundary, not an authorization
  mechanism.

No local ADR currently decides the physical schema for Kioku-owned projections. Implementation
must add the next available ADR number (currently ADR-10) and update `docs/adr/log.md`. Kiroku's
cross-repository `docs/adr/0003-dedicated-kiroku-schema.md` says Kiroku-owned relations belong in
the dedicated Kiroku schema while application projections may use other schemas. Its canonical
project reference is `mori://shinzui/kiroku`; Mori does not yet expose an artifact-level ADR URI,
so the canonical project URI plus that project-relative path is used pending ADR URI coverage.


## Plan of Work

### Milestone 1: specify and migrate the catalog layout

First record the ownership rule in a new accepted ADR under `docs/adr/` and add it to
`docs/adr/log.md`. The ADR must distinguish event-store sharing from projection ownership,
distinguish one Kioku package schema from per-memory-space schemas, document the mapping above,
and capture the migration-first deployment constraint.

Extend `kioku-migrations/test/Main.hs` before writing production SQL. Add catalog helpers which
identify the seven old and seven new relations, and tests for these cases:

- a fresh database ends with all seven target relations and no old relations;
- a database migrated through the Kiroku component alone adopts Kioku without replaying or
  changing the stored Kiroku prefix, then applies the missing Keiro and Kioku components;
- an upgrade fixture populated in the old layout retains representative rows and the table OIDs
  while moving to the target layout;
- a rerun against the fully new layout is a no-op;
- any mixed layout, missing expected source, or target-name collision aborts and leaves the whole
  catalog unchanged;
- the Codd import path includes the new migration and ends with 40 applied entries.

Create `kioku-migrations/migrations/0012-relocate-projections-to-kioku-schema.sql` through the
repository's `just new-migration` command so the manifest and generated embedding machinery stay
consistent. Make it one transaction-safe migration. It creates schema `kioku` if absent, counts
the exact old and new relation sets using `to_regclass` plus `pg_class.relkind`, and permits only
two states: seven ordinary source tables and zero occupied targets, or zero occupied sources and
seven ordinary target tables. In the first state it moves each table with `SET SCHEMA kioku` and
renames it to its short name. In the second state it does nothing. A view, materialized view,
foreign table, missing relation, or other mixed count raises an exception before a table is moved.
Add a schema comment identifying it as Kioku-owned and migration-managed. Preserve index and
constraint names and do not move the vector extension.

Update `kioku-migrations/src/Kioku/Migrations/History/Codd.hs` and its assertions for the new
forward migration and total of 40. Adapt the disposable memory-space rollback helper in
`kioku-migrations/test/Main.hs` to reverse the table renames and schema moves before it reconstructs
the pre-`0011` layout. Do not edit migrations `0001` through `0011` or the Codd fixture.

This milestone is complete when the migration package tests pass and direct catalog assertions
prove fresh install, upgrade preservation, idempotence, and atomic failure.

### Milestone 2: bind runtime SQL to Kioku's schema

Add internal module `kioku-core/src/Kioku/Database/Schema.hs` and list it in `other-modules` in
`kioku-core/kioku-core.cabal`. Import `Keiro.Connection.qualifyTable` and define these values:

```haskell
kiokuSchema :: Text
memoriesTable, sessionsTable, turnsTable :: Text
l1WatermarksTable, consolidationDecisionsTable :: Text
scenesTable, personasTable :: Text
```

`kiokuSchema` is `"kioku"`; every table value is the safely quoted, fully qualified result for
the corresponding short relation name. Keep this module internal so the database layout does not
become a new public API.

Replace literal projection relation names in every runtime file listed in Context with these
values, including inline projection writes, read-model queries, recall SQL, capability queries,
embedding worker claims and updates, all three distillation layers, and the CLI's embedding
dimension diagnostic. SQL fragments must remain parameterized; only trusted constant identifiers
are interpolated. Update tests which compare SQL text or directly seed/query projection rows.
For every `ReadModel` declaration, also set `schema = kiokuSchema` and set `tableName` to the
unqualified short name (`memories`, `sessions`, or `turns`) so Keiro metadata and
`qualifiedTableName` agree with the SQL constants.

Update capability probes from schema/table pair `kiroku`/`kioku_memories` to
`kioku`/`memories`. Preserve the existing pgvector type lookup and cast contract, and add or retain
coverage for both pgvector-present and pgvector-absent behavior.

Advance the identity constants in `Kioku.Memory.ReadModel` and `Kioku.Session.ReadModel`:

| Read-model family | Old identity | New identity |
| --- | --- | --- |
| memory | v2 / `kioku-memory-v2` | v3 / `kioku-memory-v3` |
| session | v4 / `kioku-session-v4` | v5 / `kioku-session-v5` |
| turn | v2 / `kioku-turn-v2` | v3 / `kioku-turn-v3` |

Extend `kioku-core/test/Kioku/ReadModelReconcileSpec.hs` so a registry at the previous identities
causes reads to fail with `ReadModelStaleSchema`, reconciliation advances every affected row, the
same reads then succeed against `kioku.*`, and a second reconciliation is idempotent. Update any
migration and Codd assertions which describe current identities, but do not add a SQL migration
that mutates Keiro registry rows: the existing post-migration reconciliation owns that step.

This milestone is complete when core, CLI, and migration executables build, focused tests pass,
and a repository search finds no active production reference to `kiroku.kioku_*`.

### Milestone 3: document and prove the operational cutover

Update current user documentation under `docs/user/`, including `README.md`,
`getting-started.md`, `concepts.md`, `distillation.md`, `recall.md`, `troubleshooting.md`,
`upgrading-to-memory-spaces.md`, `upgrading-to-pg-migrate.md`, and `library-api.md` wherever the
physical layout, diagnostic SQL, pgvector behavior, migration ordering, or registry reconciliation
is described. Do not rewrite completed plans or old release notes. Document that:

- Kioku shares the configured Kiroku event store but owns projections in `kioku`;
- a Kiroku-only pg-migrate ledger is adopted in place, while a host with its own ledger component
  must run one complete host-composed plan rather than standalone `kioku-migrate`;
- the migration must run while old writers are stopped, before new code starts;
- `kioku-migrate up` reconciles Keiro identities automatically;
- library embedders must call `reconcileReadModelRegistry` after applying migrations;
- the database role needs `USAGE ON SCHEMA kioku` as well as its retained table privileges;
- there are no compatibility views and binary-only rollback is unsafe after the migration commits.

Add Unreleased entries to the repository root `CHANGELOG.md` and the affected package changelogs:
`kioku-migrations/CHANGELOG.md`, `kioku-core/CHANGELOG.md`, and `kioku-migrate/CHANGELOG.md`.
Update `kioku-cli/CHANGELOG.md` too if that package records changed diagnostics separately.

Run focused and full validation. Finally, exercise a disposable, explicitly named PostgreSQL
database, inspect table names, rows, OIDs, indexes, registry versions, and event-store relations,
then clean it up only after validating the database name. Record command evidence and unexpected
findings in this plan, incorporate durable discoveries into the new ADR, and fill in Outcomes &
Retrospective. This milestone is complete when all checks pass and the catalog shows the intended
ownership boundary without any event-store relocation.


## Concrete Steps

All commands below run from `/Users/shinzui/Keikaku/bokuno/kioku`.

Before implementation, refresh dependency locations and reread the exact APIs and contracts used
by this change:

```bash
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
mori registry show shinzui/keiro --full
mori registry docs shinzui/keiro
```

Expected: Mori reports the registered source roots for `mori://shinzui/kiroku` and
`mori://shinzui/keiro`. If the local corpus changed since this plan was written, update Context
and the ADR before editing code.

Re-scan ADR numbering and current physical references:

```bash
rg -n '^#|^id:|^status:' docs/adr
rg -n 'kiroku\.kioku_|kioku-memory-v2|kioku-session-v4|kioku-turn-v2' \
  kioku-core kioku-cli kioku-migrate kioku-migrations docs/user
```

Expected: the first command shows accepted ADRs through ADR-9 unless another change has landed;
the second identifies all code, tests, migrations, and current documentation requiring triage.
Historical migrations and completed plans may legitimately retain old names.

After writing failing migration tests and the ADR, scaffold the migration through the project
command:

```bash
just new-migration relocate-projections-to-kioku-schema
```

Expected transcript includes a new manifest entry and file named:

```text
0012-relocate-projections-to-kioku-schema.sql
```

Implement the SQL and test adjustments, then run the focused migration suite:

```bash
nix develop -c cabal test kioku-migrations:test:kioku-migrations-test \
  --test-show-details=direct
```

Expected: the test suite exits zero. Its fresh-install and Codd cases report 40 composed migration
entries; its adoption case retains the Kiroku ledger prefix without replay; and the relocation
cases prove exact target layout, OID/data preservation, no-op rerun, and atomic rejection of mixed
layouts.

After centralizing relation names and updating runtime SQL, format and build the affected packages:

```bash
nix fmt
nix develop -c cabal build kioku-core kioku-cli kioku-migrate kioku-migrations
```

Expected: formatting completes without errors and Cabal reports `Build profile` followed by
successful builds for all four targets.

Run focused runtime suites:

```bash
nix develop -c cabal test kioku-core:test:kioku-test --test-show-details=direct
nix develop -c cabal test kioku-cli:test:kioku-cli-test --test-show-details=direct
```

Expected: both suites exit zero. Read-model reconciliation coverage observes the previous identity,
the expected stale-schema error, the new identity, successful query execution, and an idempotent
second reconciliation. Recall and embedding tests exercise the new qualified relation and both
pgvector capability branches.

Audit remaining old names. Review every result rather than requiring zero results globally, because
immutable migrations, the Codd fixture, changelog history, and completed plans are expected to
describe the old layout:

```bash
rg -n 'kiroku\.kioku_' \
  --glob '!docs/plans/**' \
  --glob '!docs/masterplans/**' \
  --glob '!kioku-migrations/migrations/000[1-9]-*.sql' \
  --glob '!kioku-migrations/migrations/001[01]-*.sql' \
  --glob '!kioku-migrations/test/fixtures/pre-cutover-schema.sql' \
  .
```

Expected: any remaining matches are deliberately historical assertions, changelog statements, or
upgrade-test setup. There must be no current runtime query or current operational instruction that
treats `kiroku.kioku_*` as the post-upgrade layout.

Run repository-wide gates:

```bash
nix develop -c cabal build all
nix develop -c cabal test all --test-show-details=direct
nix flake check
git diff --check
```

Expected: every command exits zero and `git diff --check` prints nothing.

For the final manual proof, first confirm the explicit disposable database does not already exist:

```bash
psql postgres -tAc \
  "SELECT datname FROM pg_database WHERE datname = 'kioku_schema_relocation_acceptance'"
```

Expected: no output. If it prints the name, stop and inspect ownership rather than deleting or
reusing it. Otherwise create and migrate it:

```bash
createdb kioku_schema_relocation_acceptance
cabal run kioku-migrate -- up \
  --database-url postgresql:///kioku_schema_relocation_acceptance
cabal run kioku-migrate -- status \
  --database-url postgresql:///kioku_schema_relocation_acceptance
```

Expected: `up` succeeds and reconciles the read-model registry; `status` reports all 40 migrations
applied with no pending or failed entry. Inspect the catalog:

```bash
psql kioku_schema_relocation_acceptance --set=ON_ERROR_STOP=1 <<'SQL'
SELECT table_schema, table_name
FROM information_schema.tables
WHERE (table_schema = 'kioku' AND table_name IN
       ('memories', 'sessions', 'turns', 'l1_watermarks',
        'consolidation_decisions', 'scenes', 'personas'))
   OR (table_schema = 'kiroku' AND table_name LIKE 'kioku\_%' ESCAPE '\')
ORDER BY table_schema, table_name;
SQL
```

Expected rows, and only these rows:

```text
kioku | consolidation_decisions
kioku | l1_watermarks
kioku | memories
kioku | personas
kioku | scenes
kioku | sessions
kioku | turns
```

Also run the upgrade-preservation SQL captured by the migration test against a disposable old
layout and retain its before/after OID and row-count transcript in Progress. Once validation is
complete, confirm the exact database name and remove only that disposable database:

```bash
acceptance_db=kioku_schema_relocation_acceptance
test "$acceptance_db" = "kioku_schema_relocation_acceptance"
dropdb "$acceptance_db"
```

Expected: all commands exit zero. Never use this cleanup sequence for a shared or user-supplied
database.


## Validation and Acceptance

Acceptance is behavioral and requires all of the following:

1. **Fresh install.** Applying the composed migration plan to an empty database succeeds with 40
   ledger entries. `to_regclass` finds exactly the seven `kioku.*` relations in the mapping table
   and returns null for every `kiroku.kioku_*` source. Kiroku event-store and Keiro registry
   relations remain in their original schemas.

2. **Existing-Kiroku adoption.** Given a database whose pg-migrate ledger contains the exact
   Kiroku component prefix, applying Kioku's composed plan does not re-execute or mutate those
   entries. It applies only missing Keiro and Kioku components and uses the existing Kiroku event
   relations. If an extra host component is present, standalone `kioku-migrate` rejects it as
   unknown and documentation directs the host to compose one complete application plan.

3. **Data-bearing upgrade.** Given a database at migration `0011` with a distinct row in each old
   relation, applying `0012` preserves every row, table OID, index, constraint, owner, and table
   grant while changing only table schema/name metadata. The `vector` column and HNSW index, when
   present, remain valid and the extension stays in its pre-upgrade schema.

4. **Strict migration state machine.** Applying the migration to the complete target layout is a
   successful no-op. Applying it to a mixed layout, to a layout missing one old table, or with any
   occupied target relation raises a descriptive exception. Because the migration is
   transactional, inspection after failure sees the exact pre-attempt layout and rows.

5. **Codd upgrade.** Importing the pinned thirty-row historical Codd cohort and applying the native
   suffix finishes with all 40 current migration identities. The fixture remains byte-for-byte
   unchanged; only forward expectations and code advance.

6. **Runtime behavior.** Memory creation/read, session creation/turn append/read, keyword recall,
   vector recall when available, embedding work claims and updates, and L1/L2/L3 distillation all
   succeed against `kioku.*`. Space-isolation tests continue proving that `memory_space_id`, not
   the PostgreSQL schema, is the partition boundary.

7. **Binary/registry guard.** After `0012` but before registry reconciliation, the new binary
   declaring memory v3, session v5, and turn v3 against the previous registry identities receives
   `ReadModelStaleSchema`. After `reconcileReadModelRegistry`, registry rows contain memory v3 /
   `kioku-memory-v3`, session v5 / `kioku-session-v5`, and turn v3 / `kioku-turn-v3`; new reads
   succeed and repeated reconciliation makes no further changes. Conversely, a representative
   read model declaring the previous identities fails stale against the reconciled rows, proving
   that an old binary fails closed instead of reaching the removed relations.

8. **pgvector compatibility.** With pgvector present, capability detection names
   `kioku.memories`, vector recall and embedding updates succeed, and the installed extension
   schema is unchanged. Without pgvector, migration and keyword recall still succeed and vector
   capability degrades exactly as before.

9. **Operational documentation.** A host already using Kiroku can follow the upgrade guide without
   creating a second event store: stop writers, back up, apply migrations, grant schema usage if
   needed, reconcile registry identities, deploy the new binary, and verify both namespaces.
   Documentation never suggests that the `kioku` schema is an authorization boundary or one
   schema per memory space.

The focused commands and the full `cabal build all`, `cabal test all`, `nix flake check`, and
`git diff --check` gates in Concrete Steps must all pass. Compilation alone is not acceptance;
the upgrade-preservation and manual catalog proofs are required.


## Idempotence and Recovery

The migration's only repeatable states are intentionally explicit. If all seven target relations
exist and none of the sources exists, rerunning the migration body changes nothing. If all seven
source relations exist and none of the targets exists, the transaction performs the complete
move. A partial or colliding state is never repaired heuristically; it aborts for operator
inspection. `CREATE SCHEMA IF NOT EXISTS kioku` is safe when a host already created an empty or
unrelated Kioku schema, but any conflicting target relation still blocks the migration.

`0012` must use PostgreSQL transactional DDL and must not opt out of the pg-migrate transaction.
If it fails, fix the precise catalog or permission cause and rerun `kioku-migrate up`; do not edit
the migration ledger, modify the released SQL after deployment, or manually mark it applied.
Tests and formatting are safe to repeat.

Before production execution, stop all application processes, workers, and migration processes
that can write these tables, take and verify a database backup, and confirm the migration role can
create/use schema `kioku` and alter all seven relations. After the move, confirm the runtime role
has `USAGE ON SCHEMA kioku`; table grants themselves move with each table. Only then start the new
binary and reconcile/read traffic.

Once `0012` commits, restarting the old binary is not a rollback: it still queries and writes
`kiroku.kioku_*`. There are no compatibility views. Before new writes occur, a rollback requires
restoring the verified pre-migration backup. After new writes occur, prefer a reviewed forward
repair that preserves them; any reverse move must be a new migration, not an edit to `0012` or the
ledger. Never move the pgvector extension as a recovery shortcut because the host may share it.

Disposable acceptance databases use the fixed name in Concrete Steps. Confirm that exact name is
absent before creation and equal before cleanup; never point the cleanup command at a host or
user-provided database.


## Interfaces and Dependencies

This change does not add or alter a public Kioku Haskell API. It changes internal SQL, migration
content, and declared read-model identities.

`kioku-migrations/migrations/0012-relocate-projections-to-kioku-schema.sql` is the stable database
interface. Its ID and contents become immutable once released. It depends only on PostgreSQL
transactional DDL and catalog lookup (`to_regclass` or an equivalently precise catalog query).
`mori://shinzui/pg-migrate` supplies component-qualified identities, ordered composition,
transaction/ledger handling, status, verification, and the authoring command. The library's
composed dependency order remains Kiroku, then Keiro, then Kioku. A host migration component may
follow those dependencies in its own complete plan; the standalone runner remains deliberately
strict about ledger components outside its declared plan.

The new internal module `kioku-core/src/Kioku/Database/Schema.hs` must provide:

```haskell
kiokuSchema :: Text
memoriesTable :: Text
sessionsTable :: Text
turnsTable :: Text
l1WatermarksTable :: Text
consolidationDecisionsTable :: Text
scenesTable :: Text
personasTable :: Text
```

Each table value is constructed with `Keiro.Connection.qualifyTable kiokuSchema <shortName>` and
is suitable for concatenating into trusted static SQL. `Kioku.Database.Schema` remains in
`other-modules`; callers outside `kioku-core` do not import it.

The public values in `Kioku.Memory.ReadModel` and `Kioku.Session.ReadModel` retain their existing
types such as `ReadModel query result`. Their embedded `version` and `shapeHash` fields advance as
listed in Milestone 2; their `schema` fields become `kiokuSchema` and their `tableName` fields
become the appropriate unqualified short names. `Kioku.ReadModel.reconcileReadModelRegistry`
retains its existing type and continues to derive desired identities from the same `ReadModel`
values used by queries.

Kiroku continues to provide the shared event store and connection settings. This plan does not
change stream identities, event codecs, event tables, the primary `kiroku` schema, or
`extraSearchPath`. Keiro continues to execute queries and store logical read-model registry rows;
it does not rewrite physical relation names. pgvector remains optional and in its installed schema.
No new external package, service, dependency bound, or network interface is introduced.
