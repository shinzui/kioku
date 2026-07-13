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
