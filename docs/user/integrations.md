# Scopes & Integrations

kioku is host-agnostic: one database serves many platforms, kept apart by **namespace** and
organized by **scope**. This page documents the scope conventions for the three first-party
hosts and how to add your own.

## Scope recap

```text
ScopeGlobal  namespace                 →  CLI:  NAMESPACE
ScopeEntity  namespace kind ref         →  CLI:  NAMESPACE:KIND:REF
```

- **namespace** — the host. Never shared across hosts.
- **kind** — the entity category within a host.
- **ref** — the specific entity's id.

Choosing scopes well is the main integration decision: pick a `kind`/`ref` that matches the
natural unit you want memories to accumulate around (a user goal, a repo, an agent).

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

| Unit          | Scope                       |
|---------------|-----------------------------|
| A single repo | `mori:repo:<repo>`          |
| A repo group  | `mori:group:<group>`        |
| Org-wide      | `mori` (global)             |

```bash
kioku recall "how is CI configured here" --scope mori:repo:web
kioku scenes --scope mori:group:frontend
```

Group-scoped memories let a run in one repo benefit from what was learned in a sibling repo.

## shikigami — autonomous system agents

`shikigami` adopts kioku as its memory subsystem with hybrid recall. Typical scopes:

| Unit              | Scope                          |
|-------------------|--------------------------------|
| A specific agent  | `shikigami:agent:<agentId>`    |
| System-wide       | `shikigami` (global)           |

```bash
kioku recall "prior incident handling" --scope shikigami:agent:watcher-01
```

## Adding your own host

1. **Pick a namespace** — a short stable label unique to your host (e.g. `myapp`). It will
   prefix every scope you write.
2. **Decide your entity kinds** — the units memories accumulate around (`project`, `user`,
   `ticket`, …). Use global scope (`myapp`) for cross-entity memory.
3. **Map your typed ids into `MemoryScope`** — `ScopeEntity (Namespace "myapp") (ScopeKind
   "project") projectId`. (kioku deliberately uses a concrete `MemoryScope` value rather than a
   type parameter, so each host maps its own ids in — see the [Library API](library-api.md).)
4. **Write and recall within those scopes** — every `record`/`recall`/`distill` call carries the
   scope, so your data never collides with another host's.
5. **Optionally capture turns** — call `recordTurn` on running sessions to feed the
   [distillation pyramid](distillation.md) with L0 evidence.

Because all hosts share one database and schema, a single `kioku worker` process can serve
embeddings and distillation for every namespace at once.
