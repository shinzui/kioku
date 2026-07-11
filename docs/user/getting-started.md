# Getting Started

This guide takes you from an empty checkout to writing and recalling your first memory.

## Prerequisites

- **PostgreSQL** reachable from your machine. kioku stores everything in a database under the
  `kiroku` schema (event streams + read-model projections). For semantic recall you also want
  the **`pgvector`** extension available; without it kioku degrades gracefully to full-text-only
  recall (see [Recall](recall.md)).
- The **Nix dev shell** (recommended). kioku is a kikan project; the flake provides GHC, Cabal,
  `psql`, `process-compose`, and the `PG*` environment variables used by the `Justfile`.
- An **OpenAI-compatible embedding endpoint** if you want semantic recall and the distillation
  pyramid. By default kioku calls `https://api.openai.com` with `text-embedding-3-small`
  (1536 dimensions). See [Configuration](configuration.md).

## 1. Enter the dev shell

```bash
cd /path/to/kioku
nix develop      # or `direnv allow` if you use direnv
```

The dev shell exports `PGHOST`, `PGDATABASE`, `PGDATA`, and `PGLOG`, which the `Justfile` and
`process-compose.yaml` rely on.

## 2. Start Postgres and create the schema

kioku ships a `process-compose.yaml` that launches a local Postgres and applies all migrations:

```bash
process-compose up
```

This starts Postgres (using the dev-shell `PG*` variables) and runs `just create-database`,
which creates the database if needed and applies the kiroku, keiro, and kioku migrations.

To do it by hand instead:

```bash
just create-database   # createdb (idempotent) + just migrate
# or, if the database already exists:
just migrate           # apply kiroku/keiro/kioku embedded migrations
```

The migrations create three things you care about:

- `kiroku.kioku_memories` — the memory read-model row table, including a `content_tsv`
  `tsvector` column (full-text) and a nullable `embedding` `vector` column (semantic).
- `kiroku.kioku_sessions` (and a turns table) — the session read model, including continuation
  chains, delegation lineage, and awaiting/resume fields.
- The distillation tables for scenes (L2) and personas (L3).

> **pgvector note.** The embedding column and vector index are created only when the `pgvector`
> extension is installable. kioku detects this at runtime (`VectorCapability`) and adapts. If
> pgvector is missing, recall runs full-text only and the embedding worker is skipped.

## 3. Point the CLI at your database

Every CLI command (except pure help) reads the connection string from an environment variable:

```bash
export PG_CONNECTION_STRING='host=localhost dbname=kioku user=me'
```

This is a standard libpq connection string. Use whatever host/db/user your `process-compose`
or local Postgres exposes.

## 4. Write and recall your first memory

The `demo` command records one memory in the scope `kioku_demo:demo:demo` and reads it back.

kioku is event-sourced and has no delete, so this writes **permanent** events to the database
at `PG_CONNECTION_STRING`. The command therefore requires an explicit `--yes-write-events`, and
prints what it is about to write, and where, before writing it:

```bash
kioku demo --yes-write-events
```

```text
kioku demo appends permanent memory events (kioku has no delete).
Target: host=localhost dbname=kioku user=me
Scope:  kioku_demo/demo/demo
Recorded memory kioku_memory_01... in scope kioku_demo/demo/demo
- kioku_memory_01... [preference/high] prefers concise answers
```

Now recall it by meaning:

```bash
kioku recall "what writing style is preferred" \
  --scope kioku_demo:demo:demo
```

```text
1. preference "prefers concise answers"
```

Add `--show-scores` to see the fused score and the component ranks:

```bash
kioku recall "writing style" --scope kioku_demo:demo:demo --show-scores
```

```text
1. score=0.0164 fts=1 vec=1 preference "prefers concise answers"
```

`fts` is the full-text rank, `vec` is the semantic (pgvector) rank, and `score` is the fused
RRF score with recency/priority/confidence signals applied. A `-` means that component did not
contribute (e.g. pgvector unavailable, or the query did not embed). See [Recall](recall.md).

## 5. (Optional) build a session and distill it

The session demo records a session aggregate. Like `kioku demo` it writes permanent events, and
completing the session also schedules a distillation timer that a running worker will process
(an LLM call), so it too requires the explicit opt-in:

```bash
kioku demo-session --yes-write-events
```

To turn a session's evidence into memory atoms (L1 distillation), run:

```bash
kioku distill session <SESSION_ID>
```

To run the background workers that compute embeddings and fire distillation timers
continuously:

```bash
kioku worker
```

See [The Distillation Pyramid](distillation.md) for the full flow, and the
[CLI Reference](cli-reference.md) for every flag.

## Where to next

- New to the model? Read **[Concepts](concepts.md)**.
- Embedding kioku in your own Haskell app? Read **[Library API](library-api.md)**.
- Tuning embeddings or endpoints? Read **[Configuration](configuration.md)**.
