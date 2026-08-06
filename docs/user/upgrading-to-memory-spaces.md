# Upgrading to memory spaces

This release gives Kioku an explicit isolation boundary. Every command and event now names a
**memory space** — the outer partition that keeps one caller's memories away from another's — and
the principal responsible for the write.

If you run a single-tenant deployment and do nothing but recompile, your data keeps working: it
all belongs to one explicit space named `kioku_legacy`, and so does everything replayed from your
existing event streams. What changes is *why* it works. Nothing in Kioku treats a missing
partition as "visible everywhere"; there is no such state.

This page covers what breaks at compile time, what to do about it, and what deliberately did not
change yet.

## What happens to data already in the database

Nothing, immediately. No migration runs and no rows move.

Every event written before this release decodes into `legacyMemorySpaceId` — the identifier
`kioku_legacy` — the moment it is read. That applies to Kioku's own older payloads and to the even
older Rei-format ones. Aggregates rebuilt from history land in the same space a later backfill
will put their rows in, so the two paths cannot disagree.

Attribution follows two rules, and neither invents anything:

- An event that carried the old free-text `agentId` is attributed to that label, **marked as
  legacy**. It renders as `kioku:legacy:demo-agent`. It is never rewritten into a directory
  principal id: nobody issued `demo-agent`, two hosts could both have picked it, and promoting it
  would put an identity no directory ever vouched for into an audit trail.
- An event that recorded no agent at all — archiving a memory, completing a session, recording a
  turn — is `kioku:unattributed`. That is the honest answer, and it is a named state rather than
  an absence, so nothing downstream has to guess.

Timers already scheduled behave the same way: an L1 distillation timer whose payload predates the
memory-space field fires in the legacy space.

Encoders only ever write the new form. A stream that is rebuilt and re-encoded keeps its legacy
marking; it is not laundered into a real principal.

## What breaks at compile time

Command payloads gained required fields, and write functions gained a required first argument.
Both are deliberate: this is the one change where a silent default would preserve exactly the
footgun the work exists to remove.

You will see two kinds of error.

**Missing record fields.** Every command payload now carries `memorySpaceId` and
`actorPrincipal`; the three creation payloads (`RecordMemoryData`, `StartSessionData`,
`RecordInteractiveSessionData`) also carry `ownerPrincipal`:

```text
Constructor ‘RecordMemoryData’ does not have the required strict field(s):
    memorySpaceId :: MemorySpaceId
    actorPrincipal :: RecordedPrincipal
    ownerPrincipal :: Maybe PrincipalRef
```

**A missing context argument.** `record`, `start`, and the rest are now
`recordWithContext`, `startWithContext`, … , each taking a `MemoryAccessContext` first.

## The migration, in two steps

### 1. Build a context

An embedded host that has already authorized its user by other means builds one directly:

```haskell
import Kioku.Api.Access

hostContext :: MemoryAccessContext
hostContext =
  assumeAuthorizedMemoryContext
    (either error id (mkMemorySpaceId "kioku_legacy"))   -- or your own space
    (MemoryActor (either error id (mkPrincipalRef "agent_01h9xk3v7hf8b9c0d1e2f3g4h5")))
```

Use `legacyMemorySpaceId` if you have one collection of memories and no reason to split it. Use
your own identifier if you are separating tenants; it is opaque validated text, so it can be
whatever your own system already calls that boundary.

A host serving untrusted callers should not use `assumeAuthorizedMemoryContext` at all. Use
`authorizeMemoryAccess`, which runs a coarse credential check, a directory lookup, and a per-space
permission check in that order, and keeps their four failures distinct. See
[Scopes & Integrations](integrations.md).

### 2. Fill the payload from the context, and pass it

```haskell
result <-
  Memory.recordWithContext hostContext
    RecordMemoryData
      { memoryId = mid
      , memorySpaceId = memoryContextSpace hostContext
      , actorPrincipal = memoryContextRecordedActor hostContext
      , ownerPrincipal = Nothing
      , agentId = "demo-agent"
      , …
      }
```

`memoryContextSpace` and `memoryContextRecordedActor` are the supported way to fill those fields.
The payload is checked against the context rather than overwritten by it, so a disagreement is a
loud `MemorySpaceMismatch` or `MemoryActorMismatch` instead of a quiet rewrite — the stored event
and the decision that allowed it stay the same fact.

