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

- [ ] Add `RecallTarget` and a context-aware recall request to the public API.
- [ ] Define stable tagged JSON for exact-scope and namespace-wide targets.
- [ ] Add a deprecated legacy conversion that preserves current behavior exactly.
- [ ] Separate validation of target, limits, strategy, and authorized memory space.
- [ ] Add unit, JSON round-trip, compatibility, and compile-surface tests.
- [ ] Document semantics and the deprecation/removal window.


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
