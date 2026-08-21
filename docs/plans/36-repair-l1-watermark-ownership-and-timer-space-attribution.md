---
id: 36
slug: repair-l1-watermark-ownership-and-timer-space-attribution
title: "Repair L1 watermark ownership and timer-space attribution"
kind: exec-plan
created_at: 2026-08-20T13:57:30Z
intention: "intention_01m0fpyzp4e2kbnhyvcm00zd9t"
master_plan: "docs/masterplans/7-remediate-the-kioku-0-3-0-0-to-0-4-0-0-release-range-review.md"
---

# Repair L1 watermark ownership and timer-space attribution

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

An L1 watermark row that carries the wrong memory space repairs itself on the next successful
pass, and the following timer fire becomes a cheap database skip instead of repeating extraction
forever. Timer diagnostics also distinguish an explicitly named legacy space from a payload that
does not name any space: malformed or foreign payloads say `[memory space unknown]` rather than
misdirecting operators toward `kioku_legacy`.

Both outcomes are visible in PostgreSQL-backed regressions: one deliberately corrupts a
watermark's space and observes self-healing plus a zero-LLM second pass; another dead-letters
space-less payloads and inspects the exact `last_error` prefix.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-21) Make the existing session-id conflict update repair `memory_space_id` monotonically.
- [x] (2026-08-21) Add a corrupt-watermark regression proving the next pass heals and the following one skips.
- [x] (2026-08-21) Separate optional diagnostic space parsing from legacy-defaulting action parsing.
- [x] (2026-08-21) Add malformed/foreign/explicit-space diagnostic tests.
- [ ] Update operator documentation and the core changelog.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `mori://shinzui/keiro/packages/keiro` applies `TimerWorkerOptions.maxAttempts` immediately after
  claim and before invoking the caller's fire callback. Kioku's former ceiling therefore bypassed
  `spaceQualified` and the fire span entirely. The focused worker suite now proves the same ninth
  claim is dead-lettered through Kioku's callback with `[memory space unknown]`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep `ON CONFLICT (session_id)` and set `memory_space_id = EXCLUDED.memory_space_id`.
  Rationale: `session_id` remains the watermark table's primary key and session ids are globally
  unique. A composite conflict target would require a schema change and permit two watermarks for
  one session; updating the owner repairs the single authoritative row.
  Date: 2026-08-20

- Decision: Use separate action and diagnostic parsers.
  Rationale: native pre-partition timers must default an absent field to the legacy space when
  executing, but a generic diagnostic must not claim a payload explicitly named that space when
  the field is absent or malformed.
  Date: 2026-08-20

- Decision: Enforce Kioku's eight-attempt ceiling inside its fire callback while passing `Nothing`
  for Keiro's pre-callback ceiling.
  Rationale: the comparison remains the same post-claim `attempts > 8` boundary, but the callback
  is the only layer that can add Kioku's required memory-space text and fire-span outcome before
  dead-lettering.
  Date: 2026-08-21


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

L1 distillation stores the highest successfully processed turn index in
`kioku.l1_watermarks`. `kioku-core/src/Kioku/Distill/L1.hs` reads by
`(memory_space_id, session_id)` but its `upsertWatermarkStmt` inserts those two values and resolves
conflict on `session_id` alone. The update advances `last_turn_index` with `GREATEST` and refreshes
`distilled_at`, but leaves `memory_space_id` unchanged. A divergent row is therefore updated yet
never visible to the same pass's later reads.

Migration `kioku-migrations/migrations/0007-kioku-l1-watermarks.sql` created `session_id` as the
primary key. Migration 0011 added and backfilled `memory_space_id` and performed a one-time drift
check, but added no persistent foreign key tying the row to `kioku.sessions`. Because a session id
is globally unique, there should still be exactly one watermark row per session.

`kioku-core/src/Kioku/Distill/Timer/Worker.hs` prefixes dead-letter reasons and trace attributes
using `timerPayloadSpace`. That helper calls `Kioku.Partition.parsePartitionSpace`, which
deliberately defaults a missing `memorySpaceId` to `legacyMemorySpaceId` for historical event and
timer execution. Used for generic diagnostics, the same default labels `{}` from an unknown
process manager and malformed object payloads as `kioku_legacy`.

`kioku-core/test/Kioku/DistillSpec.hs` already proves normal watermark skipping.
`kioku-core/test/Kioku/TimerWorkerSpec.hs` proves a valid payload's dead-letter names its space and
an unknown process manager eventually hits the attempt ceiling, but it does not assert the
space-less diagnostic prefix.

[Legacy data lands in one explicit space](../adr/legacy-data-lands-in-one-explicit-space.md)
requires absence to default to `kioku_legacy` for execution and replay. [The filesystem and
diagnostics ADR](../adr/the-partition-reaches-the-filesystem-as-a-digest.md) requires every
dead-letter and timer trace to name the payload's space and reserves `unknown` for payloads that
have none. This plan reconciles those two accepted meanings at separate call sites. No new ADR is
needed.


## Plan of Work

### Milestone 1 — A watermark upsert repairs ownership

