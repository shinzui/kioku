---
id: 34
slug: enforce-distillation-permissions-through-shared-timer-primitives
title: "Enforce distillation permissions through shared timer primitives"
kind: exec-plan
created_at: 2026-08-20T13:57:30Z
intention: "intention_01m0fpyzp4e2kbnhyvcm00zd9t"
master_plan: "docs/masterplans/7-remediate-the-kioku-0-3-0-0-to-0-4-0-0-release-range-review.md"
---

# Enforce distillation permissions through shared timer primitives

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A context authorized only to read can no longer regenerate scenes or personas, and a context
authorized only to distill can no longer make an L1 pass spend LLM calls before its later memory
writes are refused. L1 verifies `MemoryDistill`, `MemoryRecord`, and `MemoryForget` before any
read or model call. L2 and L3 verify `MemoryDistill` before regeneration. A refusal is a permanent
timer failure with the missing permission named for the operator.

The L2/L3 handlers are rebuilt from shared payload, partition-parameter, fire-pipeline, and
best-effort deletion primitives. This is part of the correctness fix: the two handlers drifted
together because their nearly identical authorization pipeline existed twice.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-21T17:35:10Z) Add shared partition-scope, payload-parser, timer-fire, and mirror-removal primitives.
- [x] (2026-08-21T17:40:52Z) Require all L1 permissions before work and `MemoryDistill` in both derived-artifact handlers.
- [x] (2026-08-21T17:40:52Z) Add denial regressions proving no LLM call, row change, or mirror write occurs.
- [x] (2026-08-21T17:44:39Z) Update authorization and distillation documentation; run API, core, and CLI suites.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The direct `regenerateScene` and `regeneratePersona` functions remain low-level trusted-host
  seams; authorization belongs to the timer boundary that first receives a provider decision.
  This distinction was implicit in the source-compatible interface requirement and is now explicit
  in `docs/user/library-api.md` and ADR-4.
- The complete validation environment had no reachable pgvector extension, so the core suite kept
  its existing vector-only skips. The affected authorization and distillation paths all executed:
  119 API tests, 220 core tests, and 50 CLI tests passed with zero failures.


## Decision Log

Record every decision made while working on the plan.

- Decision: L1 requires `MemoryDistill`, `MemoryRecord`, and `MemoryForget` as an up-front set.
  Rationale: the pass records new atoms and may supersede or merge old ones through public memory
  APIs that independently enforce record and forget. Checking only distill promises work that the
  context cannot finish and can repeat paid LLM calls on every timer retry.
  Date: 2026-08-20

- Decision: L2 and L3 require `MemoryDistill`, but not `MemoryRecord` or `MemoryForget`.
  Rationale: they write derived scene/persona projections and mirrors rather than issuing memory
  aggregate commands. `MemoryDistill` is the permission whose documented meaning includes reads
  of evidence and writes of derived memory artifacts.
  Date: 2026-08-20

- Decision: Consolidate the whole L2/L3 fire decision, not only the new permission predicate.
  Rationale: keeping decode, provider, permission, retry, and completion branches in two functions
  would leave the next hardening edit vulnerable to the same one-sided change.
  Date: 2026-08-20

- Decision: Keep direct scene/persona regeneration as trusted-host seams and enforce provider
  permission and space agreement in the background timer boundary.
  Rationale: the public regeneration signatures remain source-compatible, while the timer handler
  is the first component that holds both the untrusted payload space and the host's authorization
  decision. Validating there prevents provider success from retargeting work or bypassing
  `MemoryDistill`.
  Date: 2026-08-21


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Completed on 2026-08-21. L1 now refuses the first missing permission from
`[MemoryDistill, MemoryRecord, MemoryForget]` before reading session evidence. L2 and L3 share one
payload/provider/outcome pipeline that rejects provider refusal, missing distill permission, and
wrong-space contexts before regeneration. Partitioned SQL parameters and mirror removal likewise
have one owner instead of two copies.

Database-backed regressions prove denied L2/L3 work makes no model call, derived row, or mirror;
the wrong-space provider case is also permanent and diagnostic. User documentation and the core
changelog describe the service-host permission requirements. The full API, core, and CLI suites
passed (119, 220, and 50 tests respectively); pgvector-only cases retained their environment skip.
ADR-4 was amended rather than adding a new record because it already owns background context and
partition validation. No EP-2 work remains.


## Context and Orientation

`MemoryAccessContext` is proof that a host authorized a principal for named permissions in one
memory space. Its constructor is private; `Kioku.Api.Access.memoryContextAllows` checks a
permission and `memoryContextSpace` reads the authorized partition. A background worker does not
know its space until it claims work, so it receives a `MemoryContextProvider` and asks for a
context after decoding the timer payload.

