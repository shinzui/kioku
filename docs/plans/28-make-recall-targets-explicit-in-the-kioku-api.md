---
id: 28
slug: make-recall-targets-explicit-in-the-kioku-api
title: "Make recall targets explicit in the Kioku API"
kind: exec-plan
created_at: 2026-08-06T14:43:35Z
intention: "intention_01kzbrej1ye898yegaa8r1dmvc"
master_plan: "docs/masterplans/6-explicit-and-safe-recall-boundaries.md"
---

# Make recall targets explicit in the Kioku API

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a recall call says whether it targets one exact scope or every scope in one
namespace. Exact global-bucket recall becomes expressible without being confused with
namespace-wide recall. The request also carries the authorized memory-space context from
MasterPlan 5, so widening a target never widens tenancy. Existing `RecallRequest` callers keep
their old behavior through a deprecated conversion and receive compiler guidance to migrate.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 (public target and request types) is complete. Milestones 2 and 3 have not started.

- [x] Add `RecallTarget` and the request type to the public API. (2026-08-07:
      `kioku-api/src/Kioku/Api/Recall.hs` defines `RecallTarget`, `RecallStrategy` moved from
      `Kioku.Recall`, the validated `RecallLimit`, and `RecallQuery`. The request deliberately
      carries no memory space.)
- [ ] Make core recall execution take a `MemoryAccessContext` and a `RecallQuery`.
- [x] Define stable tagged JSON for exact-scope and namespace-wide targets. (2026-08-07: three
      required tags — `exact_global`, `exact_entity`, `namespace_wide` — hand-written, with
      strict decoding that refuses an unknown tag and a variant carrying a field it has no
      meaning for.)
- [x] Add the pure legacy conversion that preserves current behavior exactly. (2026-08-07:
      `legacyRecallTarget`, with tests that it never narrows a global scope to the global
      bucket.)
- [ ] Add the deprecated `legacyRecall` entry point that keeps `RecallRequest` callers working.
- [x] Separate validation of target, limits, and strategy. (2026-08-07: target by construction,
      limit by `mkRecallLimit`, strategy by its own total enum.)
- [ ] Validate the authorized memory space at execution, from the context and nowhere else.
- [x] Add unit and JSON round-trip tests for the vocabulary. (2026-08-07:
      `kioku-api/test/Kioku/Api/RecallSpec.hs`, 119 assertions passing.)
- [ ] Add compatibility and behavior tests in `kioku-core`.
- [ ] Document semantics and the deprecation/removal window (user docs, changelogs, ADR).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The current `RecallRequest.scope` is a `MemoryScope`. `ScopeGlobal namespace` means “all scopes
  in this namespace” in recall but “the exact global bucket” in exact read-model functions.
- The completed remediation MasterPlan documented this asymmetry deliberately, so changing the
  old constructor in place would violate an established compatibility decision.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use `ExactScope MemoryScope` and `NamespaceWide Namespace` constructors.
  Rationale: They name the data-visible difference at every call site and allow exact global
  bucket recall.
  Date: 2026-08-06

- Decision: Legacy `ScopeGlobal ns` converts to `NamespaceWide ns`; legacy entity scope converts
  to `ExactScope`.
  Rationale: This preserves the current recall behavior during migration instead of silently
  narrowing results.
  Date: 2026-08-06

- Decision: Space comes from `MemoryAccessContext`, not from `RecallTarget`.
  Rationale: The target is a retrieval boundary inside an already authorized partition; mixing
  them invites namespace-wide authorization mistakes.
  Date: 2026-08-06

- Decision: The wire format carries three tags — `exact_global`, `exact_entity`,
  `namespace_wide` — rather than the two Haskell constructors.
  Rationale: The plan requires a required discriminator and forbids inferring meaning from null
  scope fields. A two-tag encoding would separate the exact global bucket from an exact entity
  only by whether `scope_kind` was present, which is the null-means-something representation this
  whole initiative removes from SQL — reintroduced on the wire. Three tags also give the future
  HTTP/SDK union one variant per data-visible outcome. The mapping to the two constructors is
  total in both directions.
  Date: 2026-08-07

- Decision: `RecallStrategy` moves from `kioku-core`'s `Kioku.Recall` to `kioku-api`'s
  `Kioku.Api.Recall`, and `Kioku.Recall` re-exports it.
  Rationale: A request is a target, a query, a strategy and a bound. All four must be nameable by
  a host, an HTTP service, or an SDK without depending on the runtime package. Re-exporting keeps
  every existing `import Kioku.Recall (RecallStrategy (..))` compiling.
  Date: 2026-08-07

