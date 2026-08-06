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

- [x] Add memory-space and principal-context vocabulary to `kioku-api`. (2026-08-06 —
  `RecordedPrincipal`, `LegacyPrincipalRef`, `memoryContextRecordedActor`,
  `MemoryContextProvider`; 72 tests in `kioku-api`.)
- [x] Add partition context to memory and session aggregate commands, events, and state.
  (2026-08-06 — every payload carries `memorySpaceId` and `actorPrincipal`, creation payloads also
  `ownerPrincipal`; the space is a keiki register and every non-creation edge guards on it.)
- [x] Implement backward-compatible JSON decoding into the configured legacy space. (2026-08-06 —
  `Kioku.Partition` owns the rules; hand-written `FromJSON` on all 13 event payloads; `ToJSON`
  stays derived so encoders emit only the new form.)
- [x] Require context in primary library write entry points and deprecate legacy wrappers.
  (2026-08-06 — `*WithContext` on `Kioku.Memory` and `Kioku.Session`, plus `distillSessionL1`;
  the old names survive as deprecated wrappers confined to `legacyMemorySpaceId`.)
- [x] Review command idempotency and timer correlation for cross-space collisions. (2026-08-06 —
  the L1 timer payload now carries the space; the derived L1 atom and audit keys were reviewed and
  deliberately left alone. See Surprises.)
- [x] Add codec fixtures and aggregate tests for new and historical event payloads. (2026-08-06 —
  13 new cases in `Kioku.CodecCompatSpec`, 10 in the new `Kioku.MemorySpaceSpec`, 2 in
  `Kioku.TimerWorkerSpec`, and `Kioku.SessionInvariantsSpec` now hydrates a genuinely
  pre-partition stream.)
- [x] Update public API documentation and upgrade notes. (2026-08-06 —
  `docs/user/library-api.md`, `docs/user/upgrading-to-memory-spaces.md`,
  `docs/user/configuration.md`, `docs/user/integrations.md`, `docs/user/README.md`.)
- [ ] **Deliberately not done here, handed to plan 26:** partition the read models. Queries keep
  their current signatures and take no context, because the tables have no memory-space column
  yet. Two consequences are documented rather than fixed: reads still span spaces, and the
  write-path idempotency precheck can tell a caller that an id in another space exists and
  whether it is active.
- [ ] **Deliberately not done here, handed to plan 27:** partition scene, persona, and workspace
  identities, which are still derived from the scope alone.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Current memory scope (`Namespace` plus optional kind/reference) is reused for organization and
  retrieval. It is not an outer isolation boundary and can be identical for unrelated callers.
- Existing event payloads are durable and replayed to reconstruct projections. Making a new field
  required without a custom legacy decoder would make deployed streams unreadable.

- **The read-model precheck cannot be made space-aware in this plan, and that shapes where the
  check had to go.** Every write in `Kioku.Memory` and `Kioku.Session` looks the row up first to
  decide whether a duplicate is a retry or a conflict, but `MemoryRow` has no space column until
  plan 26 adds one. Putting the partition check there was therefore impossible *and* would have
  been wrong anyway: a precheck runs against a snapshot, and keiro re-evaluates the command after
  an optimistic-concurrency conflict. The check is a transducer guard over a keiki register
  instead, which is the same place the resume-correlation and turn-index invariants already live.

- **Most events never recorded an actor at all.** Only `MemoryRecorded`, `SessionStarted`, and
  `InteractiveSessionRecorded` carried `agentId`; archiving, superseding, merging, retagging,
  re-scoring, completing, failing, parking, resuming, and turn recording carried nothing. A
  two-case `PrincipalRef`-or-legacy type would have forced a fabricated actor onto ten of the
  thirteen payloads, so `RecordedPrincipal` has a third case, `UnattributedPrincipal`.

- **Background work cannot hold a context, so the timer payload had to carry the space.** The plan
  assigned asynchronous payloads to plan 27, but the L1 distillation worker writes memories, and
  without the space in the payload it would have had to guess — writing every distilled memory into
  the legacy space regardless of which space the session belonged to. The event the projection
  reads already has the field, so adding it to `L1TimerPayload` was one line, and
  `MemoryContextProvider` gives the worker a way to ask for a decision about the space it found.
  Timers scheduled before the field existed default to the legacy space.

- **The derived L1 identities did not need the space, and adding it would have cost data.**
  `l1AtomMemoryId` and `l1AuditKey` are UUIDv5 over the session id plus content. A session id is
  globally unique and the aggregate now pins each session to exactly one space, so two spaces
  cannot collide. Folding the space in would have changed every derived id, re-recording every
  already-distilled memory under a new one on the first pass after upgrade. The same argument
  applies to the L1 timer ids, which would have left a second idle timer armed for every session
  in flight at upgrade time.