`kioku-core/src/Kioku/Distill/L1.hs` implements `distillSessionL1`. It currently checks only
`MemoryDistill`, then reads a session, calls extraction and consolidation models, and invokes
`Memory.recordWithContext`, `Memory.supersedeWithContext`, or `Memory.mergeWithContext`. Those
memory functions require `MemoryRecord` or `MemoryForget`, so a context granting exactly
`MemoryDistill` passes the expensive preflight and fails later.

`kioku-core/src/Kioku/Distill/L2.hs` and `Kioku/Distill/L3.hs` implement scene and persona timer
handlers. Both decode an object containing `memorySpaceId` and `scope`, ask the provider for a
context, discard the context down to its space, and regenerate without calling
`memoryContextAllows`. They also independently define the same `PartitionedScope` record and
Hasql encoder, the same fire pipeline, and the same `removeIfPresent` helper.

`kioku-core/src/Kioku/Distill/Timer/Outcome.hs` already sits below L2, L3, and the worker in the
module graph. It owns `FireOutcome`, retry delay, and marker event creation and is cycle-free for a
shared fire helper. `kioku-core/src/Kioku/Partition.hs` owns memory-space JSON and PostgreSQL
encoding and is the correct home for a shared partition-plus-scope parameter record.
`kioku-core/src/Kioku/Workspace.hs` owns artifact filesystem mechanics and is the correct home for
best-effort removal of a file only if it exists.

`kioku-core/test/Kioku/MemorySpaceSpec.hs` proves a context without distill fails L1 before the
extractor runs. `kioku-core/test/Kioku/TimerWorkerSpec.hs` proves a provider-level refusal
dead-letters, but it does not cover a provider returning a valid context that lacks distill.
`kioku-core/test/Kioku/DistillSpec.hs` exercises L1/L2/L3 with a real PostgreSQL schema and fake
model functions.

[ADR-1](../adr/kioku-owns-memory-not-identity.md) requires Kioku to validate a supplied decision
without owning policy. [ADR-4](../adr/the-aggregate-enforces-the-partition.md) requires background
work to obtain a context for the payload's space and dead-letter refusals. This plan applies both
records and changes no durable architecture, so no new ADR is expected unless implementation
uncovers a broader permission-semantics change.


## Plan of Work

### Milestone 1 — Shared primitives below the handlers

In `kioku-core/src/Kioku/Partition.hs`, export a named `PartitionedScope` record with fields
`memorySpaceId`, `namespace`, `scopeKind`, and `scopeRef`, plus a constructor from
`MemorySpaceId` and `MemoryScope` and its Hasql `Params` encoder. Preserve the current field order
because it fixes `$1` through `$4` in every L2/L3 statement. Delete the two private copies and
make their query-key wrappers consume the shared value.

In `kioku-core/src/Kioku/Distill/Timer/Outcome.hs`, add a shared parser helper for the common
partitioned-scope payload and a shared fire pipeline. Keep `SceneTimerPayload` and
`PersonaTimerPayload` as public named types, but make their `FromJSON` instances delegate to the
same parser so old payloads continue defaulting through `parsePartitionSpace`. The fire helper
must check the process-manager name, decode the shared fields with a caller-supplied label, request
a context for the decoded space, verify `MemoryDistill`, call the supplied regeneration action
with the authorized space and decoded scope, and translate success/failure to the existing
`FireOutcome` taxonomy. Provider denial and missing permission are permanent failures;
regeneration errors are retryable; success uses `timerMarkerEventId`.

In `kioku-core/src/Kioku/Workspace.hs`, export `removeIfPresent :: FilePath -> IO ()`. Replace the
private L2 and L3 copies with this helper. Acceptance is that L2 and L3 contain no local
`PartitionedScope`, no hand-written fire decision tree, and no local `removeIfPresent`, while all
existing codec and timer tests pass.

### Milestone 2 — Permission-complete preflights

In `distillSessionL1`, evaluate required permissions in stable order
`[MemoryDistill, MemoryRecord, MemoryForget]` before reading the session. Return
`L1NotPermitted missingPermission` for the first missing item. The order preserves the existing
error for a read-only context and gives hosts a deterministic next permission to request.

Make `fireL2SceneTimer` and `fireL3PersonaTimer` thin applications of the shared fire helper.
The helper must reject a `Right context` lacking `MemoryDistill`; provider success is not itself
permission success. Use `memoryContextSpace context` for regeneration after the permission check.
If the provider somehow returns a context for a different space than requested, treat that as a
permanent configuration failure rather than silently retargeting work.

