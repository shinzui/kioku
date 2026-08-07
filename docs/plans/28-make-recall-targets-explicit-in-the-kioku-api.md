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

All three milestones are complete. What remains is owned by plans 29 and 30: exact global-bucket
recall is representable but refused at execution until the SQL statements are split, and the CLI
keeps its current `--scope` grammar.

- [x] Add `RecallTarget` and the request type to the public API. (2026-08-07:
      `kioku-api/src/Kioku/Api/Recall.hs` defines `RecallTarget`, `RecallStrategy` moved from
      `Kioku.Recall`, the validated `RecallLimit`, and `RecallQuery`. The request deliberately
      carries no memory space.)
- [x] Make core recall execution take a `MemoryAccessContext` and a `RecallQuery`. (2026-08-07:
      `recall` returns `Either RecallError [RecallHit]`; `ResolvedRecall`/`resolveRecall` bind a
      request to one authorized space and compile its target to scope columns.)
- [x] Define stable tagged JSON for exact-scope and namespace-wide targets. (2026-08-07: three
      required tags — `exact_global`, `exact_entity`, `namespace_wide` — hand-written, with
      strict decoding that refuses an unknown tag and a variant carrying a field it has no
      meaning for.)
- [x] Add the pure legacy conversion that preserves current behavior exactly. (2026-08-07:
      `legacyRecallTarget`, with tests that it never narrows a global scope to the global
      bucket.)
- [x] Add the deprecated `legacyRecall` entry point that keeps `RecallRequest` callers working.
      (2026-08-07: it also refuses a request naming a space its context does not authorize, and
      preserves the old `maxResults` edges.)
- [x] Separate validation of target, limits, and strategy. (2026-08-07: target by construction,
      limit by `mkRecallLimit`, strategy by its own total enum.)
- [x] Validate the authorized memory space at execution, from the context and nowhere else.
      (2026-08-07: `resolveRecall` takes the space as an argument; only `legacyRecall` can see a
      second space, and it refuses a mismatch.)
- [x] Add unit and JSON round-trip tests for the vocabulary. (2026-08-07:
      `kioku-api/test/Kioku/Api/RecallSpec.hs`, 119 assertions passing.)
- [x] Add compatibility and behavior tests in `kioku-core`. (2026-08-07:
      `kioku-core/test/Kioku/RecallCompatSpec.hs` runs the legacy and explicit requests side by
      side against a real database; `Kioku.RecallSqlSpec` gained the exact-global refusal case.)
