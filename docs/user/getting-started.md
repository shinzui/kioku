# Getting Started

This guide takes you from an empty checkout to writing and recalling your first memory.

## Prerequisites

- **PostgreSQL** reachable from your machine. kioku's tables live in the `kiroku` schema (event
  streams + read-model projections), alongside keiro's framework tables. For semantic recall you
  also want the **`pgvector`** extension; without it kioku degrades gracefully to full-text-only
  recall (see [Recall](recall.md)).
- The **Nix dev shell** (recommended). kioku is a kikan project; the flake provides GHC, Cabal,
  `psql`, `process-compose`, a Postgres that **ships with pgvector**, and the `PG*` /
  `PG_CONNECTION_STRING` environment variables used by the `Justfile`.
- An **OpenAI-compatible embedding endpoint** if you want semantic recall. By default kioku calls
  `https://api.openai.com` with `text-embedding-3-small` (1536 dimensions — the embedding column is
  fixed at that width). See [Configuration](configuration.md).
- An **`ANTHROPIC_API_KEY`** if you want the distillation pyramid. Distillation calls Claude, which
  is a **separate credential** from the embedding endpoint — setting up embeddings does not set up
  distillation. This trips people up constantly.

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
DATABASE_URL="$PG_CONNECTION_STRING" cabal run kioku-migrate -- status
DATABASE_URL="$PG_CONNECTION_STRING" cabal run kioku-migrate -- verify
```

The migration ledger records the stable `component/name` identity and SHA-256 checksum of all
35 migrations (kiroku 8, keiro 17, kioku 10). `verify` is read-only and fails if applied SQL no
longer matches the bytes compiled into the executable.

The migrations create three things you care about:

- `kiroku.kioku_memories` — the memory read-model row table, including a `content_tsv`
  `tsvector` column (full-text) and a nullable `embedding` `vector` column (semantic).
- `kiroku.kioku_sessions` (and a turns table) — the session read model, including continuation
  chains, delegation lineage, and awaiting/resume fields.
- The distillation tables for scenes (L2) and personas (L3).

> **pgvector note.** The embedding column and vector index are created only when the `pgvector`
> extension is installable. kioku detects this at runtime (`VectorCapability`) and adapts: if
> pgvector is missing, recall runs full-text only and the embedding worker is skipped. A database
> migrated *before* pgvector was installed can be healed by migration
> `kioku/0009-kioku-embedding-schema-heal`, provided that migration is still pending when pgvector
> becomes available. If 0009 was already recorded while pgvector was absent, pg-migrate will not
> re-run it; apply the checked-in idempotent SQL manually. Also, kioku looks for the extension on
> its own `search_path`, so a `vector` extension installed into `public` reports as *unavailable*.
> See
> [Troubleshooting](troubleshooting.md#pgvector-is-installed-but-reports-as-not-available).

## 3. Point the CLI at your database

Every CLI command (except pure help) reads the connection string from an environment variable:

```bash
export PG_CONNECTION_STRING='host=localhost dbname=kioku user=me'
```

This is a standard libpq connection string. Use whatever host/db/user your `process-compose`
or local Postgres exposes.

## 4. Write and recall your first memory

The `demo` command records one memory in the scope `kioku_demo:demo:demo` and reads it back.

kioku is event-sourced and its event log is append-only — there is no way to delete an event — so
this writes **permanent** events to the database at `PG_CONNECTION_STRING`. The command therefore
requires an explicit `--yes-write-events`, and prints what it is about to write, and where, before
writing it:

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

Recall it immediately with full-text search (the demo command does not create an embedding):

```bash
kioku recall "concise answers" --scope kioku_demo:demo:demo --strategy keyword
```

```text
1. preference "prefers concise answers"
```

Add `--show-scores` to see the score and component ranks:

```bash
kioku recall "concise answers" --scope kioku_demo:demo:demo \
  --strategy keyword --show-scores
```

```text
1. score=0.1664 fts=1 vec=- preference "prefers concise answers"
```

`fts` is the full-text rank, `vec` is the semantic (pgvector) rank, and `score` is the fused
RRF score with recency/priority/confidence signals applied. The exact score changes as the memory
ages. A `-` means that component did not contribute; here vector search was deliberately disabled.

For semantic recall, configure the embedding endpoint, backfill the new row, then use the default
hybrid strategy:

```bash
kioku worker --backfill
kioku recall "what writing style is preferred" --scope kioku_demo:demo:demo
```

See [Recall](recall.md) for the ranking and fallback behavior.

## 5. (Optional) build a session and distill it

The session demo records a session aggregate. Like `kioku demo` it writes permanent events, and
completing the session also schedules a distillation timer that a running worker will process
(an LLM call), so it too requires the explicit opt-in:

```bash
kioku demo-session --yes-write-events
```

To turn a session's evidence into memory atoms (L1 distillation), run:

```bash
export ANTHROPIC_API_KEY='sk-ant-…'          # distillation calls Claude
kioku distill session <SESSION_ID>
```

The session id must carry the `kioku_session` prefix; any other prefix is rejected. Re-running a
session with no new turns prints `Session already distilled (no new turns); use --force to re-run.`
— L1 is watermarked, so it does not pay for an LLM call it doesn't need.

To run the background workers that compute embeddings and fire distillation timers
continuously:

```bash
kioku worker
```

The worker is built to be **supervised**: it exits non-zero if either pipeline stops, rather than
lingering half-dead. Run it from the workspace you want scene/persona files mirrored into — they
land in the worker's working directory.

See [The Distillation Pyramid](distillation.md) for the full flow, and the
[CLI Reference](cli-reference.md) for every flag.

## Where to next

- New to the model? Read **[Concepts](concepts.md)**.
- Embedding kioku in your own Haskell app? Read **[Library API](library-api.md)**.
- Tuning embeddings or endpoints? Read **[Configuration](configuration.md)**.
