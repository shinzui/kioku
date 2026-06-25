# The Distillation Pyramid (L0 → L3)

Distillation turns raw, noisy evidence into compact, loadable agent context. It runs as a
layered pyramid, each level refining the one below.

```text
 L3  Persona   one distilled profile per scope
       ▲       "who/what is this scope, and what's durable about it"
 L2  Scenes    readable markdown blocks grouping related atoms by topic
       ▲
 L1  Atoms     concise durable memory sentences (MemoryRecords)
       ▲
 L0  Evidence  raw session turns / recorded notes — the floor
```

Each upward step is driven by a **pure LLM program** (a shikumi/baikai program with a typed
input/output signature). The programs are deterministic in structure: typed inputs in, typed
outputs out, with the model filling the schema.

## L0 — the evidence floor

L0 is the raw material: the **turns** a host records on a running session (role, content, tool
summary, token counts) and/or directly recorded memories. A host opts in to turn capture by
calling `recordTurn` while a session is running. If a host records no turns, distillation can
still run against recorded memories as evidence.

## L1 — extract atoms, then consolidate

L1 is a two-stage pass over one session's recent evidence:

### 1. Extract

The **extract** program reads:

- the session **focus** (task/topic),
- a human-readable **scope label**,
- the recent **conversation / evidence**,

and proposes a list of **atoms**. Each atom has:

- `atomType` — `fact | pattern | preference | constraint | instruction`,
- `content` — one concise, durable memory sentence,
- `priority` — `0` = always inject, `100` = default, larger = lower priority,
- `confidence` — `high | medium | low`.

### 2. Consolidate

For each extracted atom, the **consolidate** program looks at existing active memories (the
merge candidates) and decides one action:

| Action       | Effect                                                              |
|--------------|--------------------------------------------------------------------|
| **store**    | The atom is new → record a new memory.                              |
| **update**   | An existing memory should be revised (e.g. confidence/tags).       |
| **merge**    | The atom duplicates an existing memory → fold them together.       |
| **skip**     | The atom is redundant or low-value → drop it.                       |

Every decision is recorded as events, so the distillation history is itself auditable.

### Finding merge candidates

The candidate finder is pluggable. The CLI exposes two:

- **scan** (`--candidates scan`, default) — a recency/scope SQL scan. No embedding endpoint
  required.
- **recall** (`--candidates recall`) — uses hybrid [recall](recall.md) to find the most similar
  existing memories. Requires the `KIOKU_EMBEDDING_*` configuration.

`--limit N` caps how many candidates are considered per atom (default 5).

Run a pass manually:

```bash
kioku distill session SESSION_ID --candidates recall --limit 8
# Distilled session …: extracted=4 stored=2 merged=1 skipped=1
```

## L2 — scenes

The **scene** program groups a scope's active atoms into readable markdown **scene** blocks —
each a short narrative with a title naming the dominant topic or workflow (e.g.
"Testing & CI practices"). Scenes are what you'd hand a human or load as a digestible context
block.

Print them:

```bash
kioku scenes --scope mori:repo:web
```

## L3 — persona

The **persona** program distills all of a scope's scenes into a single **persona** document: who
or what the scope is about, its stable preferences, constraints, project facts, and durable
patterns. The program is instructed to preserve only details grounded in the scene text — it
must not invent biographical or private facts.

Print it:

```bash
kioku persona --scope rei:intention:intention_demo
```

## Timers — when distillation runs

Distillation is scheduled by **timers** rather than running on every write:

- **L1 idle-flush.** When a session goes quiet, an idle-flush timer (default **30 minutes**)
  schedules an L1 extraction pass for that session. Session lifecycle events
  (started/turn/completed/failed) drive the timer schedule via an inline projection.
- **L2 / L3 regeneration.** Recording memory schedules scene (L2) regeneration; scenes schedule
  persona (L3) regeneration. These are also timer-backed so bursts of writes collapse into one
  regeneration.

The **worker** fires due timers. Run it continuously, or fire a single timer for tests/cron:

```bash
kioku worker              # continuous: embeddings + timer loop
kioku worker --timers-once  # fire at most one due timer, then exit
```

See the [CLI Reference](cli-reference.md#kioku-worker) for worker modes.

## Workspace mirroring

L2 scenes and L3 personas are mirrored to the **current workspace** as plain markdown files, so
a coding agent (or you) can read them directly without querying the database:

```text
.kioku/scenes/<scope-slug>.md     # one file per scope's scene set
.kioku/persona/<scope-slug>.md    # one file per scope's persona
```

- Scene files render as `# <title>` + body.
- Persona files render the persona markdown directly.
- The scope slug is a sanitized `namespace-kind-ref` (or just `namespace` for global scopes).

Mirroring is **best-effort**: if the workspace isn't writable, distillation still succeeds and
the database remains the source of truth. The mirror is a convenience cache, not authoritative.

## End-to-end flow

```text
 host records turns on a running session         (L0)
        │  session goes idle ≥ 30 min
        ▼
 L1 timer fires ──► extract atoms ──► consolidate ──► memory events   (L1)
        │  recording memory schedules…
        ▼
 L2 timer fires ──► regenerate scenes ──► mirror to .kioku/scenes/     (L2)
        │  scenes schedule…
        ▼
 L3 timer fires ──► regenerate persona ──► mirror to .kioku/persona/   (L3)
```

All LLM calls in the pyramid use the embedding/model configuration described in
[Configuration](configuration.md).
