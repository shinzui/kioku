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
- [x] Update memory/session/turn/watermark/decision/scene/persona projection statements.
  (2026-08-06 — every row record, encoder, decoder, and statement; query records replace
  positional tuples; public reads take a `MemorySpaceId` first.)
- [x] Bump read-model shape/version metadata and reconciliation behavior. (2026-08-06 — memory
  models to v2, sessions to v4, turns to v2. `reconcileReadModelRegistry` needed no change: it
  derives every identity from the same `ReadModel` values the queries use.)
- [x] Add real-PostgreSQL migration tests. (2026-08-06 — three cases in
  `kioku-migrations/test/Main.hs`: backfill from a genuinely pre-partition database, the
  drift guard, and idempotence. `nix develop -c cabal test kioku-migrations`: 10 passed.)
- [x] Add real-PostgreSQL isolation, replay, and query-plan tests. (2026-08-06 —
  `kioku-core/test/Kioku/SpaceIsolationSpec.hs`: six cases over two spaces holding identical
  namespaces, scopes, content, and derived artifact keys, including the reconcile pass and the
  `EXPLAIN (ANALYZE, BUFFERS)` plan shapes. `Kioku.SchemaSpec` covers the constraints,
  `Kioku.MemorySpaceSpec` the legacy replay path, `Kioku.ScopeIdentitySpec` the timer ids.)
- [x] Document deployment preflight, verification, and rollback limits. (2026-08-06 —
  `docs/user/upgrading-to-memory-spaces.md`, four package CHANGELOGs, and
  [ADR-6](../adr/the-partition-is-a-column-not-a-schema.md).)


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

- **A partition-leading index moved the query planner off the HNSW index, and the recall
  starvation test caught it.** Rebuilding `kioku_memories_scope_idx` as
  `kioku_memories_space_scope_idx` made the planner prefer an ordinary index scan of the in-scope
  rows plus a top-N sort over the approximate vector scan, on the very corpus
  `Kioku.RecallSqlSpec` seeds to reproduce filtered-ANN starvation. Measured by dropping each new
  index in turn against the seeded corpus:

  ```text
  BASELINE     ann=50 hnsw=False
  NO TYPE IDX  ann=50 hnsw=False
  NO NS IDX    ann=50 hnsw=False
  NO SCOPE IDX ann=0  hnsw=True
  ```

  The exact plan is not worse — it returned recall@10 = 1.0 in 21ms — but it means the case had
  stopped exercising the fallback it exists to prove. The sort's cost grows with the in-scope row
  count and the HNSW scan's does not, so the fix is the one the test's own comment asks for: a
  harsher corpus. 4000 in-scope rows is the first power-of-two step where the planner goes back to
  HNSW (starving at 4000, 8000, 16000 and 32000), and that is now `defaultStarvationCorpus`.

- **The recall harness's copy of the vector statement had already drifted, and its own Haddock had
  warned about exactly that.** `explainVectorStmt` is a hand-copy of
  `selectVectorCandidatesStmt`, and it kept its pre-partition `WHERE namespace = $2`. It reported
  an index scan whose `Index Cond` named the namespace alone — a plan no live query can produce.
  The new `Kioku.SpaceIsolationSpec` plan cases therefore carry a drift guard: each one also runs
  the public read it claims to describe and asserts the plan's own observed row count matches.

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

- Decision: Scene and persona timer ids and correlation ids fold in the memory space, even though
  plan 27 owns asynchronous work identity.
  Rationale: This plan is what creates the two-spaces-one-scope situation. Those timers are keyed
  by a scope, so leaving them alone would have shipped a schedule where keiro's `scheduleTimerTx`
  upsert treats one space's regeneration as a re-arming of the other's and silently drops one
  payload — a known-broken schedule, not a deferred improvement. Plan 25 set the precedent when it
  pulled the L1 timer payload's space forward for the same reason. Timers already scheduled keep
  their old ids and fire in the legacy space. Plan 27 still owns worker claims, dead-letter
  handling, and the filesystem layout.
  Date: 2026-08-06

- Decision: `fireL2SceneTimer` and `fireL3PersonaTimer` take a `MemoryContextProvider` and
  dead-letter on refusal, matching `fireL1Timer`.
  Rationale: Both regenerate from memories, which now requires a space, and both had to learn one
  from their payload anyway. Having two of the three timer handlers ask for a decision and the
  third not would be a difference with no reason behind it, and the divergence is exactly the kind
  a later reader has to re-derive.
  Date: 2026-08-06

- Decision: `defaultStarvationCorpus` grows from 2000 to 4000 in-scope rows rather than the
  starvation assertion being relaxed.
  Rationale: The partition-leading scope index moved the planner off HNSW at 2000 rows, so the
  case stopped reaching the exact fallback it exists to prove. The test's own comment anticipated
  this and named the remedy. Relaxing the assertion would have left the fallback untested while
  looking green.
  Date: 2026-08-06

