# The Distillation Pyramid (L0 → L3)

Distillation turns raw, noisy evidence into compact, loadable agent context. It runs as a
layered pyramid, each level refining the one below.

```text
 L3  Persona   one distilled profile per scope
       ▲       "who/what is this scope, and what's durable about it"
 L2  Scenes    a readable markdown block summarizing a scope's atoms
       ▲
 L1  Atoms     concise durable memory sentences (MemoryRecords)
       ▲
 L0  Evidence  raw session turns / recorded notes — the floor
```

Each upward step is driven by a **pure LLM program** (a shikumi/baikai program with a typed
input/output signature). The programs are deterministic in structure: typed inputs in, typed
outputs out, with the model filling the schema.

All four programs call **Claude Haiku 4.5** and need **`ANTHROPIC_API_KEY`**. This is a *different*
credential from the embeddings endpoint: the `KIOKU_EMBEDDING_*` settings in
[Configuration](configuration.md) govern embeddings only. The model is currently hard-coded and is
not configurable.

## L0 — the evidence floor

L0 is the raw material: the **turns** a host records on a running session (role, content, tool
summary, token counts) and/or directly recorded memories. A host opts in to turn capture by
calling `recordTurn` while a session is running. If a host records no turns, distillation can
still run against recorded memories as evidence.

## L1 — extract atoms, then consolidate

L1 is a two-stage pass over one session's recent evidence.

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

Priorities are clamped to `0`–`100`, and an `atomType` or `confidence` outside the allowed set is
**rejected** — failing the extraction (a retryable timer fire) rather than being quietly coerced to
a default. A negative priority would otherwise sort ahead of everything in the scope forever.

### 2. Consolidate

For each extracted atom, the **consolidate** program looks at existing active memories (the
merge candidates) and decides one action:

| Action       | Effect                                                                                     |
|--------------|--------------------------------------------------------------------------------------------|
| **store**    | The atom is new → record a new memory.                                                      |
| **update**   | An existing memory should be rewritten with fresher/clearer content → a **new** memory is recorded that **supersedes** it, and the old one is merged into it. Nothing is edited in place. Requires at least one target. |
| **merge**    | Several existing memories collapse into one → the same mechanism, with every target merged into the winner. Requires at least one target. |
| **skip**     | The atom is redundant, transient, or low-value → drop it.                                   |

`update` and `merge` both count as `merged=` in the summary line — there is no `updated=` field.

The pass records what it **applied**, not what the model asked for. A merge naming targets that no
longer exist degrades to a **store**; one whose only target is the atom's own prior copy, or whose
winner is already retired, degrades to a **skip**.

Every decision is written to the `kioku_consolidation_decisions` **audit table** — the action
actually applied, its targets, the resulting memory, and the rationale — while the memory changes
themselves are events. The audit key is deterministic, so a re-fired timer does not duplicate rows.

### Idempotency: L1 is watermarked

A pass whose turns are all covered by the last successful pass is skipped **before any LLM call**,
and the CLI prints `Session already distilled (no new turns); use --force to re-run.` The watermark
advances only when the whole pass succeeds, so a failure does not silently swallow evidence. Timer
fires respect the watermark; `kioku distill session … --force` ignores it.

### Finding merge candidates

The candidate finder is pluggable. The CLI exposes two:

- **scan** (`--candidates scan`, default) — a recency/scope SQL scan. No embedding endpoint
  required.
- **recall** (`--candidates recall`) — uses hybrid [recall](recall.md) to find the most similar
  existing memories. Requires the `KIOKU_EMBEDDING_*` configuration.

`--limit N` caps how many candidates are considered per atom (default `5`, range 1–50).

**These flags govern the CLI only.** The `kioku worker` timer path — the one that actually runs in
production — always uses recall-based candidates with a fixed limit of **8**, because a
priority-ordered scan prefix hides duplicates that fall below the window. Recall degrades to
FTS-only without pgvector, so the worker needs no capability gating.

Run a pass manually:

```bash
kioku distill session kioku_session_01h455… --candidates recall --limit 8
# Distilled session kioku_session_01h455…: extracted=4 stored=2 merged=1 skipped=1
```

## L2 — scenes

The **scene** program folds *all* of a scope's active atoms into a single markdown **scene**: one
title naming the dominant topic or workflow (e.g. "Testing & CI practices") and one short narrative
body. It is what you'd hand a human, or load as a digestible context block. (The schema allows
several scenes per scope; today exactly one is generated, so there is one scene file per scope.)

