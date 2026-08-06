---
id: 26
slug: migrate-kioku-read-models-to-partitioned-memory-spaces
title: "Migrate Kioku read models to partitioned memory spaces"
kind: exec-plan
created_at: 2026-08-06T14:43:35Z
intention: "intention_01kzbreg94eh2stk5h5xwmkt8c"
master_plan: "docs/masterplans/5-portfolio-compatible-memory-isolation-and-authorization.md"
---

# Migrate Kioku read models to partitioned memory spaces

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, PostgreSQL enforces the same memory-space boundary as the domain. Every Kioku
read-model row is attributable to one space, every uniqueness/index/query identity starts with
that space where appropriate, and existing installations are backfilled into one explicit
legacy space. A real-database test can create identical namespaces and scopes in two spaces and
prove that reads, recall candidates, scenes, personas, and reconciliation never cross.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Inventory all current and concurrently planned Kioku tables, constraints, statements, and
  read-model registrations. (2026-08-06 — recorded below under "The inventory". Plans 8, 16 and
  23 have not landed, so there are no provenance or evidence tables to partition.)
- [x] Add an additive pg-migrate migration with a deterministic legacy-space backfill.
  (2026-08-06 — `kioku-migrations/migrations/0011-kioku-memory-space-partition.sql`.)
- [x] Rebuild uniqueness and lookup indexes with partition-first identities. (2026-08-06 — done
  inside the same migration; composite scene/persona primary keys, per-space scope uniqueness,
  eight partition-leading indexes.)
- [ ] Update memory/session/turn/watermark/decision/scene/persona projection statements.
- [ ] Bump read-model shape/version metadata and reconciliation behavior.
- [x] Add real-PostgreSQL migration tests. (2026-08-06 — three cases in
  `kioku-migrations/test/Main.hs`: backfill from a genuinely pre-partition database, the
  drift guard, and idempotence. `nix develop -c cabal test kioku-migrations`: 10 passed.)
- [ ] Add real-PostgreSQL isolation, replay, and query-plan tests.
- [ ] Document deployment preflight, verification, and rollback limits.


### The inventory

Seven tables hold partitioned data. Their pre-migration identities, and what the migration did
to each:

| Table | Primary key | Scope/session-derived identities rebuilt |
| --- | --- | --- |
| `kioku_memories` | `memory_id` (globally unique, unchanged) | `scope_idx`, `type_idx` |
| `kioku_sessions` | `session_id` (globally unique, unchanged) | `scope_idx`, `namespace_started_idx`, `namespace_focus_idx`, `awaiting_corr_idx` |
| `kioku_turns` | `turn_id`, `UNIQUE (session_id, turn_index)` (both unchanged) | none |
| `kioku_l1_watermarks` | `session_id` (unchanged) | none |
| `kioku_consolidation_decisions` | `decision_id` (unchanged) | `scope_idx` |
| `kioku_scenes` | `scene_id` → `(memory_space_id, scene_id)` | `UNIQUE (namespace, scope_kind, scope_ref, scene_key)`, `scope_idx` (dropped) |
| `kioku_personas` | `persona_id` → `(memory_space_id, persona_id)` | `UNIQUE (namespace, scope_kind, scope_ref)` |


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Kioku has moved its active migration chain to `kioku-migrations/migrations/`; plan 22 still
  tracks removal of the historical Codd import bridge. New schema work must use pg-migrate and
  must not add another Codd-era SQL file.
- Scenes, personas, consolidation decisions, and L1 watermarks are keyed by namespace/scope or
  session today. Adding a partition only to memories would leave derived artifacts able to
  collide or leak.

- **The scene and persona primary keys were the sharp edge, and the collision was silent.**
  `sceneRowId` and `personaRowId` derive the key from the namespace and scope alone. Two spaces
  are *supposed* to be able to use the same namespace and scope, so those keys collide across
  spaces — and because the upserts are `ON CONFLICT (scene_id) DO UPDATE`, the second space's
  scene would have overwritten the first space's row and kept the first space's scope columns.
  Adding a per-space unique constraint alone would not have caught it: there would only ever
  have been one row. The primary key itself had to become `(memory_space_id, scene_id)`.

