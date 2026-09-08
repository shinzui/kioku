---
title: "Typed memory and session event streams with compatible decoding"
type: Capability
description: "Two validated Keiki event streams whose payloads decode across every schema change Kioku has shipped, so pre-partition events land in the legacy space with an honest attribution and events belonging to another product are rejected rather than reinterpreted."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-12
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-core
interface:
  - Kioku.Memory.EventStream
  - Kioku.Session.EventStream
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/CodecCompatSpec.hs
    proves: "Literal pre-upgrade payloads still decode: every pre-partition memory and session event lands in the legacy space, a legacy agent label is never promoted to a directory principal, a pre-partition archive records no actor at all, partitioned payloads round-trip, and foreign payloads are rejected."
  - kind: module
    resource: kioku-core/src/Kioku/Memory/EventStream.hs
    proves: "The typed memory stream, its event constructors, and the parse function whose accepted set is the compatibility contract."
  - kind: guide
    resource: docs/adr/historical-attribution-is-marked-never-invented.md
    proves: "Why an event that recorded no actor decodes as unattributed rather than being backfilled with a plausible one."
---

# Typed memory and session event streams with compatible decoding

Kioku owns two Keiki event streams — one for [memories (CAP-1)](event-sourced-memory-records.md)
and one for [sessions and turns (CAP-2)](event-sourced-agent-sessions.md) — assembled and
validated at startup rather than assumed. They are the source of truth; every table
Kioku queries is a projection of them.

Because the log is permanent and Kioku has no delete, **decoding is the compatibility
surface**, and it is tested against literal payload bytes from earlier releases rather
than against re-encoded fixtures. Three properties matter to a consumer:

- **Pre-partition events still decode**, and they land in the explicit `kioku_legacy`
  space rather than in a null or wildcard one. Absence is never permission — see
  [memory-space isolation (CAP-4)](memory-space-isolation.md).
- **Attribution is marked, never invented.** A free-text agent label from before
  principals existed decodes as a `LegacyPrincipal`, and an event that recorded no actor
  decodes as `UnattributedPrincipal`. Kioku never turns either into a directory-issued
  `KnownPrincipal`, because that would fabricate a vouching that never happened.
- **Foreign payloads are rejected.** The parsers no longer accept another product's
  retired `agent_memory_*`, `agent_session_*`, or `interactive_session_recorded` values.
  One-time foreign migration codecs belong to the consumer that owns those events.

Session payloads written before `forceResume` existed hydrate unchanged, so the resume
invariants apply to a stream that predates them.

## Shape

```haskell
-- the accepted set is the contract; an unrecognised type is an error, not a default
parseMemoryEvent  :: Text -> Value -> Either Text MemoryEvent
parseSessionEvent :: Text -> Value -> Either Text SessionEvent
```

## Limits

- Read-model schema identities are versioned separately from the codecs. A binary on the
  wrong side of a projection change fails closed through
  [registry reconciliation (CAP-14)](read-model-registry-reconciliation.md) rather than
  querying relations that have moved.
- Kioku does not own an event store. It appends to the host's Kiroku streams using the
  host's connection settings and creates no second store.
- Snapshot compatibility follows the Keiki cohort. A cohort upgrade that changes shape
  hashing is a Kioku release concern, not something a consumer can pin around.