Print it:

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
kioku persona --scope rei:intention:intention_01h4...
```

## Timers — when distillation runs

Distillation is scheduled by **timers** rather than running inline on every write.

**L1 passes** are driven by three timers, from session events:

- **ramp** — fires **immediately** at turns 1, 2, 4, 8, 16, and every 16th turn thereafter. A long
  live session is therefore distilled *as it goes*, not only once it falls quiet.
- **final** — fires when the session **completes or fails**.
- **idle** — fires **30 minutes** after the last turn. It is one debounced timer per session, pushed
  forward by each new turn, so a 50-turn session holds one timer row, not fifty. The 30 minutes is a
  compile-time constant, not configuration.

**L2 scene regeneration** is scheduled (with a 5-second debounce) by every event that changes what a
scope's scene is built from:

- a memory **recorded**;
- a memory **archived**, **superseded**, or **merged** — forgetting must reach the scene, or
  forgotten content survives in it;
- a memory's **confidence** changing, which feeds both the scene's source hash and the LLM prompt.

A **tags-only** change schedules nothing, on purpose: tags are in neither the source hash nor the
prompt.

**L3 persona regeneration** is scheduled (same 5-second debounce) by every scene regeneration —
including a scene *deletion*.

### Regeneration is content-hashed

Each regeneration hashes its inputs (the scope's atoms for a scene; the scope's scenes for a
persona). If the hash is unchanged, the row and the **LLM call are skipped** and only the mirror
file is rewritten. This — not the timer debounce — is what makes a burst of writes cost one
regeneration: the extra timers still fire, they just short-circuit on the hash.

### When a scope empties, its artifacts are removed

Forgetting the last active memory in a scope (archive, supersede, or merge) **deletes** the scene
row and its mirror file, which in turn deletes the persona row and its mirror. Neither delete costs
an LLM call — there is nothing left to summarize. The event log keeps the history; the derived
artifacts do not.

### When distillation fails

A timer fire reports one of four outcomes:

- **completed** — the pass ran.
- **retry later** — a transient failure (the LLM endpoint is down, a store blip). Retries with
  backoff, `30s` doubling to a `900s` cap, under an **8-attempt** ceiling. After that the timer
  becomes a visible `dead` row instead of burning LLM tokens forever — a structurally impossible
  pass (a conversation past the model's context window, a missing `ANTHROPIC_API_KEY`) stops rather
  than retrying indefinitely.
- **failed permanently** — a structurally broken timer (malformed payload, a correlation id that is
  not a session id). Dead-lettered on the first fire.
- **not mine** — a timer no handler in this build owns. Requeued 600s out rather than killed, so a
  rolling deploy is safe.

A dead **L1** timer means that session is never distilled; a dead **L2/L3** timer means that scope's
scene or persona never regenerates. See
[Troubleshooting](troubleshooting.md#dead-letters-and-worker-halts) for how to find them.

### Running the worker

The **worker** fires due timers. Each poll drains *all* due timers, not just one.

```bash
kioku worker                # continuous: startup backfill + embeddings + timer loop
kioku worker --backfill     # one embedding backfill pass, then exit
kioku worker --timers-once  # fire at most one due timer, then exit
```

`--backfill` and `--timers-once` are mutually exclusive — passing both is a parse error. See the
[CLI Reference](cli-reference.md#kioku-worker) for worker modes.

## Workspace mirroring

L2 scenes and L3 personas are mirrored to the filesystem as plain markdown, so a coding agent (or
you) can read them without querying the database:

```text
.kioku/scenes/<slug>.md      # e.g. mori-repo-web-3f2a1c9d7b.md
.kioku/persona/<slug>.md
```

- Scene files render as `# <title>` + body; persona files render the persona markdown directly.
- The **slug** is a human-readable prefix (`namespace-kind-ref`, with every character outside
  `A-Za-z0-9_-` replaced by `-`) followed by `-` and the first 10 hex characters of a SHA-256 of the
  scope's true identity. The readable prefix alone is *not* collision-free — the sanitizer maps
  `a-b` and `a`/`b` onto the same text — so the digest is what actually keeps two scopes in separate
  files. Don't construct these names by hand: derive them, or list the directory.
- **They land in the working directory of the process that regenerates them.** In practice that is
  wherever you started `kioku worker` — so run the worker from the workspace you want mirrored, or
  the files will appear next to the worker instead of next to your code.

Mirroring is **best-effort**: if the workspace isn't writable, distillation still succeeds and the
database remains the source of truth. The mirror is a convenience cache, not authoritative. When a
scope empties, the mirror files are deleted along with the rows.

## End-to-end flow

```text
 host records turns on a running session                              (L0)
        │  ramp (turns 1,2,4,8,16,…) · session completes · 30 min idle
        ▼
 L1 timer fires ──► extract atoms ──► consolidate ──► memory events   (L1)
        │  recording / forgetting a memory, or changing its confidence, schedules…
        ▼
 L2 timer fires ──► regenerate (or delete) scene ──► mirror .kioku/scenes/   (L2)
        │  every scene regeneration schedules…
        ▼
 L3 timer fires ──► regenerate (or delete) persona ──► mirror .kioku/persona/ (L3)
```
