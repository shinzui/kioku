---
id: 29
slug: enforce-exact-and-namespace-wide-recall-in-postgresql
title: "Enforce exact and namespace-wide recall in PostgreSQL"
kind: exec-plan
created_at: 2026-08-06T14:43:35Z
intention: "intention_01kzbrejmhefk8jrjv3m7twqdv"
master_plan: "docs/masterplans/6-explicit-and-safe-recall-boundaries.md"
---

# Enforce exact and namespace-wide recall in PostgreSQL

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, PostgreSQL implements each explicit recall target with a visibly different,
partition-first predicate. Exact global, exact entity, and namespace-wide recall return the
intended rows for keyword, embedding, and hybrid strategies while preserving filtered-ANN
candidate expansion and exact FTS fallback. Real-database tests prove that neither target can
cross a memory-space boundary.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Define one target-to-predicate mapping used by FTS and vector planning. (2026-08-07:
      `ScopeBound` in `kioku-core/src/Kioku/Recall.hs` has one constructor per target;
      `resolveRecall` is now total and is the only mapping.)
- [x] Split or strongly type exact-scope and namespace-wide Hasql statements. (2026-08-07: nine
      statements — three channels x three bounds — generated from one template per channel and one
      `ScopeClause` per bound. `BoundedCandidateParams` carries no scope columns at all and
      `EntityCandidateParams` carries two non-nullable ones, so no parameter assignment can widen
      a bound.)
- [x] Preserve vector candidate expansion and exact FTS fallback behavior. (2026-08-07: the two
      passes are unchanged and now dispatch per family; `Recall.Sql` starvation and
      healthy-scope cases still pass.)
- [x] Delete `RecallExactGlobalUnsupported`. (2026-08-07: exact global executes; `RecallError` is
      down to the legacy space mismatch.)
- [x] Remove the harness's copy of the vector SQL. (2026-08-07:
      `Kioku.Recall.explainVectorAnnCandidates` explains the shipping statement itself.)
- [x] Add partition-leading indexes for each bounded query shape. (2026-08-07: measured — no new
      index is needed. `kioku_memories_space_scope_idx` already serves all three bounds; see
      Surprises & Discoveries for the captured `Index Cond` lines, and the Decision Log for why a
      redundant partial index was rejected. No migration was written.)
- [x] Extend the recall harness with two-space and exact-global fixtures. (2026-08-07:
      `Kioku.RecallTargetSpec` seeds two spaces holding byte-identical rows;
      `Kioku.RecallHarness` gained `exactEntityStarvationCorpus`.)
- [x] Add query-plan tests. (2026-08-07: `Recall.Target`'s third case asserts every bound's plan
      is partition-led and that the three bounds are three distinguishable plans.)
- [x] Run the full PostgreSQL suite. (2026-08-07: `cabal test all` — 208 + 119 + 38 + 10 tests,
      all passing, against real ephemeral PostgreSQL clusters with pgvector reachable.)
- [x] Document SQL semantics and operational verification. (2026-08-07: `docs/user/recall.md`
      gained "How a target reaches SQL"; `docs/user/library-api.md` and
      `docs/user/upgrading-to-memory-spaces.md` no longer describe the refusal;
      `kioku-core/CHANGELOG.md` records the seam changes.)