- [x] Migrate the in-repository callers without changing their behavior. (2026-08-07: the CLI and
      L1's merge-candidate finder go through `legacyRecallTarget`; `FindMergeCandidates` now
      receives the pass's `MemoryAccessContext`.)
- [x] Document semantics and the deprecation/removal window. (2026-08-07: `docs/user/recall.md`,
      `docs/user/library-api.md`, `docs/user/upgrading-to-memory-spaces.md`, the three changelogs,
      and ADR-8.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The current `RecallRequest.scope` is a `MemoryScope`. `ScopeGlobal namespace` means “all scopes
  in this namespace” in recall but “the exact global bucket” in exact read-model functions.
- The completed remediation MasterPlan documented this asymmetry deliberately, so changing the
  old constructor in place would violate an established compatibility decision.

- **The exact global bucket has no parameter assignment in the current SQL, so it cannot be
  executed in this plan.** Both candidate statements spell the scope filter
  `(($4 IS NULL AND $5 IS NULL) OR (scope_kind = $4 AND scope_ref = $5))`. NULL scope columns mean
  *no scope filter*, so an exact global request routed through them returns the namespace-wide
  answer. There is no third parameterization. Splitting the statements is plan 29's Milestone 1,
  and plan 29 has already recorded the decision to prefer *separate statements* over a nullable
  boolean predicate — so implementing it here would have shipped the design plan 29 rejected.
  `resolveRecall` therefore refuses with `RecallExactGlobalUnsupported`, proven by
  `Kioku.RecallSqlSpec`'s "the exact global bucket is refused rather than answered wrongly".

- **GHC does not warn about uses of a deprecated name inside the module that defines it.**
  Verified with a scratch module: a `{-# DEPRECATED #-}` type and function used in their own
  module compile silently under `-Wall`. That is what makes deprecating `RecallRequest` itself
  practical — `Kioku.Recall` can keep using it internally without noise, while every external
  caller gets the warning. The one test module that exercises the legacy path carries
  `{-# OPTIONS_GHC -Wno-deprecations #-}`.

- **`bimap` is already in scope through `Kioku.Prelude`,** which re-exports `Control.Lens`.
  Importing `Data.Bifunctor (bimap)` in `Kioku.Distill.L1` produced a redundant-import warning.

- **`Data.Aeson`'s `(.=)` collides with `Control.Lens`'s,** which `Kioku.Prelude` re-exports, so
  `Kioku.Api.Recall` builds JSON objects through a small local `pair` helper rather than importing
  aeson's operator.

- **A test that asserted a request carries no memory space by grepping the encoded JSON for
  `"space"` failed,** because `namespace_wide` contains it. It now checks the object's key set
  instead, which is what it meant.

- **`cabal test all` is flaky under concurrency, and it is not a recall problem.** One run reported
  `1 out of 205 tests failed` in `kioku-test` with no reproduction across four subsequent runs
  (`cabal test all` once more, then each suite sequentially). `cabal test all` runs four suites at
  once and each database test spins its own ephemeral PostgreSQL cluster, so the machine is
  running several clusters concurrently; a later `cabal test all` under a `tee` pipeline hung in
  `kioku-test` for over twenty minutes and had to be killed, while the same suite alone finishes
  in about 45 seconds. The interleaved failure output pointed at a session case, not a recall one.
  Prefer running the suites one at a time when a result matters.


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

- Decision: `ExactScope (ScopeGlobal ns)` is refused at execution with
  `RecallExactGlobalUnsupported` rather than routed through the existing scope predicate.
  Rationale: The existing predicate treats NULL scope columns as "no scope filter", so the only
  rows exact-global recall could reach through it are the namespace-wide ones — answering a
  different question silently, which is the defect this initiative removes. Plan 29 owns the SQL
  and has already decided on separate statements over a nullable predicate, so implementing it
  here would ship the design plan 29 rejected. The refusal is loud, tested, and confined to a
  target no in-repository caller constructs.
  Date: 2026-08-07

- Decision: `recall` does not re-check `MemoryRead` on the context it is given.
  Rationale: `Kioku.Memory` records the project rule that reads take a space rather than a whole
  context because "a context exists only for permissions `authorizeMemoryAccess` actually
  checked". Adding a second gate here would make recall stricter than every other read, and would
  make `recallCandidates` fail for a distill-only context where `scopedScanCandidates` — the same
  lookup by another route — succeeds. Recall takes the whole context for a different reason: it is
  the only read that can be asked to widen, so its space must come from the decision.
  Date: 2026-08-07

- Decision: The in-repository callers (CLI recall, L1 merge candidates) migrate to `recall` with
  `legacyRecallTarget`, rather than being left on the deprecated `legacyRecall`.
  Rationale: Both had to be touched anyway — `recall`'s signature changed — and both mappings are
  behavior-identical. Leaving them on the deprecated path would put two permanent warnings in our
  own build for a release, where they could mask new ones. The deprecation still reaches external
  callers, and `Kioku.RecallCompatSpec` exercises the legacy path deliberately. Plan 30 keeps its
  real work: CLI grammar, and the deliberate choice of whether merge candidates want
  namespace-wide breadth.
  Date: 2026-08-07

- Decision: `FindMergeCandidates` takes a `MemoryAccessContext` and returns `Either L1Error`.
  Rationale: A finder that runs recall needs the authorizing context, not a bare space. Its old
  `ReadModelError` channel cannot represent a recall refusal, and flattening one into an empty
  candidate list would tell the consolidator there is nothing to merge into — the
  "denial became an empty result" mistake `Kioku.Api.Access` exists to prevent. `L1Error` gained
  `L1RecallRefused`.
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

Completed 2026-08-07. The ambiguous API now exists only as a deprecated compatibility layer with
executable behavior tests, which is what completion was defined as.

**What was achieved.** A recall call says which of three sets of rows it means, and the memory
space it searches comes from the authorizing context rather than from anything a caller composes.
The exact global bucket became expressible for the first time. The pre-target request survives as
`RecallRequest` + `legacyRecall`, both deprecated, both proven against a real database to return
what they returned before. `Kioku.RecallCompatSpec` runs the legacy and the explicit request side
by side over the same seeded rows and asserts identical memory ids, so the compatibility promise
is measured rather than asserted.

**What remains, and where it belongs.** Exact global-bucket recall is representable and refused —
see the Surprises entry and ADR-8's Consequences. Plan 29 splits the statements; plan 30 gives the
CLI explicit grammar and decides whether L1's merge candidates actually want namespace-wide
breadth. Neither gap is a regression: no in-repository caller constructs an exact-global target,
and every existing caller's results are unchanged.

**Evidence.**

Each suite run on its own — see the Surprises entry on `cabal test all` under concurrency:

```text
kioku-api-test:        All 119 tests passed
kioku-cli-test:        All 38 tests passed
kioku-migrations-test: All 10 tests passed
kioku-test:            All 205 tests passed
```

Focused output, showing the four distinct cases the plan asked for:

```text
Recall.Compat
  a legacy scope returns exactly what its explicit target returns:                OK
  the legacy request's edges are preserved:                                       OK
Recall.Sql
  a namespace-wide target searches the whole namespace; an exact target does not: OK
  the exact global bucket is refused rather than answered wrongly:                OK
```

**Lessons.** Two are worth carrying forward, and both are in ADR-8. First, a compatibility mapping
has a safe direction and an unsafe one: mapping the old global scope to the *wider* target keeps
callers whole, while the narrower mapping would have compiled, run, and quietly returned fewer
rows. Second, when a new vocabulary can express something the storage layer cannot yet answer, the
honest intermediate state is a loud refusal — the alternative is a type that promises a
distinction the query does not make.


## Context and Orientation

`kioku-api/src/Kioku/Api/Scope.hs` defines `Namespace` and `MemoryScope` with global and entity
constructors. `kioku-core/src/Kioku/Recall.hs` currently defines `RecallRequest`, strategy,
planning, and recall execution. Read-model functions distinguish exact scope from explicit
namespace reads, but recall overloads `ScopeGlobal`.

`docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md`
and the completed remediation MasterPlan document the current behavior. This plan supersedes it
only for the new API. Plan 25 supplies `MemoryAccessContext`.

The repository's ADR corpus is `docs/adr/`, an OKF bundle with no local profile descriptor;
validate it with `okf validate docs/adr --strict` and append to its `log.md` with `okf log add`.
Two existing records matter here:
[ADR-2, namespace is not a security boundary](../adr/namespace-is-not-a-security-boundary.md),
which already requires that recall never span memory spaces including under a global scope, and
[ADR-6, the partition is a column not a schema](../adr/the-partition-is-a-column-not-a-schema.md),
which owns the `memory_space_id` predicate the target predicate sits beside. This plan's own
compatibility and removal policy became
[ADR-8](../adr/an-explicit-recall-target-replaces-the-overloaded-scope.md).


## Plan of Work

### Milestone 1: public target and request types

Add `kioku-api/src/Kioku/Api/Recall.hs` and expose it from the Cabal package. Define
`RecallTarget` and `RecallQuery` (or the final reviewed name) independently from SQL. The request
contains target, query text, strategy, and positive bounded result count; the authorized memory
space is supplied through `MemoryAccessContext` at execution.

Encode targets with a required discriminator, for example `exact_scope` or `namespace_wide`.
Reject unknown tags and invalid combinations. Do not infer one meaning from null scope fields.

**As built:** `kioku-api/src/Kioku/Api/Recall.hs` also holds `RecallStrategy` (moved from
`Kioku.Recall`, which re-exports it) and the validated `RecallLimit`. The wire format uses three
tags rather than two — see the Decision Log.

### Milestone 2: compatibility conversion

Keep the existing record (rather than introducing `LegacyRecallRequest`) and add a deprecated
`legacyRecall` that performs the exact mapping:

```haskell
ScopeGlobal ns    -> NamespaceWide ns
ScopeEntity ns k r -> ExactScope (ScopeEntity ns k r)
```

An exact global bucket is requested only with `ExactScope (ScopeGlobal ns)`. Add tests showing
these three cases are distinct. The compatibility conversion retains current max-result and
strategy validation.

**As built:** the mapping is the pure `legacyRecallTarget` in `kioku-api`, exported and *not*
deprecated because it is what a migrating caller calls; `legacyRecall` in `kioku-core` is the
deprecated entry point. `legacyRecall` also refuses a request whose `memorySpaceId` is not the one
its context authorizes, and preserves the old `maxResults` edges — zero returns nothing, and
anything above 100 is clamped, which is unobservable because a fused result set holds at most 100
memories. The three cases are distinct in `Kioku.Api.RecallSpec` (values and wire format) and in
`Kioku.RecallSqlSpec` (rows returned, plus the exact-global refusal).

### Milestone 3: API documentation and release policy

Move core recall execution to consume the new type, leaving SQL implementation to plan 29.
Update Haddocks, `docs/user/recall.md`, and `docs/user/library-api.md`. Add an ADR declaring a
minimum one-release deprecation window and the condition for deleting the legacy wrapper: Mori
dependents compile against the new API and the CLI no longer constructs it.

**As built:** the ADR is
[ADR-8](../adr/an-explicit-recall-target-replaces-the-overloaded-scope.md). Moving core execution
onto the new type also required migrating the in-repository callers, since `recall`'s signature
changed: `kioku-cli/src/Kioku/Cli/Commands/Recall.hs` and `Kioku.Distill.L1.recallCandidates` both
go through `legacyRecallTarget`, so their behavior is unchanged, and
`Kioku.Distill.L1.FindMergeCandidates` now receives the pass's `MemoryAccessContext`.
`docs/user/upgrading-to-memory-spaces.md`, `docs/user/cli-reference.md`, and the `kioku-api`,
`kioku-core` and `kioku-cli` changelogs were updated in the same change.


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

Acceptance requires, with the evidence each was met:

- The new API cannot construct an unlabelled scope target. `RecallTarget` has two constructors and
  no absent case; `RecallQuery` has no scope field at all.
- Tagged JSON round-trips exact global, exact entity, and namespace-wide values distinctly.
  `Kioku.Api.RecallSpec`'s "targets on the wire" pins the three encodings and asserts the
  exact-global and namespace-wide encodings differ; decoding refuses an unknown tag and refuses a
  variant carrying a field it has no meaning for.
- Legacy `ScopeGlobal` retains namespace-wide behavior and emits a compile-time deprecation.
  `Kioku.RecallCompatSpec`'s "a legacy scope returns exactly what its explicit target returns"
  proves the behavior against a real database; `RecallRequest` and `legacyRecall` both carry
  `{-# DEPRECATED #-}`.
- Exact global bucket has a supported new request representation. `ExactScope (ScopeGlobal ns)`
  type-checks and round-trips on the wire. It is refused at execution — see the Surprises entry —
  and `Kioku.RecallSqlSpec`'s "the exact global bucket is refused rather than answered wrongly"
  fails the day that becomes a silent namespace-wide answer.
- Recall execution always receives a memory access context; target conversion cannot alter its
  space. `resolveRecall` takes the space as a separate argument, and `Kioku.SpaceIsolationSpec`'s
  "recall never crosses a space, however wide its scope" exercises the widest target across two
  spaces sharing a namespace.
- User docs contain a migration table and declared removal window.
  `docs/user/recall.md#migrating-from-recallrequest` has the table; the removal conditions are in
  [ADR-8](../adr/an-explicit-recall-target-replaces-the-overloaded-scope.md).


## Idempotence and Recovery

The change is additive for one compatibility release. Keep golden JSON fixtures for both forms.
If downstream migration is incomplete, retain the deprecated wrapper; do not reinterpret it.
Deleting the wrapper is a later PVP-breaking release step and is not performed merely because
the new code exists.


## Interfaces and Dependencies

The public seam as built, in `kioku-api/src/Kioku/Api/Recall.hs` and `kioku-core/src/Kioku/Recall.hs`:

```haskell
data RecallTarget
  = ExactScope !MemoryScope
  | NamespaceWide !Namespace

data RecallQuery = RecallQuery
  { target :: !RecallTarget,
    query :: !Text,
    strategy :: !RecallStrategy,
    maxResults :: !RecallLimit    -- validated 1..100 by mkRecallLimit
  }

data RecallError
  = RecallSpaceMismatch !MemorySpaceId !MemorySpaceId   -- legacyRecall only
  | RecallExactGlobalUnsupported !Namespace

legacyRecallTarget :: MemoryScope -> RecallTarget       -- not deprecated: it is the migration tool

recall ::
  (IOE :> es, Store :> es) =>
  EmbeddingModel -> VectorCapability -> MemoryAccessContext -> RecallQuery ->
  Eff es (Either RecallError [RecallHit])

legacyRecall ::                                          -- DEPRECATED
  (IOE :> es, Store :> es) =>
  EmbeddingModel -> VectorCapability -> MemoryAccessContext -> RecallRequest ->
  Eff es (Either RecallError [RecallHit])
```

The embedding model and vector capability stay as arguments; the plan's original sketch elided
them. Internally, `resolveRecall :: MemorySpaceId -> RecallQuery -> Either RecallError
ResolvedRecall` is the one mapping from a target to the scope columns the SQL takes, and the
candidate-SQL test seams take a `ResolvedRecall` so no test can hand the statements a column
combination the mapping would never produce. That is the seam plan 29 replaces.

`RecallStrategy` moved into `kioku-api` and is re-exported from `Kioku.Recall`. Plan 29 owns SQL
mapping; plan 30 owns CLI grammar and downstream migration.


## Revision Notes

**2026-08-07 — implementation.** Every section was updated to reflect the delivered work rather
than the plan's intent, because the plan is now the record of what was built.

The substantive divergences from the original text, each with its reason recorded in the Decision
Log:

- The wire format carries three tags (`exact_global`, `exact_entity`, `namespace_wide`) rather
  than the two the plan sketched, so that no variant's meaning depends on a missing field.
- The existing `RecallRequest` record was kept and deprecated rather than renamed to
  `LegacyRecallRequest`; the deprecated entry point is `legacyRecall`, and the pure conversion
  `legacyRecallTarget` is deliberately left un-deprecated because it is the migration tool.
- `recall` does not re-check a permission on the context it receives, matching the read
  convention `Kioku.Memory` already records. It takes the whole context because it is the only
  read that can be asked to widen.
- Exact global-bucket recall is representable but refused at execution, because the current scope
  predicate cannot express it and plan 29 has already decided how it should be expressed. This is
  recorded in Surprises & Discoveries, the Decision Log, Validation and Acceptance, and ADR-8.
- Milestone 3 grew the in-repository caller migration (CLI, L1) that `recall`'s changed signature
  forced, along with `FindMergeCandidates` taking a `MemoryAccessContext` and returning
  `Either L1Error`. Behavior at those call sites is unchanged; plan 30 still owns the grammar and
  the deliberate breadth choice.
