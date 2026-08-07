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

- [ ] Define one target-to-predicate mapping used by FTS and vector planning.
- [ ] Split or strongly type exact-scope and namespace-wide Hasql statements.
- [ ] Add partition-leading indexes for each bounded query shape.
- [ ] Preserve vector candidate expansion and exact FTS fallback behavior.
- [ ] Extend the recall harness with two-space and exact-global fixtures.
- [ ] Add query-plan/limit tests and run the full PostgreSQL suite.
- [ ] Document SQL semantics and operational verification.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Current SQL treats null scope parameters as “omit the scope filter.” That representation
  cannot distinguish exact global-bucket recall from namespace-wide recall.
- The existing recall harness and plan 19 fix already protect against filtered ANN starvation.
  A query rewrite that removes candidate expansion could reintroduce that bug while passing
  simple semantic tests.


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

No implementation has started. Completion means the semantic matrix passes for all strategies
against a real PostgreSQL database and query plans stay bounded.


## Context and Orientation

`kioku-core/src/Kioku/Recall.hs` contains FTS/vector statements, execution planning, reciprocal
rank fusion, capability fallback, and query entry points. `Kioku.Recall.Capability` detects
pgvector availability. `kioku-core/test/Kioku/RecallHarness.hs` builds real PostgreSQL fixtures;
`Kioku.RecallSqlSpec` and `Kioku.RecallSpec` cover SQL and pure planning.

The completed `docs/plans/18-build-a-recall-quality-harness-that-reproduces-filtered-ann-starvation.md`
and `docs/plans/19-fix-filtered-ann-starvation-in-vector-recall.md` are regression constraints.
Plans 26 and 28 supply the partitioned schema and target type. No additional ADR is expected
beyond the API/compatibility ADR from plan 28.


## Plan of Work

### Milestone 1: explicit predicate planning

Introduce a small internal plan that compiles `RecallTarget` into either an exact-scope or
namespace-wide statement family. Exact global uses `scope_kind IS NULL AND scope_ref IS NULL`;
exact entity compares both values; namespace-wide omits only those scope comparisons. All three
compare memory space and namespace explicitly.

Use distinct Hasql input records so it is impossible to call a namespace-wide statement by
passing nullable scope fields to an exact statement. Validate `maxResults` before SQL.

### Milestone 2: keyword/vector statements and indexes

Update FTS and vector statements for both target families. Keep the filtered-ANN algorithm:
retrieve an expanded vector candidate set inside the authorized predicate, combine/rank, and
fall back to exact filtered scoring when expansion cannot fill the requested page. Keyword-only
fallback remains available when vector capability is absent.

Add or replace indexes in the pg-migrate schema from plan 26. Every index starts with
`memory_space_id` and supports the target's namespace/scope predicates before ranking fields.
Do not add an unbounded namespace query.

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


## Concrete Steps

Run from the repository root:

```bash
nix develop -c cabal test kioku-core --test-options='-p "Recall SQL|Recall harness"'
nix develop -c cabal test kioku-core --test-options='-p "filtered ANN"'
nix develop -c cabal test kioku-migrations
nix develop -c cabal test all
```

When pgvector is unavailable, vector-specific cases may report a documented skip; keyword and
partition isolation cases must still run and pass.


## Validation and Acceptance

Acceptance requires the nine target/strategy combinations above to return exactly the fixture
IDs and never the second space. It also requires:

- Exact global and namespace-wide compile to distinct SQL shapes.
- Every query has a positive bounded limit and validates oversized/zero requests consistently.
- Filtered ANN expansion and exact fallback still recover the in-scope nearest rows.
- Keyword fallback preserves target and memory-space predicates when vectors are unavailable.
- Representative plans can use partition-leading indexes and do not scan unrelated spaces.


## Idempotence and Recovery

SQL and test edits are safe to rerun. Index migrations use new names and are additive until the
new statements are deployed. Drop obsolete indexes only in a later migration after production
plan verification. If vector tests expose a regression, retain the old candidate-expansion
implementation and change only its target predicate.


## Interfaces and Dependencies

Internal input types should make widening explicit, for example:

```haskell
data ExactRecallSql = ExactRecallSql MemorySpaceId MemoryScope Text Int
data NamespaceRecallSql = NamespaceRecallSql MemorySpaceId Namespace Text Int
```

The implementation uses existing Hasql, pgvector capability detection, and RRF helpers. It
depends on plan 26's schema and plan 28's `RecallTarget`. It must not call En per candidate;
authorization has already produced one allowed memory-space context.
