---
title: "Event-sourced agent sessions, turns, and park-and-resume"
type: Capability
description: "Record an agent run as an aggregate with strictly ordered conversation turns, continuation and delegation lineage validated at start, and a durable awaiting state whose resume correlation key is checked against replayed state rather than a read model."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-2
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-api
  - kioku-core
interface:
  - Kioku.Session
  - Kioku.Session.Domain
  - Kioku.Session.ReadModel
requires:
  - CAP-3
  - CAP-4
  - CAP-12
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/AwaitingSpec.hs
    proves: "Park then resume round-trips, the awaiting session is findable by correlation key, the aggregate rehydrates after a crash, and a mismatched key is rejected."
  - kind: test
    resource: kioku-core/test/Kioku/SessionInvariantsSpec.hs
    proves: "A stale resume after a re-park is rejected, forceResume waives the key check and nothing else, a keyed resume of a keyless wait is refused, and turn indexes must strictly increase."
  - kind: test
    resource: kioku-core/test/Kioku/SessionLineageSpec.hs
    proves: "A session may not be its own predecessor or parent, delegation depth must agree with parentSessionId and stay within the cap, and getChain terminates on a cyclic chain."
  - kind: module
    resource: kioku-core/src/Kioku/Session.hs
    proves: "The lifecycle writes, the SessionWriteError taxonomy, and the chain, delegation, focus, range, and correlation-key reads."
  - kind: guide
    resource: docs/user/library-api.md
    proves: "The session write signatures, SessionRow's fields, and what each conflict and lineage error means."
---

# Event-sourced agent sessions, turns, and park-and-resume

A session is one agent run, anchored to [a scope (CAP-3)](host-agnostic-memory-scopes.md) and
recorded on [a typed event stream (CAP-12)](typed-event-streams-and-codecs.md). Every write
takes an [access context (CAP-4)](memory-space-isolation.md) and asks it for `MemoryRecord`:
a session, its turns, and its lifecycle are memory being recorded.

`startWithContext` opens a session; `completeWithContext` or
`failSessionWithContext` closes it; `awaitInputWithContext` parks it while the host
waits for something external, and `resumeWithContext` restarts it. Closing an
already-closed session **conflicts** rather than silently succeeding: completing a
failed session, or failing a completed one, returns `SessionConflict`.

**Resume correlation is an aggregate invariant.** The key a resume supplies must
equal the key the session actually parked on — exactly, including the keyless case,
where a resume must also supply no key. Because the awaited key is part of replayed
state, a caller holding a stale key cannot answer a wait that was already resumed and
re-parked under a new one. `forceResumeWithContext` waives that check explicitly for an
operator whose key is lost or wrong; it waives nothing else, and the session must still
belong to the space the context authorizes.

**Lineage is validated at `start`**, on two independent axes. `previousSessionId` is a
chronological continuation chain that `getChain` follows; `parentSessionId` plus
`delegationDepth` record delegated child work that `getDelegationChildren` lists. A
session may not be its own predecessor or parent, depth must be non-negative, capped,
and consistent with the parent link. Existence of the referenced sessions is *not*
checked — a dangling pointer is harmless, and requiring existence would forbid
out-of-order ingestion.

While a session is running, `recordTurnWithContext` captures raw turns — role, content,
tool summary, token counts. Turns are the **L0 evidence floor** that
[L1 distillation (CAP-8)](l1-atom-distillation.md) feeds on. A turn's identity is
`(sessionId, turnIndex)` and `turnId` is an idempotency token that travels with it;
indexes must strictly increase, so a stale or out-of-order turn cannot overwrite a
committed one.

## Shape

```haskell
sid <- Session.startWithContext context startData
_   <- Session.recordTurnWithContext context turnData
_   <- Session.awaitInputWithContext context awaitData {correlationKey = Just "review-42"}
_   <- Session.resumeWithContext context resumeData {correlationKey = Just "review-42"}
_   <- Session.completeWithContext context completeData
```

## Limits

- The awaiting `deadline` is **advisory**. Kioku stores it for the host's bookkeeping
  and does not enforce it: no timer fires and nothing expires when it passes.
- `recordInteractive` records a terminal metadata-only marker for an externally managed
  interactive run. It carries no transcript, summary, or completion time — use a normal
  running session plus `recordTurn` when a conversation must become L0 evidence.
- `recordTurn` succeeds only while a session is `running`; a closed or parked session
  returns `SessionNotRunning`.
- Reusing a `turnId` across two different sessions is a caller bug that surfaces as a
  raw store failure rather than a typed conflict.
