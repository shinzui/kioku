---
title: "Deferred interactive work: parking and leased foreground resume"
type: Capability
description: "Park background timer work that would need an interactive session under a stable dead-letter reason instead of silently falling back to an HTTP provider, then let an operator list it and resume it in the foreground under a renewable Keiro lease that rechecks authorization and admits exactly one winner."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-18
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: unreleased
packages:
  - kioku-core
  - kioku-cli
interface:
  - Kioku.Distill.Timer.Deferred
requires:
  - CAP-10
  - CAP-17
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/TimerWorkerSpec.hs
    proves: "Interactive unavailability stays parked across repeated worker runs, deferred discovery recovers an expired foreground claim, resume preflights preserve attempts and recheck access, resume has exactly one concurrent winner, a cancelled resume re-parks the original timer, and ordinary dead letters and malformed payloads cannot resume."
  - kind: test
    resource: kioku-cli/test/Kioku/Cli/RecallEndToEndSpec.hs
    proves: "The deferred commands list parked work, refuse disabled execution, and complete the original work rather than a copy of it."
  - kind: guide
    resource: docs/user/configuration.md
    proves: "The operator sequence — list, then resume with an explicit AI config — the lease renewal and expiry timings, and the attempt accounting."
  - kind: guide
    resource: docs/adr/host-owned-ai-execution.md
    proves: "Why unavailable interactive work is parked through Keiro's dead-letter operation under a stable reason prefix, and what a leased claim does and does not promise."
---

# Deferred interactive work: parking and leased foreground resume

A background worker cannot own a terminal session, so a timer whose configured feature
needs [interactive execution (CAP-17)](host-owned-ai-execution.md) has no way to run. It is
**parked**, not downgraded: the timer is dead-lettered through Keiro's existing operation
under the stable reason prefix `kioku:deferred:interactive-unavailable`, and no HTTP or
batch fallback occurs. Polling cannot reclaim it — repeated worker passes leave it parked —
so the work waits for a human with a terminal rather than quietly running somewhere the host
did not authorize.

`listDeferredTimers` takes the host's current `MemoryContextProvider` and a bounded page
request, and returns only what the caller is authorized to see; a page whose entries are all
filtered out still yields its `nextAfterTimerId`, so authorization filtering never truncates
the walk. `resumeDeferredTimer` rechecks space authorization and session ownership **before**
claiming, then atomically claims the original timer by its id, its process-manager owner, and
the expected deferred reason. That last predicate is why an ordinary dead letter or a
malformed payload cannot be resumed through this path.

Keiro 0.16 owns the claim token, the renewable lease, finalization fencing, and expired-claim
recovery; Kioku renews while executing, re-parks an unsuccessful foreground outcome for
explicit retry, and preserves the eight-attempt ceiling. A **fresh refusal consumes no
attempt** — only a genuine resume does. A lost lease is never reported as a successful
completion.

## Shape

```bash
kioku worker deferred list
kioku worker deferred resume TIMER_ID --ai-config /path/to/ai-interactive.json
```

## Limits

- **Unreleased**: default branch only, and it requires Keiro 0.16's resume-lease migration.
  Run `kioku-migrate up` before using these commands.
- A leased claim does not promise exactly-once model execution across crashes. External
  effects still depend on Kioku's existing idempotent writes, per
  [L1's audited consolidation (CAP-8)](l1-atom-distillation.md).
- Do not replay these rows with generic dead-letter tooling or touch the timer tables by
  hand. Kioku uses only Keiro's public API and writes no Keiro-owned timer SQL.
- Leases renew every 30 seconds with a 120-second expiry. A host that only ever operates in
  the foreground should list or resume periodically so expired claims are recovered;
  ordinary [worker passes (CAP-10)](distillation-timers.md) recover them too.
- The CLI's trusted worker context covers every space in the database. An embedded host
  supplies its own authorization.
