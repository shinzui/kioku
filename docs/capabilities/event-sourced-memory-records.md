---
title: "Event-sourced memory records with honest idempotency"
type: Capability
description: "Record facts, patterns, preferences, constraints, and instructions as an event-sourced aggregate whose retirement transitions are enforced by replayed state, so a matching retry succeeds and a conflicting one is refused rather than silently winning."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-1
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-api
  - kioku-core
interface:
  - Kioku.Memory
  - Kioku.Memory.Domain
  - Kioku.Memory.ReadModel
  - Kioku.Api.Types
requires:
  - CAP-3
  - CAP-4
  - CAP-12
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/IdempotencySpec.hs
    proves: "A retry that re-reads its clock is still a duplicate, a record with different content under the same id is a conflict, and supersede and merge stay idempotent even after their winner has itself been retired."
  - kind: test
    resource: kioku-core/test/Kioku/MemorySpaceSpec.hs
    proves: "A supersede or merge target absent from the source's space is MemoryNotFound rather than a cross-space existence oracle, and a payload naming another space or principal is refused."
  - kind: module
    resource: kioku-core/src/Kioku/Memory.hs
    proves: "The write functions, the MemoryWriteError taxonomy, and the row and record read APIs a host calls."
  - kind: guide
    resource: docs/user/library-api.md
    proves: "Every write signature, what each error means, and which permission each write asks the access context for."
---

# Event-sourced memory records with honest idempotency

A memory is one durable thing an agent learned: a `fact`, `pattern`, `preference`,
`constraint`, or `instruction`, carrying content, a priority, a confidence, a tag set,
and [the scope (CAP-3)](host-agnostic-memory-scopes.md) it lives in. It is an aggregate,
not a row. Every change is an event on
[the typed memory stream (CAP-12)](typed-event-streams-and-codecs.md), appended to a Kiroku stream, and the queryable forms — the structured row, the `tsvector`, the
embedding — are projections of that stream. There is no delete.

`recordWithContext` creates one. `supersedeWithContext`, `archiveWithContext`, and
`mergeWithContext` retire one; `updateTagsWithContext` and
`updateConfidenceWithContext` amend an active one in place. Each asks the
[access context (CAP-4)](memory-space-isolation.md) for exactly one permission —
`MemoryRecord` to create or amend, `MemoryForget` to retire — and each refuses a
payload that names a different space or principal than the context was minted for.

**Idempotency is decided against replayed aggregate state, not a read-model
precheck**, so it holds under concurrent writers: a duplicate that loses a race
still gets the success the winner got. Re-recording an existing id succeeds only
when the agent id, session id, content, scope, type, priority, confidence, tags,
and `supersedes` all match; a semantic difference returns `MemoryConflict` naming
the field. Call-time timestamps are deliberately excluded from the comparison,
because the id is the identity and a retry that re-reads its clock is still a retry.
Retiring is compared against the stored source first, so an identical retry stays
idempotent even after the winner has itself been retired.

Active, superseded, merged, and archived are the four states, and the last three are
terminal. Only active memories are returned by [recall (CAP-5)](hybrid-recall-with-explicit-targets.md).
Retiring a memory — or changing its confidence — propagates: it schedules regeneration
of the scope's derived artifacts, so forgotten content does not survive in a scene or
a persona. A tags-only change deliberately schedules nothing.

## Shape

```haskell
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))

result <- Memory.recordWithContext context
  RecordMemoryData
    { memoryId = mid
    , memorySpaceId = memoryContextSpace context
    , actorPrincipal = memoryContextRecordedActor context
    , scope = ScopeEntity (Namespace "mori") (ScopeKind "repo") "shinzui/kikan"
    , memoryType = MemoryPreference
    , content = "prefers conventional commits"
    , priority = 100
    , confidence = HighConfidence
    , ...
    }
```

## Limits

- The event log is append-only and Kioku exposes no delete. Archiving retires a
  memory from recall; it does not remove what was recorded.
- A first supersede or merge requires its target to already exist in the source's
  space. Out-of-order ingestion of a winner is not supported for that transition.
- `priority` is a bare `Int` at the API boundary; `0` meaning "always inject" is a
  host convention and the maximum ranking boost, not a bypass of candidate selection.
- The unsuffixed `record`/`supersede`/`archive`/`updateTags`/`updateConfidence`/`merge`
  wrappers still exist for one release as deprecated legacy-space shims and refuse any
  payload naming a space other than `kioku_legacy`.
