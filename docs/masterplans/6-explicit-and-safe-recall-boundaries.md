---
id: 6
slug: explicit-and-safe-recall-boundaries
title: "Explicit and safe recall boundaries"
kind: master-plan
created_at: 2026-08-06T14:43:35Z
intention: "intention_01kzbrehehe2wak4axxp5mrsas"
---

# Explicit and safe recall boundaries

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Recall callers choose an explicit target: one exact memory scope or all scopes in one
namespace, always inside one authorized memory space. The type system, SQL, CLI, and user docs
use the same vocabulary, so `ScopeGlobal` can no longer mean an exact global bucket in one API
and namespace-wide search in another. Existing callers receive a deliberate compatibility
path and deprecation period rather than a silent semantic change.

This initiative covers the public recall request, FTS and vector SQL, fallback behavior,
bounded query tests, CLI migration, and documentation. It does not redesign ranking, change
embedding models, add authorization policy, or search across memory spaces. Partition and
authorization context come from
`docs/masterplans/5-portfolio-compatible-memory-isolation-and-authorization.md`.


## Decomposition Strategy

EP-1 makes ambiguity unrepresentable at the public API boundary. EP-2 implements the two
meanings as separately named, partition-first SQL plans and proves them against PostgreSQL.
EP-3 migrates library/CLI consumers and removes the compatibility wrapper after a documented
release window. Separating these streams lets API review finish before SQL work and prevents a
CLI flag from becoming the de facto contract.

The current asymmetry was deliberately documented by the completed remediation work in
`docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md`; this
initiative supersedes the decision only through a new explicit API while retaining the old
wrapper temporarily. That compatibility policy became
[ADR-8](../adr/an-explicit-recall-target-replaces-the-overloaded-scope.md) during EP-1, which also
records the removal conditions and the alternatives rejected. The chief one was to reinterpret
`ScopeGlobal` in place, which would silently narrow existing recall results.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Make recall targets explicit in the Kioku API | docs/plans/28-make-recall-targets-explicit-in-the-kioku-api.md | MasterPlan 5 EP-2 | None | Complete |
| EP-2 | Enforce exact and namespace-wide recall in PostgreSQL | docs/plans/29-enforce-exact-and-namespace-wide-recall-in-postgresql.md | EP-1, MasterPlan 5 EP-3 | None | Complete |
| EP-3 | Migrate recall consumers to explicit targets | docs/plans/30-migrate-recall-consumers-to-explicit-targets.md | EP-1, EP-2 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 waits for the memory-space types from MasterPlan 5 so `RecallTarget` is not revised twice.
EP-2 requires both that API and the partitioned schema. It must place `memory_space_id` first in
every query predicate before applying exact-scope or namespace-wide conditions. EP-3 requires
both behaviors to be implemented and covered by the real-PostgreSQL harness before changing
defaults or CLI grammar.

Within EP-2, keyword and vector statements can be changed in parallel as long as they share one
target-to-SQL predicate table. The filtered-ANN fallback from the completed
`docs/masterplans/3-kioku-follow-up-scene-freshness-and-filtered-ann-recall-quality.md` remains
an invariant and must not be weakened.


## Integration Points

For each shared artifact (type, module, configuration, database table) that multiple
child plans touch, document: which plans are involved, what the shared artifact is,
which plan is responsible for defining it, and how later plans should consume or extend
it. Identify any cross-plan decisions that should become ADRs, especially architecture
boundaries, durable integration constraints, shared interface ownership, decomposition
rationale that will matter later, and deliberate exclusions.

- **Recall request:** EP-1 owns `RecallTarget` and the deprecated conversion from legacy
  `MemoryScope`. Exact global bucket and namespace-wide are separate constructors.
- **SQL predicate:** EP-2 owns one tested mapping from each target constructor to FTS and vector
  predicates. `memory_space_id` is mandatory in both mappings.
- **Quality harness:** EP-2 extends `Kioku.RecallHarness` and `Kioku.RecallSqlSpec` from
  MasterPlan 3, preserving vector-candidate expansion and exact FTS fallback.
- **Consumers:** EP-3 owns CLI syntax, Haddocks, upgrade notes, and downstream compilation
  fixtures. The HTTP and SDK improvement requests must expose the new target vocabulary rather
  than the legacy overload.
- **Bounded queries:** the proposed
  `docs/improvement-requests/add-indexed-session-and-bounded-memory-read-models.md` must use the
  same partition-first, explicit-target contract.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: add explicit recall target types and a compatibility conversion. (2026-08-07:
      `Kioku.Api.Recall` holds `RecallTarget`, `RecallQuery`, `RecallStrategy` and `RecallLimit`;
      `legacyRecallTarget` and the deprecated `legacyRecall` preserve current behavior.)
- [x] EP-1: prove JSON and library behavior distinguish exact-global from namespace-wide.
      (2026-08-07: `Kioku.Api.RecallSpec` pins three distinct tagged encodings;
      `Kioku.RecallCompatSpec` and `Kioku.RecallSqlSpec` prove the row-level behavior against a
      real database, including that exact-global is refused rather than silently answered as
      namespace-wide.)