Add L1 tests for contexts missing `MemoryRecord` and `MemoryForget`, with an extractor that fails
the test if invoked. Add L2 and L3 timer tests using a provider that returns a read-only context;
assert permanent failure/dead-letter text names `MemoryDistill`, fake scene/persona model
functions are not invoked, database rows do not change, and no mirror appears. Keep the existing
provider-denial tests distinct.

### Milestone 3 — Contract documentation and verification

Update the permission table and examples in `docs/user/upgrading-to-memory-spaces.md`,
`docs/user/library-api.md`, `docs/user/distillation.md`, and any worker troubleshooting text that
currently says provider success alone authorizes a fire. A service-backed host must request all
three L1 permissions when minting a context; an embedded host remains unchanged because
`assumeAuthorizedMemoryContext` grants all permissions. Add a fixed entry to
`kioku-core/CHANGELOG.md`. Run API tests because the permission vocabulary lives there, then the
complete core and CLI suites.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/kioku`.

Before editing, use the repository source of truth for all dependency APIs; this plan adds none:

```bash
mori registry show shinzui/kioku --full
rg -n 'fireL2SceneTimer|fireL3PersonaTimer|PartitionedScope|removeIfPresent|MemoryDistill' \
  kioku-core/src kioku-core/test docs/user
```

After each milestone, format and run focused behavior:

```bash
nix fmt
cabal test kioku-core:kioku-test --test-options='-p "Memory space isolation"'
cabal test kioku-core:kioku-test --test-options='-p "Timer worker"'
cabal test kioku-core:kioku-test --test-options='-p Distill'
```

Expected result is zero failures. Then run the complete affected workspace:

```bash
cabal build kioku-api kioku-core kioku-cli
cabal test kioku-api:kioku-api-test kioku-core:kioku-test kioku-cli:kioku-cli-test
git diff --check
```


## Validation and Acceptance

For L1, a context granting only `MemoryDistill` returns `Left (L1NotPermitted MemoryRecord)` and
the extractor invocation count remains zero. A context granting distill and record returns
`Left (L1NotPermitted MemoryForget)` with the same zero count. A full context continues to skip an
up-to-date watermark or distill normally.

For L2 and L3, a provider-level `Left denial` still dead-letters as not authorized. A provider
returning `Right readOnlyContext` now also dead-letters, specifically naming the missing distill
permission; before this change it would regenerate. Tests assert no model call, row mutation, timer
reschedule, or workspace write. A full context completes and marks the timer fired.

Native pre-partition L2/L3 payloads without `memorySpaceId` still decode into
`legacyMemorySpaceId` for execution. Moving their parser behind a shared helper must not turn
historical work into malformed payloads. The complete API, core, and CLI suites pass.


## Idempotence and Recovery

These are code and documentation changes with no schema mutation. Re-running tests and formatting
is safe. A timer dead-lettered because its worker context lacks a permission should be requeued
only after the host fixes its `MemoryContextProvider`; retries cannot create permission. Existing
dead-letter recovery guidance remains valid.

If the shared-helper refactor causes a regression, keep each milestone compiling and tests green
before deleting the old private helper. The source transformation is additive first: introduce
the shared primitive, migrate L2, migrate L3, then remove the duplicates.


## Interfaces and Dependencies

`Kioku.Partition` owns a public-to-`kioku-core` internal record and helpers equivalent to:

```haskell
data PartitionedScope = PartitionedScope
  { memorySpaceId :: MemorySpaceId
  , namespace :: Text
  , scopeKind :: Maybe Text
  , scopeRef :: Maybe Text
  }

partitionedScope :: MemorySpaceId -> MemoryScope -> PartitionedScope
partitionedScopeEncoder :: E.Params PartitionedScope
```

`Kioku.Workspace` exports:

```haskell
removeIfPresent :: FilePath -> IO ()
```

`Kioku.Distill.Timer.Outcome` additionally exports behavior equivalent to:

```haskell
parsePartitionedScopeFields
  :: Object
  -> Parser (MemorySpaceId, MemoryScope)

firePartitionedDistillTimer
  :: Show err
  => Text
  -> String
  -> MemoryContextProvider (Eff es)
  -> TimerRow
  -> (MemorySpaceId -> MemoryScope -> Eff es (Either err result))
  -> Eff es FireOutcome
```

The `Text` is the expected process-manager name and the `String` is the diagnostic payload label.
The helper is the only provider/permission/outcome translation used by L2 and L3. Public
signatures of `fireL2SceneTimer`, `fireL3PersonaTimer`, `SceneTimerPayload`, and
`PersonaTimerPayload` stay source-compatible.

No new package dependency is required. Use existing `aeson`, `hasql`, `effectful`, `directory`,
and Kioku API types. Do not import L2 from L3 or L3 from L2 for the shared mechanics; the helper
must remain below both modules to preserve the cycle-free graph.