- **A mixed-era stream is refused, and that is the correct behaviour.** The pre-force hydration
  fixture initially stamped the new space onto its hand-built `SessionStarted` while its
  hand-built `SessionResumed` JSON had no partition at all; hydration failed with
  `HydrationNoInvertingEdge`. The fixture was wrong, not the guard — a genuine historical stream
  has no partition anywhere and lands wholly in the legacy space. The test now strips the
  partition keys from all three events and asserts both halves: the legacy-space command is
  accepted and a command from another space is refused.

  ```text
  a pre-force stream failed to hydrate:
    HydrationReplayFailed (StreamVersion 3) HydrationNoInvertingEdge
  ```


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

- Decision: The memory space is aggregate state and the cross-space check is a transducer guard.
  Rationale: A read-model precheck is a snapshot check on a path with an optimistic-concurrency
  retry, and the read models have no space column until plan 26. Recorded durably as
  [ADR-4](../adr/the-aggregate-enforces-the-partition.md).
  Date: 2026-08-06

- Decision: The payload is *checked* against the context, not stamped from it.
  Rationale: Stamping makes the payload fields decorative — a caller cannot tell which value won —
  and removes the one place a mistaken assumption becomes a loud error. Checking the actor is also
  what stops a caller authorized as one principal from writing an event naming another.
  Date: 2026-08-06

- Decision: `RecordedPrincipal` has three cases, with `kioku:legacy:` and `kioku:unattributed`
  markers, and `LegacyPrincipalRef` validates nothing.
  Rationale: Ten of the thirteen payloads never recorded an actor, so a two-case type would have
  forced a fabrication. The markers are unambiguous because `mkPrincipalRef` rejects `:`. A
  validating legacy constructor would turn a historical event into one that no longer decodes.
  Recorded durably as [ADR-5](../adr/historical-attribution-is-marked-never-invented.md).
  Date: 2026-08-06

- Decision: Read functions keep their current signatures and take no context in this plan.
  Rationale: The tables have no memory-space column until plan 26, so a query accepting a context
  would claim an isolation it cannot perform — worse than one that visibly does not have it. The
  gap and its two consequences are documented in the upgrade guide instead of hidden.
  Date: 2026-08-06

- Decision: The deprecated wrappers keep the old function names and reject any payload naming a
  space other than `legacyMemorySpaceId`, rather than defaulting one in.
  Rationale: A wrapper that silently retargeted a payload into the legacy space would reintroduce
  exactly the defaulting this plan removes. Callers must still add the payload fields; what they
  can defer is threading a context through their call sites.
  Date: 2026-08-06

- Decision: The L1 timer payload carries the memory space, and the worker takes a
  `MemoryContextProvider`.
  Rationale: Plan 27 owns asynchronous payloads generally, but distillation writes memories, and
  leaving the space out would have made every background pass write into the legacy space
  regardless of which space its session belonged to. Deferring that would have shipped a known
  wrong write.
  Date: 2026-08-06

- Decision: The CLI declares itself as `kioku_cli` and defaults to the legacy space, both
  overridable through `KIOKU_ACTOR` and `KIOKU_MEMORY_SPACE`, with a malformed value a startup
  error.
  Rationale: Something has to name the principal for writes the CLI performs on its own initiative,
  and the CLI is genuinely that thing. Refusing to start without an operator-supplied principal
  would turn a library upgrade into an outage; a silent fallback on a typo would send writes to the
  wrong space.
  Date: 2026-08-06


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Completed 2026-08-06, with two items deliberately handed on.

**What exists now.** Every memory and session command names the memory space it acts in and the
principal that acted; every event records both, and creation events also record an optional owner.
The space is a keiki register, so a command naming a different space has no transition to take:
the refusal comes from the state machine and survives a concurrency retry. Public writes take a
`MemoryAccessContext` first and are checked against it on permission, space, and actor.
`Kioku.Partition` holds the two compatibility rules — legacy space, legacy-marked agent label — so
no codec invents its own. The deprecated wrappers keep the old names and refuse any non-legacy
payload. Distillation takes a context and demands `MemoryDistill` before spending an LLM token;
its timer payload carries the space so the worker can ask for a decision about it.

