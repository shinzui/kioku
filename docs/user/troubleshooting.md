# Troubleshooting & FAQ

## Common errors

### `PG_CONNECTION_STRING is not set`

Every CLI command needs the database connection string. Export it:

```bash
export PG_CONNECTION_STRING='host=localhost dbname=kioku user=me'
```

In the Nix dev shell this is exported for you.

### `kioku … store error: …`

The command reached Postgres but a query failed. Usual causes:

- The schema isn't migrated. Run `just migrate` (or `just create-database` for a fresh DB).
- The database in your connection string isn't the one you migrated.
- A `pgvector` operation ran against a database where the extension/column is missing — see the
  pgvector section below.

### Missing columns, or a missing table

If a command mentions `parent_session_id`, `delegation_depth`, `awaiting_reason`,
`awaiting_correlation_key`, `awaiting_deadline`, `resume_input` (session lineage and
park-and-resume), or a missing `kiroku.kioku_l1_watermarks` table (L1 idempotency), the database is
on an older kioku migration set. Run:

```bash
just migrate
```

Check the ledger afterwards:

```bash
DATABASE_URL="$PG_CONNECTION_STRING" cabal run kioku-migrate -- status
DATABASE_URL="$PG_CONNECTION_STRING" cabal run kioku-migrate -- verify
```

`MigrationChecksumMismatch` means an applied SQL file differs from the compiled history. Restore
the reviewed migration bytes; do not edit the pg-migrate ledger to hide the mismatch.

