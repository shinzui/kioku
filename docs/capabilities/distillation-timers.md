---
title: "Timer-driven distillation with a typed fire-outcome taxonomy"
type: Capability
description: "Schedule L1, L2, and L3 work from the events that change what each level is built from — a ramp during a live session, a debounced idle flush, and debounced regeneration — and report every fire as completed, retry-later, permanently failed, or not mine, with bounded retries and diagnostic dead letters."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-10
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-core
interface:
  - Kioku.Distill.Timer
  - Kioku.Distill.Timer.Outcome
  - Kioku.Distill.Timer.Worker
requires:
  - CAP-4
  - CAP-8
  - CAP-9
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/TimerWorkerSpec.hs
    proves: "A permanent failure dead-letters, a transient one reschedules with backoff, an unknown process manager requeues with a long delay, a drain processes every due timer in one pass, a refused or wrong-space context dead-letters, and a dead letter names the exact memory space or reports it unknown."
  - kind: test
    resource: kioku-core/test/Kioku/DistillSpec.hs
    proves: "A session accumulates one idle timer however many turns it has, two confidence changes schedule two distinct scene timers, and one worker serving two spaces keeps their artifacts disjoint."
  - kind: guide
    resource: docs/user/distillation.md
    proves: "The three L1 triggers and their constants, what schedules L2 and L3, and what each of the four fire outcomes means operationally."
  - kind: module
    resource: kioku-core/src/Kioku/Distill/Timer/Worker.hs
    proves: "The single worker step, the drain, the handler, and the outcome applier a host's own supervised loop composes."
---

# Timer-driven distillation with a typed fire-outcome taxonomy

Distillation is scheduled, not inline. [L1 passes (CAP-8)](l1-atom-distillation.md) are
driven by three timers derived from session events: a **ramp** firing immediately at
turns 1, 2, 4, 8, 16 and every 16th thereafter, so a long live session is distilled as it
goes; a **final** timer when the session completes or fails; and an **idle** timer 30
minutes after the last turn — one debounced row per session, pushed forward by each new
turn, so a 50-turn session holds one timer, not fifty.

[Scene and persona regeneration (CAP-9)](scenes-and-personas.md) is scheduled with a
5-second debounce by every event that changes what the level is built from: a memory
recorded, archived, superseded, or merged, or its confidence changed, for a scene; every
scene regeneration, including a deletion, for a persona.

Each fire returns one of four outcomes, which replaced a `Maybe EventId` whose `Nothing`
meant three incompatible things:

```haskell
data FireOutcome
  = FireCompleted EventId
  | FireRetryLater NominalDiffTime Text
  | FireFailedPermanently Text
  | FireNotMine
```

`FireRetryLater` is a transient failure — a model endpoint down, a store blip — retried at
30s doubling to a 900s cap under an eight-attempt ceiling, after which the timer becomes a
visible dead row rather than burning tokens forever. `FireFailedPermanently` is a
structurally broken timer or an authorization failure and dead-letters on the first fire.
`FireNotMine` is a timer no handler in this build owns, requeued 600s out so a rolling
deploy is safe.

Every dead-letter reason opens with the payload's diagnostic ownership — an explicit
space verbatim, or `[memory space unknown]` when the field is absent or unreadable. A
worker reads the space from the claimed timer and asks a `MemoryContextProvider` for a
decision about it, per [memory-space isolation (CAP-4)](memory-space-isolation.md);
refusal, a missing `MemoryDistill`, or a context minted for another space is permanent,
because each is a configuration fact an operator has to see.

**Kioku ships no loop function.** The supervised loop belongs to the host; Kioku provides
one step, a drain, the handler, and the outcome applier.

## Shape

```haskell
fired <- drainKiokuTimers metrics contextProvider runtime candidateFinder
```

```bash
kioku worker              # supervised: embeddings plus the timer loop
kioku worker --timers-once
```

## Limits

- The ramp points, the 30-minute idle flush, the 5-second debounce, the 5-second poll,
  and both backoff schedules are compile-time constants, not configuration.
- A dead L1 timer means that session is never distilled; a dead L2 or L3 timer means that
  scope's artifact never regenerates. Nothing retries them automatically.
- `unknown` in a dead-letter prefix is diagnostic only. A known native timer written
  before memory spaces still executes in `kioku_legacy` through the decoder's
  compatibility default.
