---
id: 35
slug: enforce-memory-lineage-and-centralize-write-context-gates
title: "Enforce memory lineage and centralize write-context gates"
kind: exec-plan
created_at: 2026-08-20T13:57:30Z
intention: "intention_01m0fpyzp4e2kbnhyvcm00zd9t"
master_plan: "docs/masterplans/7-remediate-the-kioku-0-3-0-0-to-0-4-0-0-release-range-review.md"
---

# Enforce memory lineage and centralize write-context gates

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Every stored supersession or merge points to a memory that exists in the same authorized memory
space. A caller cannot append `MemoryRecorded`, `MemorySuperseded`, or `MemoryMerged` with a
dangling or cross-space lineage id, and a cross-space id remains indistinguishable from an absent
one. The proof is at the public memory boundary, so callers other than L1 receive the same
invariant.

Memory and Session writes also consume one generic permission/space/actor gate from
`Kioku.Api.Access`. Their public error constructors and behavior remain unchanged, but future
hardening cannot be applied to one module while silently leaving the other behind.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Add lineage-target validation to record, supersede, and merge write paths.
- [x] Add missing, cross-space, idempotent-retry, and happy-path lineage regressions.
- [ ] Move generic context and legacy-space gates into `Kioku.Api.Access` and migrate both callers.
- [ ] Update API documentation and changelog; run API and core suites against PostgreSQL.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: The plan's focused command using `-p Idempotency` selects zero tests because the
  actual Tasty group is named `Idempotent accepts`; `-p "Idempotent accepts"` runs all 18
  intended regressions.
  Evidence: the first command reported `All 0 tests passed`; the corrected command reported
  `All 18 tests passed`.
  Date: 2026-08-21


## Decision Log

Record every decision made while working on the plan.

- Decision: A missing or cross-space lineage target returns the existing `MemoryNotFound` error.
  Rationale: introducing a target-specific error would let a caller distinguish an id in another
  space from one that never existed. Existing cross-space write behavior deliberately makes those
  cases identical.
  Date: 2026-08-20

- Decision: Validate a lineage target before the first state transition, but preserve idempotent
  retry behavior after the source memory is already retired.
  Rationale: a winner may itself be retired after a valid merge. Requiring it to remain active on
  every retry would turn an already accepted command into a later failure.
  Date: 2026-08-20

- Decision: Parameterize the shared context gate over the three module-specific error injectors.
  Rationale: `MemoryWriteError` and `SessionWriteError` are intentionally separate public types;
  sharing the decision logic does not require collapsing their error vocabularies.
  Date: 2026-08-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Kioku memory is event-sourced: `kioku-core/src/Kioku/Memory.hs` performs read-model prechecks and
then sends a command to the aggregate in `kioku-core/src/Kioku/Memory/Domain.hs`. The aggregate
stores a memory's `MemorySpaceId` and refuses later commands naming another space. References to a
different memory, however, are ordinary ids inside the event payload and are not aggregate state.

`recordIn` checks only whether the new memory id already exists, then can append a
`MemoryRecorded` whose optional `supersedes` id is missing or belongs to another space.
`supersedeIn` looks up only the memory being retired and does not validate `supersededBy`.
`mergeIn` likewise looks up only the loser and does not validate the winner. A recursive
supersession query joins within one space, so a bad reference silently ends the chain.

`kioku-core/src/Kioku/Distill/L1.hs` currently performs its own target resolution before a merge,
because a model can hallucinate a syntactically valid TypeID. That pre-planning avoids partial L1
writes but does not protect public callers of `Kioku.Memory`. It may remain as L1's graceful
degradation mechanism; the invariant must additionally live in the shared memory write boundary.

`Kioku.Memory` and `kioku-core/src/Kioku/Session.hs` each define byte-for-byte copies of
`underContext` and `inLegacySpaceOnly`. The first checks a requested permission, space equality,
and actor equality. The second confines deprecated wrappers to `legacyMemorySpaceId`. Only the
three injected errors differ. `kioku-api/src/Kioku/Api/Access.hs` is already imported by both
modules and has no dependency on `kioku-core`, so a generic `Applicative` gate can live there
without a cycle.

`kioku-core/test/Kioku/MemorySpaceSpec.hs` drives real writes and inspects event streams to prove
cross-space refusals append nothing. `kioku-core/test/Kioku/IdempotencySpec.hs` proves duplicate
record, supersede, and merge commands append one transition and conflicts remain conflicts. Extend
these suites rather than creating mock-only tests.

[The aggregate partition ADR](../adr/the-aggregate-enforces-the-partition.md) requires every
memory to remain in one space for life and cross-space ids to look absent at the read-model
boundary. [The authorization ownership ADR](../adr/kioku-owns-memory-not-identity.md) requires
Kioku to consume, not derive, a context. This work centralizes and completes those accepted
decisions; no new ADR is expected.


## Plan of Work

### Milestone 1 — The memory boundary owns lineage validity

In `Kioku.Memory`, add a private space-scoped target lookup that maps read-model failure to
`MemoryReadFailed` and both absent and cross-space rows to `MemoryNotFound`. Before `recordIn`
appends a newly created memory with `supersedes = Just target`, require that target to exist in
the command's space. Before `supersedeIn` transitions an active source, require
`supersededBy` to exist in that space. Before `mergeIn` transitions an active loser, require the
winner to exist in that space. Do not issue an unpartitioned lookup.