- Decision: `MemoryRecord` — the public record `Kioku.Recall` returns — does not gain a
  `memorySpaceId` field.
  Rationale: A caller already knows the space; it is the argument they passed. Adding it would be
  a breaking change to every `kioku-api` consumer for a value that cannot differ from the one they
  supplied.
  Date: 2026-08-06


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Completed 2026-08-06.

**What exists now.** Seven read-model tables carry a non-null `memory_space_id`, every existing
row backfilled into `kioku_legacy`, and every statement that reads or writes them names the space
first — including the recursive supersession and session-chain walks, which follow bare ids with
no foreign key and would otherwise have walked out of their space. Scene and persona rows have
composite primary keys, so the scope-derived id two spaces both compute no longer makes one
space's upsert overwrite the other's row. Every public read takes a `MemorySpaceId`. Indexes led
by a namespace or a scope were rebuilt partition-first; indexes led by a globally unique id were
left alone.

**Against the original purpose.** The purpose was that PostgreSQL enforces the same boundary as
the domain, and that a real-database test can create identical namespaces and scopes in two spaces
and prove that reads, recall candidates, scenes, personas, and reconciliation never cross.
`Kioku.SpaceIsolationSpec` is that test: two spaces with the same namespace, the same entity
scope, the same content, the same focus, the same awaiting correlation key, and the same derived
scene and persona ids, with every public read asserted in both directions. The migration half is
proved on a database rolled back to its pre-partition shape and then run through the shipped
migration bytes, rather than on a mock of one.

**What this closed that was not asked for.** Plan 25 left a documented residual: a caller
presenting the id of a memory in another space could learn from an idempotent answer that the id
existed and whether it was active. Scoping the write-path lookup to the command's own space closed
it, and the answer is now byte-identical to the one an id that was never written gets. That
changed three assertions in `Kioku.MemorySpaceSpec` from `MemoryCommandRejected` to
`MemoryNotFound` — the refusal now arrives before the aggregate is reached, and the aggregate's
guard sits behind it unchanged.

**What is not done here.** Workspace mirrors under `.kioku/scenes` and `.kioku/persona` are still
keyed by scope alone, so two spaces sharing a scope still collide on one filename even though
their rows do not. Worker claims, dead-letter handling, and metrics attributes are plan 27's.
Recall targets are still a `MemoryScope` with two meanings, which is MasterPlan 6's.

**Lessons.** Two are worth carrying. The recall harness's hand-copy of the vector statement had
drifted the moment the partition landed, and its own Haddock had predicted precisely that failure
— a copy of a query is a copy that will be wrong, and the only defence that works is a guard
comparing it against the real thing, which the new plan cases now carry. And the starvation test
failing was more useful than it looked: it was not reporting a bug in the partition, it was
reporting that a partition-leading index changes which plan the planner picks, which is a durable
constraint on every future index in this schema and is now in
[ADR-6](../adr/the-partition-is-a-column-not-a-schema.md).

**Task-local notes.** `nix develop -c cabal test all`: 186 + 72 + 36 + 10 passing.
`okf validate docs/adr` reports `OK: 6 concepts`.


## Context and Orientation

The active SQL history is under `kioku-migrations/migrations/` and is embedded by
`kioku-migrations/src/Kioku/Migrations.hs`. Historical compatibility lives in
`Kioku.Migrations.History.Codd`; `docs/plans/22-remove-the-codd-import-bridge-from-kioku.md`
owns its eventual removal.

Memory projection statements live in `kioku-core/src/Kioku/Memory/ReadModel.hs`; session and
turn statements live in `kioku-core/src/Kioku/Session/ReadModel.hs`. Distillation tables and
statements are spread across `Kioku.Distill.L1`, `L2`, and `L3`. Read-model registration and
reconciliation are in `Kioku.ReadModel` and the migrate executable. Plan 25 supplies the domain
fields.

