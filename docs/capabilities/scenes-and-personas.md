---
title: "L2 scenes and L3 personas with content-hashed regeneration"
type: Capability
description: "Summarize a scope's active atoms into a readable markdown scene and its scenes into one persona document, skipping the model call whenever the hashed inputs are unchanged and deleting both artifacts when the scope empties."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-9
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-core
interface:
  - Kioku.Distill.L2
  - Kioku.Distill.L3
  - Kioku.Distill.Scene
  - Kioku.Distill.Persona
requires:
  - CAP-1
  - CAP-4
  - CAP-17
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/DistillSpec.hs
    proves: "Forget operations schedule scene timers, an emptied scope deletes its scene, persona, and mirrors, a confidence change refreshes all three while a tag change schedules nothing, and L2 and L3 reject a read-only worker before models, rows, or mirrors are touched."
  - kind: test
    resource: kioku-core/test/Kioku/SchemaSpec.hs
    proves: "Two global scenes or personas with the same key collide inside one space, and two spaces may hold the same key without colliding."
  - kind: guide
    resource: docs/user/distillation.md
    proves: "What each level summarizes, why content hashing rather than the timer debounce is what makes a burst of writes cost one regeneration, and what happens when a scope empties."
  - kind: module
    resource: kioku-core/src/Kioku/Distill/L2.hs
    proves: "regenerateScene, the scope scene reads, and the mirroring helpers; Kioku.Distill.L3 carries the persona equivalents."
---

# L2 scenes and L3 personas with content-hashed regeneration

A **scene** folds all of a scope's active atoms into one markdown block: a title naming
the dominant topic or workflow, and a short narrative body. It is what you would hand a
human, or load as a digestible context block. A **persona** distills a scope's scenes
into a single document — who or what the scope is about, its stable preferences,
constraints, project facts, and durable patterns. The persona program is instructed to
preserve only what is grounded in the scene text; it must not invent biographical facts.

**Regeneration is content-hashed.** Each pass hashes its inputs — the scope's atoms for a
scene, the scope's scenes for a persona — and an unchanged hash skips both the row write
and the model call, rewriting only the mirror file. That, and not the timer debounce, is
what makes a burst of writes cost one regeneration: the extra timers still fire, they
just short-circuit.

**Forgetting reaches the artifacts.** Superseding, archiving, or merging a memory, and
changing a memory's confidence, all schedule a scene regeneration, so retired or
downgraded content does not survive in the scene, the persona, or the mirror. A
tags-only change schedules nothing, deliberately: tags feed neither the source hash nor
the prompt. When the last active memory in a scope is forgotten, both rows and both
mirror files are **deleted** — neither delete costs a model call, because there is
nothing left to summarize. The event log keeps the history; the derived artifacts do not.

`regenerateScene` and `regeneratePersona` are low-level trusted-host seams that take the
memory space explicitly. The [timer handlers (CAP-10)](distillation-timers.md) are the
authorization boundary for background regeneration, and they require `MemoryDistill` from
the [access context (CAP-4)](memory-space-isolation.md) before calling either.

## Shape

```haskell
maybeScene   <- regenerateScene   runtime space scope
maybePersona <- regeneratePersona runtime space scope
```

```bash
kioku scenes  --scope mori:repo:proj_01h4...
kioku persona --scope rei:intention:intention_01h4...
```

## Limits

- Both seams return `Nothing` when the scope has emptied: they delete the row and its
  mirror rather than summarizing nothing.
- The schema allows several scenes per scope, but exactly one is generated today, so
  there is one scene file per scope.
- Scenes and personas are derived from [memories (CAP-1)](event-sourced-memory-records.md)
  in one exact scope. A namespace-wide view has no scene: entity-scoped rows feed their own
  scope's artifacts and nothing else.
- Generation requires an authorized capability from
  [host-owned AI execution (CAP-17)](host-owned-ai-execution.md).