- **Only two tables needed a derivation rather than a constant.** Every row that exists before
  the migration predates memory spaces, so the backfill is `kioku_legacy` everywhere. Turns and
  L1 watermarks are still derived from their parent session rather than assumed, because the
  rule "a derived row lives in its session's space" is the one that must hold for every future
  write, and stating it as SQL is what makes a future violation loud. The validation block
  proves it and aborts the migration if it does not hold:

  ```text
  refuses to finish when a derived row disagrees with its session: OK (2.67s)
  ```


## Decision Log

Record every decision made while working on the plan.

- Decision: Backfill absence to one named legacy space, then make the column non-null.
  Rationale: `NULL` must never mean unrestricted or “all spaces.”
  Date: 2026-08-06

- Decision: Add partition predicates to tables and statements even when the current primary key
  is globally unique.
  Rationale: Defense in depth prevents a caller with a leaked ID from bypassing its authorized
  space and makes query review mechanical.
  Date: 2026-08-06

- Decision: Migration order is compatible with plan 22's bridge removal and with plans 8/16's
  future provenance/evidence tables.
  Rationale: A new migration must extend the active pg-migrate history exactly once and avoid
  schema churn when the security initiative lands.
  Date: 2026-08-06

- Decision: Scene and persona rows get a composite `(memory_space_id, <id>)` primary key; their
  scope-derived id strings are left exactly as they are.
  Rationale: Re-deriving the ids to fold the space in would rewrite every scene and persona row
  and every plaintext mirror filename, for a purely cosmetic gain, and it would step on plan 27,
  which owns the workspace artifact layout. The composite key makes the cross-space collision
  impossible without touching a single stored id.
  Date: 2026-08-06

- Decision: Indexes led by a globally unique id — `memory_id`, `session_id`,
  `parent_session_id`, `supersedes`, `superseded_by`, `content_hash` — keep their existing
  shape; only indexes led by a namespace or a scope are rebuilt partition-first.
  Rationale: The Decision Log's defense-in-depth rule is about *predicates*, and those
  statements all gain one. An id is already selective enough that prefixing its index with the
  space would buy no rows and cost a write on every insert. Migration 0008 dropped
  `kioku_turns_session_idx` for exactly this reason, and the same argument retires
  `kioku_scenes_scope_idx` here, now that it is a strict prefix of the per-space unique index.
  Date: 2026-08-06

- Decision: Read functions take a `MemorySpaceId`, not a `MemoryAccessContext`.
  Rationale: The plan's own interface contract is `memorySpaceId :: MemorySpaceId` on the query
  records, and the read functions return `Either ReadModelError`. Threading a permission denial
  through them would mean a new error type on roughly two dozen functions and every call site,
  which buys a check the host has already made: `authorizeMemoryAccess` mints a context only for
  permissions it verified, and the caller passes `memoryContextSpace` of that context. The
  schema is what enforces the boundary; the context is what decides which space to name.
  Date: 2026-08-06


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

No implementation has started. Completion means both migrated legacy data and freshly written
data pass cross-space isolation tests in a real PostgreSQL instance.


## Context and Orientation

The active SQL history is under `kioku-migrations/migrations/` and is embedded by
`kioku-migrations/src/Kioku/Migrations.hs`. Historical compatibility lives in
`Kioku.Migrations.History.Codd`; `docs/plans/22-remove-the-codd-import-bridge-from-kioku.md`
owns its eventual removal.

Memory projection statements live in `kioku-core/src/Kioku/Memory/ReadModel.hs`; session and
turn statements live in `kioku-core/src/Kioku/Session/ReadModel.hs`. Distillation tables and
statements are spread across `Kioku.Distill.L1`, `L2`, and `L3`. Read-model registration and
reconciliation are in `Kioku.ReadModel` and the migrate executable. Plan 25 supplies the domain
fields. No local ADR beyond those created by plan 24 is expected.