- Decision: `RecallLimit` is a validated newtype bounded to 1–100; the pure `legacyRecallTarget`
  conversion is *not* deprecated.
  Rationale: Zero silently returns nothing and an unbounded upper end asks the planner for rows
  that can never exist — each channel contributes at most 50 candidates, so 100 is the ceiling a
  fused result set can reach. The command line has enforced 1–100 since it was written. The pure
  conversion is the migration tool: warning on the one function a migrating caller must call
  would punish the migration. The compile-time deprecation lives on `legacyRecall`, which every
  unmigrated caller must go through.
  Date: 2026-08-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

No implementation has started. Completion means the ambiguous API remains only as a deprecated
compatibility layer with executable behavior tests.


## Context and Orientation

`kioku-api/src/Kioku/Api/Scope.hs` defines `Namespace` and `MemoryScope` with global and entity
constructors. `kioku-core/src/Kioku/Recall.hs` currently defines `RecallRequest`, strategy,
planning, and recall execution. Read-model functions distinguish exact scope from explicit
namespace reads, but recall overloads `ScopeGlobal`.

`docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md`
and the completed remediation MasterPlan document the current behavior. This plan supersedes it
only for the new API. Plan 25 supplies `MemoryAccessContext`. The repository has no ADR today;
the compatibility/removal policy becomes an ADR before implementation is complete.


## Plan of Work

### Milestone 1: public target and request types

Add `kioku-api/src/Kioku/Api/Recall.hs` and expose it from the Cabal package. Define
`RecallTarget` and `RecallQuery` (or the final reviewed name) independently from SQL. The request
contains target, query text, strategy, and positive bounded result count; the authorized memory
space is supplied through `MemoryAccessContext` at execution.

Encode targets with a required discriminator, for example `exact_scope` or `namespace_wide`.
Reject unknown tags and invalid combinations. Do not infer one meaning from null scope fields.

### Milestone 2: compatibility conversion

Keep the existing record or introduce `LegacyRecallRequest` with a deprecated function that
performs the exact mapping:

```haskell
ScopeGlobal ns    -> NamespaceWide ns
ScopeEntity ns k r -> ExactScope (ScopeEntity ns k r)
```

An exact global bucket is requested only with `ExactScope (ScopeGlobal ns)`. Add tests showing
these three cases are distinct. The compatibility conversion retains current max-result and
strategy validation.

### Milestone 3: API documentation and release policy

Move core recall execution to consume the new type, leaving SQL implementation to plan 29.
Update Haddocks, `docs/user/recall.md`, and `docs/user/library-api.md`. Add an ADR declaring a
minimum one-release deprecation window and the condition for deleting the legacy wrapper: Mori
dependents compile against the new API and the CLI no longer constructs it.


## Concrete Steps

Run from the repository root:

```bash
nix develop -c cabal test kioku-api
nix develop -c cabal test kioku-core --test-options='-p "Recall"'
nix develop -c cabal build all
```

The focused output must include distinct exact-global, exact-entity, namespace-wide, and legacy
conversion cases.


## Validation and Acceptance

Acceptance requires:

- The new API cannot construct an unlabelled scope target.
- Tagged JSON round-trips exact global, exact entity, and namespace-wide values distinctly.
- Legacy `ScopeGlobal` retains namespace-wide behavior and emits a compile-time deprecation.
- Exact global bucket has a supported new request representation.
- Recall execution always receives a memory access context; target conversion cannot alter its
  space.
- User docs contain a migration table and declared removal window.


## Idempotence and Recovery

The change is additive for one compatibility release. Keep golden JSON fixtures for both forms.
If downstream migration is incomplete, retain the deprecated wrapper; do not reinterpret it.
Deleting the wrapper is a later PVP-breaking release step and is not performed merely because
the new code exists.


## Interfaces and Dependencies

The public seam is equivalent to:

```haskell
data RecallTarget
  = ExactScope MemoryScope
  | NamespaceWide Namespace

recall :: MemoryAccessContext -> RecallQuery -> Eff es (Either RecallError [RecallHit])
legacyRecall :: MemoryAccessContext -> LegacyRecallRequest -> Eff es (Either RecallError [RecallHit])
```

Use existing `RecallStrategy`, `MemoryScope`, and validation helpers. Plan 29 owns SQL mapping;
plan 30 owns CLI/downstream migration.
