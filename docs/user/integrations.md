# Scopes & Integrations

kioku is host-agnostic: one database serves many platforms, kept apart by **namespace** and
organized by **scope**. This page documents the scope conventions for the three first-party
hosts and how to add your own.

## Scope recap

```text
ScopeGlobal  namespace                 →  CLI:  NAMESPACE
ScopeEntity  namespace kind ref         →  CLI:  NAMESPACE:KIND:REF
```

- **namespace** — the host. Never shared across hosts. May not contain `%`, `/`, or `:`.
- **kind** — the entity category within a host. Same restriction.
- **ref** — the specific entity's id. Host free text: it **may** contain `:` and `/`, so
  `myapp:repo:shinzui/kikan` and `ops:host:db.internal:5432` are both valid. The CLI splits on the
  first two colons only.

Choosing scopes well is the main integration decision: pick a `kind`/`ref` that matches the
natural unit you want memories to accumulate around (a user goal, a repo, an agent).

> **The global scope is not just another bucket.** For **recall**, a global scope (`--scope mori`)
> means *no scope filter*: it returns every active memory in the namespace, entity-scoped rows
> included. For **scoped reads and distillation**, the same value means only the rows recorded with
> no entity scope. So a `mori:repo:proj_01h4...` memory *is* found by
> `kioku recall --scope mori`, but it
> does *not* feed `mori`'s persona. The "User-wide"/"Org-wide"/"System-wide" rows in the tables
> below are the *global bucket* in that second sense. See
> [Recall](recall.md#global-scope-namespace-wide-recall-vs-exact-scope-reads).

Scope identity is collision-free: each component is percent-escaped before being joined, so
`ScopeGlobal "a/b/c"` and `ScopeEntity "a" "b" "c"` cannot share a scene or persona row. That is why
`%`, `/`, and `:` are reserved in namespaces and kinds — they are the characters the encoding gives
meaning to.

## rei — personal coaching

`rei` migrated its `AgentMemory`/`AgentSession` modules onto kioku. Rei's typed anchors map to
scopes:

| Rei anchor    | Scope                                          |
|---------------|------------------------------------------------|
| Intention     | `rei:intention:<intentionId>`                  |
| Habit         | `rei:habit:<habitId>`                          |
| User-wide     | `rei` (global)                                 |

```bash
kioku recall "what motivates this user" --scope rei:intention:intention_abc
kioku persona --scope rei:intention:intention_abc
```

Rei's Rei-specific scheduling (`AgentSchedule` — delegation/autonomy/triggers) intentionally
stays in Rei; only the memory/session substrate moved to kioku.

## mori — multi-repo agent execution

`mori agent exec --group` runs a prompt or skill across a group of repos, accumulating
cross-run learnings in kioku. Natural scopes:

| Unit          | Scope                              |
|---------------|------------------------------------|
| A single repo | `mori:repo:<projectId>`            |
| A repo group  | `mori:group:<groupId>`             |
| Org-wide      | `mori` (global)                    |

```bash
kioku recall "how is CI configured here" --scope mori:repo:proj_01h4...
kioku scenes --scope mori:group:grp_01h4...
```

The refs are Mori's typed `ProjectId` (`proj_...`) and `GroupId` (`grp_...`), not a repository slug
or display name. Group-scoped memories let a run in one repo benefit from what was learned in a
sibling repo.

## shikigami — autonomous system agents

`shikigami` adopts kioku as its memory subsystem with hybrid recall. Typical scopes:

| Unit              | Scope                          |
|-------------------|--------------------------------|
| A specific agent  | `shikigami:agent:<agentName>`  |
| System-wide       | `shikigami` (global)           |

```bash
kioku recall "prior incident handling" --scope shikigami:agent:watcher-01
```

## Adding your own host

1. **Pick a namespace** — a short stable label unique to your host (e.g. `myapp`). It will
   prefix every scope you write.
2. **Decide your entity kinds** — the units memories accumulate around (`project`, `user`,
   `ticket`, …). Use global scope (`myapp`) for cross-entity memory.
3. **Map your typed ids into `MemoryScope`** — build the labels through the validating
   constructors, and render your typed id into the ref slot (which is plain `Text`):

   ```haskell
   scope <- ScopeEntity <$> mkNamespace "myapp" <*> mkScopeKind "project" <*> pure (idText projectId)
   ```

   `mkNamespace`/`mkScopeKind` reject `%`, `/`, and `:`. The ref is unconstrained. (kioku
   deliberately uses a concrete `MemoryScope` value rather than a type parameter, so each host maps
   its own ids in — see the [Library API](library-api.md).)
4. **Write and recall within those scopes** — every `record`/`recall`/`distill` call carries the
   scope, so your data never collides with another host's.
5. **Optionally capture turns** — call `recordTurn` on running sessions to feed the
   [distillation pyramid](distillation.md) with L0 evidence. Turns are only accepted while the
   session is **running**, and turn indexes must strictly increase — replaying turns out of order
   returns `SessionConflict` rather than silently overwriting a committed turn.

Because all hosts share one database and schema, a single `kioku worker` process can serve
embeddings and distillation for every namespace at once.

## Namespace is organization, not a security boundary

Everything above is *organization*. A namespace keeps `rei`'s memories from colliding with
`mori`'s inside one deployment; it does not decide who is allowed to read them. Nothing in the
scope machinery authenticates a caller, and any process that can open the database can read
every namespace in it. If you need "these memories belong to this customer, and that customer's
agents must never see them", that is a *memory space* — the isolation boundary described below —
not a namespace.

## The portfolio trust triad

Kioku is one of several services in the Kikan portfolio. Three of its siblings own the pieces of
identity and access control that Kioku deliberately does **not** implement:

- **Shomei** (証明, "proof") — authentication. It verifies a credential (a JWT, a session cookie)
  and hands the caller a verified *subject* string plus coarse claims: roles and OAuth-style
  scopes. Its Haskell surface is `mori://shinzui/shomei/packages/shomei-servant`, whose `AuthUser`
  record carries `authUserId`, `authSessionId`, `authRoles`, `authScopes`, and `authPermissions`.
  Those claims are static: they were minted at login and say nothing about any particular memory
  space.
- **Meibo** (名簿, "roster") — the directory. It is the canonical list of *principals* — people,
  agents, teams, roles, services, connectors, and organizations — and it owns the mapping from a
  Shomei subject to a principal, agent lifecycle (including the kill switch that pauses an
  agent), and team membership. Its canonical identifier type lives at
  `mori://shinzui/meibo/docs/initial-spec` and is implemented in the project-relative
  `meibo-api/src/Meibo/Api/Id.hs` as `PrincipalId`, with exactly one renderer,
  `principalIdText`, producing kind-prefixed TypeIDs: `person_01h…`, `agent_01h…`, `team_01h…`,
  `role_01h…`, `service_01h…`, `connector_01h…`, `org_01h…`.
- **En** (縁, "relationship") — authorization. It is a Zanzibar-style relationship-based engine:
  you ask it `check(subject, permission, object)` and it answers `Allowed`, `Denied`, or
  `Conditional`. Its transport-neutral core is `mori://shinzui/en/packages/en-core`; its Servant
  guard is `mori://shinzui/en/packages/en-servant`. Every answer comes back with a
  `ConsistencyToken` (`checkedAt`) that a later read can present as `AtLeastAsFresh` to be sure it
  observes at least everything the first one did.

The portfolio-wide vocabulary that names memory spaces and user-facing principals inside En is
tracked by `mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-1`.

### Contract matrix

Read this as: what Kioku receives, who owns it, what Kioku does with it, and — the load-bearing
column — what Kioku must never infer from it.

| Value Kioku receives | Owner | How Kioku uses it | What Kioku must never infer |
|---|---|---|---|
| Verified subject + roles/scopes | Shomei | Coarse per-action gate before any space-specific work; a failure is `MemoryCoarseScopeMissing` | That the subject may touch a particular memory space. Shomei claims are static and space-blind. |
| Rendered principal id (`person_…`, `team_…`, `agent_…`, `service_…`, `org_…`) | Meibo | Stored verbatim as the actor and, where applicable, the owner of a memory | The principal's kind, profile, handle, memberships, or lifecycle. Kioku never parses the prefix. |
| Shomei subject → principal resolution | Meibo | Turns an authenticated subject into an actor before any En call | That an unresolved subject is merely "new". A paused agent or an unlinked credential also arrives as unresolved, and both must fail closed. |
| `Allowed` / `Denied` / `Conditional` + `checkedAt` token | En | Mints a `MemoryAccessContext` recording the space, actor, granted permissions, and token | That a `Conditional` answer is an allow, or that a denial on one space says anything about another. |
| Memory-space object type and permission names | Kikan-En (schema owner) | Supplied to Kioku as a `MemoryAuthorizationBinding`; Kioku renders `type:spaceId` object refs from it | The names themselves. Kioku ships no default binding, because the owning schema has not shipped. |
| `MemorySpaceId` | Kioku | The isolation partition on every command, query, worker, and (from a later plan) every row | That a *missing* space means "visible everywhere". Absence is never permission. |

### The request order, and why it is that order

Authorization runs in three steps, and no one of them can stand in for another:

1. **Shomei** proves the credential is real and carries the coarse scope for the action. Skipping
   this means trusting an unauthenticated subject string.
2. **Meibo** resolves that subject to a canonical principal. Skipping this means Kioku invents its
   own user table, or trusts a caller-supplied principal id.
3. **En** decides whether *that principal* may perform *that permission* on *this memory space*.
   Skipping this means a coarse `kioku:read` scope grants every space in the deployment.

The failures are kept distinct on purpose. A missing coarse scope, an unresolved principal, and an
En denial are three different errors, and none of them may be quietly turned into a successful
recall that happens to return zero rows — a caller cannot tell "you may not look here" from "there
is nothing here", and the difference matters.

### What is not available yet

None of Meibo, Shomei, En, or Kikan-En is a published package: each is at an in-tree `0.1.0.0`
with no release tag, and none resolves on Hackage. Kikan-En's schema
(project-relative `src/Kikan/En/Schema.hs`) still has `agent` as its only subject type and has no
`space` object and no `can_view` permission family; IR-1, which adds them, is `status: proposed`.

Kioku therefore takes **no build dependency** on any of them. It accepts the rendered principal id
as opaque text at its boundary, and it takes the En object type and permission names from the host
as a `MemoryAuthorizationBinding` rather than hard-coding names the schema owner has not published.
When those packages ship, an adapter maps them onto the types in
`kioku-api/src/Kioku/Api/Access.hs`; nothing in Kioku's core has to change.