- [x] Distill into ADRs and update the MasterPlan. (2026-08-07:
      [ADR-9](../adr/each-recall-target-gets-its-own-statement.md) created, ADR-8's intermediate
      state closed, `docs/adr/log.md` updated, MasterPlan 6 marks EP-2 complete.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Current SQL treats null scope parameters as “omit the scope filter.” That representation
  cannot distinguish exact global-bucket recall from namespace-wide recall.
- The existing recall harness and plan 19 fix already protect against filtered ANN starvation.
  A query rewrite that removes candidate expansion could reintroduce that bug while passing
  simple semantic tests.

- **The harness was carrying its own copy of the vector SQL, and the split would have made that
  copy wrong a third time.** `Kioku.RecallHarness.explainVectorStmt` restated the statement
  verbatim so it could `EXPLAIN` it; with three statement families it would have had to restate
  three, and its own Haddock records two occasions when the copy silently drifted and reported a
  plan no live query can produce. The copy is gone: `Kioku.Recall.explainVectorAnnCandidates`
  builds the `EXPLAIN` from the same SQL text and the same parameters as the statement it
  describes, and the harness calls it. Net effect on the module's exports is a reduction — five
  seams became four.

- **`resolveRecall` became total, which means `recall` can no longer fail.** Once every target has
  a predicate, the only inhabitant of `RecallError` is `RecallSpaceMismatch`, which only
  `legacyRecall` can produce. `recall` keeps its `Either` anyway; see the Decision Log.

- **The milestone asking for new indexes turned out to need none.** All three bounds are already
  served by `kioku_memories_space_scope_idx` — the partition-first index migration 0011 installed
  — because a btree index answers `IS NULL` as an index condition rather than as a filter. With
  `enable_seqscan = off` on the two-space fixture, the three exact-vector plans are:

  ```text
  Index Scan using kioku_memories_space_scope_idx on kioku_memories
    Index Cond: ((memory_space_id = 'space_test') AND (namespace = 'mori')
                 AND (scope_kind IS NULL) AND (scope_ref IS NULL))
  Index Scan using kioku_memories_space_scope_idx on kioku_memories
    Index Cond: ((memory_space_id = 'space_test') AND (namespace = 'mori')
                 AND (scope_kind = 'repo') AND (scope_ref = 'web'))
  Index Scan using kioku_memories_space_scope_idx on kioku_memories
    Index Cond: ((memory_space_id = 'space_test') AND (namespace = 'mori'))
  ```

  Exact global is a full four-column match, exact entity is a full four-column match, and
  namespace-wide is a two-column prefix. Every one of them leads with `memory_space_id`. The
  keyword channel produces the same three access paths.


## Decision Log

Record every decision made while working on the plan.

- Decision: Prefer separate exact-scope and namespace-wide statements over a nullable boolean
  predicate.
  Rationale: The security-relevant widening is visible in statement names, parameters, and plans;
  null no longer carries two meanings.
  Date: 2026-08-06

- Decision: `memory_space_id` is the first mandatory filter in every statement and index family.
  Rationale: Namespace-wide means all scopes in one space, never all spaces.
  Date: 2026-08-06

- Decision: Preserve recall ranking/fallback semantics unless a named test demonstrates a needed
  change.
  Rationale: This initiative clarifies boundaries, not ranking quality.
  Date: 2026-08-06

- Decision: Realize "separate exact and namespace-wide statements" as three SQL shapes, not two.
  Rationale: The plan's Interfaces sketch proposed `ExactRecallSql` carrying a `MemoryScope`, but
  a Hasql encoder for a `MemoryScope` needs nullable scope parameters again for the global case —
  which reintroduces the very representation this plan removes, one layer down. Three shapes
  (`scope_kind IS NULL AND scope_ref IS NULL`, `scope_kind = $4 AND scope_ref = $5`, and no scope
  clause at all) each have a non-nullable parameter record, and the choice between them is a total
  `case` over `ScopeBound`.
  Date: 2026-08-07

- Decision: Keep `recall :: ... -> Eff es (Either RecallError [RecallHit])` even though it can no
  longer return `Left`.
  Rationale: Collapsing it to a total function is a public signature change at every call site,
  including `Kioku.Distill.L1`'s `L1RecallRefused` channel that ADR-8 records. That is consumer
  migration work and belongs with `docs/plans/30-migrate-recall-consumers-to-explicit-targets.md`,
  not with the SQL split. `resolveRecall` itself did become total, because it is an internal seam
  and an `Either` it can never inhabit is a lie a test has to pattern-match on.
  Date: 2026-08-07

- Decision: Ship no index migration. `kioku_memories_space_scope_idx` already serves all three
  bounds.
  Rationale: A dedicated partial index for the global bucket — `(memory_space_id, namespace)
  WHERE status = 'active' AND scope_kind IS NULL AND scope_ref IS NULL` — would be smaller but no
  more selective as an access path, because the existing index already answers `scope_kind IS
  NULL` as an index condition rather than as a filter (measured; see Surprises & Discoveries).
  Adding it would buy nothing and cost a write on every insert, which is exactly the redundancy
  migrations 0008 and 0011 removed twice (`kioku_turns_session_idx`, `kioku_scenes_scope_idx`) and
  that `Kioku.SchemaSpec` asserts stays removed. The plan asked for "add or replace indexes"; the
  honest answer to a measured question was "neither".
  Date: 2026-08-07

- Decision: Prove the exact-scope family's filtered-ANN fallback with one new heavy corpus, not
  three.
  Rationale: The two-pass mechanism is shared code dispatched per statement family, so the
  realistic family-local regression is a dropped `OFFSET 0` fence. `exactEntityStarvationCorpus`
  puts 4000 answers and 2000 nearer decoys under sibling entity scopes in one namespace, which is
  both the shape plan 19 was found in and the narrowest the exact family can be pushed. Each such
  corpus costs ~8s of suite time on its own ephemeral cluster; the exact-global family's two
  passes are covered by the target matrix's small fixture, where the fallback fires by
  construction and must return exactly the bucket.
  Date: 2026-08-07

- Decision: Prove the strategy dimension of the semantic matrix at the channel level (FTS, vector,
  and their fusion) rather than by calling `recall` with an embedding model.
  Rationale: `Baikai.Embedding.EmbeddingModel` is an HTTP endpoint — `embedWithRetry` makes a
  network call — so an `embedding` or `hybrid` recall cannot run in this suite without either a
  live embedding service or a stub HTTP server. The channels are where the target predicate lives;
  hybrid adds only `fuseRecallCandidates`, which is pure and cannot reintroduce a row that neither
  channel returned. The keyword row of the matrix additionally goes through the public `recall`,
  which needs no embedding, so the full entry point is still proven for all three targets.
  Date: 2026-08-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Completed 2026-08-07.

**What was achieved.** Recall's three targets compile to three SQL scope clauses across nine
statements — full text, the approximate vector pass and the exact vector pass, each in an
exact-global, exact-entity and namespace-wide family. Exact global recall executes for the first
time and returns the global bucket rather than the whole namespace;
`RecallExactGlobalUnsupported` is deleted and `resolveRecall` is total. Every statement leads with
`memory_space_id`, and `Kioku.RecallTargetSpec` proves against a real database that the nine
target/strategy combinations return exactly the rows their target names, that the same three
targets under a second space's context return that space's byte-identical twins, and that no case
crosses the boundary. The filtered-ANN expansion and exact fallback are unchanged and are now
proven on the exact-scope family as well as the namespace-wide one.

**What was measured rather than built.** The index milestone. All three bounds are already served
by `kioku_memories_space_scope_idx`, so no migration was written; the captured `Index Cond` lines
are in Surprises & Discoveries and the reasoning is in ADR-9.

**Two lessons worth carrying.**

The first is that a representation defect does not stay in one layer. This plan existed because
NULL meant two things in SQL; EP-1 had already had to reject the same shape on the wire (two tags
separated only by whether `scope_kind` was present), and the plan's own Interfaces sketch would
have reintroduced it a third time in the Hasql encoder for `ExactRecallSql`. The fix each time was
the same: give each meaning its own name in the artifact a reader actually sees.

The second is that an instrument that restates the thing it measures will drift, and the fix is to
delete the restatement rather than to check it. The harness's copy of the vector SQL had been
wrong twice before this plan and would have had to become three copies; removing it *reduced*
`Kioku.Recall`'s exported test seams from five to four.

**What remains.** Nothing in this plan. The CLI still has no grammar for the exact global bucket,
which is `docs/plans/30-migrate-recall-consumers-to-explicit-targets.md`.


## Context and Orientation

`kioku-core/src/Kioku/Recall.hs` contains FTS/vector statements, execution planning, reciprocal
rank fusion, capability fallback, and query entry points. `Kioku.Recall.Capability` detects
pgvector availability. `kioku-core/test/Kioku/RecallHarness.hs` builds real PostgreSQL fixtures;
`Kioku.RecallSqlSpec` and `Kioku.RecallSpec` cover SQL and pure planning.

The completed `docs/plans/18-build-a-recall-quality-harness-that-reproduces-filtered-ann-starvation.md`
and `docs/plans/19-fix-filtered-ann-starvation-in-vector-recall.md` are regression constraints.
Plans 26 and 28 supply the partitioned schema and target type.

Three local ADRs matter here.
[ADR-8](../adr/an-explicit-recall-target-replaces-the-overloaded-scope.md) is the vocabulary this
plan makes executable; it explicitly hands this plan the decision that exact and namespace-wide
recall get separate statements rather than one statement with a nullable predicate.
[ADR-2](../adr/namespace-is-not-a-security-boundary.md) is why `memory_space_id` is mandatory and
first in every statement — namespace-wide means every scope in one space, never every space — and
[ADR-6](../adr/the-partition-is-a-column-not-a-schema.md) is the column and the partition-first
index those predicates sit on.

The plan originally recorded that no additional ADR was expected. That was wrong: the split is a
durable structural decision about how a security-relevant breadth choice is made visible, and it
became [ADR-9](../adr/each-recall-target-gets-its-own-statement.md) during implementation.


## Plan of Work

### Milestone 1: explicit predicate planning

Introduce a small internal plan that compiles `RecallTarget` into a statement family. Exact global
uses `scope_kind IS NULL AND scope_ref IS NULL`; exact entity compares both values; namespace-wide
omits only those scope comparisons. All three compare memory space and namespace explicitly.

Use distinct Hasql input records so it is impossible to call a namespace-wide statement by
passing nullable scope fields to an exact statement. Validate `maxResults` before SQL.

*As built:* three families, not two. `ScopeBound` has one constructor per target;
`BoundedCandidateParams` (used by exact-global and namespace-wide) carries no scope columns at
all and `EntityCandidateParams` carries two non-nullable ones, so no parameter assignment can
widen a bound — the choice is which statement you name. `maxResults` was already validated into a
`RecallLimit` by plan 28, which is what let `resolveRecall` become total.

### Milestone 2: keyword/vector statements and indexes

Update FTS and vector statements for every target family. Keep the filtered-ANN algorithm:
retrieve an expanded vector candidate set inside the authorized predicate, combine/rank, and
fall back to exact filtered scoring when expansion cannot fill the requested page. Keyword-only
fallback remains available when vector capability is absent.

Every index must start with `memory_space_id` and support the target's namespace/scope predicates
before ranking fields. Do not add an unbounded namespace query.

*As built:* nine statements — three channels times three bounds — generated from one SQL template
per channel and one scope clause per bound, so the space, namespace and `status` predicates cannot
drift apart between families. The two-pass vector channel is unchanged and now dispatches per
family. **No index migration was needed**: `kioku_memories_space_scope_idx` from plan 26's
migration 0011 already answers all three bounds, which was measured rather than assumed — see
Surprises & Discoveries for the captured plans and the Decision Log for why a partial index for
the global bucket was rejected.

### Milestone 3: semantic and query-plan matrix

Extend the harness with two spaces containing the same namespace, one global-bucket row and two
entity-scope rows per space, identical content, and controlled embeddings. For keyword,
embedding, and hybrid strategies, assert:

- exact global returns only the global bucket in the requested space;
- exact entity returns only that entity scope in the requested space;
- namespace-wide returns all three scopes in the requested space;
- no case returns the other space.

Add low-`ef_search` and selective-filter fixtures to preserve plan 19. Capture concise `EXPLAIN`
evidence that queries use a bounded partition-leading access path.

*As built:* `kioku-core/test/Kioku/RecallTargetSpec.hs` holds the matrix. Its two spaces carry
byte-identical rows — same namespace, same three scopes, same content — so nothing but the
`memory_space_id` predicate can separate them, and it runs the three targets under each space's
context. `embedding` and `hybrid` are exercised at the channel level because
`Baikai.Embedding.EmbeddingModel` is an HTTP endpoint (Decision Log); the keyword row also goes
through the public `recall`. The plan evidence runs under `SET LOCAL enable_seqscan = off`,
because the six-row fixture would otherwise be scanned sequentially and the plan would say nothing
about which access paths are available. Plan 19's selective-filter fixture became
`Kioku.RecallHarness.exactEntityStarvationCorpus`, which starves the exact-scope family.


## Concrete Steps

Run from the repository root. The tasty group names are `Recall scoring`, `Recall.Compat`,
`Recall.Sql` and `Recall.Target`, so `-p Recall` selects every recall case:

```bash
nix develop -c cabal test kioku-core --test-options='-p "Recall"'
nix develop -c cabal test kioku-core --test-options='-p "Recall.Target"'
nix develop -c cabal test kioku-migrations
nix develop -c cabal test all
```

Expected output for the target matrix:

```text
  Recall.Target
    every target and strategy returns its own rows, in its own space:        OK
    the public entry point answers all three targets:                        OK
    each target's plan is bounded by the partition and its own scope clause: OK
```

When pgvector is unavailable, the vector rows of the matrix and the starvation cases print
`[skipped] no reachable pgvector on this cluster` rather than passing silently; the keyword rows
and every partition-isolation assertion still run and must pass.


## Validation and Acceptance

Acceptance requires the nine target/strategy combinations above to return exactly the fixture
IDs and never the second space. It also requires:

- Exact global and namespace-wide compile to distinct SQL shapes.
- Every query has a positive bounded limit and validates oversized/zero requests consistently.
- Filtered ANN expansion and exact fallback still recover the in-scope nearest rows.
- Keyword fallback preserves target and memory-space predicates when vectors are unavailable.
- Representative plans can use partition-leading indexes and do not scan unrelated spaces.

All met, 2026-08-07:

- The nine combinations are `Recall.Target`'s first case, and the second space's twins are
  asserted absent from every one of them.
- Distinct SQL shapes are asserted from the query plans themselves rather than from the Haskell:
  the exact-global plan tests `scope_kind` for NULL, the exact-entity plan compares it, the
  namespace-wide plan constrains no scope, and the first two plans differ from the third.
- Limits: `RecallLimit` is validated 1–100 by `mkRecallLimit` before a `RecallQuery` exists (plan
  28), and `Recall.Compat`'s edge case still pins the legacy request's zero-returns-nothing and
  clamp-above-100 behaviour.
- `Recall.Sql`'s two starvation cases prove expansion and fallback on the namespace-wide and
  exact-entity families; `a healthy scope never pays for the exact fallback` proves the fallback
  stays off when the pool fills.
- Keyword fallback: `Recall.Target`'s second case runs under `VectorExtensionUnavailable` with an
  embedding model that throws if forced, and still gets the right rows in the right space.
- Every plan captured carries `Index Cond: ((memory_space_id …`, which is asserted, not merely
  observed.


## Idempotence and Recovery

SQL and test edits are safe to rerun. No migration was written, so there is no schema state to
recover: the change is entirely in compiled statements, and rolling back is reverting the commits.
Had an index been needed it would have used a new name and been additive, with obsolete indexes
dropped only in a later migration after production plan verification.

The candidate-expansion implementation was deliberately not rewritten — only the predicate it
carries changed — so a vector regression is diagnosable as a predicate problem rather than an
algorithm one.


## Interfaces and Dependencies

Internal input types make widening explicit. The plan originally sketched two families:

```haskell
data ExactRecallSql = ExactRecallSql MemorySpaceId MemoryScope Text Int
data NamespaceRecallSql = NamespaceRecallSql MemorySpaceId Namespace Text Int
```

That was rejected during implementation (Decision Log): encoding a `MemoryScope` needs nullable
scope parameters again for the global case, which is the representation this plan removes, one
layer down. What shipped in `kioku-core/src/Kioku/Recall.hs` is three bounds and two parameter
records, neither of which can express a scope filter's absence:

```haskell
data ScopeBound
  = GlobalBucketOnly              -- AND scope_kind IS NULL AND scope_ref IS NULL
  | EntityScopeOnly !Text !Text   -- AND scope_kind = $4 AND scope_ref = $5
  | EveryScopeInNamespace         -- (no scope clause)

data BoundedCandidateParams = BoundedCandidateParams
  { match :: !Text, memorySpaceId :: !MemorySpaceId, namespace :: !Text, limit :: !Int32 }

data EntityCandidateParams = EntityCandidateParams
  { match :: !Text, memorySpaceId :: !MemorySpaceId, namespace :: !Text,
    scopeKind :: !Text, scopeRef :: !Text, limit :: !Int32 }
```

`FtsCandidateSql` and `VectorCandidateSql` are the compiled queries — one constructor per family —
and `runFtsCandidates`, `runVectorAnnCandidates`, `runVectorExactCandidates` and the three
`explain*` seams dispatch on them with a total `case`.

The implementation uses existing Hasql, pgvector capability detection, and RRF helpers. It
depends on plan 26's schema and plan 28's `RecallTarget`. It makes no per-candidate authorization
call; authorization has already produced one allowed memory-space context.


## Revision Notes

**2026-08-07 — implementation.** Three sections changed against what was planned, and each is
recorded where a reader meets it rather than only here.

*Two statement families became three.* The Interfaces sketch proposed `ExactRecallSql` carrying a
`MemoryScope`, which needs nullable scope parameters again for the global case — the same
null-means-two-things representation this plan exists to delete, moved into the Hasql encoder. The
Interfaces section now shows what shipped and why the sketch was rejected.

*The index milestone produced no migration.* "Add partition-leading indexes for each bounded query
shape" was answered by measuring: `kioku_memories_space_scope_idx` already serves all three,
because a btree index takes `scope_kind IS NULL` as an index condition. The captured plans are in
Surprises & Discoveries and the rejection of a redundant partial index is in the Decision Log.

*The plan expected no new ADR and was wrong.* Context and Orientation said so; the split is a
durable structural decision and became ADR-9. That section now cites ADR-2, ADR-6, ADR-8 and
ADR-9, and says plainly that the original expectation was mistaken.

Two smaller corrections: Concrete Steps named tasty filters (`Recall SQL`, `Recall harness`,
`filtered ANN`) that match no test group in this repository and would have selected nothing, and
are replaced with commands that run; and Validation and Acceptance now records how each acceptance
criterion was met rather than only stating it.