**Against the original purpose.** The purpose was that a caller cannot accidentally issue a new
unpartitioned command through the primary API, and that existing streams still decode. Both hold,
and the second is proved on the real fixtures rather than on new ones: every payload in
`Kioku.CodecCompatSpec` was captured before memory spaces existed, so asserting that they land in
`kioku_legacy` with their attribution intact is a test of the actual historical bytes.

**What is not done here, and why.** Reads are unchanged. The plan's Milestone 3 asked for
context-first variants of the read and recall functions, and that turned out to be the wrong thing
to build first: the read models have no memory-space column until plan 26, so those variants would
have accepted a context and then queried across every space. The gap is documented in the upgrade
guide with its two consequences — reads span spaces, and the write-path idempotency precheck is a
small existence oracle for ids in other spaces — rather than papered over. Scene, persona, and
workspace identities are still scope-derived; that is plan 27's.

**Lessons.** Two are worth carrying. First, the fixture that failed was more informative than the
ones that passed: a stream with a partition on one event and none on the next is exactly what a
half-migrated deployment would produce, and the guard refusing it is the behaviour you want —
which only became clear after reading the failure rather than "fixing" it. Second, the
question "where does this check go?" was answered by the schema not being ready, and the answer
turned out to be the better one on its own merits; a precheck would have been a snapshot check on
a retry path.

**Task-local notes.** `nix develop -c cabal test all`: 173 + 72 + 36 + 7 passing.
`okf validate docs/adr` reports `OK: 5 concepts`.


## Context and Orientation

`kioku-api/src/Kioku/Api/Scope.hs` defines `MemoryScope`. Memory command/event types live in
`kioku-core/src/Kioku/Memory/Domain.hs`; session equivalents live in
`kioku-core/src/Kioku/Session/Domain.hs`. `Kioku.Memory` and `Kioku.Session` are the public
library entry points. Event codecs in `Kioku.Memory.EventStream` and
`Kioku.Session.EventStream` already contain historical compatibility logic, including legacy
Rei memory payloads.

The access types and portfolio mapping are owned by
`docs/plans/24-define-portfolio-identity-and-authorization-contracts-for-kioku.md`. This plan
does not finalize identifiers independently. It consumes the ADRs created by plan 24 —
[ADR-1](../adr/kioku-owns-memory-not-identity.md) (Kioku carries a decision, never makes one),
[ADR-2](../adr/namespace-is-not-a-security-boundary.md) (namespace organizes, memory space
isolates), [ADR-3](../adr/legacy-data-lands-in-one-explicit-space.md) (legacy data lands in
`kioku_legacy`) — and added two of its own during implementation:
[ADR-4](../adr/the-aggregate-enforces-the-partition.md) and
[ADR-5](../adr/historical-attribution-is-marked-never-invented.md).


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

Add context-first variants to `Kioku.Memory`, `Kioku.Session`, and the distillation entry points,
and make them the documented API. Keep old functions as deprecated wrappers only when their
behavior can be confined to the legacy space; the wrappers here keep the old names and reject any
payload naming a space other than `legacyMemorySpaceId`, rather than defaulting one in.

Read and recall functions are **excluded**, on the same rule that governs the wrappers. Their
behavior cannot be confined to one space — the read models have no memory-space column until plan
26 — so giving them a context parameter would advertise an isolation they do not perform. They
keep their signatures, and the gap is documented rather than disguised. Plan 26 adds the column
and the predicate together.

Background work cannot arrive holding a context, because it discovers its own work. The L1 timer
payload therefore carries the memory space and the timer worker takes a `MemoryContextProvider`,
so a scheduled pass acts in the space its session belongs to rather than in a default one.

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
- The documented compatibility wrappers cannot mutate any non-legacy space.

Each was checked on 2026-08-06 and holds, with one narrowed and one carrying a stated residual.

Every command payload has required `memorySpaceId` and `actorPrincipal` fields and every write
takes a context, so neither can be omitted at a call site — a missing field or a missing argument
is a compile error, which is what the upgrade guide's "what breaks" section documents. New event
JSON carries both fields and round-trips through the same decoder the historical fixtures use;
`the encoded form actually contains the partition` asserts the bytes, so a round-trip that
defaulted on both sides could not pass. All thirteen pre-partition fixtures in
`Kioku.CodecCompatSpec` decode into `kioku_legacy`, and `Kioku.SessionInvariantsSpec` rehydrates a
whole pre-partition stream into it and then refuses a command from another space. A legacy agent
label renders as `kioku:legacy:demo-agent` and cannot be parsed as a `PrincipalRef`, because
`mkPrincipalRef` rejects `:`.

