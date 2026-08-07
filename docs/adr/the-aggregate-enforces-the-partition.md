---
type: Architecture Decision Record
title: The aggregate enforces the memory-space partition
description: >-
  The memory space lives in aggregate state and is checked by a transducer guard, so a
  cross-space command is refused by the state machine rather than by a read-model precheck.
timestamp: 2026-08-06T19:10:00Z
docId: ADR-4
status: accepted
date: 2026-08-06
---

# The aggregate enforces the memory-space partition

## Status

Accepted, 2026-08-06. Amended the same day, once the read models gained the memory-space column:
the read-side gap this record described is closed, and the section below that stated it now says
what replaced it.

## Context

[ADR-2](namespace-is-not-a-security-boundary.md) established that isolation is carried by an
explicit `MemorySpaceId`. That leaves the question of where the check happens.

The obvious place is the read model. Every write in `Kioku.Memory` and `Kioku.Session` already
looks the row up first — to decide whether a duplicate is an idempotent retry or a conflict — so
comparing a space column there would have cost nothing extra.

It would also have been wrong twice over.

It is wrong on timing. A read-model precheck runs against a snapshot, and keiro's optimistic
concurrency means the command is evaluated again after a conflict retry, against state the
precheck never saw. Every other invariant in this codebase that started as a precheck had to move
into the aggregate for exactly that reason: the resume-correlation guard and the
strictly-increasing turn index both live in the transducer, and both have a test that bypasses the
precheck to prove it.

It is also wrong on ordering. The read models do not have a memory-space column yet — that is a
later migration — so a precheck-based design could not have been implemented at all without first
changing the schema, which would have put the security boundary behind a data migration.

## Decision

The memory space is aggregate state. `MemoryRegs` and `SessionRegs` each carry a
`memorySpaceId` slot, set by the creation edge (`RecordMemory`, `StartSession`,
`RecordInteractiveSession`) and never reassigned. Every other edge begins with

```haskell
B.requireGuard (d.memorySpaceId .== B.reg @"memorySpaceId")
```

so a command naming a different space has no transition to take. The refusal is a
`CommandRejected`, produced by the state machine, and it survives a concurrency retry because
keiro re-runs the edge against the post-conflict state.

A memory or session therefore belongs to exactly one space for its whole life, and nothing can
move it. `force` on a session resume waives the correlation-key check and nothing else: an
operator override for a lost key is not an override for the isolation boundary.

The public write functions take a `MemoryAccessContext` first and check the payload against it —
permission, space, and actor. This is a check rather than a rewrite: a payload that disagrees is
refused rather than silently corrected, so the stored event and the decision that authorized it
remain the same fact. In particular the actor is checked, which is what stops a caller authorized
as one principal from writing an event claiming another one acted.

**Reads are not partitioned by this decision.** They are partitioned by the schema instead — see
[ADR-6](the-partition-is-a-column-not-a-schema.md), which added the column and made every
statement name it. Until that landed the query functions deliberately kept their old signatures
and refused a context, because a query that accepted one would have claimed an isolation it could
not perform. They now take a `MemorySpaceId` and return nothing outside it.

## Consequences

The boundary is enforced from the first release that has it, with no schema change and no backfill
ordering to get right. A deployment that upgrades and does nothing else is already unable to write
across spaces.

Cross-space writes are impossible from this record's first release, before any schema change. It
left one residual, now closed: a caller presenting the id of a memory in another space could learn
from an idempotent answer that the id existed and whether it was still active. The read-model
column ([ADR-6](the-partition-is-a-column-not-a-schema.md)) scoped that lookup to the command's
own space, so the answer is now identical to the one an id that does not exist gets — and the
refusal arrives as `MemoryNotFound` before the aggregate is consulted, rather than as a
`CommandRejected` from it. The guard below is still what makes the refusal survive a concurrency
retry; it is simply no longer the first thing a cross-space command meets.

Every command payload carries a space, which is redundant with the register on every edge except
the creation one. That redundancy is what makes the event self-describing for projections and
workers, and it is what the guard compares against.

Background work cannot hold a context, because it discovers its own work. The L1 timer payload
therefore carries the memory space, and the worker asks a `MemoryContextProvider` for a decision
about that space. A refusal dead-letters the timer rather than retrying it silently: an
unauthorized worker is a configuration fact and an operator has to see it.

## Alternatives rejected

**Compare a memory-space column in the read-model precheck.** Rejected: it is a snapshot check on
a path with an optimistic-concurrency retry, and it would have made the security boundary depend
on a schema migration landing first.

**Have the write functions stamp the space and actor into the payload from the context.** Rejected:
it makes the payload fields decorative, so a caller cannot tell which value won, and it removes
the one place where a caller's mistaken assumption becomes a loud error.

**Give reads a context parameter now, filtering in Haskell after an unfiltered query.** Rejected:
it reads as isolation, performs as a fetch-everything-then-drop, and would have to be undone when
the column lands.

## References

- `kioku-core/src/Kioku/Memory/Domain.hs`, `kioku-core/src/Kioku/Session/Domain.hs` — the register
  and the guards
- `kioku-core/src/Kioku/Memory.hs` — `underContext`, and the space-scoped lookup on `mismatchOf`
- `kioku-core/test/Kioku/MemorySpaceSpec.hs` — the cross-space cases, asserted on the event stream
- [ADR-1](kioku-owns-memory-not-identity.md), [ADR-2](namespace-is-not-a-security-boundary.md),
  [ADR-5](historical-attribution-is-marked-never-invented.md),
  [ADR-6](the-partition-is-a-column-not-a-schema.md)
