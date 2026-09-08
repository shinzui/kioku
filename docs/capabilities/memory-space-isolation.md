---
title: "Memory-space isolation on a host-supplied access decision"
type: Capability
description: "Carry an already-made authorization decision as a MemoryAccessContext naming one memory space, one principal, and the actions it was minted for, so every write is checked against it and every read returns nothing outside its space — without Kioku depending on any identity service."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-4
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.4.0.0"
packages:
  - kioku-api
  - kioku-core
interface:
  - Kioku.Api.Access
  - Kioku.Api.Access.Internal
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/SpaceIsolationSpec.hs
    proves: "Every memory and session read returns only the requested space, recall never crosses a space however wide its scope, identically keyed scenes and personas stay apart, and every partitioned lookup has a partition-leading index."
  - kind: test
    resource: kioku-core/test/Kioku/PortfolioAccessSpec.hs
    proves: "A worked three-service integration: a missing coarse claim is refused before anyone is looked up, a paused agent resolves to nothing, an unresolved subject is not a denial, a Conditional answer is a refusal, and the minted context pins the consistency token a follow-up read chains from."
  - kind: test
    resource: kioku-core/test/Kioku/MemorySpaceSpec.hs
    proves: "A memory cannot be archived from another space, an id in another space is indistinguishable from one that does not exist, and a read-only context cannot record."
  - kind: test
    resource: kioku-api/test/Kioku/Api/AccessSpec.hs
    proves: "The memory space id and principal ref validators accept opaque host-shaped identifiers and reject empty, whitespace, control-character, over-long, and relationship-separator values."
  - kind: guide
    resource: docs/user/upgrading-to-memory-spaces.md
    proves: "What breaks at compile time, what happens to data already stored, and how to deploy and verify the backfill migration."
  - kind: guide
    resource: docs/user/integrations.md
    proves: "The two supported ways a host supplies a decision, and the contract matrix naming what Kioku must never infer from each value it receives."
---

# Memory-space isolation on a host-supplied access decision

A **memory space** is the isolation boundary. It is a different axis from
[scope (CAP-3)](host-agnostic-memory-scopes.md): scope organizes memory inside a space,
and two spaces may use the same namespace and scope for entirely unrelated data.

Kioku never decides access itself — it carries a decision somebody else made. Every
write takes a `MemoryAccessContext` naming one `MemorySpaceId`, the principal the write
is attributed to, and the permissions it was minted for. Two rules are checked on every
write: the payload must name the **same** space and principal as the context
(`MemorySpaceMismatch`, `MemoryActorMismatch` — never a quiet rewrite), and the context
must have been minted for the action (`MemoryNotPermitted`). A memory or session belongs
to its creating space permanently, and the aggregate refuses any later command naming a
different one, so the check survives a concurrent-writer retry. Reads take a bare
`MemorySpaceId` and return nothing outside it.

There are two supported ways to supply a decision, and the first is the default:

- **Trusted, in-process.** `assumeAuthorizedMemoryContext` grants every action on the
  named space without asking anyone. It is named the way it is so it cannot be used by
  accident. This is how the [CLI (CAP-15)](operational-cli.md) works, and it is why
  Kioku is usable on its own.
- **Behind a service boundary.** `authorizeMemoryAccess` runs a coarse credential check,
  a directory lookup, and a per-space permission check, in that order, through two
  records of plain functions — `PrincipalDirectory` and `PermissionChecker` — that the
  host fills in. The three failures stay distinct on purpose: a missing coarse scope, an
  unresolved principal, and an authorization denial are three different errors, and none
  may become a successful recall that happens to return zero rows.

A background worker cannot arrive holding a context, because it discovers its own work.
It reads the space out of the claimed timer's payload and asks a `MemoryContextProvider`
for a decision about *that* space; provider refusal, a missing permission, or a
context minted for another space dead-letters the work before any database, model, or
workspace access.

**Kioku's build closure contains no identity service and never will.** Every type in
`Kioku.Api.Access` is plain `base`, `containers`, `text`, and `aeson`. Object types and
permission names come from the host as a `MemoryAuthorizationBinding` rather than being
hard-coded, and a rendered principal id is opaque text whose prefix Kioku never parses.

## Shape

```haskell
import Kioku.Api.Access

context :: MemoryAccessContext
context =
  assumeAuthorizedMemoryContext
    (either error id (mkMemorySpaceId "acme-tenant-3"))
    (MemoryActor (either error id (mkPrincipalRef "agent_01h9xk3v7hf8b9c0d1e2f3g4h5")))
```

## Limits

- Kioku ships **no default authorization binding**, because it does not own the schema
  that names memory-space object types and permissions. A service-backed host supplies
  one or gets no `authorizeMemoryAccess` at all.
- A `Conditional` authorization answer is treated as a refusal. Kioku has no way to
  evaluate a condition it does not own.
- `assumeAuthorizedMemoryContext` observes nothing and pins no consistency token; a host
  that needs read-your-writes against a lagging authorization replica must use the
  checked path and chain from the context's recorded token.
- Data written before 0.4.0.0 lives in one explicit space, `kioku_legacy`, backfilled by
  migration `0011`. Nothing moves between spaces and nothing is deleted.
