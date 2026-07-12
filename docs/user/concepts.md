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

**Forgetting propagates.** Superseding, archiving, or merging a memory — and changing a memory's
**confidence** — schedules a regeneration of its scope's scene, so forgotten or downgraded content
does not survive in the scene, in the persona, or in the `.kioku/` mirror files. Changing only a
memory's **tags** does not, deliberately: tags feed neither the scene's source hash nor its prompt.

When the last active memory in a scope is forgotten, the scope's scene and persona rows **and their
mirror files are deleted**. The event log keeps the history; the derived artifacts do not.

> **Idempotency.** A duplicate write that matches what already happened succeeds; a *conflicting*
> one is rejected. Recording a memory id that already exists is a no-op only when the request
> carries the same agent id, session id, content, scope, type, priority, confidence, tags, and
> `supersedes` — recording different content under an existing id returns `MemoryConflict`.
> Likewise, superseding a memory that was
> already superseded is a no-op only when the winner is the same; naming a different winner
> conflicts, as does archiving a memory that was superseded.
>
> Call-time timestamps (`recordedAt` and friends) are deliberately *not* compared: the id is the
> identity, and a retry that re-reads its clock is still a retry.
>
> These rules are enforced by the aggregate, not by a read-model precheck, so they hold under
> concurrent writers. A duplicate that loses a concurrent race still gets the same success the
> winner got.

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

- **namespace** — the host: `rei`, `mori`, `shikigami`, or your own. May not contain `%`, `/`, or
  `:`.
- **kind** — the entity category: `intention`, `habit`, `repo`, `group`, `agent`, … Same
  restriction.
- **ref** — the specific entity id. Host free text: it **may** contain `:` and `/`. The CLI splits
  on the first two colons only, so `ops:host:db.internal:5432` is the entity scope `ops` / `host` /
  `db.internal:5432`, and `mori:repo:shinzui/kikan` is a valid repo ref.

### Global scope means different things to recall and to reads

An **entity** scope is exact everywhere: it matches only that exact `namespace`/`kind`/`ref`, and
never sees the namespace's global memories.

A **global** scope is where people get caught out, because it is not symmetric:

| You call                                | `ScopeGlobal ns` means | You get                                                        |
|-----------------------------------------|------------------------|----------------------------------------------------------------|
| `recall` / `kioku recall --scope ns`     | *no scope filter*      | every active memory in the namespace, **entity-scoped rows included** |
| `getActiveByScope`, `getGlobal`, and distillation | *the global bucket*    | only rows recorded with **no** entity scope                     |

In one line: **recall searches namespace-wide for a global scope; scoped reads and distillation are
exact-scope.** So a memory under `mori:repo:web` *is* returned by `kioku recall --scope mori`, but
it does *not* feed `mori`'s scene or persona. For the read-side equivalent of recall's breadth, use
`getActiveInNamespace`.

Full detail: [Recall](recall.md#global-scope-namespace-wide-recall-vs-exact-scope-reads). See
[Scopes & Integrations](integrations.md) for per-host conventions.

## Session

A **session** is one agent run (or interactive conversation). Like memory, it is an
event-sourced aggregate. A session has a `focus` (its task/topic), a `scope`, an optional
`subjectRef`, optional continuation/delegation links, and optional awaiting metadata when the
run is parked for external input.

Sessions move through states:

- **start → running** — `start` opens a session.
- **running → awaiting** — `awaitInput` parks it while the host waits for external input,
  optionally with a correlation key and deadline. The **deadline is advisory**: kioku stores it
  for the host's own bookkeeping and *does not enforce it*. No timer fires and nothing expires
  when it passes — a parked session stays parked until something resumes, completes, or fails it.
- **awaiting → running** — `resume` restarts it and stores the resume input on the read model.
- **running → completed** — `complete` closes it (optionally records the model used and a
  summary).
- **running → failed** — `failSession` closes it with an error message.
- **interactive** — `recordInteractive` captures a whole interactive conversation in one shot.

`complete` and `failSession` can also close a session while it is **awaiting**; both clear the
awaiting fields in the read model. Closing an *already-closed* session conflicts rather than
silently succeeding: completing a failed session, or failing a completed one, returns
`SessionConflict`.

**Resume correlation is an aggregate invariant.** The key a `resume` supplies must equal the key
the session actually parked on — exactly, including the keyless case, where a resume must also
supply no key. The awaited key is part of the session's replayed state, so the check survives
concurrent writers: a caller holding a stale key cannot answer a wait that was already resumed
and re-parked under a new one. `resume` is idempotent after a successful resume only when it
re-delivers the same input; a different input means someone else answered the wait, and returns
`SessionConflict`. To answer a wait *without* the key — an operator override for a session whose
key is lost or wrong — call `forceResume`, which is explicit and inherently last-writer-wins.

**Lineage is validated at `start`.** A session may not be its own predecessor or its own parent,
`delegationDepth` must be non-negative and consistent with `parentSessionId` (a delegated session
sits at depth ≥ 1; a root session at depth 0), and the depth is capped. kioku does *not* check
that the referenced sessions exist — a dangling pointer is harmless, and requiring existence
would forbid out-of-order ingestion.

While a session is **running**, a host can call `recordTurn` to capture raw conversation
**turns** (role, content, tool summary, token counts). Turns are the **L0 evidence floor** the
distillation pyramid feeds on — but only when a host opts in to recording them. A host that
never records turns can still distill from recorded memories directly.

A turn's identity is `(sessionId, turnIndex)`; `turnId` is an idempotency token that travels with
it. Indexes must strictly increase — the aggregate enforces this, so a stale or out-of-order turn
cannot overwrite a committed one. Re-recording an identical turn is a no-op; the same index with
different content, or a `turnId` reappearing at a different index, returns `SessionConflict`.

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
  memory: **store**, **update**, **merge**, or **skip**. The resulting memory changes are events;
  the decision itself is written to an audit table.
- **L1 → L2 (Scenes).** Active atoms in a scope are summarized into a readable markdown **scene**
  with a title and a narrative body.
- **L2 → L3 (Persona).** Scenes for a scope are distilled into a single **persona** document —
  the durable profile of who/what this scope is about.

L2 and L3 are also **mirrored to the workspace** as files (`.kioku/scenes/*.md` and
`.kioku/persona/*.md`) so a coding agent can read them directly.

Distillation is driven by **timers**, not by every write. L1 runs on a ramp during a live session,
on session completion, and after the session goes idle; L2 and L3 regenerate when the memories
underneath them change. The LLM programs call **Anthropic** (`ANTHROPIC_API_KEY`) — a different
credential from the embeddings endpoint.

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
