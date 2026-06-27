# Concepts

This page is the mental model behind kioku. Read it once; the rest of the guide assumes it.

## Memory

A **memory** is one durable thing an agent has learned. It is modeled as an event-sourced
aggregate: every change is an event appended to a kiroku stream, and the queryable forms (a
structured row, a full-text vector, a semantic embedding) are **projections** of that stream.
The event log — not the row table — is the source of truth.

Each memory has:

| Field        | Meaning                                                                        |
|--------------|--------------------------------------------------------------------------------|
| `memoryId`   | Stable identifier (`memory_…`).                                                 |
| `agentId`    | Which agent recorded it.                                                        |
| `sessionId`  | Optional session it came from.                                                  |
| `scope`      | Where it lives — see [Scope](#scope) below.                                     |
| `memoryType` | One of `fact`, `pattern`, `preference`, `constraint`, `instruction`.           |
| `content`    | The memory text itself.                                                         |
| `priority`   | `0` = always inject; `100` = default; larger = lower priority.                  |
| `confidence` | `high`, `medium`, or `low`.                                                     |
| `tags`       | A set of free-form labels.                                                      |
| `status`     | `active`, `superseded`, `merged`, or `archived`.                               |
| `createdAt`  | When it was recorded.                                                           |

### Memory types

- **fact** — a stable truth (e.g. "the deploy script lives in `bin/release`").
- **pattern** — a recurring behavior or workflow ("tends to refactor before adding features").
- **preference** — a stated like/dislike ("prefers concise answers").
- **constraint** — a hard rule ("never touch the `legacy/` directory").
- **instruction** — a standing directive ("always run the formatter before committing").

### Memory lifecycle

A memory starts **active**. From there it can be:

- **superseded** — replaced by a newer memory (the new one records `supersedes`);
- **merged** — folded into another memory (a winner absorbs a loser);
- **archived** — retired without a replacement.

Superseded, merged, and archived are *terminal* states. Only **active** memories are returned by
recall. Tags and confidence can be updated in place while a memory is active. These transitions
are exposed as library functions (`record`, `supersede`, `archive`, `updateTags`,
`updateConfidence`, `merge`) — see [Library API](library-api.md).

> **Idempotency.** Writes are idempotent and guarded by the current read-model state. Recording
> a memory id that already exists is a no-op; superseding/archiving an already-inactive memory
> is a no-op rather than an error.

## Scope

A **scope** is how kioku partitions memory so multiple hosts share one database. It is the key
host-agnostic idea. A `MemoryScope` is one of:

- **Global** — `namespace` only. Memory shared across the whole host: `ScopeGlobal "mori"`.
- **Entity** — `namespace` + `kind` + `ref`. Memory anchored to a specific thing:
  `ScopeEntity "rei" "intention" "intention_abc"`.

In CLI commands a scope is written as a colon-delimited string:

```text
NAMESPACE                 →  global scope        e.g.  mori
NAMESPACE:KIND:REF         →  entity scope        e.g.  rei:intention:intention_abc
```

- **namespace** — the host: `rei`, `mori`, `shikigami`, or your own.
- **kind** — the entity category: `intention`, `habit`, `repo`, `group`, `agent`, …
- **ref** — the specific entity id.

Recall and distillation always operate **within a scope**. An entity scope query matches only
memories with that exact `namespace`/`kind`/`ref`; a global scope query matches that namespace's
global memories. See [Scopes & Integrations](integrations.md) for per-host conventions.

## Session

A **session** is one agent run (or interactive conversation). Like memory, it is an
event-sourced aggregate. A session has a `focus` (its task/topic), a `scope`, an optional
`subjectRef`, optional continuation/delegation links, and optional awaiting metadata when the
run is parked for external input.

Sessions move through states:

- **start → running** — `start` opens a session.
- **running → awaiting** — `awaitInput` parks it while the host waits for external input,
  optionally with a correlation key and deadline.
- **awaiting → running** — `resume` restarts it and stores the resume input on the read model.
- **running → completed** — `complete` closes it (optionally records the model used and a
  summary).
- **running → failed** — `failSession` closes it with an error message.
- **interactive** — `recordInteractive` captures a whole interactive conversation in one shot.

`complete` and `failSession` can also close a session while it is **awaiting**; both clear the
awaiting fields in the read model. `resume` is idempotent after a successful resume, but a
resume that supplies a non-matching correlation key is rejected.

While a session is **running**, a host can call `recordTurn` to capture raw conversation
**turns** (role, content, tool summary, token counts). Turns are the **L0 evidence floor** the
distillation pyramid feeds on — but only when a host opts in to recording them. A host that
never records turns can still distill from recorded memories directly.

Sessions have two separate relationship axes:

- **Continuation chain** — `previousSessionId` links repeated work over time. `getChain` follows
  this chain.
- **Delegation lineage** — `parentSessionId` and `delegationDepth` record child sessions spawned
  by a parent run. `getDelegationChildren` returns direct children without mixing them into the
  continuation chain.

## Recall

**Recall** answers "what does the agent know that is relevant to this query, in this scope?"
kioku's recall is **hybrid**:

- **Keyword** — Postgres full-text search (`tsvector` / `websearch_to_tsquery`).
- **Embedding** — `pgvector` cosine similarity against the query's embedding.
- **Hybrid** (default) — both, fused with **Reciprocal Rank Fusion (RRF)**, then nudged by
  recency, priority, and confidence, and trimmed to a character budget.

When pgvector is unavailable, hybrid and embedding strategies transparently fall back to
keyword-only. Full details and the scoring formula are in **[Recall](recall.md)**.

## The distillation pyramid (L0 → L3)

Raw evidence is noisy. The pyramid progressively refines it into something an agent can load as
context:

```text
 L3  Persona   ── one distilled profile per scope (who this is, stable traits)
       ▲
 L2  Scenes    ── readable markdown "scene" blocks grouping related atoms
       ▲
 L1  Atoms     ── concise, durable memory sentences (the MemoryRecords above)
       ▲
 L0  Evidence  ── raw session turns / recorded notes (the floor)
```

- **L0 → L1 (Extract + Consolidate).** An LLM program reads recent session evidence and extracts
  candidate **atoms**. For each atom, a second program decides how it interacts with existing
  memory: **store**, **update**, **merge**, or **skip**. The decision is recorded as events.
- **L1 → L2 (Scenes).** Active atoms in a scope are summarized into readable markdown **scene**
  blocks, each with a title and a narrative body.
- **L2 → L3 (Persona).** Scenes for a scope are distilled into a single **persona** document —
  the durable profile of who/what this scope is about.

L2 and L3 are also **mirrored to the workspace** as files (`.kioku/scenes/*.md` and
`.kioku/persona/*.md`) so a coding agent can read them directly. Distillation is driven by
**timers** (idle-flush after a session goes quiet) and can be run on demand from the CLI.

The full pyramid — extraction prompts, consolidation actions, timers, and mirroring — is
documented in **[The Distillation Pyramid](distillation.md)**.

## How the pieces fit

```text
   host app
      │  records memories / sessions / turns
      ▼
  Kioku.Memory / Kioku.Session  ──►  event streams (source of truth)
      │                                   │ projections
      │                                   ▼
      │                          kiroku.kioku_memories (row + tsvector + embedding)
      ▼                                   │
  Kioku.Recall  ◄───────────────────────┘  hybrid retrieval (FTS + vector + RRF)

  worker:  embeds new memories · fires distillation timers
  distill: L0 turns ──► L1 atoms ──► L2 scenes ──► L3 persona
```