## Plan of Work

### Milestone 1: inventory and migration design

Build a table/statement matrix before editing. It must include `kioku_memories`,
`kioku_sessions`, `kioku_turns`, `kioku_l1_watermarks`, `kioku_consolidation_decisions`,
`kioku_scenes`, and `kioku_personas`, plus provenance/evidence tables if plans 8 or 16 have
landed. Record every unique constraint and index whose identity contains namespace, scope,
session, or artifact key.

Add the next numbered file in `kioku-migrations/migrations/`. Introduce `memory_space_id` in a
safe sequence: nullable column, deterministic backfill, validation query, non-null constraint,
then indexes/constraints. Turns inherit space from their parent session; derived artifacts use
the source context. Abort migration if orphan rows make that derivation ambiguous.

### Milestone 2: projection and query conversion

Update row records, encoders, decoders, insert/upsert/update/select/delete statements, and
reconciliation identities. Every lookup accepting an ID must also accept memory space unless it
is an internal projection step whose event already proves the same space. Prefer composite
query records over positional text tuples so partition order is visible.

For namespace/scope indexes, put `memory_space_id` before namespace and scope columns. Update
scene/persona uniqueness to allow identical scope keys in different spaces. Update watermark and
decision uniqueness so sessions from different spaces cannot collide even under legacy IDs.

### Milestone 3: migration and isolation proof

Extend migration test support to populate a pre-migration database, apply the new migration,
and assert every row is in the configured legacy space. Replay events and reconcile all read
models. Add two-space fixtures with identical namespace, scope, content, and derived-artifact
keys. Assert every public read returns only its requested space.

Run `EXPLAIN (ANALYZE, BUFFERS)` fixtures for bounded read/recall shapes and assert the intended
partition-leading index is available. Exact cost numbers are not golden; plan shape and absence
of an unbounded cross-space scan are.


## Concrete Steps

Run from the repository root:

```bash
nix develop -c cabal test kioku-migrations
nix develop -c cabal test kioku-core --test-options='-p "Schema|read model|memory space"'
nix develop -c cabal run kioku-migrate -- verify
nix develop -c cabal test all
```

The migration suite must show pre-partition → current migration success, full reconciliation,
and zero rows with a null or unexpected memory-space ID.


## Validation and Acceptance

Acceptance requires:

- Every listed table has a non-null `memory_space_id`; no active query interprets null as all.
- Pre-migration fixtures land only in the configured legacy space and produce the same visible
  memories/sessions after reconciliation.
- Identical namespace/scope/scene/persona keys coexist in two spaces.
- Reads by memory/session/artifact ID include a space predicate and deny a mismatched space.
- All partitioned query families have appropriate leading indexes and bounded limits.
- The migration is represented once in pg-migrate history and plan 22's Codd-history tests remain
  green until that bridge is removed.


## Idempotence and Recovery

The migration is forward-only and must be tested from a database snapshot before production.
Within one transaction, a failed validation rolls back column/constraint edits. On a large table,
split the non-null validation into an online-safe staged migration if lock measurements demand it
and record that discovery here. Application rollback is safe only while old code ignores additive
columns and before new-space rows are written; after multi-space writes begin, rolling back to
unpartitioned code is unsafe and must be refused operationally.


## Interfaces and Dependencies

Every relevant query record gains `memorySpaceId :: MemorySpaceId`. Representative SQL must be
structurally equivalent to:

```sql
SELECT ...
FROM kiroku.kioku_memories
WHERE memory_space_id = $1
  AND namespace = $2
  AND ...
LIMIT $n;
```

Use `pg-migrate` through `kioku-migrations`; do not edit applied migration files. Plan 25 owns
the domain type, plan 27 audits asynchronous paths, and plans 8/16 must add the same column if
they land first.
