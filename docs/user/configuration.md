# Configuration

kioku is configured entirely through **environment variables**. There is no config file.

## Database

| Variable                | Required | Default | Description                                         |
|-------------------------|----------|---------|-----------------------------------------------------|
| `PG_CONNECTION_STRING`  | **yes**  | —       | libpq connection string used by every CLI command.  |

Example:

```bash
export PG_CONNECTION_STRING='host=localhost dbname=kioku user=me'
```

In the Nix dev shell, the `PG*` variables (`PGHOST`, `PGDATABASE`, `PGDATA`, `PGLOG`) are set for
you and used by the `Justfile`/`process-compose.yaml` for migrations and local Postgres. The CLI
itself only reads `PG_CONNECTION_STRING`, so set that to point at the same database.

## Embeddings

Embeddings power semantic recall and the distillation pyramid. kioku talks to an
**OpenAI-compatible** embeddings endpoint.

| Variable                     | Default                       | Description                                                |
|------------------------------|-------------------------------|------------------------------------------------------------|
| `KIOKU_EMBEDDING_BASE_URL`   | `https://api.openai.com`      | Base URL of the OpenAI-compatible embeddings API.          |
| `KIOKU_EMBEDDING_MODEL`      | `text-embedding-3-small`      | Embedding model id.                                        |
| `KIOKU_EMBEDDING_DIMENSIONS` | `1536`                        | Embedding vector dimension. Must match the DB vector column. |
| `KIOKU_EMBEDDING_API_KEY`    | *(falls back to `OPENAI_API_KEY`)* | API key for the endpoint.                            |
| `OPENAI_API_KEY`             | —                             | Used as the API key if `KIOKU_EMBEDDING_API_KEY` is unset. |

Notes:

- **API key resolution** tries `KIOKU_EMBEDDING_API_KEY` first, then `OPENAI_API_KEY`. If neither
  is set the key is empty — fine for keyword-only recall, but embedding/hybrid recall and the
  distillation programs will fail to embed and fall back to keyword-only where applicable.
- **Dimensions must match the schema.** The `pgvector` column is created for a fixed dimension. If
  you change `KIOKU_EMBEDDING_DIMENSIONS`, the embedding column must use the same dimension or
  vector operations will error. Pick the dimension before backfilling.
- **Self-hosted / alternative endpoints.** Any endpoint exposing the OpenAI embeddings API shape
  works — set `KIOKU_EMBEDDING_BASE_URL` and the matching model/dimensions.

Example (self-hosted gateway):

```bash
export KIOKU_EMBEDDING_BASE_URL='https://my-gateway.internal'
export KIOKU_EMBEDDING_MODEL='text-embedding-3-large'
export KIOKU_EMBEDDING_DIMENSIONS='3072'
export KIOKU_EMBEDDING_API_KEY='sk-…'
```

## Which commands need what

| Command                                   | Needs DB | Needs embeddings |
|-------------------------------------------|----------|------------------|
| `kioku demo`, `kioku demo-session`        | ✔        | ✗                |
| `kioku recall --strategy keyword`         | ✔        | ✗                |
| `kioku recall` (hybrid/embedding)         | ✔        | ✔ (falls back to keyword on failure) |
| `kioku distill session --candidates scan` | ✔        | ✗ for candidates; ✔ for the LLM extract/consolidate programs |
| `kioku distill session --candidates recall` | ✔      | ✔                |
| `kioku scenes`, `kioku persona`           | ✔        | ✗ (just reads stored rows) |
| `kioku worker`                            | ✔        | ✔ (embedding worker; timer loop also drives LLM distillation) |

## Internal tuning constants (not configurable)

These live in the source and are documented here so behavior is predictable. They are **not**
environment variables:

- Recall: RRF `k = 60`, recency half-life `30 days`, signal weights
  (recency `0.10`, priority `0.15`, confidence `0.05`), candidate pool `50` per channel.
- Character budgets: `2000` per memory, `12000` total.
- Distillation: L1 idle-flush after `30 minutes`; default merge-candidate limit `5`.
- Worker: timer poll interval `5 seconds`.

See [Recall](recall.md) and [Distillation](distillation.md) for how these affect results.
