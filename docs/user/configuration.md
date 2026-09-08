# Configuration

AI execution requires an explicit versioned JSON file or a host-supplied `AIRuntime`.
Without either, AI is disabled. Memory storage, keyword recall, and stored scene/persona readers
remain usable. Credentials alone never authorize execution.

`--ai-config FILE` on `distill session`, `recall`, and all worker modes overrides
`KIOKU_AI_CONFIG`. The shared parser rejects unknown fields, unknown features, invalid modes,
missing models, and feature overrides that exceed the selected permissions before any model call.

## Database

| Variable                | Required | Default | Description                                          |
|-------------------------|----------|---------|------------------------------------------------------|
| `PG_CONNECTION_STRING`  | for `kioku` database operations | — | libpq connection string used by the runtime CLI. |
| `DATABASE_URL`          | for `kioku-migrate` database operations | — | migration target; overridden by `--database-url URL`. |

```bash
export PG_CONNECTION_STRING='host=localhost dbname=kioku user=me'
```

In the Nix dev shell the `PG*` variables (`PGHOST`, `PGDATABASE`, `PGDATA`, `PGLOG`) **and
`PG_CONNECTION_STRING`** are exported for you, pointing at the local Postgres that
`process-compose`/`just` manage. That Postgres ships with `pgvector`, so a freshly created dev
database has a working vector path. You only need to set `PG_CONNECTION_STRING` yourself outside
the dev shell.

Migrations run through a **separate binary** (`kioku-migrate`, which is what `just migrate`
invokes). Database-backed subcommands default to `DATABASE_URL`; the `Justfile` derives that value
from the dev-shell `PG*` variables. An explicit `--database-url URL` wins. Outside the dev shell,
set `DATABASE_URL` explicitly:

```bash
export DATABASE_URL="$PG_CONNECTION_STRING"
cabal run kioku-migrate -- status
cabal run kioku-migrate -- verify
cabal run kioku-migrate -- up
```

`status` and `verify` do not reconcile or mutate read-model rows. A successful `up` applies pending
migrations and then reconciles the compiled read-model registry.

## Memory space and actor

Every read and write the CLI performs names a memory space — the isolation boundary — and every
write names the principal it is attributed to. Both come from the environment, and a malformed
value is a startup error rather than a silent fallback: a typo in a space name must not quietly
send writes somewhere else, or hide the rows a read was meant to return.

| Variable             | Required | Default        | Description                                                                 |
|----------------------|----------|----------------|-----------------------------------------------------------------------------|
| `KIOKU_MEMORY_SPACE` | no       | `kioku_legacy` | The memory space CLI commands read and write. The default is where every row written before memory spaces existed lives, so an unchanged CLI operates on exactly the data it did before. `kioku recall`, `kioku scenes`, and `kioku persona` return nothing outside it. |
| `KIOKU_ACTOR`        | no       | `kioku_cli`    | The principal CLI writes are attributed to. The CLI is genuinely the thing acting; naming it plainly beats borrowing an identity from a directory the CLI does not talk to. |

The worker is not pinned to one space: it claims timers for whatever space they were scheduled in
and acts as `KIOKU_ACTOR` in each. See
[Upgrading to memory spaces](upgrading-to-memory-spaces.md).

## AI execution

Start with [the API example](../examples/ai-api.json) or
[the interactive example](../examples/ai-interactive.json). Both are version 1 documents.
`permissions` lists allowed modes; `distillation` supplies defaults; `features` supplies complete
per-feature replacements for `extraction`, `consolidation`, `scene`, and `persona`.
Each replacement must be authorized by the same permissions.

`api` selects a Baikai HTTP transport, model, provider, endpoint, and options.
`batch` selects a Baikai batch transport such as `anthropic-messages-cli` or
`openai-completions-cli`; batch is a separate permission. `interactive` selects Claude or Codex,
an explicit model, working directory, and optional effort. It launches the genuine terminal
session, using a private request manifest and a checked JSON result envelope. A successful
process exit without a valid matching result is a failed generation.

The CLI grants interactive availability only to foreground `distill session`. Background workers
park interactive work with `kioku:deferred:interactive-unavailable` in the timer's dead-letter
reason. No HTTP or batch fallback occurs. Authorized atomic resume and deferred listing remain
blocked on an upstream Keiro API addition; no `worker deferred` command is shipped yet.
Do not replay these rows using generic dead-letter tools or modify timer tables manually.

```bash
export KIOKU_AI_CONFIG=/path/to/ai-interactive.json
kioku distill session SESSION_ID --candidates scan
kioku worker --timers-once
```

## Embeddings

`embeddings` has separate settings for `memory-embedding`, `query-embedding`, and
`candidate-embedding`. Each enabled entry requires `mode: api`, a model, endpoint,
`dimensions: 1536`, and optionally `apiKeyEnv`. Baikai resolves the named credential at execution.
The interactive example leaves this object empty, so embeddings remain disabled.
Legacy `KIOKU_EMBEDDING_*` variables no longer enable or select AI; migrate them into the file.

Hybrid recall reports disabled query embeddings and uses keyword search. Explicit
`--strategy embedding` and `worker --backfill` refuse unavailable AI. Candidate lookup uses
scope-local scan when its embedding capability is disabled. A continuous worker can run timers
without starting an embedding subscription.

The stored vector width is 1536. Configuration validates this before execution; changing a model
requires re-embedding the corpus and keeping memory/query/candidate settings compatible. A model
name change does not migrate stored vectors. Semantic recall and candidate lookup refuse a memory space containing vectors labelled with
another model. Embedding writes/backfill likewise refuse mixing labelled models. Explicit
low-level host/test embedding adapters remain the caller’s responsibility.

## Commands and credentials

Storage, keyword recall, `scenes`, and `persona` readers need no AI credential. Distillation needs
an explicitly authorized completion or interactive capability. Embedding workers and semantic
recall need an independently authorized embedding API capability. The API example names
`ANTHROPIC_API_KEY` and `OPENAI_API_KEY`; these are examples of credential sources, not defaults
that enable a provider. The demo commands retain their `--yes-write-events` requirement.

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
