# Configuration

kioku is configured entirely through **environment variables**. There is no config file.

kioku talks to **two different model providers**, and they are configured separately:

- an **OpenAI-compatible embeddings endpoint**, for recall's vector channel and the embedding
  worker (`KIOKU_EMBEDDING_*`);
- **Anthropic**, for the four distillation programs (`ANTHROPIC_API_KEY`).

Configuring one does not configure the other. This is the most common setup mistake.

## Database

| Variable                | Required | Default | Description                                          |
|-------------------------|----------|---------|------------------------------------------------------|
| `PG_CONNECTION_STRING`  | **yes**  | —       | libpq connection string used by every `kioku` command. |

```bash
export PG_CONNECTION_STRING='host=localhost dbname=kioku user=me'
```

In the Nix dev shell the `PG*` variables (`PGHOST`, `PGDATABASE`, `PGDATA`, `PGLOG`) **and
`PG_CONNECTION_STRING`** are exported for you, pointing at the local Postgres that
`process-compose`/`just` manage. That Postgres ships with `pgvector`, so a freshly created dev
database has a working vector path. You only need to set `PG_CONNECTION_STRING` yourself outside
the dev shell.

Migrations run through a **separate binary** (`kioku-migrate`, which is what `just migrate`
invokes). It does not read `PG_CONNECTION_STRING`; it takes `CODD_CONNECTION` (a libpq keyword
string) plus `CODD_SCHEMAS=kiroku`. The `Justfile` sets these from the dev-shell `PG*` variables,
so inside the dev shell you never see them. Outside it, set `CODD_CONNECTION` yourself.

## Embeddings

Embeddings power recall's semantic channel and the `--candidates recall` merge-candidate finder.
kioku talks to an **OpenAI-compatible** embeddings endpoint.

| Variable                     | Default                            | Description                                                  |
|------------------------------|------------------------------------|--------------------------------------------------------------|
| `KIOKU_EMBEDDING_BASE_URL`   | `https://api.openai.com`           | Base URL of the OpenAI-compatible embeddings API.            |
| `KIOKU_EMBEDDING_MODEL`      | `text-embedding-3-small`           | Embedding model id.                                          |
| `KIOKU_EMBEDDING_DIMENSIONS` | `1536`                             | Embedding vector dimension. **Must be 1536** — see below.    |
| `KIOKU_EMBEDDING_API_KEY`    | *(falls back to `OPENAI_API_KEY`)* | API key for the endpoint.                                    |
| `OPENAI_API_KEY`             | —                                  | Used as the API key if `KIOKU_EMBEDDING_API_KEY` is unset.    |

Notes:

- **API key resolution** tries `KIOKU_EMBEDDING_API_KEY` first, then `OPENAI_API_KEY`. Only an
  *unset* variable falls through: `export KIOKU_EMBEDDING_API_KEY=` (empty) is honored as an
  empty key and **suppresses** the `OPENAI_API_KEY` fallback. If neither is set the key is empty
  — fine for keyword-only recall, but the vector channel and the embedding worker cannot embed.
- **The embedding column is `vector(1536)`, and the dimension is not really yours to choose.**
  The shipped migrations hard-code the column width, and no migration parameterizes it. Leave
  `KIOKU_EMBEDDING_DIMENSIONS` at `1536` unless you are prepared to write your own migration that
  re-types the column, rebuilds the HNSW index, and re-embeds every row. The embedding model's
  output dimension, the column, and this variable must all agree.
- **A mismatch is caught at startup, not at query time.** Nothing "errors" mid-flight; the vector
  path just disappears. `kioku worker --backfill` refuses and exits non-zero, `kioku worker` runs
  the distillation timers but no embedding worker, and `kioku recall` silently degrades to
  keyword-only. See [Troubleshooting](troubleshooting.md).
- A non-numeric `KIOKU_EMBEDDING_DIMENSIONS` is silently ignored and falls back to `1536`.
- **Self-hosted / alternative endpoints.** Any endpoint exposing the OpenAI embeddings API shape
  works — but it must emit **1536-dimension** vectors, or you must migrate the column first.

```bash
export KIOKU_EMBEDDING_BASE_URL='https://my-gateway.internal'
export KIOKU_EMBEDDING_MODEL='text-embedding-3-small'   # must emit 1536 dimensions
export KIOKU_EMBEDDING_API_KEY='sk-…'
```