In `Kioku.Distill.L1.upsertWatermarkStmt`, keep the existing insert columns and
`ON CONFLICT (session_id)`, then set `memory_space_id = EXCLUDED.memory_space_id` in the update
alongside the monotonic turn index and timestamp. Do not change the primary key or add a new
migration. The pass has already loaded the session from `memoryContextSpace context`, so the
excluded space is the validated current owner.

Extend `Kioku.DistillSpec`. Create a session and complete one successful pass, directly update its
watermark row to `otherSpace` through a test-only Hasql statement, and prove a read in the real
space no longer covers the session. Run another successful pass with a counted extractor and
assert the row's `memory_space_id` returns to the session's space. Run a third pass with an
extractor that fails if called and assert `L1SkippedUpToDate`. Also assert the repaired turn index
never decreases.

### Milestone 2 — Diagnostics parse only explicit ownership

In `kioku-core/src/Kioku/Partition.hs`, add an optional parser for diagnostics with behavior
equivalent to `o .:? "memorySpaceId"`: present valid text becomes `Just space`; absent, null, or
malformed content causes `timerPayloadSpace` to return `Nothing` through `Aeson.parseMaybe`.
Keep `parsePartitionSpace` unchanged and continue using it in `L1TimerPayload`,
`SceneTimerPayload`, and `PersonaTimerPayload` action codecs. If EP-2 has already introduced a
shared payload parser, update that parser only for action decoding and add the optional helper
beside it without merging their semantics.

Change `Timer.Worker.timerPayloadSpace` to use the optional parser. Existing
`spaceQualified` and `timerSpanAttributes` then naturally render `unknown`/omit the attribute for
space-less payloads. Do not add a metric label.

Extend `TimerWorkerSpec` with three cases. A malformed object dead-letter says
`[memory space unknown]`; an unknown process manager with an object lacking `memorySpaceId`,
forced to the attempt ceiling, says unknown; and a valid explicit payload still names the exact
space. Keep the pre-partition execution test: a known old payload without the field still acts in
`legacyMemorySpaceId`.

### Milestone 3 — Operational contract and full tests

Update `docs/user/distillation.md` and `docs/user/troubleshooting.md` to explain that an explicit
legacy payload is reported as `kioku_legacy`, while absent or unreadable ownership is `unknown`.
Add fixed notes to `kioku-core/CHANGELOG.md`. Format and run the complete core suite. Acceptance
is both correct operator text and unchanged legacy execution behavior.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/kioku`.

Reconfirm the table and parser shapes:

```bash
rg -n 'kioku_l1_watermarks|upsertWatermarkStmt|selectWatermarkStmt' \
  kioku-migrations/migrations kioku-core/src kioku-core/test
rg -n 'parsePartitionSpace|timerPayloadSpace|spaceQualified' \
  kioku-core/src kioku-core/test
```

After editing, format and run focused tests:

```bash
nix fmt
cabal test kioku-core:kioku-test --test-options='-p watermark'
cabal test kioku-core:kioku-test --test-options='-p "Timer worker"'
```

Then run the complete affected package:

```bash
cabal build kioku-core
cabal test kioku-core:kioku-test
git diff --check
```

Expected behavior in the new timer assertions includes:

```text
[memory space unknown]
[memory space space_test]
```


## Validation and Acceptance

The watermark regression must fail against the old SQL: after the second pass the row would still
belong to `otherSpace`, and the third pass would call the exploding extractor. With the repair,
the second pass invokes extraction exactly once, moves the row back to the session's space, and
the third returns `L1SkippedUpToDate` without extraction.

A malformed or foreign object that does not carry a valid `memorySpaceId` is dead-lettered with
`[memory space unknown]`. A valid payload carrying `testSpace` names that exact id. A known
pre-partition L1/L2/L3 payload without the field still decodes and executes in
`legacyMemorySpaceId`; only generic attribution changed.

No migration file or manifest entry changes, no metric gains a space label, and the full core
suite passes.


## Idempotence and Recovery

The upsert stays idempotent and monotonic. Repeating it with the same space and turn index changes
only `distilled_at`; a later lower turn index cannot rewind `last_turn_index`. If an operator has
divergent rows, normal successful passes repair them without manual SQL.

The diagnostic change mutates no timer payload. Dead-letter and trace text are observations only.
Requeue a dead timer after correcting its malformed payload or installing the owning handler;
`unknown` is a prompt to inspect the payload, not a substitute memory space.


## Interfaces and Dependencies

`Kioku.Partition.parsePartitionSpace` retains:

```haskell
parsePartitionSpace :: Object -> Parser MemorySpaceId
```

Add a distinctly named helper equivalent to:

```haskell
parseOptionalPartitionSpace :: Object -> Parser (Maybe MemorySpaceId)
```

Only `Timer.Worker.timerPayloadSpace` consumes the optional helper. The watermark statement keeps
its `Statement WatermarkRow ()` type and existing encoder. Use existing `aeson`, `hasql`, and
test-support APIs; no new package, service, schema constraint, or cross-repository dependency is
required.
