---
title: "Host-agnostic memory scopes and collision-free scope identity"
type: Capability
description: "Partition memory by a generic namespace plus optional entity kind and ref so unrelated agent platforms share one store without colliding, with a derived scope identity whose digest keeps two scopes in separate timer ids and mirror files even when their readable slugs would coincide."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-3
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-api
  - kioku-core
interface:
  - Kioku.Api.Scope
  - Kioku.Distill.ScopeIdentity
  - Kioku.Id
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/ScopeIdentitySpec.hs
    proves: "Two scopes that once collided now derive different everything, well-formed scopes keep their exact historical ids, the escaping is injective on adversarial components, and one scope in two memory spaces derives different timer ids."
  - kind: test
    resource: kioku-cli/test/Kioku/Cli/ParserSpec.hs
    proves: "The colon-delimited scope string splits on the first two colons only, so a host:port or URL ref keeps its colons, while empty or slash-bearing namespaces and kinds are rejected."
  - kind: module
    resource: kioku-api/src/Kioku/Api/Scope.hs
    proves: "The MemoryScope type and its validating constructors, including the reserved characters a namespace and kind may not contain."
  - kind: guide
    resource: docs/user/integrations.md
    proves: "The namespace conventions rei, mori, and shikigami use, and how to add a host of your own."
---

# Host-agnostic memory scopes and collision-free scope identity

A `MemoryScope` is either **global** — a namespace alone, the bucket for memory shared
across a whole host — or an **entity** scope: a namespace, a kind, and a free-text ref
anchoring memory to one specific thing.

```haskell
data MemoryScope
  = ScopeGlobal Namespace
  | ScopeEntity Namespace ScopeKind Text
```

That is the idea that makes Kioku host-agnostic. `rei` (personal coaching), `mori`
(multi-repo agent execution), and `shikigami` (autonomous system agents) each own a
namespace and organize entities under it however they like, in one database, without
agreeing on a schema. On the command line the same value is written `NAMESPACE` or
`NAMESPACE:KIND:REF`, split on the **first two colons only**, so refs that are URLs or
`host:port` pairs need no escaping.

Namespaces and kinds are short vocabulary labels: non-empty, and free of `%`, `/`, and
`:` — the three characters the scope-identity encoding gives meaning to. Refs are host
free text.

**Scope identity is what the rest of the system keys on.** `scopeIdentity` derives the
stable identity used for distillation timer ids and mirror filenames, and it is built
from an injective escaping plus a digest rather than from the readable text alone.
The readable prefix by itself is not collision-free — a sanitiser that maps every
character outside `A-Za-z0-9_-` to `-` puts `a-b` and `a`/`b` on the same string — so
`slugWithDigest` appends the first ten hex characters of a SHA-256 of the true identity.
The same recipe names the space directories in
[workspace mirroring (CAP-11)](workspace-artifact-mirroring.md).

## Shape

```bash
mori                                   # global bucket of the mori namespace
rei:intention:intention_01h4...        # entity scope
ops:host:db.internal:5432              # ref = db.internal:5432
```

## Limits

- **A namespace is organization, not authorization.** Nothing in the scope machinery
  authenticates anyone, and any process that can open the database can read every
  namespace in it. Tenant isolation is
  [a memory space (CAP-4)](memory-space-isolation.md), a separate axis.
- An entity scope is exact everywhere: it never sees its namespace's global memories,
  and the global bucket never sees entity rows. Only
  [recall (CAP-5)](hybrid-recall-with-explicit-targets.md) can ask for a whole namespace,
  and it must say so.
- `Kioku.Id.parseIdLenient` exists for legacy streams only: it will take a
  `kioku_memory` id, discard its prefix, and rebrand the UUID. Use `parseId` for operator
  and host input.
