# CLI Reference

The `kioku` command bundles the memory tools. Every command that touches the database reads the
connection string from the `PG_CONNECTION_STRING` environment variable and exits with an error
if it is unset.

```text
kioku

Usage: kioku COMMAND

  kioku reusable agent memory tools

Available commands:
  demo           Run the memory/session demonstration (writes permanent events)
  demo-session   Run the session aggregate demonstration (writes permanent events)
  distill        Run distillation commands
  persona        Print distilled L3 persona
  recall         Recall memories by query
  scenes         Print distilled L2 scenes
  worker         Run kioku background workers
```

Run `kioku <command> --help` for the flags of any subcommand.

## Global requirements

| Variable                | Required by            | Purpose                                    |
|-------------------------|------------------------|--------------------------------------------|
| `PG_CONNECTION_STRING`  | every command          | libpq connection string to the database.   |
| `KIOKU_EMBEDDING_*`     | `recall`, `distill --candidates recall`, `worker` | embedding endpoint config (see [Configuration](configuration.md)). |
| `ANTHROPIC_API_KEY`     | `distill`, `worker`    | the distillation LLM. **Separate from the embeddings key** — configuring `KIOKU_EMBEDDING_*` does not configure this. |

The scope string format used by several commands is:

```text
NAMESPACE                 # global scope
NAMESPACE:KIND:REF         # entity scope
```

Only the **first two** colons split the string. Everything after the second colon is the ref,
colons included, so refs that are URLs or `host:port` pairs need no escaping:

```text
ops:host:db.internal:5432             # ref = db.internal:5432
rei:url:https://example.com:8080/x    # ref = https://example.com:8080/x
```

`NAMESPACE` and `KIND` are short vocabulary labels and may not contain `:`, `/`, or `%`; all
three parts must be non-empty.

---

## `kioku demo`

Records one example memory (`kioku_demo:demo:demo`, a `preference` with `high` confidence) and
reads back the active memories in that scope. Useful as a smoke test that your database and
connection string work.

> **This writes permanent events.** kioku is event-sourced and has no delete: the events this
> command appends to the database at `PG_CONNECTION_STRING` cannot be removed. It therefore
> requires `--yes-write-events`; without it the command is a parse error and nothing is written
> (the environment is not even read).

```bash
kioku demo --yes-write-events
```

| Flag                | Description                                                          |
|---------------------|----------------------------------------------------------------------|
| `--yes-write-events`| **Required.** Confirms you accept permanent writes to the target database. |

Before writing, the command prints what it is about to do — the permanence warning, the target
connection string with any password redacted, and the scope:

```text
kioku demo appends permanent memory events (kioku has no delete).
Target: host=localhost dbname=kioku user=me
Scope:  kioku_demo/demo/demo
Recorded memory kioku_memory_01... in scope kioku_demo/demo/demo
- kioku_memory_01... [preference/high] prefers concise answers
```

The demo writes into the `kioku_demo` namespace, which nothing else reads, so demo residue is
unmistakable and distillation of demo data stays confined to it.

---

## `kioku demo-session`

Demonstrates the **session** aggregate end to end (start → record → complete). Useful to verify
the session read model and projections are wired up.

> **This writes permanent events**, and completing the demo session also schedules a real
> distillation timer — a running `kioku worker` will process it, which costs an LLM call. Like
> `kioku demo`, it requires `--yes-write-events` and prints a preflight notice first.

```bash
kioku demo-session --yes-write-events
```

| Flag                | Description                                                          |
|---------------------|----------------------------------------------------------------------|
| `--yes-write-events`| **Required.** Confirms you accept permanent writes to the target database. |

---

## `kioku recall`

Recall memories relevant to a query, within a scope, using the chosen strategy.

```bash
kioku recall QUERY --scope NAMESPACE[:KIND:REF] [options]
```

| Argument / flag    | Default  | Description                                                    |
|--------------------|----------|---------------------------------------------------------------|
| `QUERY` (positional) | —      | The natural-language query to match against.                  |
| `--scope`          | —        | Scope to search. Required. `NAMESPACE` or `NAMESPACE:KIND:REF`. |
| `--strategy`       | `hybrid` | `keyword`, `embedding`, or `hybrid`.                          |
| `--limit N`        | `8`      | Maximum hits to return. Must be between **1 and 100**; anything else is a parse error stating the range. |
| `--show-scores`    | off      | Print the fused score and the FTS/vector component ranks.     |

Examples:

```bash
# Default hybrid recall within an entity scope
kioku recall "preferred writing style" --scope kioku_demo:demo:demo

# Keyword-only, limited to 3 hits
kioku recall "deploy script" --scope mori:repo:web --strategy keyword --limit 3

# Show scoring detail
kioku recall "testing practices" --scope mori --show-scores
```

Output (`--show-scores`):

```text
1. score=0.0164 fts=1 vec=1 preference "prefers concise answers"
```

- `score` — fused RRF score plus recency/priority/confidence signals.
- `fts` — full-text rank (`-` if FTS did not contribute).
- `vec` — pgvector rank (`-` if vector recall did not run or the query failed to embed).

When nothing matches, `kioku recall` prints `(no matches)`.