## Distillation LLM

The four distillation programs (extract, consolidate, scene, persona) call an **Anthropic**
model. This is a **different credential from the embeddings key**, and without it every
distillation pass fails.

| Variable            | Required                | Default | Description                             |
|---------------------|-------------------------|---------|-----------------------------------------|
| `ANTHROPIC_API_KEY` | for `distill` / `worker` | —       | API key for the Anthropic Messages API. |

The model is **hard-coded** to `claude-haiku-4-5`; there is no environment variable to change the
model or the endpoint.

If `ANTHROPIC_API_KEY` is unset, every extract/consolidate/scene/persona call fails with an auth
error. The timer worker retries with backoff and eventually dead-letters the timer, so the
symptom is "scenes and personas never appear" rather than a crash — see
[Troubleshooting](troubleshooting.md#dead-letters-and-worker-halts).

Recall and the `scenes`/`persona` *print* commands do not need it.

## Which commands need what

| Command                                    | DB | Embeddings                       | LLM (`ANTHROPIC_API_KEY`) |
|--------------------------------------------|----|----------------------------------|---------------------------|
| `kioku demo --yes-write-events`            | ✔  | ✗                                | ✗                         |
| `kioku demo-session --yes-write-events`    | ✔  | ✗                                | ✗ directly — but it schedules a timer a running worker will fire |
| `kioku recall --strategy keyword`          | ✔  | ✗                                | ✗                         |
| `kioku recall` (hybrid/embedding)          | ✔  | ✔ (falls back to keyword on failure) | ✗                     |
| `kioku distill session --candidates scan`  | ✔  | ✗                                | ✔                         |
| `kioku distill session --candidates recall`| ✔  | ✔                                | ✔                         |
| `kioku scenes`, `kioku persona`            | ✔  | ✗ (just reads stored rows)       | ✗                         |
| `kioku worker`                             | ✔  | ✔ (embedding worker)             | ✔ (timer loop)            |
| `kioku worker --backfill`                  | ✔  | ✔                                | ✗                         |
| `kioku worker --timers-once`               | ✔  | ✔ (recall-based merge candidates) | ✔                        |

The demo commands require `--yes-write-events` because the event log is append-only — there is no
way to delete what they write. `--backfill` and `--timers-once` are mutually exclusive.

## Internal tuning constants (not configurable)

These live in the source and are documented here so behavior is predictable. They are **not**
environment variables.

**Recall.** RRF `k = 60`; recency half-life `30 days`; signal weights (recency `0.10`, priority
`0.15`, confidence `0.05`); candidate pool `50` per channel; character budgets `2000` per memory
and `12000` total.

**Recall's vector channel.** `hnsw.ef_search` is set to the candidate pool size (50) for every
vector query — pgvector's default of 40 sits *below* the pool and under-filled it by 20%. If the
approximate (HNSW) pass returns fewer rows than the pool, an **exact** pass re-runs the query with
the scope filter applied ahead of the ranking, so a selective scope cannot starve the semantic
channel. See [Recall](recall.md#the-vector-channels-two-passes).

**Distillation — L1 triggers.** L1 does not wait for a session to go quiet. It runs on a **ramp**
(turns 1, 2, 4, 8, 16, and every 16th thereafter — fired immediately, so a long live session is
distilled as it goes), on session **completion or failure**, and after **30 minutes** of session
idleness (one debounced timer per session, pushed forward by each new turn).

**Distillation — merge candidates.** The `kioku distill session --limit` default is `5` (range
1–50). The **timer worker ignores it** and hard-codes a limit of `8` with recall-based candidates
— and the timer worker is the path that actually runs in production.

**Worker resilience.** Timer poll every `5 seconds`, draining all due timers each pass. Timer-loop
store errors retry with `5s` doubling to a `60s` cap. Failed distillation timers retry with `30s`
doubling to a `900s` cap and are dead-lettered after `8` claims. Failed embedding events retry at
`5s, 20s, 60s, 180s` and are dead-lettered after 5 deliveries.

See [Recall](recall.md) and [Distillation](distillation.md) for how these affect results, and
[Troubleshooting](troubleshooting.md#dead-letters-and-worker-halts) for what a dead letter means.