- [x] EP-2: implement partition-first FTS and vector predicates for both targets. (2026-08-07:
      nine statements — full text, the approximate vector pass and the exact vector pass, each in
      an exact-global, exact-entity and namespace-wide family — generated from one template per
      channel and one scope clause per bound, all led by `memory_space_id`.
      `RecallExactGlobalUnsupported` is deleted and `resolveRecall` is total.)
- [x] EP-2: extend real-PostgreSQL isolation, ranking, and fallback tests. (2026-08-07:
      `Kioku.RecallTargetSpec` runs the nine target/strategy combinations, and the same three
      targets from a second space holding byte-identical rows, against a real database; its plan
      case asserts the three bounds are three partition-led plans.
      `Kioku.RecallHarness.exactEntityStarvationCorpus` keeps plan 19's fallback proven on the
      exact-scope family too.)
- [ ] EP-3: migrate CLI and library call sites with upgrade documentation.
- [ ] EP-3: retire the legacy overload only after the declared compatibility window.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- `RecallRequest.scope = ScopeGlobal namespace` currently drops the scope predicate and searches
  the whole namespace, while exact read-model functions interpret the same constructor as the
  global bucket only. The behavior is documented, but the type cannot communicate it.
- The existing recall harness already reproduces filtered ANN starvation and verifies exact FTS
  fallback. It should be extended, not replaced.

- **EP-1 could not make exact-global recall executable, and EP-2 carried that.** The shared
  scope predicate had no parameter assignment that means "the global bucket only": NULL scope
  columns mean *no scope filter*. `ExactScope (ScopeGlobal ns)` was therefore representable,
  round-tripped on the wire, and was refused at execution with `RecallExactGlobalUnsupported`.
  EP-2 split the statements and deleted the constructor (2026-08-07).

- **EP-2's index milestone was answered by measuring rather than by migrating.** The plan asked
  for partition-leading indexes per bounded query shape; all three shapes turn out to be served by
  `kioku_memories_space_scope_idx`, which migration 0011 already installed, because a btree index
  takes `scope_kind IS NULL` as an index condition rather than as a filter. No migration was
  written, and [ADR-9](../adr/each-recall-target-gets-its-own-statement.md) records why a partial
  index for the global bucket was rejected.

- **EP-2 also removed a hazard EP-3 would have inherited.** `Kioku.RecallHarness` kept its own copy
  of the vector SQL so it could `EXPLAIN` it, and that copy had already gone wrong twice. Three
  statement families would have meant three copies, so the copy is gone: `Kioku.Recall` exports
  `EXPLAIN` seams built from the same SQL text and parameters as the statements they describe.

- **EP-3's in-repository migration is smaller than planned.** EP-1 had to touch the CLI and L1
  anyway, because `recall`'s signature changed, so both now build a `RecallTarget` through
  `legacyRecallTarget` and behave exactly as before. What remains for EP-3 is the genuine work:
  CLI grammar for exact versus namespace-wide, and the deliberate decision about whether merge
  candidates want namespace-wide breadth.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Introduce `ExactScope MemoryScope` and `NamespaceWide Namespace` as separate recall
  targets.
  Rationale: The distinction affects visibility and result count and must be visible at every
  call site.
  Date: 2026-08-06

- Decision: Keep the old request behavior behind a deprecated compatibility constructor for a
  release window.
  Rationale: Existing callers may rely on namespace-wide recall from `ScopeGlobal`; silently
  changing it would be a breaking data-visibility change without a compiler signal.
  Date: 2026-08-06

- Decision: Recall can widen only within one memory space.
  Rationale: Namespace-wide is a retrieval choice, not an authorization bypass or tenant
  selector.
  Date: 2026-08-06


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

Planning completed on 2026-08-06. Three child plans cover API semantics, PostgreSQL behavior,
and consumer migration.

EP-1 completed 2026-08-07. The public API can no longer express an unlabelled scope target, and
the compatibility path is measured against a real database rather than asserted. The compatibility
policy that this MasterPlan said "should become an ADR during implementation" is
[ADR-8](../adr/an-explicit-recall-target-replaces-the-overloaded-scope.md), which also carries the
removal conditions.

EP-2 completed 2026-08-07. The vision's central claim — that `ScopeGlobal` can no longer mean an
exact global bucket in one API and namespace-wide search in another — now holds all the way down
to the SQL: the three meanings are three scope clauses across nine statements, and which one a
call ran is visible in the statement's name and in the plan PostgreSQL chose. The integration
point this MasterPlan assigned EP-2 ("one tested mapping from each target constructor to FTS and
vector predicates, `memory_space_id` mandatory in both") is
[ADR-9](../adr/each-recall-target-gets-its-own-statement.md) and `Kioku.Recall.resolveRecall`.
Exact global recall executes for the first time, and the filtered-ANN invariant this MasterPlan
declared untouchable is now proven per statement family rather than once.

EP-3 has not started. Two of its inputs changed: the library work it was to build on is finished
and measured, so what remains is genuinely CLI grammar and the merge-candidate breadth decision;
and the CLI is now the only surface where the exact global bucket cannot be asked for.