Set `ownerPrincipal` when the memory belongs to somebody other than the actor: an agent recording
on a person's behalf is the motivating case, and later retention or deletion questions are asked
about the owner.

## If you cannot migrate in one go

The old names survive for one release as **deprecated** wrappers:

```haskell
{-# DEPRECATED record "Use recordWithContext. This wrapper accepts only legacyMemorySpaceId and will be removed." #-}
```

They take no context and refuse any payload naming a space other than `legacyMemorySpaceId`, so
they cannot reach anybody else's data — including through a memory id belonging to another space,
which the aggregate itself refuses. You still have to add the payload fields; what you can defer
is threading a context through your call sites.

## New failure modes

| Error | Means |
| --- | --- |
| `MemoryNotPermitted` / `SessionNotPermitted` | the context authorized other actions, but not this one |
| `MemorySpaceMismatch` / `SessionSpaceMismatch` | the payload named a space the context was not minted for |
| `MemoryActorMismatch` / `SessionActorMismatch` | the payload attributed the write to somebody else |
| `MemoryCommandRejected` | the aggregate refused it — including a command naming a space the memory or session does not belong to |
| `L1NotPermitted` | the context does not authorize distillation in this space |

The last two are worth separating in your logs. A `MemorySpaceMismatch` is a caller bug caught
before anything was read. A `MemoryCommandRejected` on a cross-space command means somebody
presented an id belonging to a different space — the aggregate refused it, and no event was
appended.

## Which permission each write asks for

- `MemoryRecord` — recording a memory, retagging, re-scoring confidence, and every session write
  (a session, its turns, and its lifecycle are memory being recorded).
- `MemoryForget` — superseding, archiving, and merging.
- `MemoryDistill` — running an L1 distillation pass, checked before any LLM call.

`assumeAuthorizedMemoryContext` grants all of them. A context obtained through
`authorizeMemoryAccess` grants exactly what was checked, so ask for what you intend to do.

## Background workers

A worker claims a timer and only then learns which space the work belongs to, so it takes a
`MemoryContextProvider` rather than a context:

```haskell
contexts = assumeAuthorizedContextProvider (MemoryActor …)
drainKiokuTimers Nothing contexts runtime finder
```

A refusal dead-letters the timer instead of retrying it silently: a worker that is not authorized
for a space is a configuration problem, and an operator needs to see it rather than watch it
retry every thirty seconds for an hour.

## The CLI

`kioku` resolves its space and actor from the environment:

- `KIOKU_MEMORY_SPACE` — default `kioku_legacy`, so an unchanged CLI operates on exactly the data
  it did before.
- `KIOKU_ACTOR` — default `kioku_cli`. The CLI is genuinely the thing acting, and naming it
  plainly beats borrowing an identity from a directory the CLI does not talk to.

A malformed value is a startup error rather than a silent fallback: a typo in a space name must
not quietly send writes somewhere else.

## What has not changed yet

**Reads are not partitioned.** `Kioku.Recall`, the `Kioku.Memory` row queries, and the
`Kioku.Session` queries still return rows from every space, and they deliberately do not take a
context. The read-model tables have no memory-space column yet; a query that accepted a context
would be claiming an isolation it cannot perform, which is worse than one that visibly does not
have it. Until the projection migration lands, isolation applies to writes and to the event
history they produce.

Two consequences follow while that is true:

- Do not treat a second memory space as a privacy boundary for *reads* yet.
- A caller presenting the id of a memory in another space can still learn from an idempotent
  answer whether that id exists and whether it is active. It cannot read any content and it cannot
  change anything.

**Scenes, personas, and workspace mirrors are still keyed by scope alone**, so two spaces sharing
a namespace and scope would share a scene row. That, the read-model column, and partitioned
recall are the next changes in this sequence.

## Related

- [Library API](library-api.md) — the full write and read surface.
- [Scopes & Integrations](integrations.md) — namespaces, scopes, and wiring an identity stack.
- [ADR-2](../adr/namespace-is-not-a-security-boundary.md) — why a namespace is not tenancy.
- [ADR-3](../adr/legacy-data-lands-in-one-explicit-space.md) — why legacy data gets a named space.