Missing `embedding`, `embedding_model`, `dimensions`, or `content_hash` columns can instead mean
that the embedding DDL was deliberately skipped when pgvector was unavailable. Follow
["columns are missing"](#columns-are-missing) below; whether another `up` is sufficient depends on
whether the heal migration is still pending.

### `read model … stale schema` / `ReadModelStaleSchema`

A read model's registered version or shape hash no longer matches the one compiled into the
binary, so every query against it **fails closed** rather than returning rows built to an old
shape.

Run `just migrate`. The migration binary reconciles the read-model registry against what the code
declares, so the repair ships with the schema change. Do not hand-edit the registry.

### `recall` returns `(no matches)`

- **The scope is wrong.** An **entity** scope matches exactly: `rei:intention:abc` does not match
  `rei:intention:xyz`. A **global** scope (`--scope rei`) is *namespace-wide* for recall — it
  returns entity-scoped rows too, so it is the broader search, not the narrower one. (Library
  reads like `getActiveByScope` are exact-scope even for a global scope. See
  [Recall](recall.md#global-scope-namespace-wide-recall-vs-exact-scope-reads).)
- The memory isn't `active` (it was superseded/merged/archived). Only active memories are
  recalled.
- Keyword strategy with no lexical overlap. Try `--strategy hybrid` (the default) so semantic
  matching can help — assuming embeddings are configured.

### `Session already distilled (no new turns); use --force to re-run.`

Not an error. L1 is watermarked per session: a pass whose turns are all covered by the last
successful pass is skipped **before any LLM call**. Re-run with `--force` if you want it anyway.

## pgvector

### How do I know if pgvector is active?

Run the worker; it reports the detected capability. Three unhealthy answers:

```text
pgvector is not available; recall will run FTS-only; running kioku timer worker only.
pgvector columns are missing (embedding, embedding_model, dimensions, content_hash); running kioku timer worker only.
kioku worker: embedding dimension mismatch: KIOKU_EMBEDDING_DIMENSIONS=512 but kiroku.kioku_memories.embedding is vector(1536); fix the env var or migrate the column; running kioku timer worker only.
```

A healthy start prints, in order:

```text
Startup backfill: embedded N missing memory embeddings.
kioku timer worker started.
kioku embedding worker started. Press Ctrl+C to stop.
```

### pgvector is installed but reports as not available

This is the most common false alarm. kioku connects with `search_path = kiroku, pg_catalog`, so an
extension installed into `public` — the usual operator default — **cannot be named** and reports as
unavailable even though `CREATE EXTENSION vector` succeeded. Move it, then follow the healing
procedure below:

```bash
psql "$PG_CONNECTION_STRING" -c 'ALTER EXTENSION vector SET SCHEMA kiroku;'
```

### "columns are missing"

The database was migrated while the server had no pgvector, so the embedding DDL was skipped. The
heal migration `kioku/0009-kioku-embedding-schema-heal` re-attempts it. First install pgvector in
the `kiroku` schema (or move an existing extension there), then inspect the ledger:

```bash
DATABASE_URL="$PG_CONNECTION_STRING" cabal run kioku-migrate -- status
```

If 0009 is **pending**, the normal migration run applies it:

```bash
DATABASE_URL="$PG_CONNECTION_STRING" cabal run kioku-migrate -- up
```

If 0009 is already **applied**, pg-migrate correctly will not replay it. Apply the same idempotent
checked-in SQL manually instead:

```bash
psql "$PG_CONNECTION_STRING" --set=ON_ERROR_STOP=1 \
  --file=kioku-migrations/migrations/0009-kioku-embedding-schema-heal.sql
```

Then populate vectors:

```bash
kioku worker --backfill
```

The Nix dev shell now ships pgvector, so a fresh dev database is fine.

Capability detection checks the vector type and required columns, but **not** the HNSW index. If
vector recall works but is unexpectedly slow, check it separately:

```bash
psql "$PG_CONNECTION_STRING" -tAc \
  "SELECT to_regclass('kiroku.kioku_memories_embedding_hnsw')"
```

An empty result means the index is absent. Reapplying the idempotent 0009 SQL above recreates it;
the absence of the index does not trigger keyword-only degradation.

### Embedding dimension mismatch

```text
embedding dimension mismatch: KIOKU_EMBEDDING_DIMENSIONS=512 but kiroku.kioku_memories.embedding is vector(1536)
```

The embedding column is `vector(1536)` — the shipped migrations hard-code it. kioku checks your
configured dimension against the column's declared width **at startup**, rather than discovering
it one failed event at a time:

- `kioku worker --backfill` **refuses and exits non-zero** before embedding anything.
- `kioku worker` prints the message to stderr and runs the **distillation timers only**.
- `kioku recall` degrades to **keyword-only, silently**.

Fix the environment variable (unset it, or set `1536`). If you genuinely need another dimension you
must write a migration that re-types the column and rebuilds the HNSW index, then re-embed
everything with `kioku worker --backfill`.

### Recall ignores the semantic channel

If `--show-scores` shows `vec=-` on **every** hit, the vector channel did not run at all. In order
of likelihood:

1. `--strategy keyword`.
2. pgvector is unavailable, its columns are missing, or `KIOKU_EMBEDDING_DIMENSIONS` disagrees with
   the column — all three make recall **silently** keyword-only, with no error on the recall
   itself. Run `kioku worker` once and read its capability line (above).
3. The embedding endpoint failed or has no key: recall falls back to keyword for that request,
   silently.
4. The memories have no embeddings yet: `kioku worker --backfill`.

A `vec=-` on *some* hits is normal — that hit was found by the keyword channel and was not in the
vector channel's 50-candidate pool.

**Semantic results that are plausible but incomplete.** The HNSW index is post-filtered, so on a
selective scope inside a large namespace the approximate scan can spend its whole budget on
out-of-scope rows and return nothing. kioku detects this and re-runs an exact pass that cannot
starve, so results stay correct — but the exact pass scans the scope, so a starving *and* very
large scope is slow rather than wrong. Library hosts can observe this directly:
`selectVectorCandidatesDiagnosed` returns a `VectorChannelOutcome`, and `vectorChannelStarved`
tells you whether the fallback had to rescue the query — worth counting as a health metric. The
CLI does not surface it. See [Recall](recall.md#the-vector-channels-two-passes).

## Dead letters and worker halts

kioku's two background pipelines both give up eventually — **visibly**, rather than retrying
forever. If scenes, personas, or embeddings silently stop appearing, look here.

### Embedding events

A failing embedding provider is retried (`5s, 20s, 60s, 180s`) and then dead-lettered after five
deliveries; an undecodable event is dead-lettered on sight.

```sql
SELECT dead_letter_id, event_id, created_at, reason
  FROM kiroku.dead_letters
 WHERE subscription_name = 'kioku-memory-embedding'
 ORDER BY dead_letter_id DESC;
```

There is no drain command, and you do not need one: `kioku worker --backfill` re-embeds every
active memory whose stored content hash doesn't match its content, which recovers exactly the
memories a dead-lettered event would have embedded. A backfill also runs automatically at every
`kioku worker` start.

### Distillation timers

A failing distillation retries with backoff (`30s` doubling to `900s`) and is dead-lettered after
**8 claims** — roughly an hour — so a structurally impossible pass stops burning LLM tokens. The
most common cause is a missing or invalid `ANTHROPIC_API_KEY`.

A dead **L1** timer means that session is never distilled. A dead **L2/L3** timer means that
scope's scene or persona never regenerates.

```sql
SELECT timer_id, process_manager_name, correlation_id, attempts, last_error
  FROM keiro.keiro_timers
 WHERE status = 'dead' AND process_manager_name LIKE 'kioku-%';
```

Failures are logged to stderr as `kioku-distill-timer[<process-manager> attempt N]: …`. For a dead
L1 timer, the simplest recovery is `kioku distill session <id> --force`.

### The worker exits non-zero

If either pipeline stops — a fatal store error, a halted embedding processor, a crash — the worker
prints `kioku worker: <reason>; exiting` and exits `1`, rather than lingering as a process that
looks alive with half its work dead. **Run it under a supervisor that restarts it.** Transient
store errors in the timer loop are *not* fatal; they retry with capped backoff.

## FAQ

**Is kioku a standalone app?**
No. It's a library plus a CLI, embedded by host applications (rei, mori, shikigami, or your own).
The CLI is for operations, demos, and inspection.

**Where is the source of truth — the row table or the event log?**
The **event log**. The `kiroku.kioku_memories` row (with its `tsvector` and `embedding`) is a
projection of the memory's event stream. Recall reads the projection; writes append events.

**Can I run without an embedding endpoint?**
Yes, for keyword recall and the scene/persona *printing* commands. Hybrid/embedding recall falls
back to keyword, but you lose semantic matching. Note that distillation does **not** use the
embedding endpoint for its LLM work — it calls Anthropic and needs `ANTHROPIC_API_KEY`, a separate
credential. See [Configuration](configuration.md).

**Do I have to record conversation turns?**
No. Turns are opt-in L0 evidence. Without them, distillation can still work from recorded
memories. With them, the pyramid has richer raw material.

**Do different hosts interfere with each other?**
No. Memory is partitioned by `namespace`, and recall/distillation always run within a scope. One
shared database and one `kioku worker` can serve every namespace. See
[Scopes & Integrations](integrations.md).

**Why does a high `--limit` sometimes return fewer hits?**
A character budget (2000 per memory, 12000 total) is applied after ranking, so output is capped to
fit an agent's context window. See [Recall](recall.md#character-budgets). Note that `--limit` is
also clamped at the parser — 1–100 for `recall`, 1–50 for `distill session` — so `--limit 500` is a
parse error, not a big result set.

**Where do the mirrored scene/persona files live?**
In the working directory of the process that regenerates them — in practice, wherever you started
`kioku worker` — under `.kioku/scenes/<slug>.md` and `.kioku/persona/<slug>.md`. The slug is a
readable rendering of the scope plus a short hash of its exact identity, so
`rei:intention:abc` becomes `rei-intention-abc-1f4a9c7e2b.md`. The hash is what keeps two different
scopes from colliding on one filename; don't construct these names by hand, derive them or list the
directory. Mirroring is best-effort and the database remains authoritative. When a scope's last
memory is forgotten, the scene/persona row **and** its mirror file are deleted. See
[Distillation](distillation.md#workspace-mirroring).