The idempotency criterion holds where a key can actually be reused: two spaces cannot share a
memory or session id, because the aggregate refuses every command naming a space other than the
one the aggregate was created in, and the derived L1 identities are session-derived and therefore
space-pinned. The **residual** is on the read side of the write path: `mismatchOf` compares
`MemoryRow`, which has no space column until plan 26, so a caller presenting an id from another
space can learn that it exists and whether it is active. It cannot change anything and cannot read
content. This is stated in the code, in the upgrade guide, and in ADR-4.

The wrapper criterion was **narrowed from "query or mutate" to "mutate"**: there are no
partitioned queries in this plan to confine, and the wrappers are write-only. `Kioku.MemorySpaceSpec`
proves both halves — a non-legacy payload is refused before any read, and a legacy-shaped payload
naming a memory that lives elsewhere is refused by the aggregate with the stream left unchanged.

```text
kioku-core: All 173 tests passed
kioku-api:  All 72 tests passed
kioku-cli:  All 36 tests passed
kioku-migrations: All 7 tests passed
okf validate docs/adr: OK: 5 concepts
```


## Idempotence and Recovery

Domain and codec changes are additive at the JSON level. Keep golden historical fixtures before
editing parsers; they are the rollback oracle. New encoders must never emit the old form. If a
downstream migration is incomplete, callers can continue using deprecated legacy wrappers for
one release, but application code must not write mixed new/old context into the same operation.


## Interfaces and Dependencies

The exact records follow plan 24. As shipped:

```haskell
recordWithContext :: MemoryAccessContext -> RecordMemoryData -> Eff es (Either MemoryWriteError MemoryId)
startWithContext  :: MemoryAccessContext -> StartSessionData -> Eff es (Either SessionWriteError SessionId)

-- every command and event payload
memorySpaceId  :: MemorySpaceId
actorPrincipal :: RecordedPrincipal
-- creation payloads only
ownerPrincipal :: Maybe PrincipalRef

-- kioku-api: who a stored fact says acted
data RecordedPrincipal
  = KnownPrincipal PrincipalRef
  | LegacyPrincipal LegacyPrincipalRef
  | UnattributedPrincipal

-- kioku-api: how work that discovers itself gets authorized
newtype MemoryContextProvider m = MemoryContextProvider
  { contextForSpace :: MemorySpaceId -> m (Either MemoryAccessDenial MemoryAccessContext) }
```

The actor is a `RecordedPrincipal` rather than the sketch's `PrincipalRef`, because ten of the
thirteen payloads never recorded an actor and the three that did recorded free text; the owner is
a plain `PrincipalRef`, because ownership did not exist before this field did and so has no legacy
form. The legacy decoder uses one centralized `legacyMemorySpaceId` from `Kioku.Partition`; no
module invents its own default.

Plan 26 consumes these fields in projections. It inherits two specific obligations: the
memory-space column that makes the write-path idempotency comparison space-aware (closing the
existence oracle described in Validation), and composite `(memory_space_id, …)` identities for
scene and persona rows, which are still scope-derived. Plan 27 consumes the fields in the
remaining asynchronous payloads; the L1 timer payload is already done here, because leaving it
would have made every background distillation write into the legacy space.


## Revision Notes

### 2026-08-06 — implementation

All three milestones were implemented and the plan revised to match what shipped. Four changes to
the plan as written are worth calling out, each with a Decision Log entry.

The partition check went into the **aggregate** rather than anywhere near the existing read-model
prechecks. Milestone 1 said to review every idempotency key; doing that surfaced the fact that
`MemoryRow` has no space column until plan 26, so a precheck was not implementable — and reading
how the resume-correlation and turn-index invariants had already been moved into the transducer
showed it would have been the wrong place regardless. This is now ADR-4.

**Read and recall functions were removed from Milestone 3's scope.** The milestone asked for
context-first variants of them alongside the writes. Building those would have produced functions
that accept a memory space and then query across all of them, because the predicate they would
need lands with plan 26's column. Milestone 3's own rule — keep a wrapper only when its behavior
can be confined — is what excludes them, so the milestone text now says so explicitly and the
Validation criterion narrowed from "query or mutate" to "mutate".

The **L1 timer payload gained the memory space**, which the Interfaces section had assigned to
plan 27. Distillation writes memories; without the space in the payload, a scheduled pass would
have written into the legacy space no matter which space its session belonged to. That is a known
wrong write, and deferring it would have shipped one.

The actor type is a **three-case `RecordedPrincipal`**, not the sketched `PrincipalRef`. Ten of
the thirteen event payloads never carried an agent at all, so a two-case type would have required
inventing an actor for them. This is now ADR-5.
