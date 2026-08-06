---
id: 25
slug: carry-memory-space-partitions-through-kioku-domain-and-apis
title: "Carry memory-space partitions through Kioku domain and APIs"
kind: exec-plan
created_at: 2026-08-06T14:43:35Z
intention: "intention_01kzbrefp9e6ttm2canx4svkfv"
master_plan: "docs/masterplans/5-portfolio-compatible-memory-isolation-and-authorization.md"
---

# Carry memory-space partitions through Kioku domain and APIs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, every newly recorded memory and session carries an explicit memory-space
partition and attributable principal context through the public API, aggregate commands, events,
and replay. Existing event streams still decode into one explicit legacy space, so upgrading does
not lose data or silently make old data visible to new spaces. A caller cannot accidentally issue
a new unpartitioned command through the primary API.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Add memory-space and principal-context fields to `kioku-api` request types.
- [ ] Add partition context to memory and session aggregate commands, events, and state.
- [ ] Implement backward-compatible JSON decoding into the configured legacy space.
- [ ] Require context in primary library write/read entry points and deprecate legacy wrappers.
- [ ] Include memory space in command idempotency, timer correlation, and read-model identities.
- [ ] Add codec fixtures and aggregate tests for new and historical event payloads.
- [ ] Update public API documentation and upgrade notes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Current memory scope (`Namespace` plus optional kind/reference) is reused for organization and
  retrieval. It is not an outer isolation boundary and can be identical for unrelated callers.
- Existing event payloads are durable and replayed to reconstruct projections. Making a new field
  required without a custom legacy decoder would make deployed streams unreadable.


## Decision Log

Record every decision made while working on the plan.

- Decision: Primary APIs require `MemoryAccessContext`; compatibility wrappers target only an
  explicitly configured legacy space and are deprecated.
  Rationale: A silent default on new calls would preserve the exact footgun this initiative fixes.
  Date: 2026-08-06

- Decision: The event payload records space, actor, and optional owner; it does not record ACLs.
  Rationale: These values are audit and partition facts. Permissions are evaluated by En and may
  change independently of event history.
  Date: 2026-08-06

- Decision: A memory scope remains an organization/retrieval key inside a space.
  Rationale: Reusing scope as the partition would make namespace-wide recall an authorization
  operation and prevent the same scope vocabulary in two spaces.
  Date: 2026-08-06


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

No implementation has started. Completion means all new domain facts are explicit while all
historical fixtures still replay deterministically into the legacy partition.


## Context and Orientation

`kioku-api/src/Kioku/Api/Scope.hs` defines `MemoryScope`. Memory command/event types live in
`kioku-core/src/Kioku/Memory/Domain.hs`; session equivalents live in
`kioku-core/src/Kioku/Session/Domain.hs`. `Kioku.Memory` and `Kioku.Session` are the public
library entry points. Event codecs in `Kioku.Memory.EventStream` and
`Kioku.Session.EventStream` already contain historical compatibility logic, including legacy
Rei memory payloads.

The access types and portfolio mapping are owned by
`docs/plans/24-define-portfolio-identity-and-authorization-contracts-for-kioku.md`. This plan
does not finalize identifiers independently. The repository has no existing ADR corpus; it
consumes the ADRs created by plan 24.


## Plan of Work

### Milestone 1: public request and aggregate vocabulary

Expose the access module from `kioku-api/kioku-api.cabal`. Add `MemoryAccessContext` to new
memory record/update/forget and session start/interactive-session requests. Thread
`memorySpaceId`, `actorPrincipal`, and optional `ownerPrincipal` into command data, accepted
events, and aggregate state in `Kioku.Memory.Domain` and `Kioku.Session.Domain`.

Review every idempotency key. Two otherwise identical requests in different spaces must not
collide. Preserve globally unique memory/session IDs, but include memory space in correlation
and external idempotency material wherever callers can reuse a key.

### Milestone 2: compatible event decoding

Replace automatic `FromJSON` deriving where needed with parsers that recognize both the new
fields and old payloads. Old payloads map to `legacyMemorySpaceId` and retain their historical
free-text agent value as a clearly marked `LegacyPrincipalRef`; they must never be fabricated as
a valid `agent_…` Meibo ID. Encode only the new form.

Extend `Kioku.CodecCompatSpec`, `Kioku.ReiCompatSpec`, session invariant tests, and event replay
fixtures. Prove byte fixtures from the current release still rehydrate and project.

### Milestone 3: require context at library boundaries

Add context-first variants to `Kioku.Memory`, `Kioku.Session`, recall/read functions, and
distillation entry points. Make them the documented API. Keep old functions as deprecated
wrappers only when their behavior can be confined to the legacy space. If a function could
cross an authorization boundary, require the new context immediately rather than supplying a
default.

Update Haddocks and `docs/user/library-api.md`. Add `docs/user/upgrading-to-memory-spaces.md`
describing the deployment-provided legacy-space ID, event compatibility, and downstream
compiler errors.


## Concrete Steps

Run from the repository root:

```bash
nix develop -c cabal test kioku-core --test-options='-p "codec|compat|invariant"'
nix develop -c cabal test kioku-api
nix develop -c cabal build all
```

After all call sites compile:

```bash
nix develop -c cabal test all
```

Expected focused output includes passing old-event decode, new-event round-trip, cross-space
idempotency, and legacy-wrapper cases.


## Validation and Acceptance

Acceptance requires:

- Constructing a new primary record/session request without a memory access context is
  impossible at compile time.
- New event JSON contains memory-space and actor fields; decoding then encoding preserves them.
- Every historical event fixture decodes and rehydrates into the configured legacy space.
- A legacy arbitrary agent string remains marked legacy and is not accepted as a canonical
  Meibo principal by new authorization adapters.
- Idempotency keys reused in two spaces do not suppress or conflate each other's commands.
- The documented compatibility wrappers cannot query or mutate any non-legacy space.


## Idempotence and Recovery

Domain and codec changes are additive at the JSON level. Keep golden historical fixtures before
editing parsers; they are the rollback oracle. New encoders must never emit the old form. If a
downstream migration is incomplete, callers can continue using deprecated legacy wrappers for
one release, but application code must not write mixed new/old context into the same operation.


## Interfaces and Dependencies

The exact records follow plan 24, with primary entry points equivalent to:

```haskell
recordWithContext :: MemoryAccessContext -> RecordMemoryData -> Eff es (Either StoreError MemoryId)
startWithContext :: MemoryAccessContext -> StartSessionData -> Eff es (Either StoreError SessionId)
```

Command/event payloads expose `memorySpaceId :: MemorySpaceId`,
`actorPrincipal :: PrincipalRef`, and `ownerPrincipal :: Maybe PrincipalRef`. The legacy decoder
uses one centralized `legacyMemorySpaceId`; no module invents its own default. Plan 26 consumes
these fields in projections, and plan 27 consumes them in asynchronous payloads.
