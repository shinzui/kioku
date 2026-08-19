---
type: Architecture Decision Record
title: Historical attribution is marked, never invented
description: >-
  A pre-memory-space agentId is recorded as a legacy-marked label and an event that named no
  actor stays unattributed; Kioku never manufactures a principal for a fact that lacked one.
timestamp: 2026-08-06T22:40:00Z
docId: ADR-5
status: accepted
date: 2026-08-06
---

# Historical attribution is marked, never invented

## Status

Accepted, 2026-08-06.

## Context

Events now record the principal responsible for a write. Events already on disk do not, and they
are not uniform about it either.

Some carry the old `agentId`: a free-text string the host chose, such as `demo-agent`, `rei`, or
`claude`. Nobody issued it, nothing can resolve it, and two unrelated hosts could have picked the
same one. Most events carry nothing at all — archiving a memory, completing a session, and
recording a turn never had an agent field.

Both have an obvious-looking fix and both fixes are traps.

The `agentId` could be turned into a principal id by pasting a kind prefix onto it:
`demo-agent` becomes `agent_demo-agent`, the field becomes uniformly typed, and every downstream
consumer stops having to think about it. What it actually does is manufacture an identity no
directory ever vouched for, and put it in an audit trail next to identities that were. Any later
authorization decision made about it is a decision about a string somebody typed.

The absent actor could be filled with a placeholder — the host, the deployment, `unknown` — for
the same tidiness. That records that somebody acted when the event says no such thing.

## Decision

`RecordedPrincipal` has three cases and they stay distinct all the way to storage:

- `KnownPrincipal` — a principal a directory issued, carried verbatim.
- `LegacyPrincipal` — a pre-memory-space free-text label, kept exactly as written and marked.
- `UnattributedPrincipal` — the event recorded no actor. This is a named state, not an absence,
  so nothing downstream has to guess what a missing value meant.

The wire form is text with a Kioku-owned marker: `kioku:legacy:<label>` and `kioku:unattributed`.
That is unambiguous rather than merely unlikely, because `mkPrincipalRef` rejects `:` outright, so
no principal any directory can issue is spellable as either marker.

`LegacyPrincipalRef` validates nothing, deliberately. It only ever comes from data already on
disk, and a validating constructor would turn a historical event into one that no longer decodes —
which is to say, an aggregate that can no longer be rebuilt.

Encoding only ever emits the new form, so a stream that is replayed and re-encoded keeps its
legacy marking rather than being laundered on the way through.

The compatibility rules live in one module, `Kioku.Partition`, so that no codec invents its own
default for what an older payload means.

## Consequences

An operator reading an audit trail can tell the three cases apart, which is the point. A future
authorization adapter that is handed a legacy label cannot mistake it for a real principal, and
the natural thing for it to do — refuse — is also the correct thing.

The cost is that consumers must handle three cases rather than one. That cost is real and it is
the honest shape of the data: history genuinely does not know who archived that memory.

Attribution on new writes is not caller-supplied. It comes from the context that authorized the
write (`memoryContextRecordedActor`), and a payload naming anybody else is refused. Otherwise the
type-level care above would be undone by a caller who simply writes a different name into the
field.

`LegacyPrincipal` and `UnattributedPrincipal` are therefore decode-side only. Both describe events
written before memory spaces existed, and neither is reachable through the memory-space write API:
`memoryContextRecordedActor` returns `KnownPrincipal` unconditionally, and a context can only be
minted from a `MemoryActor`, which wraps a `PrincipalRef`. The deprecated pre-context wrappers can
still write either, because they bypass the context gate — that is an artifact of their being
wrappers, not a capability being preserved. When they are removed, every new write names a
principal, which is what this record has said all along.

**What `KnownPrincipal` asserts is that a principal was vouched for, not that a directory did the
vouching.** Two contexts produce it and they differ in who stands behind the claim.
`authorizeMemoryAccess` resolves a subject through a `PrincipalDirectory`, so the directory
vouched. `assumeAuthorizedMemoryContext` — the embedded-host escape hatch, for a single-tenant
in-process host that has already authorized its user by other means — has no directory to consult,
so the host itself vouches, and the `PrincipalRef` it supplies is an assertion it is accountable
for. That is a real assurance because the escape hatch is named to be unmissable in review: a host
reaching for it is declaring that it owns its database and its authentication boundary.

A directory-less host therefore mints a `PrincipalRef` from whatever stable identifier it has and
records it as `KnownPrincipal`. It does not mark the write as unvouched, because there is no such
forward state and adding one would misdescribe it: a `kioku:legacy:` marker on an event written
today would claim the event predates memory spaces, which is false, and `UnattributedPrincipal`
would claim nobody acted, which is also false. The distinction the three cases protect is between
history that genuinely lacks attribution and writes that have it — not between grades of
confidence in a live principal.

The residual cost is that an audit trail cannot, from the stored value alone, separate a
directory-resolved principal from a host-asserted one. That is accepted here and bounded by
deployment rather than by type: a deployment either has a directory or does not, and one that
does not has no second kind of principal to confuse it with. A deployment that runs both paths
against one space and needs to tell them apart should carry that in the `PrincipalRef`'s own kind
prefix, which is the field that names what a principal is, rather than in `RecordedPrincipal`,
which names how much history knows.

## Alternatives rejected

**Prefix legacy labels into principal ids.** Rejected: it fabricates identities and destroys the
distinction between a vouched-for principal and a string.

**Make the actor `Maybe RecordedPrincipal`.** Rejected: `Nothing` would carry the same information
as `UnattributedPrincipal` while being one more thing to interpret, and it invites a new write to
omit the actor rather than being unable to.

**Backfill a placeholder actor during migration.** Rejected: it writes a claim about who acted into
records that never made one.

**Let a trusted context carry a `RecordedPrincipal`, so a directory-less host can keep writing
`LegacyPrincipal` or `UnattributedPrincipal` after the deprecated wrappers are removed**
— proposed as `assumeAuthorizedMemoryContextAs :: MemorySpaceId -> RecordedPrincipal ->
MemoryAccessContext`, with `memoryContextRecordedActor` returning it verbatim and the existing
constructor becoming the `KnownPrincipal` case. Rejected, though it is a small and otherwise
well-shaped change: it preserves the two gates that carry weight and is scoped to the trusted
path, but it makes both historical constructors writable forward, and their meaning is
specifically historical. An event stamped `kioku:legacy:<label>` today would assert it predates
memory spaces; `UnattributedPrincipal` on a write whose actor is standing right there would assert
nobody acted. The distinction would stop meaning what this record says it means — the same failure
the proposal set out to prevent, arrived at from the other side. A host that wants to record that
its principal is self-asserted has a place to say so already: the kind prefix of the
`PrincipalRef` it mints.

## References

- `kioku-api/src/Kioku/Api/Access/Internal.hs` — `RecordedPrincipal`, `LegacyPrincipalRef`, the
  marker scheme
- `kioku-core/src/Kioku/Partition.hs` — the single home for what an older payload means
- `kioku-core/test/Kioku/CodecCompatSpec.hs` — pre-partition fixtures decoding into the legacy
  space with their attribution intact
- [ADR-1](kioku-owns-memory-not-identity.md),
  [ADR-3](legacy-data-lands-in-one-explicit-space.md),
  [ADR-4](the-aggregate-enforces-the-partition.md)