> **A bare `NAMESPACE` scope is the *broadest* search, not the narrowest.** For recall, a global
> scope drops the scope filter entirely: `--scope mori` matches every active memory in the `mori`
> namespace, entity-scoped rows included. An entity scope matches exactly. (Library reads are
> exact-scope even for a global scope — the asymmetry is deliberate. See
> [Recall](recall.md#global-scope-namespace-wide-recall-vs-exact-scope-reads).)

If pgvector is unavailable, `embedding` and `hybrid` fall back to keyword search automatically.
See **[Recall](recall.md)** for the full scoring model.

---

## `kioku distill`

Run a distillation pass. Currently one subcommand exists: `session`.

### `kioku distill session`

Run one **L1** distillation pass for a session: extract candidate atoms from the session's
evidence, decide store/update/merge/skip against existing memory, and append the resulting
events.

```bash
kioku distill session SESSION_ID [options]
```

| Argument / flag      | Default | Description                                                       |
|----------------------|---------|-------------------------------------------------------------------|
| `SESSION_ID` (positional) | — | The session to distill. Must carry the `kioku_session` prefix; any other prefix (a `kioku_memory` id, a bare UUID) is rejected with an error naming both the expected and the received prefix. |
| `--candidates`       | `scan`  | How merge candidates are found: `scan` (scope SQL scan) or `recall` (hybrid recall). |
| `--limit N`          | `5`     | Maximum merge candidates considered per extracted atom. Must be between **1 and 50**; anything else is a parse error stating the range. |
| `--force`            | off     | Re-run even when the session has no turns newer than the last successful pass. |

- `--candidates scan` does a recency/scope SQL scan and needs **no** embedding endpoint.
- `--candidates recall` uses hybrid recall to find merge candidates and therefore needs the
  `KIOKU_EMBEDDING_*` configuration.
- Either way the pass calls the distillation LLM, so `ANTHROPIC_API_KEY` must be set.

These flags govern **the CLI only**. The `kioku worker` timer path — the one that actually runs in
production — always uses recall-based candidates with a fixed limit of 8.

Example:

```bash
kioku distill session kioku_session_01h455vb4pex5vsknk084sn02q --candidates recall --limit 8
```

Output:

```text
Distilled session kioku_session_01h455vb4pex5vsknk084sn02q: extracted=4 stored=2 merged=1 skipped=1
```

- `extracted` — atoms the LLM proposed.
- `stored` — new memories created.
- `merged` — atoms folded into existing memories (both the `update` and `merge` actions land here;
  there is no `updated=` count).
- `skipped` — atoms judged redundant or low value.

L1 is **watermarked per session**: a pass whose turns are all covered by the last successful pass is
skipped before any LLM call, and prints

```text
Session already distilled (no new turns); use --force to re-run.
```

---

## `kioku scenes`

Print the distilled **L2** scene blocks for a scope (markdown).

```bash
kioku scenes --scope NAMESPACE[:KIND:REF]
```

| Flag      | Description                                  |
|-----------|----------------------------------------------|
| `--scope` | Scope whose scenes to print. Required.       |

Prints each scene as `# <title>` followed by its markdown body, or `(no scenes)` if none have
been distilled yet.

```bash
kioku scenes --scope mori:repo:web
```

---

## `kioku persona`

Print the distilled **L3** persona for a scope (markdown).

```bash
kioku persona --scope NAMESPACE[:KIND:REF]
```

| Flag      | Description                                  |
|-----------|----------------------------------------------|
| `--scope` | Scope whose persona to print. Required.      |

Prints the persona markdown, or `(no persona yet)` if none has been distilled.

```bash
kioku persona --scope rei:intention:intention_01h4...
```

---

## `kioku worker`

Run kioku's background workers. With no flags it runs **continuously**; the flags select
one-shot modes.

```bash
kioku worker [--backfill | --timers-once]
```

| Flag           | Description                                                                              |
|----------------|------------------------------------------------------------------------------------------|
| *(none)*       | Run continuously. When pgvector is available it first runs an idempotent **startup backfill**, then runs the embedding worker and the distillation timer loop under supervision. |
| `--backfill`   | Compute embeddings for any memories missing them, then exit, printing `Backfilled N memory embeddings.` Refuses (exit 1) if the configured embedding dimension does not match the column. |
| `--timers-once`| Claim and fire at most one due distillation timer, then exit.                            |

The two one-shot modes are **mutually exclusive** — they do unrelated work, so there is no
combined meaning. Passing both is a parse error naming whichever flag came *second*
(``Invalid option `--timers-once'`` for `--backfill --timers-once`, and ``Invalid option
`--backfill'`` for the reverse). It used to be silent: `--timers-once` won and `--backfill` was
ignored without a word.

Behavior of the continuous worker depends on the detected vector capability:

- **pgvector available** — runs the embedding worker host (embeds new memories) and the timer
  loop concurrently.
- **pgvector extension missing** — prints a notice; recall will be FTS-only; runs the timer
  worker only.
- **pgvector columns missing** — prints which columns are missing; runs the timer worker only.
- **embedding dimension mismatch** — `KIOKU_EMBEDDING_DIMENSIONS` disagrees with the declared width
  of the `embedding` column. Logs to **stderr** and runs the timer worker only; `--backfill`
  refuses outright and exits 1 rather than failing every row. See
  [Troubleshooting](troubleshooting.md#embedding-dimension-mismatch).

The continuous worker is built to be **supervised**: if either pipeline stops, it prints the reason
to stderr and exits `1` so a supervisor restarts it, rather than lingering as a process that looks
alive with half its work dead. Transient store errors in the timer loop are *not* fatal — they are
logged and retried with capped backoff (5s doubling to 60s). Each poll **drains** all due timers,
not just one.

Examples:

```bash
# Long-running worker (typical service deployment)
kioku worker

# One-off embedding backfill after importing memories
kioku worker --backfill

# Fire a single due timer (useful in cron or tests)
kioku worker --timers-once
```

See **[The Distillation Pyramid](distillation.md)** for what the timers do and
**[Recall](recall.md)** for how embeddings affect retrieval.
