# Troubleshooting & FAQ

## Common errors

### `PG_CONNECTION_STRING is not set`

Every CLI command needs the database connection string. Export it:

```bash
export PG_CONNECTION_STRING='host=localhost dbname=kioku user=me'
```

In the Nix dev shell, point it at the same database `process-compose`/`just` use.

### `kioku … store error: …`

The command reached Postgres but a query failed. Usual causes:

- The schema isn't migrated. Run `just migrate` (or `just create-database` for a fresh DB).
- The database in your connection string isn't the one you migrated.
- A `pgvector` operation ran against a database where the extension/column is missing — see the
  pgvector section below.

### Session queries fail with missing columns

If a session command or library read mentions missing columns such as `parent_session_id`,
`delegation_depth`, `awaiting_reason`, `awaiting_correlation_key`, `awaiting_deadline`, or
`resume_input`, the database is on an older kioku migration set. Run:

```bash
just migrate
```

Those columns back the delegation lineage and park-and-resume read model. After migration,
`getDelegationChildren`, `getAwaitingByCorrelationKey`, and the expanded `SessionRow` fields
can read correctly.

### `recall` returns `(no matches)`

- The scope is wrong. Recall is scoped exactly: `rei:intention:abc` does **not** match
  `rei:intention:xyz` or the global `rei` scope. Double-check `--scope`.
- The memory isn't `active` (it was superseded/merged/archived). Only active memories are
  recalled.
- Keyword strategy with no lexical overlap. Try `--strategy hybrid` (the default) so semantic
  matching can help — assuming embeddings are configured.

### `scenes`/`persona` print `(no scenes)` / `(no persona yet)`

Nothing has been distilled for that scope yet. Run an L1 pass (`kioku distill session …`) and let
the L2/L3 timers regenerate (or run `kioku worker`). Distillation only produces scenes/personas
once there are atoms to summarize.

### Embedding/distillation failures

If `KIOKU_EMBEDDING_API_KEY`/`OPENAI_API_KEY` is unset or the endpoint is unreachable:

- **Recall** falls back to keyword-only for that request (no error).
- **Distillation** programs that need the model will fail. Check the endpoint, key, model id, and
  network. See [Configuration](configuration.md).

## pgvector

### How do I know if pgvector is active?

Run the worker; it reports the detected capability:

```text
pgvector is not available; recall will run FTS-only; running kioku timer worker only.
```

or

```text
pgvector columns are missing (embedding); running kioku timer worker only.
```

No such message (and embeddings backfill) means pgvector is available.

### Recall ignores the semantic channel

If `--show-scores` always shows `vec=-`, vector recall isn't running. Either pgvector is
unavailable, or memories have no embeddings yet. Backfill them:

```bash
kioku worker --backfill
```

### I changed `KIOKU_EMBEDDING_DIMENSIONS` and vectors broke

The `pgvector` column is a fixed dimension. The embedding model's output dimension must match the
column. Don't change dimensions against an existing populated column — choose the dimension up
front, or migrate the column and re-embed everything.

## FAQ

**Is kioku a standalone app?**
No. It's a library plus a CLI, embedded by host applications (rei, mori, shikigami, or your
own). The CLI is for operations, demos, and inspection.

**Where is the source of truth — the row table or the event log?**
The **event log**. The `kiroku.kioku_memories` row (with its `tsvector` and `embedding`) is a
projection of the memory's event stream. Recall reads the projection; writes append events.

**Can I run without an embedding endpoint?**
Yes, for keyword recall and the scene/persona *printing* commands. Hybrid/embedding recall fall
back to keyword, but you lose semantic matching, and full distillation (which calls the model)
won't work.

**Do I have to record conversation turns?**
No. Turns are opt-in L0 evidence. Without them, distillation can still work from recorded
memories. With them, the pyramid has richer raw material.

**Do different hosts interfere with each other?**
No. Memory is partitioned by `namespace`, and recall/distillation always run within a scope. One
shared database and one `kioku worker` can serve every namespace. See
[Scopes & Integrations](integrations.md).

**Why does a high `--limit` sometimes return fewer hits?**
A character budget (2000 per memory, 12000 total) is applied after ranking, so output is capped
to fit an agent's context window. See [Recall](recall.md#character-budgets).

**Where do the mirrored scene/persona files live?**
In the current workspace under `.kioku/scenes/<scope>.md` and `.kioku/persona/<scope>.md`.
Mirroring is best-effort; the database remains authoritative. See
[Distillation](distillation.md#workspace-mirroring).
