---
type: Architecture Decision Record
title: The aggregate enforces the memory-space partition
description: >-
  The memory space lives in aggregate state and is checked by a transducer guard, so a
  cross-space command is refused by the state machine rather than by a read-model precheck.
timestamp: 2026-08-06T22:40:00Z
docId: ADR-4
status: accepted
date: 2026-08-06
---

# The aggregate enforces the memory-space partition

## Status

Accepted, 2026-08-06.

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

**Reads are not partitioned by this decision and must not pretend to be.** Until the read models
carry the column, the query functions keep their existing signatures and do not accept a context.
A query that accepted one would claim an isolation it cannot perform, which is worse than one that
visibly does not have it.

## Consequences

The boundary is enforced from the first release that has it, with no schema change and no backfill
ordering to get right. A deployment that upgrades and does nothing else is already unable to write
across spaces.

Cross-space *writes* are impossible; cross-space *reads* are still possible, and so is a small
residual oracle on the write path: a caller presenting the id of a memory in another space can
learn from an idempotent answer that the id exists and whether it is still active. It cannot read
content and it cannot change anything. Closing it needs the read-model column, and the
comparison in `Kioku.Memory.mismatchOf` says so at the point where it would go.

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
- `kioku-core/src/Kioku/Memory.hs` — `underContext`, and the residual-oracle note on `mismatchOf`
- `kioku-core/test/Kioku/MemorySpaceSpec.hs` — the cross-space cases, asserted on the event stream
- [ADR-1](kioku-owns-memory-not-identity.md), [ADR-2](namespace-is-not-a-security-boundary.md),
  [ADR-5](historical-attribution-is-marked-never-invented.md)
