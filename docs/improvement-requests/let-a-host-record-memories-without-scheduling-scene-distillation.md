---
type: Improvement Request
title: Let a host record memories without scheduling scene distillation
description: Give a host that only stores and recalls memories a supported way to turn off scene-timer scheduling for a memory space, so its writes do not accumulate timers that nothing fires or that spend model calls on scenes nobody reads.
generated:
  by: claude-code/claude-fable-5-2
  at: "2026-11-19T05:58:53Z"
timestamp: 2026-11-19T05:58:53Z
requestId: IR-8
status: proposed
origin: mori://shinzui/mori-kaizen
acceptanceCriteria:
  - id: AC-1
    statement: A host can declare, per memory space or per runtime, that memory events schedule no scene timer; record, supersede, archive, merge and confidence changes then append their events and update the read models without writing a timer row.
    verification: A PostgreSQL test records, supersedes and archives memories with scheduling off and asserts that no timer exists for the `kioku-l2-scene` process manager while recall returns the expected memories.
  - id: AC-2
    statement: With scheduling on, which stays the default, behaviour is unchanged.
    verification: The existing distillation and memory suites pass unchanged.
  - id: AC-3
    statement: Turning scheduling on later for a space that wrote memories with it off has a documented way to bring scenes up to date.
    verification: The distillation guide names the command or function, and a test runs it and asserts a scene exists for a scope written while scheduling was off.
  - id: AC-4
    statement: The setting and its consequences for scene and persona readers are documented.
    verification: "`docs/user/distillation.md` and `docs/user/library-api.md` describe it."
---

# Improvement Request: Let a host record memories without scheduling scene distillation

## Status

- **Status:** proposed (2026-11-19)
- **Origin:** `mori://shinzui/mori-kaizen`, raised while planning
  `mori://shinzui/mori-kaizen/plans/3-remember-friction-observations-in-kioku-and-recall-them-across-repositories`
- **Owner of the build:** `shinzui/kioku`

## Context

mori-kaizen (`mori://shinzui/mori-kaizen`) embeds Kioku as a library and uses it as a recall
index: it records one memory per friction entry it observes in the owner's repositories,
supersedes the memory when the entry changes, and asks for similar entries across repositories.
Its own database holds the authoritative copy, so it has no use for scenes or personas. The
initial load is several hundred memories, written by a daemon that runs no `kioku worker`.

## What exists today

Verified on 2026-11-19 against Kioku 0.13.0.0 at `ac4393d`.

- `Kioku.Memory.runMemoryCommandChanged` runs every memory command with
  `typedInlineProjections kiokuProjectionCatalog memoryProjectionSet <> [l2SceneTimerScheduleProjection]`.
  The scene projection is appended unconditionally.
- `Kioku.Distill.L2.scheduleSceneTimersForEvent` schedules a timer in the append transaction
  for `MemoryRecorded`, `MemoryArchived`, `MemorySuperseded`, `MemoryMerged` and confidence
  changes. The timer id includes the memory id or the event id, so each write schedules its own
  timer.
- A host with no timer worker accumulates one unfired timer per write. A host that later starts
  a worker regenerates a scene for every scope those timers name, which calls the model when AI
  is configured.
- No option on the write path, the memory space, or the runtime disables this.

## Requested change

Add the opt-out as the acceptance criteria describe. Where it lives (memory space policy,
runtime configuration, or an argument to the context) is the maintainer's choice; the request is
that a store-and-recall host needs neither a worker nor a cleanup job.

## Non-goals

- Changing the default.
- Disabling the embedding worker, which such a host does want when vectors are configured.

## Workaround

Leave the timers unfired and never run a timer worker against the database, or run one with AI
unconfigured so the timers drain without model calls. Neither is documented as supported.