Preserve existing idempotence ordering. If the memory being recorded already exists, compare the
stored semantic fields as today. If a supersede or merge source is already non-active, use the
existing `idempotentOr` comparison before revalidating the winner's current status. For a first
transition, require target existence. Do not add a separate self-reference policy in this plan;
the review finding is missing/cross-space validity, and changing an otherwise existing target's
meaning belongs in a separately justified domain decision.

Keep L1's `resolveExistingTargets` until its degrade-to-store and write-before-merge behavior is
covered by an equivalent core API. The public invariant must not depend on that helper, and L1's
precheck must not be cited as the acceptance proof.

### Milestone 2 — Prove lineage behavior on real streams

Extend `MemorySpaceSpec` and `IdempotencySpec`. Cover `RecordMemoryData.supersedes`,
`SupersedeMemoryData.supersededBy`, and `mergeWithContext` with an absent target and with a target
that exists only in `otherSpace`. In each case assert `MemoryNotFound`, inspect the source stream,
and prove no new event was appended. Assert the absent and cross-space results render identically
so the change creates no existence oracle.

Add happy-path cases for same-space targets and preserve duplicate behavior when the winner is
later retired. The latter regression proves that a valid earlier supersede/merge remains
idempotent rather than depending on mutable winner status. Run these tests against
`withKiokuMigratedDatabase`, not only pure event constructors.

### Milestone 3 — One context gate, two error vocabularies

In `kioku-api/src/Kioku/Api/Access.hs`, export two generically typed helpers. The context helper
accepts functions that construct the permission, space-mismatch, and actor-mismatch error values,
then performs the existing three checks in the existing order. The legacy helper accepts the
space-mismatch constructor and confines a deprecated operation to `legacyMemorySpaceId`. Keep
them `Applicative`-polymorphic so `kioku-api` gains no Effectful dependency.

Replace both private copies in `Kioku.Memory` and `Kioku.Session` with thin local applications
that inject `MemoryNotPermitted`/`SessionNotPermitted`, the two mismatch constructors, and the
actor mismatch constructors; keep the local names `underContext` and `inLegacySpaceOnly` as
module-private partial applications so call sites remain compact. Their bodies must contain no
decision logic. Add pure API tests with sentinel error constructors plus existing core tests to
prove each public error stays unchanged.

Update `docs/user/library-api.md` to name the common gate as an internal consistency mechanism,
not a new way to mint contexts. Add fixed notes to `kioku-api/CHANGELOG.md` and
`kioku-core/CHANGELOG.md`, format, and run all API/core tests.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/kioku`.

Reconfirm source and dependents before editing the public API:

```bash
mori registry show shinzui/kioku --full
mori registry dependents shinzui/kioku --packages
rg -n 'underContext|inLegacySpaceOnly|recordIn|supersedeIn|mergeIn' \
  kioku-api/src kioku-core/src kioku-core/test
```

After the lineage milestone, run focused database tests:

```bash
nix fmt
cabal test kioku-core:kioku-test --test-options='-p "Memory space isolation"'
cabal test kioku-core:kioku-test --test-options='-p Idempotency'
```

After the shared gate lands, run the whole affected surface:

```bash
cabal build kioku-api kioku-core
cabal test kioku-api:kioku-api-test kioku-core:kioku-test
git diff --check
```

Expected result is zero failed tests and no incomplete-pattern warning introduced in the public
error types.


## Validation and Acceptance

For each lineage-bearing operation, a missing target and a target in another memory space return
the same `MemoryNotFound` result. `readStreamForward` shows only the source's earlier events, and
the bad target id appears in no newly stored event. A valid same-space target succeeds and the
read model's `supersedes` or `superseded_by` field contains it.

A repeated valid supersede or merge remains successful without a second transition, including
after the winner is subsequently retired. Existing different-winner conflicts remain conflicts.

Memory and Session permission denial, payload-space mismatch, actor mismatch, and deprecated
non-legacy wrapper tests return their exact existing constructors. Pure API tests exercise the
generic helper with different injected error types, demonstrating there is one branch ordering
without coupling the two core error types. Full API and core suites pass.


## Idempotence and Recovery

There is no schema or data migration. Rejected commands append nothing and may be retried after
the caller supplies a valid target. Accepted commands retain existing at-least-once semantics.

Implement target validation additively and keep stream assertions green after each operation.
For the gate refactor, add the generic API helper and tests before deleting either local copy;
migrate Memory and Session one at a time. If a downstream compile failure exposes reliance on a
newly exported helper name, that is not a reason to export context constructors or weaken the
gate—rename the helper while preserving its semantics.


## Interfaces and Dependencies

The exact names may follow repository style, but `Kioku.Api.Access` must expose behavior
equivalent to:

```haskell
underMemoryContext ::
  Applicative f =>
  (MemoryPermission -> err) ->
  (MemorySpaceId -> MemorySpaceId -> err) ->
  (RecordedPrincipal -> RecordedPrincipal -> err) ->
  MemoryAccessContext ->
  MemoryPermission ->
  MemorySpaceId ->
  RecordedPrincipal ->
  f (Either err a) ->
  f (Either err a)

inLegacyMemorySpaceOnly ::
  Applicative f =>
  (MemorySpaceId -> MemorySpaceId -> err) ->
  MemorySpaceId ->
  f (Either err a) ->
  f (Either err a)
```

Do not export the `MemoryAccessContext` constructor. `Kioku.Memory` retains all current public
write signatures and `MemoryWriteError` constructors. Lineage checks use existing
`getMemoryRowById`/read-model lookup machinery inside one space and existing Store effects. No
new library or service dependency is required.