The ADRs plan 24 and plan 25 created are the ones this plan consumes:
[ADR-2](../adr/namespace-is-not-a-security-boundary.md) (namespace organizes, memory space
isolates), [ADR-3](../adr/legacy-data-lands-in-one-explicit-space.md) (legacy data lands in
`kioku_legacy`, and the migration must be a genuine backfill ending in a `NOT NULL` column), and
[ADR-4](../adr/the-aggregate-enforces-the-partition.md) (the write-side guard is in the aggregate,
with a named read-side gap this plan closes). Implementation added
[ADR-6](../adr/the-partition-is-a-column-not-a-schema.md) and amended ADR-3's status and ADR-4's
read-side paragraph.


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
nix develop -c cabal test kioku-core --test-options='-p "$0 ~ /memory space/ || $0 ~ /Schema/"'
nix develop -c cabal test all
```

The `-p` argument is a tasty *awk expression*, not an alternation: `-p "Schema|memory space"` is
rejected with `is not a valid pattern`. `$0` is the full test path, so the two clauses above
select the isolation groups and the schema constraints.

`kioku-migrate verify` needs a live database and so is a deployment step rather than a test step;
`docs/user/upgrading-to-memory-spaces.md` carries the runbook. The migration suite exercises the
same plan against an ephemeral PostgreSQL instead.

Observed on 2026-08-06:

```text
All  10 tests passed  (kioku-migrations)
All 186 tests passed  (kioku-core)
All  72 tests passed  (kioku-api)
All  36 tests passed  (kioku-cli)
```

The migration suite shows the pre-partition → current migration succeeding on a database rolled
back to its old shape, every row landing in `kioku_legacy`, and the derived-row drift guard
refusing a turn that disagrees with its session:

```text
the memory-space partition migration
  backfills every pre-partition row into the legacy space:              OK
  refuses to finish when a derived row disagrees with its session:      OK
  re-applying its body changes nothing:                                 OK
```


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

Each was checked on 2026-08-06 and holds, with one refinement.

The column is `NOT NULL` on all seven tables with a `CHECK (memory_space_id <> '')` beside it, so
"no space" has no spelling at all; `Kioku.SchemaSpec` asserts both rejections (`23502` and
`23514`). The backfill is proved against a database rolled back to its pre-partition shape, with
eight seeded rows including a turn whose session no longer exists; all eight land in
`kioku_legacy`. `Kioku.SpaceIsolationSpec` seeds two spaces sharing a namespace, an entity scope,
content, a focus, an awaiting correlation key, and both derived artifact ids, and asserts every
public memory, session, recall, scene, and persona read in both directions — the row it should see
and the row it must not. `reconcileReadModelRegistry` on a freshly migrated database reports every
model already current, and both spaces still read afterwards. The pg-migrate ledger carries the
migration once (39 applied, 0 pending, no unknowns), and the Codd cohort rehearsal still imports
30 rows and applies nine forward migrations rather than eight.

The **index criterion was refined** rather than met literally. The migration installs several
partition-first indexes per table and they overlap on their `(memory_space_id, namespace)` prefix,
so the planner chooses freely between them: the by-scope query is served by
`kioku_memories_space_namespace_idx`, not `…_space_scope_idx`, because the scope predicate is a
disjunction no index can answer and the namespace index also supplies the `ORDER BY`. Pinning a
winner would fail on a better plan. What is asserted instead, under `enable_seqscan = off`, is
that *some* partition-first index on the right table was used, that `memory_space_id` appears in
an `Index Cond` rather than a post-hoc filter, and that no plan falls back to a sequential scan of
every space's rows.


## Idempotence and Recovery

The migration is forward-only and must be tested from a database snapshot before production.
Within one transaction, a failed validation rolls back column/constraint edits — which is exactly
what the drift guard does, and the migration test asserts it by tampering with a turn's space
after a successful pass and re-running the body.

Every statement is idempotent: `ADD COLUMN IF NOT EXISTS`, a backfill that matches only rows still
`NULL`, constraints dropped before being re-added under stable names, and `CREATE INDEX IF NOT
EXISTS`. A deployment that failed part-way can simply be re-run; `re-applying its body changes
nothing` asserts that on a schema-and-index snapshot.

The non-null validation was not split into a staged migration, because no lock measurement
demanded it here. On a large installation it may: adding the `NOT NULL` column and rebuilding the
scene and persona primary keys takes `ACCESS EXCLUSIVE` for the duration, and the backfill
rewrites every row of the seven tables. The preflight section of
`docs/user/upgrading-to-memory-spaces.md` says so.

Application rollback is safe only while old code ignores additive columns and before new-space
rows are written; after multi-space writes begin, rolling back to unpartitioned code is unsafe and
must be refused operationally. That is stated in the upgrade guide as a deployment rule, not left
implicit.


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

As shipped, the query records are records with named fields rather than positional constructors,
so the partition cannot be transposed with the namespace beside it:

```haskell
data MemoriesByScopeQuery = MemoriesByScopeQuery
  { memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text)
  }
```

`Kioku.Partition` gained the one pair of functions that turns a `MemorySpaceId` into the column
and back — `memorySpaceColumn` and `memorySpaceParam` — so no module spells the encoding itself.
The decoder goes through `mkMemorySpaceId`, so a row holding a value no caller could have
constructed fails the read loudly rather than becoming a space id that compares equal to nothing.
