---
id: 37
slug: scale-full-text-recall-and-embedding-backfill-by-memory-space
title: "Scale full-text recall and embedding backfill by memory space"
kind: exec-plan
created_at: 2026-08-20T13:57:30Z
intention: "intention_01m0fpyzp4e2kbnhyvcm00zd9t"
master_plan: "docs/masterplans/7-remediate-the-kioku-0-3-0-0-to-0-4-0-0-release-range-review.md"
---

# Scale full-text recall and embedding backfill by memory space

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Full-text recall and embedding recovery should cost roughly what one memory space owns, not what
every tenant in the database owns. After this change PostgreSQL can combine the mandatory
`memory_space_id` and namespace predicates with the full-text GIN index, and a settled embedding
backfill does not send unchanged memory content across the Hasql boundary merely to discard it in
Haskell.

The improvement is observable in PostgreSQL-backed tests. An `EXPLAIN` over a two-space corpus
uses the partition-aware index for a scoped keyword recall, while the production backfill
candidate statement returns zero rows after a successful pass and returns only rows whose vector
is missing or whose stored content hash is stale.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Add the next manifest-ordered, partition-aware full-text index migration with a safe fallback. (2026-08-21; migration 0013 and all 21 migration tests pass.)
- [x] Prove scoped recall correctness and index use with a two-space PostgreSQL fixture. (2026-08-21; all three FTS target plans name `kioku_memories_space_namespace_tsv_idx` and bind space, namespace, and `content_tsv` in the index condition.)
- [x] Move the embedding missing-or-stale predicate into both backfill candidate statements. (2026-08-21; both statements share one SQL fragment and the Haskell race check remains.)
- [x] Add candidate-transfer regressions, documentation, and changelogs. (2026-08-21; the regression observes the production statements and passes on a cluster without pgvector.)
- [x] Run and record the complete migration/core builds, suites, and diff checks. (2026-08-21; both packages build, 21 migration tests and 226 core tests pass, `nix fmt` and `git diff --check` are clean.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- PostgreSQL preferred the existing four-column scope B-tree for a one-row exact scope even with
  sequential scans disabled; that was correct for the tiny fixture but did not exercise the new
  GIN. Seeding same-scope rows with nonmatching content and comparing bitmap-capable paths made
  the intended access-path proof stable. Evidence: the focused `Recall.Target` suite passes with
  all three FTS plans naming `kioku_memories_space_namespace_tsv_idx`.
- The ephemeral PostgreSQL can install `btree_gin` but not `pgvector`. A skipped embedding test
  would leave the transfer regression unproved, so the test installs test-only nullable marker
  and hash columns when vector is absent and constructs the same settled row state directly.
  Evidence: `-p "settled rows do not cross"` passes and observes zero candidates after settling,
  then only the two stale identities after changing content.


## Decision Log

Record every decision made while working on the plan.

- Decision: Prefer a partial multicolumn GIN on `(memory_space_id, namespace, content_tsv)` when
  the `btree_gin` extension is available, and retain the old content-only index otherwise.
  Rationale: every full-text candidate query constrains the first two columns and active status.
  `btree_gin` lets one index enforce that access path, but an optional performance migration must
  not make an otherwise valid installation fail solely because the database role cannot install
  an extension.
  Date: 2026-08-20

- Decision: Calculate the current content hash in PostgreSQL when selecting backfill candidates.
  Rationale: the database already stores the content and can reject settled rows before returning
  their full text. The existing Haskell check remains useful for single-event race defense but is
  too late to protect startup scan bandwidth.
  Date: 2026-08-20

- Decision: Allocate the migration number at implementation time with `just new-migration`.
  Rationale: [the migration 0011 remediation](32-restore-host-search-path-after-kioku-migrations.md)
  or another concurrent plan may append a migration first. The manifest, not this document,
  owns the next ordinal.
  Date: 2026-08-20

- Decision: Make the candidate-transfer regression run without pgvector instead of treating the
  missing optional extension as a skip.
  Rationale: candidate eligibility depends only on embedding nullability and the stored content
  hash. Test-only columns can represent those facts and execute the exact production SELECTs,
  preserving evidence for the performance boundary without pretending the vector write path is
  available.
  Date: 2026-08-21


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Migration 0013 now replaces the content-only GIN with an active-only
`(memory_space_id, namespace, content_tsv)` GIN when `btree_gin` is available, and preserves the
old index when extension installation is unavailable. All three production FTS families use the
replacement in planner-scale two-space fixtures. Both production embedding scans now reject
settled content in PostgreSQL while retaining the Haskell race check, and the candidate-transfer
regression runs even without pgvector. The affected packages build; all 21 migration tests and
226 core tests pass; formatting and diff checks are clean. ADR-9 was updated because its original
“No new index” conclusion no longer described the multi-tenant FTS cost boundary. No other durable
architecture decision changed.


## Context and Orientation

`kioku-core/src/Kioku/Recall.hs` builds every full-text candidate query from one
`ftsCandidateQuerySql`. The generated SQL always filters active rows by `memory_space_id` and
namespace before applying `content_tsv @@ websearch_to_tsquery(...)`. Migration
`kioku-migrations/migrations/0001-kioku-base.sql`, however, created only
`kioku_memories_tsv_idx USING gin (content_tsv)`. On a shared database the index can therefore
produce candidates from every memory space and discard the unauthorized rows afterward.
`Kioku.Recall.explainFtsCandidates` and `kioku-core/test/Kioku/RecallTargetSpec.hs` already provide
the right test seam for inspecting all three target-specific plans.

`kioku-core/src/Kioku/Memory/Embedding/Worker.hs` has two startup/backfill statements: one scans
every space and one filters a requested space. Both select full `content`, `content_hash`, and an
`embedding IS NOT NULL` flag for every active row. `backfillMissingEmbeddings` then calculates
`sha256Hex content` and calls `shouldSkipEmbedding`. That avoids a remote embedding call but only
after PostgreSQL has transferred the full content to the worker. The event-driven
`embedMemoryContent` path reads one row by id and should retain its defensive Haskell check; this
plan changes the bulk scans.

The ordered manifest is `kioku-migrations/migrations/manifest`. The repository's
`just new-migration` command derives the next prefix and invokes the migration CLI; implementations
must not hand-create or renumber a migration. `kioku-migrations/migrations.lock` is the historical
Codd manifest and is not the native forward manifest to edit for this change.

[Namespace is not a security boundary](../adr/namespace-is-not-a-security-boundary.md) requires
the memory space to remain the outer predicate. [The partition is a column, not a
schema](../adr/the-partition-is-a-column-not-a-schema.md) rules out per-tenant schemas or tables.
[Each recall target gets its own statement](../adr/each-recall-target-gets-its-own-statement.md)
requires preserving the target-specific statements and their planner visibility.
[Projections live in the Kioku schema](../adr/projections-live-in-the-kioku-schema.md) fixes the
index's final table and schema identity. This plan changes only access paths and candidate
selection, so no new ADR is required.


## Plan of Work

### Milestone 1 — Scoped full-text recall has a scoped index

Run `just new-migration partition-aware-fts-index` and edit the generated SQL. Keep it append-only;
do not amend migrations 0001, 0011, or 0012. The migration runs against `kioku.memories` after the
projection relocation and attempts `CREATE EXTENSION IF NOT EXISTS btree_gin` inside a nested
PL/pgSQL exception block. If `btree_gin` is installed or can be installed, create an active-only
GIN index over `(memory_space_id, namespace, content_tsv)`. Only after that index exists, drop the
old single-column `kioku_memories_tsv_idx`. If the extension is unavailable, emit a notice and
leave the old index intact so correctness is unchanged and the installation remains usable.

Extend `kioku-migrations/test/Main.hs` to assert both branches structurally: a normal migrated
database with `btree_gin` has the partition-aware index and no old index, while the migration text
places extension failure handling before any old-index drop. Repeating the full migration plan
must remain a no-op. Do not use `CREATE INDEX CONCURRENTLY`; repository migrations run in a
transaction and the plan's retry guarantee is more important than online index construction.

Extend the PostgreSQL portion of `kioku-core/test/Kioku/RecallTargetSpec.hs`. Seed enough active
memories in two memory spaces and at least two namespaces to make the index competitive, run each
of the three `explainFtsCandidates` variants, and assert the plan references the new index and its
index condition carries the requested space and namespace. Keep the existing result-isolation
assertions so a planner assertion can never substitute for correctness. Reuse the suite's
`SET LOCAL enable_seqscan = off` access-path test. If the migration recorded the graceful
`btree_gin` fallback, print an explicit skipped-performance message and run only correctness
assertions; do not fail an installation for lacking an optional extension.

### Milestone 2 — Settled embedding rows do not cross the database boundary

In `Kioku.Memory.Embedding.Worker`, factor one SQL fragment used by both
`selectEmbeddingCandidatesStmt` and `selectEmbeddingCandidatesInSpaceStmt`:

```sql
embedding IS NULL
OR content_hash IS DISTINCT FROM encode(sha256(convert_to(content, 'UTF8')), 'hex')
```

Append that predicate after `status = 'active'` and, for the scoped form, after
`memory_space_id = $1`. Keep ordering by `created_at`. Retain `content_hash` and
`has_embedding` in `EmbeddingCandidate` for a defensive recheck until the candidate loop runs;
another writer may settle the row between selection and use. The SQL predicate is the transfer
boundary, while `shouldSkipEmbedding` is the race boundary.

Add a narrowly labelled test seam in the worker module that executes the same production
candidate statements but returns only the selected `(memory_space_id, memory_id)` identities.
Do not create a parallel query for the test: project identities from the actual decoded
candidates so the test observes precisely what the worker fetched. In
`kioku-core/test/Kioku/EmbeddingWorkerSpec.hs`, prove:

1. a row with no embedding is selected;
2. after a successful backfill, it is not selected by either all-space or matching-space scans;
3. changing `content` without refreshing `content_hash` selects it again;
4. a one-space scan never returns a stale row owned by another space.

The second assertion is the key regression: the old implementation returns the row from
PostgreSQL and only later skips its embedder call.

### Milestone 3 — Record and validate the operational change

Update `docs/user/recall.md` to describe the preferred composite index and its `btree_gin`
fallback. Update the worker sections of `docs/user/cli-reference.md` and
`docs/user/troubleshooting.md` to say startup backfill transfers only missing or stale active
rows. Add fixed notes to `kioku-migrations/CHANGELOG.md` and `kioku-core/CHANGELOG.md`, format, and
run the complete migration and core suites.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/kioku`.

Reconfirm the current manifest tail and SQL seams, then allocate the migration:

```bash
tail -n 3 kioku-migrations/migrations/manifest
rg -n 'kioku_memories_tsv_idx|ftsCandidateQuerySql|selectEmbeddingCandidates|shouldSkipEmbedding' \
  kioku-migrations kioku-core/src kioku-core/test
just new-migration partition-aware-fts-index
```

After editing, format and run focused suites:

```bash
nix fmt
cabal test kioku-migrations:kioku-migrations-test
cabal test kioku-core:kioku-test --test-options='-p "recall target"'
cabal test kioku-core:kioku-test --test-options='-p embedding'
```

Then validate the full affected packages and manifests:

```bash
cabal build kioku-migrations kioku-core
cabal test kioku-migrations:kioku-migrations-test
cabal test kioku-core:kioku-test
git diff --check
```

The focused embedding test should report zero production candidates after the settled pass and
one after content changes. The recall plan should name the newly generated index rather than
`kioku_memories_tsv_idx`.


## Validation and Acceptance

For a request authorized in `space_a` and one namespace, keyword recall returns no `space_b` row,
and `EXPLAIN` shows the partition-aware GIN for every full-text target shape. If `btree_gin` cannot
be installed, the migration succeeds, preserves the old GIN, and records the degraded access
path with a notice; application correctness is identical.

For a settled active memory whose `embedding` exists and whose `content_hash` equals PostgreSQL's
SHA-256 of current content, both production backfill scans return no candidate. A NULL embedding
or stale hash returns exactly that row, and `BackfillOneSpace` never fetches another space's full
content. Event-driven embedding still skips an already current row defensively.

The generated migration is present once in `kioku-migrations/migrations/manifest`; no released
migration is edited. Migration verification, repeat application, all recall-target tests, all
embedding tests, and the complete core suite pass.


## Idempotence and Recovery

The migration uses `IF NOT EXISTS`, drops the old index only after the replacement is present,
and remains safe to retry after a transaction rollback. If extension installation is forbidden,
leave the old index in place. Installing `btree_gin` later does not replay an already recorded
migration; add a new manifest-ordered repair migration or follow a separately reviewed DBA
maintenance procedure. Never delete an applied migration ledger row, rerun embedded SQL by hand,
or rewrite the released migration chain.

Candidate scans are read-only and repeatable. A failed or interrupted embedding pass leaves
unsettled rows eligible for its next run. Because the update already writes the vector and
content hash together, a successful row naturally disappears from later candidate scans.


## Interfaces and Dependencies

PostgreSQL supplies generated `tsvector`, GIN, `btree_gin`, `sha256(bytea)`, `convert_to`, and
`encode`; no new Haskell package is required. The migration must tolerate `btree_gin` absence but
the hash functions are part of the supported PostgreSQL baseline and are required by candidate
selection.

`Kioku.Recall` retains `ftsCandidateSql` and `explainFtsCandidates` unchanged. In
`Kioku.Memory.Embedding.Worker`, retain:

```haskell
backfillMissingEmbeddings
  :: (IOE :> es, Store :> es)
  => VectorCapability
  -> EmbeddingWorkerEnv
  -> EmbeddingBackfillScope
  -> Eff es Int

shouldSkipEmbedding :: Bool -> Maybe Text -> Text -> Bool
```

Add a test-seam function whose result exposes identities, not contents:

```haskell
selectEmbeddingCandidateIds
  :: Store :> es
  => EmbeddingBackfillScope
  -> Eff es [(MemorySpaceId, Text)]
```

It must execute the same `Statement`s used by `backfillMissingEmbeddings`; it is not a second
definition of candidate eligibility. No metric, public worker outcome, database table, or recall
API changes.
