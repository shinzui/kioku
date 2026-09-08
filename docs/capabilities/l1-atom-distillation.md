---
title: "L1 distillation: extraction, audited consolidation, and watermarks"
type: Capability
description: "Turn a session's raw turns into durable memory atoms through two typed LLM programs, record every consolidation decision that was actually applied to an audit table, and skip a session with no new evidence before any model call."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-8
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-core
interface:
  - Kioku.Distill.L1
  - Kioku.Distill.Extract
  - Kioku.Distill.Consolidate
  - Kioku.Distill.Runtime
requires:
  - CAP-1
  - CAP-2
  - CAP-4
  - CAP-17
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/DistillSpec.hs
    proves: "A replay distills duplicate turns into one merged atom, a re-run creates no new memories or audit rows, a consolidation failure stores nothing and fails the pass, a merge naming a missing target degrades and stays convergent, and the watermark skips re-extraction until a new turn arrives."
  - kind: test
    resource: kioku-core/test/Kioku/MemorySpaceSpec.hs
    proves: "A distill-only context cannot start L1 and a context without forget cannot either, because the pass preflights all three permissions before reading the session."
  - kind: guide
    resource: docs/user/distillation.md
    proves: "The extract and consolidate stages, the four consolidation actions and how each degrades, the audit table, and the permission preflight order."
  - kind: module
    resource: kioku-core/src/Kioku/Distill/L1.hs
    proves: "distillSessionL1, the run modes, the outcome type, and the pluggable merge-candidate finder."
---

# L1 distillation: extraction, audited consolidation, and watermarks

L1 is a two-stage pass over one session's recent evidence.

The **extract** program reads the session focus, a readable scope label, and the recent
conversation, and proposes atoms: a type, one concise durable sentence, a priority, and a
confidence. Values are validated rather than coerced — priorities are clamped to 0–100,
and an atom type or confidence outside the allowed set **fails the extraction**, which is
a retryable timer fire. A negative priority would otherwise sort ahead of everything in
the scope forever.

The **consolidate** program then decides, per atom, against existing active memories:
`store`, `update`, `merge`, or `skip`. `update` and `merge` never edit in place — a new
memory is recorded that supersedes the old, and the old is merged into it, through the
ordinary [memory writes (CAP-1)](event-sourced-memory-records.md).

**The pass records what it applied, not what the model asked for.** A merge naming
targets that no longer exist degrades to a store; one whose only target is the atom's own
prior copy, or whose winner is already retired, degrades to a skip. Every decision — the
action actually applied, its targets, the resulting memory, and the rationale — is written
to `kioku.consolidation_decisions` under a deterministic key, so a re-fired timer does not
duplicate rows, while the memory changes themselves remain events.

**L1 is watermarked.** Under `RespectWatermark` a session whose turns are all covered by
the last successful pass returns `L1SkippedUpToDate` before any LLM call. The watermark
advances only when the whole pass succeeds, so a failure does not silently swallow
evidence.

Because a pass reads session evidence, records new atoms, and retires old ones, it
preflights `MemoryDistill`, `MemoryRecord`, and `MemoryForget` in that stable order
against the [access context (CAP-4)](memory-space-isolation.md), and returns
`L1NotPermitted` on the first missing one — before the session read and before the model
call.

## Shape

```haskell
outcome <- distillSessionL1 context RespectWatermark runtime candidateFinder sessionId
```

```bash
kioku distill session kioku_session_01h455... --candidates recall --limit 8
# Distilled session kioku_session_01h455...: extracted=4 stored=2 merged=1 skipped=1
```

## Limits

- The merge-candidate finder is pluggable, but the flags that select it govern the
  **CLI only**. The [timer path (CAP-10)](distillation-timers.md) — the one that runs in
  production — always uses recall-based candidates with a fixed limit of 8, because a
  priority-ordered scan prefix hides duplicates that fall below the window.
- `update` and `merge` both report as `merged=` in the summary line; there is no
  `updated=` field.
- L1 needs an authorized completion or interactive capability from
  [host-owned AI execution (CAP-17)](host-owned-ai-execution.md). With generation
  disabled there is no fallback path.
- Evidence is what the host chose to record. A host that never calls `recordTurn` on
  [a running session (CAP-2)](event-sourced-agent-sessions.md) distills from recorded
  memories instead of a transcript.
