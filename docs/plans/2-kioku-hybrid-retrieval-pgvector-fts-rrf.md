---
id: 2
slug: kioku-hybrid-retrieval-pgvector-fts-rrf
title: "kioku Hybrid Retrieval (pgvector + FTS + RRF)"
kind: exec-plan
created_at: 2026-06-24T16:31:00Z
intention: "intention_01kvx5py1yeanvyn7xh58epfnt"
master_plan: "docs/masterplans/1-kioku-reusable-agent-memory-session-library.md"
---

# kioku Hybrid Retrieval (pgvector + FTS + RRF)

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan upgrades **kioku**'s memory recall from keyword-only full-text search to **hybrid
retrieval**: it fuses Postgres full-text search (FTS) with semantic vector similarity (cosine
distance over OpenAI embeddings stored in **pgvector**), combining the two ranked lists with
**Reciprocal Rank Fusion (RRF)** and then blending in recency, priority, and confidence
signals. "Recall" here means: given a free-text query and a memory **scope** (a namespace plus
an optional entity reference), return the most relevant stored agent memories.

kioku (記憶, "memory") is a standalone Haskell library at `/Users/shinzui/Keikaku/bokuno/kioku`
that gives agent platforms an event-sourced memory engine. A prior plan, ExecPlan EP-1
(`docs/plans/1-kioku-scaffold-and-core-extraction.md`), stands up the four-package project
(`kioku-api`, `kioku-core`, `kioku-cli`, `kioku-migrations`), the event-sourced memory
aggregate, an **inline** read-model projection that writes one row per memory into a
`kioku_memories` table (including a generated `content_tsv` `tsvector` column for FTS), the
write API (`Kioku.Memory`), and a **placeholder** read API `Kioku.Recall` that only runs simple
scoped SQL filters. This plan (EP-2) replaces that placeholder with a real hybrid recall and
adds the machinery that makes semantic search possible.

What a user can do after this change that they could not before: run

```bash
kioku recall "how should I handle a flaky test in CI" --scope rei:intention:int_abc --strategy hybrid
```

and get back a memory that was recorded as *"retry the test runner up to three times before
failing the build"* — even though the query shares **no keywords** with that memory. FTS alone
would miss it; the embedding similarity surfaces it; RRF ranks it sensibly against any
keyword-matching memories. If the embedding provider is unavailable (no API key, network down,
or the `vector` Postgres extension is not installed), recall **fails open** and degrades to
FTS-only rather than erroring, so the caller is never blocked.

The change is observable end-to-end via CLI transcripts (recorded in **Validation and
Acceptance**): record a memory, run the background **embedding worker** to backfill its vector,
then issue a paraphrased query and watch hybrid recall return the right memory with a higher
fused score than FTS-only would give it.


## Progress

This section reflects the actual current state of the work and is updated at every stopping
point. Steps are grouped by milestone (see **Plan of Work**).

Milestone 1 — vector column, ANN index, capability detection:

- [x] Add migration `kioku-migrations/sql-migrations/<ts>-kioku-memory-embeddings.sql` that
      runs `CREATE EXTENSION IF NOT EXISTS vector`, adds `embedding vector(1536)`,
      `embedding_model text`, `dimensions int`, `content_hash text` to `kioku_memories`, and
      creates an HNSW ANN index `kioku_memories_embedding_hnsw` using `vector_cosine_ops` when
      pgvector is installed.
- [x] Make the migration tolerate a missing `vector` extension (a guarded `DO $$ ... $$` block
      that skips the vector column + index when the extension is unavailable) and document the
      privilege requirement. Completed 2026-06-24: the local Postgres lacks pgvector and the
      migration emitted a NOTICE, committed, and left the optional columns absent.
- [x] Add `Kioku.Recall.Capability` with `detectVectorCapability :: ... -> Eff es VectorCapability`
      that probes `pg_extension` / `information_schema.columns` once at startup. Completed
      2026-06-24: `Kioku.Recall.Capability` exposes `VectorAvailable`,
      `VectorExtensionUnavailable`, and `VectorColumnsUnavailable`.
- [x] `cabal run kioku-migrations:kioku-migrate` applies cleanly to a fresh DB; verify the
      local no-pgvector fallback with metadata queries. Completed 2026-06-24: `just migrate`
      applied `2026-06-24-01-00-00-kioku-memory-embeddings.sql`; `pg_extension` showed
      `has_vector_extension = f`; `information_schema.columns` returned no optional vector
      columns, as expected for the degraded path.

Milestone 2 — async embedding worker backfills vectors (idempotent on `content_hash`):

- [ ] Add `Kioku.Memory.Embedding.Worker` (an `AsyncProjection`-shaped worker) that, on
      `MemoryRecorded`/`MemoryMerged`, computes `content_hash`, skips if unchanged, calls
      baikai `embed`, and upserts `embedding`/`embedding_model`/`dimensions`/`content_hash`.
      Progress 2026-06-24: a vector-capability-gated one-shot backfill exists in
      `Kioku.Memory.Embedding.Worker`; the continuous async projection/event follower remains.
- [x] Add `Baikai.Embedding` batching + retry wrappers (`embedBatched`, `embedWithRetry`) in
      `kioku-core` (NOT in baikai) since baikai's `embed` is one HTTP call per text with no
      retry. Completed 2026-06-24 in `Kioku.Memory.Embedding`.
- [ ] Host the worker behind a `kioku worker` CLI command (kioku-cli), reusing the keiro async
      worker host pattern. Progress 2026-06-24: `kioku worker --backfill` runs a one-shot
      backfill and exits; the long-running keiro worker host is still open.
- [ ] Backfill existing rows: run the worker, then `SELECT id, embedding IS NOT NULL,
      embedding_model, dimensions FROM kioku.kioku_memories` shows non-null vectors. Progress
      2026-06-24: local no-pgvector path verified with `cabal run kioku -- worker --backfill`,
      which reports that recall will run FTS-only and does not touch vector columns.

Milestone 3 — hybrid RRF recall replaces the placeholder:

- [ ] Implement `Kioku.Recall.recall` with `RecallStrategy = Keyword | Embedding | Hybrid`
      (default `Hybrid`), running an FTS candidate query and a vector candidate query, fusing
      with RRF (`k=60`), then blending recency/priority/confidence with documented weights and
      budgets.
- [ ] Wire `kioku recall "<query>" --scope <scope> [--strategy …] [--limit …]` in kioku-cli.
- [ ] Demonstrate: a paraphrased query recalls a keyword-disjoint memory via hybrid; the same
      query under `--strategy keyword` does NOT; fail-open to FTS-only when embeddings are
      disabled.

(No Milestone 3 work has started.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence here with short snippets (psql output, test output)
as they are found.

- **Local Postgres does not have pgvector installed.** The first migration attempt revealed that
  missing pgvector reports SQLSTATE `0A000` (`extension "vector" is not available`), not one of the
  narrower `undefined_file`/`undefined_object` cases. The migration now catches any failure inside
  only the `CREATE EXTENSION vector` sub-block, then skips vector DDL if `pg_extension` does not show
  the extension. Evidence: `just migrate` committed the migration with a NOTICE, and
  `SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector')` returned `f`.

- **`embedDir` needed a source change to pick up the new SQL file locally.** `just migrate` initially
  saw zero pending migrations until `Kioku.Migrations` changed. M1 now sorts the embedded SQL files
  by filename (`sortOn fst $(embedDir "sql-migrations")`), which both makes migration order explicit
  and invalidated the stale TH object for the local run.

- **Baikai's OpenAI base URL is not `/v1`-suffixed.** Reading
  `/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Embedding.hs` showed
  `openAIEmbeddingModel` uses `https://api.openai.com` and the client appends `/v1/embeddings`
  itself. `KIOKU_EMBEDDING_BASE_URL` therefore defaults to `https://api.openai.com`.

- **Do not pin streamly separately for baikai in this project.** A first attempt to add a streamly
  source pin pulled in `streamly-0.12`, which conflicts with `shibuya-core`'s `streamly ^>=0.11`
  bound. `baikai` builds against the existing 0.11 line, so the project pins `baikai` only and
  lets the solver keep the coherent streamly version.


## Decision Log

Record every decision made while working on the plan. The MasterPlan
(`docs/masterplans/1-kioku-reusable-agent-memory-session-library.md`) already fixed several
binding decisions that this plan inherits; they are restated here so this document is
self-contained.

- Decision: Embeddings are an **async** projection (a background worker), while the structured
  memory row and the `content_tsv` FTS column are **inline** projections (written in the
  command's append transaction).
  Rationale: generating an embedding is an external `baikai` HTTP call; the kikan rule is that
  inline projections must be simple and never-fail, so a network call cannot be inline. FTS is
  deterministic pure SQL, so it stays inline (and is owned by EP-1). Carrying
  `embedding_model`/`dimensions`/`content_hash` per row makes re-embedding (new model or
  dimensionality) a projection rebuild rather than a schema change.
  Date: 2026-06-24 (inherited from MasterPlan #1 Decision Log + IP-3/IP-4).

- Decision: Use **HNSW** (`hnsw` with `vector_cosine_ops`) for the ANN (approximate
  nearest-neighbour) index, not `ivfflat`.
  Rationale: HNSW gives good recall without needing a pre-populated table to train on (ivfflat's
  `lists` must be tuned to row count and the index should be built *after* data exists). For a
  greenfield table that starts empty and grows incrementally, HNSW is the robust default. The
  migration documents the alternative.
  Date: 2026-06-24.

- Decision: Fuse FTS and vector candidate lists with **Reciprocal Rank Fusion (RRF)** with
  constant `k = 60`, then add recency/priority/confidence as separate **additive weighted
  terms** on top of the fused RRF score (not as more RRF lists).
  Rationale: RRF is rank-based and robust to the fact that `ts_rank` scores and cosine
  distances live on incomparable scales — you cannot simply add them. `k=60` is the canonical
  default from the original RRF paper and is the value used across the ecosystem. Recency,
  priority, and confidence are *signals about the memory itself*, independent of the query, so
  they are cleanest as a small additive bonus on the fused relevance score (exact formula and
  weights below in **Plan of Work**, Milestone 3).
  Date: 2026-06-24.

- Decision: Recall is **fail-open**. If the embedding call errors, or pgvector is absent, recall
  degrades to FTS-only and never throws to the caller.
  Rationale: memory recall feeds an agent's context; a transient embedding outage must not block
  the agent. This mirrors the TencentDB-style capability degradation the MasterPlan calls out.
  Date: 2026-06-24.

- Decision: Add embedding **batching** and **basic retry** wrappers in `kioku-core`, not in
  baikai.
  Rationale: `Baikai.Embedding.embed` (read at
  `/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Embedding.hs`) issues one HTTP call
  per input text and has no retry; it deliberately stays policy-free (the comment says "error
  remapping is the consumer's job"). kioku is that consumer, so the resilience policy lives
  here.
  Date: 2026-06-24.

- Decision: The embedding **provider is pluggable via configuration**, defaulting to OpenAI but
  swappable to any OpenAI-compatible endpoint — including a **local** embedder with no external
  API — without code changes. kioku resolves an `EmbeddingConfig` from the environment
  (`KIOKU_EMBEDDING_BASE_URL` default `https://api.openai.com`, `KIOKU_EMBEDDING_MODEL` default
  `text-embedding-3-small`, `KIOKU_EMBEDDING_DIMENSIONS` default `1536`, `KIOKU_EMBEDDING_API_KEY`
  falling back to `OPENAI_API_KEY` and tolerating an empty key for keyless local servers) and
  builds baikai's `EmbeddingModel` from it via `toEmbeddingModel`.
  Rationale: `Baikai.Embedding` already targets an OpenAI-compatible `/v1/embeddings` endpoint
  through `EmbeddingModel { modelId, baseUrl, dimensions, apiKey }`, and local embedders (Ollama,
  text-embeddings-inference, vLLM, llama.cpp server, LM Studio) all expose that same API. Surfacing
  the four fields as config makes "run a local model, no API" a config flip, and requires NO change
  to baikai. Caveat: the pgvector column is a fixed `vector(1536)`, so switching to a model with a
  different dimensionality is a migration (alter the column) plus a re-embed; the rebuildable-
  projection design (per-row `embedding_model`/`dimensions`/`content_hash`) makes that a clean
  incremental backfill. Same-dimension swaps are config-only.
  Date: 2026-06-24.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare the
result against the original purpose (hybrid recall that surfaces a keyword-disjoint memory a
paraphrased query would otherwise miss).

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**Where kioku lives.** kioku is a standalone Haskell library at
`/Users/shinzui/Keikaku/bokuno/kioku`, structured as four cabal packages: `kioku-api` (shared
types), `kioku-core` (aggregates, projections, read API), `kioku-cli` (the `kioku` command-line
binary), and `kioku-migrations` (the database schema). This four-package layout mirrors the
sibling project **kizashi** at `/Users/shinzui/Keikaku/bokuno/kizashi`, which you should read as
the reference implementation for *every* convention this plan relies on (migration packaging,
worker hosting, CLI wiring). When this plan says "the kizashi pattern", open the named kizashi
file and copy its shape.

**What EP-1 already built (your hard dependency).** EP-1
(`docs/plans/1-kioku-scaffold-and-core-extraction.md`) produces, before this plan starts:

- A read-model table `kioku_memories` in the **`kiroku` schema** (kizashi convention: read-model
  tables live in the `kiroku` schema because the application queries them on the same hasql
  connection pool as the event store, whose connections run `SET search_path TO kiroku,
  pg_catalog`). The table has at least: a text primary key `id`, the memory `content` (text), a
  `namespace` text, a `scope_kind` text and `scope_id` text (the `MemoryScope` decomposed —
  see below), a `memory_type` text, a `priority` int (with a sentinel value meaning
  "always inject"; EP-1 fixes its exact representation), a `confidence` (text or numeric), a
  `status` text (`active`/`superseded`/`archived`), a `created_at timestamptz`, and a
  **generated** `content_tsv tsvector` column with a GIN index over it for full-text search.
  (If EP-1's final column names differ slightly, treat the names in this plan as a contract and
  reconcile in the Decision Log; the *shape* — id, content, scope columns, priority,
  confidence, created_at, content_tsv — is fixed by MasterPlan IP-3.)
- An **inline projection** that folds each memory event into one `kioku_memories` row inside the
  append transaction.
- A write API module `Kioku.Memory` (record / supersede / merge / archive / retag /
  reconfidence) that appends events to a kiroku stream.
- A **placeholder** read API module `Kioku.Recall` that exposes scoped SQL queries only (e.g.
  "active memories for this scope, newest first"). **This plan replaces the body of
  `Kioku.Recall` with hybrid recall** — same module, same top-level place in the public API
  surface (MasterPlan IP-1), a fuller implementation.
- The `kioku-migrations` package, built like
  `/Users/shinzui/Keikaku/bokuno/kizashi/kizashi-migrations/src/Kizashi/Migrations.hs`: it uses
  Template Haskell `embedDir "sql-migrations"` to bake the timestamped `.sql` files in at
  compile time, then composes `kirokuMigrations <> keiroFrameworkMigrations <> ownMigrations`
  and applies them through **codd** (`applyMigrationsNoCheck`). A migrate executable
  (the kioku analogue of `kizashi-migrate`) runs them.

**Key terms defined.**

- **MemoryScope** — kioku's host-agnostic way to address *whose* memory a row is. Defined in
  `kioku-api` (`Kioku.Api.Scope`) as `newtype Namespace = Namespace Text` (e.g. `"rei"`,
  `"mori"`) and `data MemoryScope = ScopeGlobal Namespace | ScopeEntity Namespace ScopeKind
  Text` where `newtype ScopeKind = ScopeKind Text` (e.g. `"intention"`, `"habit"`, `"repo"`).
  In the read-model table this is stored decomposed into `namespace`, `scope_kind` (NULL for
  `ScopeGlobal`), and `scope_id` (NULL for `ScopeGlobal`). A recall request always carries the
  scope to filter candidates.
- **FTS (full-text search)** — Postgres's built-in keyword search. EP-1's generated
  `content_tsv` column is a `tsvector` (a normalized, stemmed bag of lexemes). A query string is
  turned into a `tsquery` with `websearch_to_tsquery('english', $q)` (which understands quoted
  phrases and `or`); a match is `content_tsv @@ query` and a relevance score is
  `ts_rank(content_tsv, query)`.
- **pgvector** — a Postgres extension providing a `vector` column type and distance operators.
  It does **not exist anywhere in this ecosystem yet** — this plan introduces it. The cosine
  *distance* operator is `<=>` (smaller = more similar; `0` = identical direction). We store a
  `vector(1536)` because the default OpenAI model `text-embedding-3-small` returns 1536-dimension
  embeddings.
- **Embedding** — a fixed-length list of floating-point numbers (here 1536 of them) that
  represents the *meaning* of a text. Two texts with similar meaning have embeddings close in
  cosine distance even if they share no words. kioku gets embeddings from **baikai**
  (`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Embedding.hs`), a thin client over an
  OpenAI-compatible `/v1/embeddings` HTTP endpoint, keyed by the `OPENAI_API_KEY` environment
  variable.
- **ANN index (approximate nearest neighbour)** — an index that makes "find the N closest
  vectors" fast without scanning every row. pgvector offers `hnsw` and `ivfflat`; we use `hnsw`.
- **RRF (Reciprocal Rank Fusion)** — a way to merge two ranked lists into one. Each document `d`
  scores `Σ_i 1/(k + rank_i(d))` summed over the lists it appears in, with `k = 60` and `rank`
  starting at 1 for the top result. A document near the top of *either* list scores well;
  appearing in both lists scores best.
- **Async projection / worker host** — keiro (the event-sourcing framework at
  `/Users/shinzui/Keikaku/bokuno/keiro`) defines `Keiro.Projection.AsyncProjection`, a record
  `{ name, subscriptionName, applyRecorded :: RecordedEvent -> Tx.Transaction (), idempotencyKey
  :: RecordedEvent -> EventId }`. keiro ships **no** worker supervisor; the application hosts the
  worker. Rei's host
  (`/Users/shinzui/Keikaku/bokuno/rei-project/rei/rei-core/src/Rei/Infrastructure/WorkerHost.hs`)
  is the reference: it bridges each `AsyncProjection` into a Shibuya `QueueProcessor` over a
  kiroku subscription and applies the projection's transaction per delivered event. **Caveat,
  read it carefully:** that host's `applyRecorded` runs in a `Hasql.Transaction.Transaction`,
  which **cannot** make an HTTP call. Our embedding worker therefore is **not** a plain
  `AsyncProjection` — it is a worker that runs the embedding HTTP call in `IO`/`Eff` *outside* a
  transaction and then opens a short transaction only to write the vector. We model it on the
  **side-effect leg** pattern instead (`sideEffectReactorSpec` /`sideEffectProcessor` in the same
  `WorkerHost.hs`), which is exactly the kikan tool for "react to an event by doing non-`Tx`
  work". See **Plan of Work** Milestone 2 for the precise shape.

**Why the embedding worker mirrors the side-effect leg, with one twist.** Read
`/Users/shinzui/Keikaku/bokuno/rei-project/rei/rei-core/src/Rei/Modules/AgentMemory/Reactor/FilesystemProjection.hs`
for the simplest side-effect leg: it decodes the recorded event with a codec and performs a
best-effort `IO` action, converging on the same state when an event is redelivered (it is
content-idempotent). The git side-effect legs in `WorkerHost.hs` (`sideEffectProcessor`) always
ack OK and swallow their own failures because a git commit is best-effort. Our embedding worker
borrows that *non-transactional* shape (HTTP call allowed) but, unlike the git legs, it **does**
write to Postgres afterward (the vector upsert) — so it must be idempotent the way the
`GitSyncEnqueueProjection` is. We get idempotency for free from the **content hash**: the worker
computes `content_hash = sha256(content)` and, before calling the embedding API, checks the row's
stored `content_hash`; if it already matches (and `embedding IS NOT NULL`), the worker skips the
API call and the write entirely. A redelivered event therefore re-hashes, finds a match, and does
nothing.

**The baikai embedding client, exactly as it is.** `Baikai.Embedding` exposes
`embed :: EmbeddingModel -> [Text] -> IO (Vector (Vector Double))` (one HTTP call per text — it
loops internally), `embedOne :: EmbeddingModel -> Text -> IO (Vector Double)`, and
`openAIEmbeddingModel :: Text -> EmbeddingModel` (defaults to `api.openai.com`,
`OPENAI_API_KEY`, model-default dimensionality). The underlying SDK request type is
`OpenAI.V1.Embeddings.CreateEmbeddings` (`input :: Text`, `model :: Model`, `dimensions ::
Maybe Natural`) at
`/Users/shinzui/Keikaku/hub/haskell/openai-project/openai/src/OpenAI/V1/Embeddings.hs`. baikai's
`embed` lets the Servant client exception propagate as plain `IO`; kioku must catch it (for
fail-open) and retry transient failures.

**What does not yet exist and is introduced by this plan:** the `vector` Postgres extension and
its column/index; `Postgres FTS` is already introduced by EP-1 (the `content_tsv` column), so
this plan only *queries* it. There is no prior pgvector or embedding code anywhere in kioku,
rei, kizashi, mori, or shikigami — both pgvector and Postgres FTS are greenfield in this
ecosystem.


## Plan of Work

The work splits into three independently verifiable milestones. Milestone 1 makes the database
able to *store* vectors and lets the application *detect* whether it can. Milestone 2 *fills in*
the vectors with a background worker. Milestone 3 *uses* them in hybrid recall. Each milestone
builds and demonstrates something on its own.

Throughout, follow the kizashi conventions. The migration package mirrors
`/Users/shinzui/Keikaku/bokuno/kizashi/kizashi-migrations`; the worker host and CLI worker
command mirror `/Users/shinzui/Keikaku/bokuno/kizashi/kizashi-cli/src/Kizashi/Cli/Commands/Worker.hs`
and Rei's
`/Users/shinzui/Keikaku/bokuno/rei-project/rei/rei-core/src/Rei/Infrastructure/WorkerHost.hs`.


### Milestone 1 — vector column, ANN index, and capability detection

**Scope.** Add one timestamped migration to `kioku-migrations` that enables pgvector and extends
`kioku_memories` with the embedding columns and an ANN index, and add a small capability probe in
`kioku-core` so the rest of the system can ask "does this database actually have pgvector?". At
the end of this milestone the schema applies to a fresh database, and a function reports the
vector capability. Nothing yet fills the vectors; that is Milestone 2.

**The migration.** Create
`kioku-migrations/sql-migrations/<UTC-timestamp>-kioku-memory-embeddings.sql` (timestamp format
`YYYY-MM-DD-HH-MM-SS`, sorting *after* EP-1's `kioku_memories` migration — codd sorts the
combined migration set by filename timestamp, so the timestamp must be later than EP-1's). Because
codd's `embedDir` bakes the directory at compile time, after adding the file you must force a
rebuild of the migrations module (touch or `cabal clean kioku-migrations` then rebuild) — same as
the kizashi/Rei `embedDir` caveat.

The migration's SQL:

```sql
-- codd: in-txn
-- kioku embedding columns + pgvector ANN index (EP-2). Read-model lives in the
-- `kiroku` schema; pin search_path so unqualified names resolve there whether codd
-- applies this in the same batch as the kiroku bootstrap or on its own.
SET search_path TO kiroku, pg_catalog;

-- Enable pgvector. Requires the extension to be installed in the Postgres image
-- and the migration role to be superuser-or-owner. If it is not available, the
-- guarded block below leaves the table FTS-only and a NOTICE explains why.
DO $$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS vector;
  EXCEPTION WHEN insufficient_privilege OR undefined_file THEN
    RAISE NOTICE 'pgvector unavailable (%); kioku recall will run FTS-only', SQLERRM;
  END;

  -- model/dims/hash columns are always added (cheap, and the worker needs them).
  ALTER TABLE kioku_memories
    ADD COLUMN IF NOT EXISTS embedding_model text,
    ADD COLUMN IF NOT EXISTS dimensions      int,
    ADD COLUMN IF NOT EXISTS content_hash    text;

  -- The vector column + ANN index only when the extension actually loaded.
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
    ALTER TABLE kioku_memories
      ADD COLUMN IF NOT EXISTS embedding vector(1536);
    CREATE INDEX IF NOT EXISTS kioku_memories_embedding_hnsw
      ON kioku_memories USING hnsw (embedding vector_cosine_ops);
  END IF;
END $$;
```

Notes a novice needs:

- `vector(1536)` matches `text-embedding-3-small`. If a future model changes dimensionality, that
  is a new migration plus a re-embed (the `dimensions` column records what each row actually is).
- `vector_cosine_ops` is the operator class that makes the `<=>` cosine-distance operator use the
  index.
- **Privilege requirement (call this out to the operator).** `CREATE EXTENSION vector` needs the
  pgvector shared library present in the Postgres install *and* the connecting role to be
  superuser or the database owner. The local development Postgres (process-compose, see
  **Concrete Steps**) must be built with pgvector. The guarded `DO` block means the migration
  still *succeeds* on a Postgres without pgvector — it just leaves the table FTS-only, and recall
  degrades accordingly (Milestone 3 fail-open). The fallback if pgvector cannot be installed at
  all: run everything in keyword mode; hybrid simply has no vector list to fuse.
- `hnsw` vs `ivfflat`: HNSW builds incrementally and needs no row-count tuning, so it is correct
  for a table that starts empty. The alternative `ivfflat` would require `WITH (lists = N)` tuned
  to the eventual row count and is best built after data exists.

**Capability detection.** Add `kioku-core/src/Kioku/Recall/Capability.hs` exposing:

```haskell
data VectorCapability = VectorAvailable | VectorAbsent
  deriving stock (Eq, Show)

-- Probe once (at worker/CLI startup) whether pgvector is usable: the `vector`
-- extension is installed AND kioku_memories.embedding exists.
detectVectorCapability ::
  (Hasql :> es, Error SessionError :> es) => Eff es VectorCapability
```

Its SQL probe:

```sql
SELECT
  EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector')
  AND EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'kiroku'
      AND table_name = 'kioku_memories'
      AND column_name = 'embedding'
  );
```

Recall (Milestone 3) takes the resolved `VectorCapability` as a parameter so it never re-probes
per query; the CLI resolves it once at startup.

**Acceptance for M1.** From `/Users/shinzui/Keikaku/bokuno/kioku`, `cabal run
kioku-migrations:kioku-migrate` (or the EP-1 name for the migrate executable) applies cleanly to a
fresh database, and `psql ... -c '\d+ kioku.kioku_memories'` shows the `embedding`,
`embedding_model`, `dimensions`, `content_hash` columns and the `kioku_memories_embedding_hnsw`
index. A throwaway call to `detectVectorCapability` returns `VectorAvailable` against that DB.


### Milestone 2 — async embedding worker backfills vectors

**Scope.** Add the background worker that turns recorded memories into stored vectors, host it
under a `kioku worker` CLI command, and add the batching+retry wrappers around baikai. At the end
of this milestone, after recording memories and running `kioku worker` (or a one-shot backfill),
the `embedding` column is non-null for every active memory, and re-running is a no-op.

**The embedding wrappers.** Add `kioku-core/src/Kioku/Memory/Embedding.hs`:

```haskell
-- Provider config, resolved from the environment so the embedding backend is
-- pluggable: OpenAI by default, or ANY OpenAI-compatible endpoint (including a
-- local server such as Ollama / text-embeddings-inference / vLLM / llama.cpp)
-- by setting KIOKU_EMBEDDING_BASE_URL. No code change and no baikai change.
data EmbeddingConfig = EmbeddingConfig
  { baseUrl    :: !Text  -- KIOKU_EMBEDDING_BASE_URL   (default https://api.openai.com/v1)
  , model      :: !Text  -- KIOKU_EMBEDDING_MODEL      (default text-embedding-3-small)
  , dimensions :: !Int   -- KIOKU_EMBEDDING_DIMENSIONS (default 1536; MUST match the model)
  , apiKey     :: !Text  -- KIOKU_EMBEDDING_API_KEY    (fallback OPENAI_API_KEY; "" = keyless local)
  }
  deriving stock (Show)

resolveEmbeddingConfig :: IO EmbeddingConfig                 -- read the four env vars + apply defaults
toEmbeddingModel       :: EmbeddingConfig -> EmbeddingModel  -- build baikai's EmbeddingModel from config

-- A small resilience layer over Baikai.Embedding (which is one HTTP call per text,
-- no retry, plain IO). Batching here means "embed many texts with bounded
-- concurrency / chunking"; retry means "re-attempt a transient failure a few times
-- with backoff, then give up and propagate".
embedWithRetry :: EmbeddingModel -> Int -> Text -> IO (Either EmbedError (Vector Double))
embedBatched   :: EmbeddingModel -> Int -> [Text] -> IO [Either EmbedError (Vector Double)]

data EmbedError = EmbedTransport !Text | EmbedEmpty
  deriving stock (Show)
```

`embedWithRetry model maxAttempts text` calls `Baikai.Embedding.embedOne` inside a `try`,
retrying on a Servant transport exception with exponential backoff (e.g. 200ms, 400ms, 800ms),
returning `Left (EmbedTransport …)` after `maxAttempts`. `embedBatched` chunks the input list
(default chunk 16) and embeds each chunk, so a backfill of many rows does not open one connection
per row needlessly. The `EmbeddingModel` passed to these functions is built by
`toEmbeddingModel <$> resolveEmbeddingConfig`, so the provider — OpenAI by default, or a local
OpenAI-compatible server via `KIOKU_EMBEDDING_BASE_URL` — is chosen entirely by environment
configuration, with no code change and no baikai change. `resolveEmbeddingConfig` defaults to
`baseUrl=https://api.openai.com/v1`, `model=text-embedding-3-small`, `dimensions=1536`, and an api
key from `KIOKU_EMBEDDING_API_KEY` or `OPENAI_API_KEY` (an empty key is allowed for keyless local
servers). `toEmbeddingModel` constructs baikai's `EmbeddingModel { modelId, baseUrl, dimensions,
apiKey }` from it. **kioku owns this resolution policy**, not baikai (baikai stays deliberately
policy-free).

**The worker.** Add `kioku-core/src/Kioku/Memory/Embedding/Worker.hs`. The worker reacts to
`MemoryRecorded` and `MemoryMerged` events on the kioku memory stream. Because computing an
embedding is an HTTP call, the worker is modeled on the **non-transactional side-effect leg**
(`sideEffectReactorSpec`/`sideEffectProcessor` in Rei's `WorkerHost.hs`), *not* a plain
`AsyncProjection` whose `applyRecorded` runs in a `Tx.Transaction` (you cannot do HTTP in a
transaction). Per delivered event the worker:

1. Decodes the recorded event with kioku's memory codec; ignores any event that is not
   `MemoryRecorded`/`MemoryMerged` (a no-op, like `FilesystemProjection`'s `_ -> pure ()`).
2. Extracts the memory id and the current `content`.
3. Computes `content_hash = sha256Hex content`.
4. Opens a short read transaction (or read-model query on the store pool, the
   `store ^. #pool` single-pool trick the side-effect legs use) to fetch the row's stored
   `content_hash` and whether `embedding IS NOT NULL`. **If the stored hash equals the computed
   hash and the embedding is present, skip entirely** (content-idempotent — this is what makes
   redelivery safe).
5. Otherwise calls `embedWithRetry model 3 content`. On `Left _` it **logs and acks OK without
   writing** (fail-open: a transient embedding outage must not wedge the worker, exactly like the
   git side-effect legs always-ack). On `Right vec`, it opens a short write transaction and runs
   an UPSERT.

The UPSERT statement (run via `Tx.statement` over the store pool):

```sql
UPDATE kiroku.kioku_memories
   SET embedding       = $2::vector,
       embedding_model = $3,
       dimensions      = $4,
       content_hash    = $5
 WHERE id = $1;
```

The `vector` value is sent as its text literal `'[0.1,0.2,...]'` cast to `::vector` (pgvector
accepts the bracketed-float text form), encoded with `Hasql.Encoders` as `E.text` then cast in
SQL; this avoids needing a bespoke hasql `vector` codec. (If a row was deleted/superseded between
record and embed, the `WHERE id` matches zero rows and the write is a harmless no-op.)

The worker is exposed as a `ReactorWorkerSpec`-shaped value built with the kioku analogue of
`sideEffectReactorSpec` (gated on the memory bounded context, subscribed to the memory stream
category, with a globally unique subscription/checkpoint name like
`"kioku-memory-embedding"`). If kioku does not yet vendor a worker-host module, port the minimal
slice of Rei's `WorkerHost.hs` needed (`sideEffectReactorSpec`, `sideEffectProcessor`,
`runKirokuWorkerHost`) into `kioku-core/src/Kioku/Infrastructure/WorkerHost.hs`; kizashi has the
same machinery, so cross-check both.

**One-shot backfill mode.** For existing rows recorded before the worker ran (and for the
acceptance transcript), also add a direct backfill function
`Kioku.Memory.Embedding.Worker.backfillMissingEmbeddings :: EmbeddingModel -> Eff es Int` that
`SELECT id, content FROM kiroku.kioku_memories WHERE status='active' AND (embedding IS NULL OR
content_hash IS DISTINCT FROM <recomputed>)`, embeds each, and upserts — returning the count
embedded. This is the same logic as the worker minus the subscription, so it shares the
hash-skip and upsert helpers. The CLI exposes it as `kioku worker --backfill` (run once and
exit) versus `kioku worker` (run continuously).

**The CLI command.** Add `kioku worker` to kioku-cli (mirror
`/Users/shinzui/Keikaku/bokuno/kizashi/kizashi-cli/src/Kizashi/Cli/Commands/Worker.hs`). It opens
the kioku store, resolves the embedding model via `resolveEmbeddingConfig` (the `KIOKU_EMBEDDING_*`
environment described under **Environment** below — OpenAI by default; a `--model` flag overrides
`KIOKU_EMBEDDING_MODEL`), runs `detectVectorCapability`, and:

- with `--backfill`: runs `backfillMissingEmbeddings` once, prints the count, exits.
- without: starts the worker host (`runKirokuWorkerHost`) and blocks until SIGINT, exactly as
  Rei's `rei worker kiroku` does.

If `detectVectorCapability` returns `VectorAbsent`, `kioku worker` prints a clear message
("pgvector not available; recall will run FTS-only; nothing to embed") and exits 0 rather than
erroring.

**Acceptance for M2.** Record two or three memories via `kioku` (EP-1's write CLI), run `kioku
worker --backfill`, and observe the printed count plus `SELECT id, embedding IS NOT NULL AS has_vec,
embedding_model, dimensions FROM kiroku.kioku_memories` showing `has_vec = t`, `embedding_model =
text-embedding-3-small`, `dimensions = 1536`. Run `--backfill` a second time and observe a count of
`0` (idempotent on `content_hash`).


### Milestone 3 — hybrid RRF recall replaces the placeholder

**Scope.** Replace the body of EP-1's placeholder `Kioku.Recall` with hybrid retrieval: an FTS
candidate query, a vector candidate query, RRF fusion, and recency/priority/confidence blending,
with a configurable strategy and fail-open behavior. Wire `kioku recall`. At the end, a
paraphrased, keyword-disjoint query recalls the right memory under hybrid, and does not under
keyword-only.

**The recall API.** In `kioku-core/src/Kioku/Recall.hs` (extending EP-1's module — same public
surface per MasterPlan IP-1), define:

```haskell
data RecallStrategy = Keyword | Embedding | Hybrid
  deriving stock (Eq, Show)

data RecallRequest = RecallRequest
  { scope      :: !MemoryScope     -- whose memories to search (from kioku-api)
  , query      :: !Text            -- the free-text query
  , strategy   :: !RecallStrategy  -- default Hybrid
  , maxResults :: !Int             -- budget; default 8
  }

data RecallHit = RecallHit
  { memory     :: !MemoryRecord    -- the kioku-api record (id, content, type, …)
  , score      :: !Double          -- final blended score (higher = better)
  , ftsRank    :: !(Maybe Int)     -- 1-based rank in the FTS list, if present
  , vecRank    :: !(Maybe Int)     -- 1-based rank in the vector list, if present
  }

recall ::
  (Hasql :> es, Error SessionError :> es, IOE :> es) =>
  EmbeddingModel ->
  VectorCapability ->
  RecallRequest ->
  Eff es [RecallHit]
```

**How `recall` works.**

1. Resolve the *effective strategy*. If `VectorCapability = VectorAbsent`, force `Keyword`
   (fail-open at the capability layer). If `strategy = Hybrid` or `Embedding`, attempt to embed
   the query once via `embedWithRetry model 2 (query req)`; on `Left _`, fall back to `Keyword`
   (fail-open at the request layer). This single query embedding is reused for the vector list.

2. **FTS candidate list** (run unless effective strategy is `Embedding`-only): query the top
   `candidatePoolSize` (default 50) active memories in scope, ranked by `ts_rank`:

   ```sql
   SELECT id, content, memory_type, priority, confidence, created_at,
          ts_rank(content_tsv, websearch_to_tsquery('english', $query)) AS rank
     FROM kiroku.kioku_memories
    WHERE status = 'active'
      AND namespace = $ns
      AND ( $scopeKind IS NULL
            OR (scope_kind = $scopeKind AND scope_id = $scopeId) )
      AND content_tsv @@ websearch_to_tsquery('english', $query)
    ORDER BY rank DESC
    LIMIT $pool;
   ```

   The scope predicate: when the request scope is `ScopeGlobal ns`, `$scopeKind`/`$scopeId` are
   NULL and the predicate matches all rows in the namespace; when `ScopeEntity ns k i`, it
   restricts to that entity. (Optionally also fold in namespace-global memories for an entity
   scope — but keep v1 strict to the requested scope and note the option.)

3. **Vector candidate list** (run only when effective strategy is `Embedding` or `Hybrid` *and*
   `VectorAvailable`): order by cosine distance ascending against the query embedding:

   ```sql
   SELECT id, content, memory_type, priority, confidence, created_at,
          (embedding <=> $qvec::vector) AS distance
     FROM kiroku.kioku_memories
    WHERE status = 'active'
      AND namespace = $ns
      AND ( $scopeKind IS NULL
            OR (scope_kind = $scopeKind AND scope_id = $scopeId) )
      AND embedding IS NOT NULL
    ORDER BY embedding <=> $qvec::vector
    LIMIT $pool;
   ```

   `$qvec` is the query embedding serialized as the pgvector text literal `[f1,f2,…]`.

4. **RRF fusion.** Assign each list a 1-based rank (position in the ORDER BY). For every distinct
   memory id appearing in either list, compute the RRF base score:

   ```text
   rrf(d) = (if d in FTS list:  1 / (k + ftsRank(d))  else 0)
          + (if d in vec list:  1 / (k + vecRank(d))  else 0)
   with k = 60
   ```

   `Keyword` strategy uses only the FTS term; `Embedding` uses only the vector term; `Hybrid`
   sums both. This is pure Haskell over the two result lists — implement it as a fold building a
   `Map MemoryId (rrf, maybeFtsRank, maybeVecRank, row)`.

5. **Signal blending.** On top of the RRF base, add three weighted, normalized bonuses computed
   per memory:

   ```text
   final(d) = rrf(d)
            + w_recency    * recencyDecay(now, created_at(d))
            + w_priority   * priorityWeight(priority(d))
            + w_confidence * confidenceWeight(confidence(d))

   recencyDecay(now, t)   = exp( -ln(2) * ageDays / halfLifeDays )   -- in [0,1], halfLifeDays = 30
   priorityWeight(p)      = 1.0 if p is the always-inject sentinel (from EP-1)
                            else clamp(p / pMax, 0, 1)                 -- pMax = 100
   confidenceWeight(c)    = c mapped to [0,1] (e.g. high=1.0, medium=0.6, low=0.3,
                            or the numeric confidence directly if EP-1 stores a number)

   Default weights (documented + tunable as named constants):
     w_recency    = 0.10
     w_priority   = 0.15
     w_confidence = 0.05
   ```

   Rationale for the magnitudes: an RRF term for a rank-1 hit is `1/61 ≈ 0.0164`; a perfect blend
   bonus of `w_recency+w_priority+w_confidence = 0.30` would swamp RRF, so the signal weights
   are deliberately *small* relative to a few stacked RRF hits — they act as tie-breakers and
   gentle nudges, not as the primary ranking force. The **always-inject priority sentinel** from
   EP-1 is special-cased: a sentinel-priority memory gets the full `w_priority` bonus so it
   reliably floats near the top of its scope. (If EP-1 additionally requires sentinel memories to
   be *unconditionally* included regardless of FTS/vector match, add them to the candidate set
   directly before fusion — note this as an EP-1↔EP-2 contract to confirm.)

6. **Budgets and final shape.** Sort by `final` descending, take `maxResults` (default 8). Apply
   character budgets so a caller injecting this into an LLM prompt has bounded size: a
   per-memory cap (default 2000 chars, truncate longer `content` with an ellipsis) and a total
   cap (default 12000 chars across all returned hits — stop adding hits once the running total
   would exceed it). Return `[RecallHit]`.

**Fail-open summary (must hold).** No path in `recall` throws to the caller for an embedding or
pgvector problem: capability-absent → keyword; embed-error → keyword; an empty FTS *and* empty
vector list → empty result list (not an error). Only a genuine SQL/connection failure surfaces as
the normal `SessionError`.

**The CLI command.** Add `kioku recall "<query>" --scope <scope>` to kioku-cli with
`--strategy keyword|embedding|hybrid` (default `hybrid`) and `--limit N` (default 8). `--scope`
parses the `namespace[:kind:id]` shorthand into a `MemoryScope` (`rei` → `ScopeGlobal "rei"`;
`rei:intention:int_abc` → `ScopeEntity "rei" "intention" "int_abc"`). The command resolves the
embedding model + `VectorCapability` once, calls `recall`, and prints each hit: the score, the FTS
and vector ranks (so the transcript *shows* which list surfaced it), and the (truncated) content.
A flag `--show-scores` (or always-on compact form) makes the fused/component scores visible for
the acceptance transcript.

**Acceptance for M3.** See **Validation and Acceptance** for the exact transcript: a memory whose
content shares no keywords with a paraphrased query is returned by `--strategy hybrid` (with a
non-null `vecRank` and a null or low `ftsRank`) and is **absent** under `--strategy keyword`,
proving embeddings add value over FTS alone. With `OPENAI_API_KEY` unset, `--strategy hybrid`
still returns FTS results without error (fail-open).


## Concrete Steps

All commands run from the kioku repository root `/Users/shinzui/Keikaku/bokuno/kioku` unless
stated otherwise. The local development database is a process-compose Postgres exactly like
kizashi's and Rei's; **it must be built with pgvector available** (see Milestone 1's privilege
note). Assume EP-1 is Complete and the kioku store + migrations already exist.

**Environment.** The embedding backend is configured entirely through the environment, so the same
build talks to OpenAI today or a local model later. Defaults target OpenAI; set just the key:

```bash
export OPENAI_API_KEY=sk-...                        # api key (or KIOKU_EMBEDDING_API_KEY)
# KIOKU_EMBEDDING_BASE_URL   defaults to https://api.openai.com/v1
# KIOKU_EMBEDDING_MODEL      defaults to text-embedding-3-small
# KIOKU_EMBEDDING_DIMENSIONS defaults to 1536
```

To use a **local model with no external API** — an Ollama / text-embeddings-inference / vLLM /
llama.cpp server that speaks the OpenAI `/v1/embeddings` API — point the base URL at it. No code
change, no baikai change:

```bash
export KIOKU_EMBEDDING_BASE_URL=http://localhost:11434/v1   # local OpenAI-compatible server
export KIOKU_EMBEDDING_MODEL=nomic-embed-text
export KIOKU_EMBEDDING_DIMENSIONS=768                       # must match the model
export KIOKU_EMBEDDING_API_KEY=                             # empty is fine for keyless local
```

**Dimension caveat:** the pgvector column is `vector(1536)`. A local model whose dimension is not
1536 (the example above is 768) needs a one-line migration to change the column dimension plus a
re-embed (`kioku worker --backfill` after clearing stale vectors); the per-row `dimensions` column
records what each row actually is. A same-dimension provider swap needs neither.

Recall and the worker both **fail open** when the embedding endpoint is unreachable or the key is
missing (FTS-only); configure the above to exercise the hybrid path.

**Step 1 — apply the M1 migration.** After adding the migration `.sql`, force the `embedDir`
rebuild and apply:

```bash
cabal clean kioku-migrations          # embedDir is baked at compile time; force a rebuild
cabal run kioku-migrations:kioku-migrate
```

Expected tail (codd):

```text
Applying  2026-XX-XX-XX-XX-XX-kioku-memory-embeddings.sql ... OK
All migrations applied.
```

Verify the schema (replace the conninfo with your local socket/db, as in kizashi/Rei):

```bash
psql "$KIOKU_DB" -c '\d+ kioku.kioku_memories' | grep -E 'embedding|content_hash|dimensions|hnsw'
```

Expected (abridged):

```text
 embedding       | vector(1536) |
 embedding_model | text         |
 dimensions      | integer      |
 content_hash    | text         |
 "kioku_memories_embedding_hnsw" hnsw (embedding vector_cosine_ops)
```

**Step 2 — record memories (EP-1 write CLI).** Use EP-1's record command (exact name from EP-1;
shown here as `kioku memory record`):

```bash
kioku memory record --scope rei:intention:int_abc \
  --type pattern \
  "retry the test runner up to three times before failing the build"
kioku memory record --scope rei:intention:int_abc \
  --type fact \
  "the deploy script lives in ops/deploy.sh"
```

**Step 3 — backfill embeddings (M2).**

```bash
kioku worker --backfill
```

Expected:

```text
pgvector: available
embedded 2 memories (model=text-embedding-3-small, dims=1536)
```

Verify and prove idempotency:

```bash
psql "$KIOKU_DB" -c \
  "SELECT left(content,40), embedding IS NOT NULL AS has_vec, embedding_model, dimensions
     FROM kiroku.kioku_memories ORDER BY created_at;"
kioku worker --backfill    # second run
```

Expected second run:

```text
embedded 0 memories (all up to date)
```

(Or run `kioku worker` continuously in another terminal; recording a new memory backfills it
within a second.)

**Step 4 — hybrid recall (M3).** Issue a paraphrased query that shares **no words** with the
stored "retry the test runner..." memory:

```bash
kioku recall "how do I deal with a flaky CI test" \
  --scope rei:intention:int_abc --strategy hybrid --show-scores
```

Expected (the retry memory is surfaced by the vector list, not FTS):

```text
1. score=0.0173  fts=-   vec=1   pattern   "retry the test runner up to three times before failing the build"
2. score=0.0008  fts=-   vec=2   fact      "the deploy script lives in ops/deploy.sh"
```

Now the keyword-only path, which cannot match (no shared lexemes):

```bash
kioku recall "how do I deal with a flaky CI test" \
  --scope rei:intention:int_abc --strategy keyword --show-scores
```

Expected:

```text
(no matches)
```

This contrast is the headline result: hybrid found a semantically-relevant memory that keyword
search misses.

**Step 5 — fail-open check.** Unset the key and re-run hybrid:

```bash
env -u OPENAI_API_KEY kioku recall "retry the test runner" \
  --scope rei:intention:int_abc --strategy hybrid --show-scores
```

Expected (no error; degrades to FTS, which *does* match this keyword query):

```text
1. score=0.0164  fts=1   vec=-   pattern   "retry the test runner up to three times before failing the build"
```


## Validation and Acceptance

Acceptance is behavioral, demonstrated by the Step 1–5 transcripts above and by unit tests.

**Behavioral acceptance (the three observable facts):**

1. *Vectors are backfilled.* After `kioku worker --backfill` (Step 3) the `embedding` column is
   non-null for active memories, with `embedding_model=text-embedding-3-small` and
   `dimensions=1536`; a second backfill embeds `0` rows (idempotent on `content_hash`).
2. *Hybrid beats FTS on a paraphrase.* The Step 4 query "how do I deal with a flaky CI test"
   returns the "retry the test runner..." memory under `--strategy hybrid` with a non-null
   `vec` rank and a missing `fts` rank, and returns **no matches** under `--strategy keyword`.
   This is the proof that embeddings add value beyond keyword search.
3. *Fail-open works.* With `OPENAI_API_KEY` unset (Step 5), `--strategy hybrid` returns FTS
   results without raising an error; with pgvector absent entirely, `detectVectorCapability`
   reports `VectorAbsent` and recall runs keyword-only.

**Unit tests (in `kioku-core/test`, run with `cabal test kioku-core`):**

- *RRF fusion is pure and testable without a database.* Given two synthetic ranked id lists,
  `rrf` produces the expected scores (`1/(60+rank)` summed) and the expected fused ordering;
  a document in both lists outranks a document in one. Assert `k=60`.
- *Signal blending math.* `recencyDecay` halves at `halfLifeDays`; `priorityWeight` returns
  `1.0` for the always-inject sentinel; `confidenceWeight` maps the confidence domain into
  `[0,1]`. Assert `final = rrf + Σ weighted signals` on a hand-built example.
- *Budgets.* A `content` longer than the per-memory cap is truncated with an ellipsis; the
  returned set stops before exceeding the total character cap.
- *Capability gating.* `recall` with `VectorAbsent` never runs the vector query (mock/observe
  that only the FTS statement is issued) and never calls the embedding client.
- *Idempotent backfill.* The hash-skip predicate skips a row whose stored `content_hash` matches
  the recomputed hash and whose `embedding` is non-null.

A database-integration test (guarded like kizashi/Rei DB suites) records a memory, runs the
backfill helper against a real pgvector-enabled test database, and asserts the embedding column
is populated and that a `recall` for a paraphrase returns the row. If the CI Postgres lacks
pgvector, this integration test is skipped and the capability path (`VectorAbsent` → keyword)
is asserted instead.

Acceptance is met when `cabal build all` and `cabal test kioku-core` pass and the Step 1–5
transcripts reproduce.


## Idempotence and Recovery

Every step is safe to repeat.

- **The migration** uses `CREATE EXTENSION IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`, and
  `CREATE INDEX IF NOT EXISTS`, all inside a guarded `DO` block, so re-applying it (or applying
  it to a partially-migrated DB) is a no-op. codd additionally dedups by filename, so it only
  runs once per database anyway. If pgvector is unavailable, the migration still succeeds
  (FTS-only), and re-running after pgvector is later installed will add the vector column and
  index on the next apply.
- **The embedding worker / backfill** is content-idempotent: it computes `content_hash` and skips
  any row whose stored hash matches and whose embedding is present. A crashed or re-delivered
  event re-hashes and does nothing. Killing and restarting `kioku worker` re-processes from the
  subscription checkpoint; already-embedded rows are skipped. To *force* a re-embed (e.g. after
  changing the model), clear the columns: `UPDATE kiroku.kioku_memories SET embedding=NULL,
  content_hash=NULL;` then re-run `kioku worker --backfill` — this is the model-rebuild path the
  `embedding_model`/`dimensions`/`content_hash` columns exist to support.
- **Recall** is read-only: it never mutates state, so it can be run any number of times. Its
  fail-open design means a transient embedding outage produces (at worst) FTS-only results, never
  an error or partial write.

**Rollback.** The migration is additive (new columns + one index); to roll back, drop the index
and columns (`DROP INDEX IF EXISTS kiroku.kioku_memories_embedding_hnsw; ALTER TABLE
kiroku.kioku_memories DROP COLUMN IF EXISTS embedding, DROP COLUMN IF EXISTS embedding_model,
DROP COLUMN IF EXISTS dimensions, DROP COLUMN IF EXISTS content_hash;`). Recall then falls back to
keyword via capability detection without any code change. The `CREATE EXTENSION vector` is left in
place (harmless and shared).


## Interfaces and Dependencies

**Libraries and services.**

- **pgvector** (Postgres extension) — the `vector` column type, the `<=>` cosine-distance
  operator, and the `hnsw`/`vector_cosine_ops` index. New to this ecosystem; introduced by the M1
  migration. Requires the extension binary in the Postgres install and superuser/owner at
  migration time.
- **Postgres FTS** — `tsvector`/`tsquery`, `websearch_to_tsquery('english', …)`, `@@`,
  `ts_rank`. The `content_tsv` generated column and its GIN index already exist (EP-1); this plan
  only queries them.
- **baikai** — `Baikai.Embedding`
  (`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Embedding.hs`): `embed`, `embedOne`,
  `openAIEmbeddingModel`, `EmbeddingModel`. OpenAI-compatible `/v1/embeddings`, keyed by
  `OPENAI_API_KEY`. One HTTP call per text, no retry — kioku adds batching+retry on top
  (`Kioku.Memory.Embedding`). Add `baikai` to `kioku-core`'s `build-depends` and pin it in
  `cabal.project` (per MasterPlan IP-4/IP-5; EP-1 may already have added the pin for EP-3).
- **keiro** — `Keiro.Projection.AsyncProjection` and the worker-host primitives. The embedding
  worker uses the **side-effect leg** shape (non-`Tx`, HTTP allowed), modeled on Rei's
  `Rei.Infrastructure.WorkerHost` (`sideEffectReactorSpec`, `sideEffectProcessor`,
  `runKirokuWorkerHost`) — port the minimal slice into
  `kioku-core/src/Kioku/Infrastructure/WorkerHost.hs` if kioku does not already vendor it; kizashi
  has an equivalent host to cross-check.
- **codd + `Data.FileEmbed.embedDir`** — migration packaging, exactly as
  `/Users/shinzui/Keikaku/bokuno/kizashi/kizashi-migrations/src/Kizashi/Migrations.hs`.
- **hasql** (`Hasql.Statement`, `Hasql.Encoders`/`Decoders`, `Hasql.Transaction`) — the recall
  queries and the embedding upsert. The `vector` value crosses the boundary as a bracketed-float
  text literal cast `::vector` in SQL (no bespoke hasql vector codec needed).

**Modules and signatures that must exist at the end of each milestone (full paths).**

End of Milestone 1:

- `kioku-migrations/sql-migrations/<ts>-kioku-memory-embeddings.sql` (the migration above).
- `kioku-core/src/Kioku/Recall/Capability.hs`:
  - `data VectorCapability = VectorAvailable | VectorAbsent`
  - `detectVectorCapability :: (Hasql :> es, Error SessionError :> es) => Eff es VectorCapability`

End of Milestone 2:

- `kioku-core/src/Kioku/Memory/Embedding.hs`:
  - `data EmbedError = EmbedTransport !Text | EmbedEmpty`
  - `embedWithRetry :: EmbeddingModel -> Int -> Text -> IO (Either EmbedError (Vector Double))`
  - `embedBatched :: EmbeddingModel -> Int -> [Text] -> IO [Either EmbedError (Vector Double)]`
- `kioku-core/src/Kioku/Memory/Embedding/Worker.hs`:
  - the side-effect worker spec value (gated on the memory context, subscription name
    `"kioku-memory-embedding"`)
  - `backfillMissingEmbeddings :: (Hasql :> es, Error SessionError :> es, IOE :> es) =>
    EmbeddingModel -> Eff es Int`
- `kioku-core/src/Kioku/Infrastructure/WorkerHost.hs` (only if not vendored by EP-1): the ported
  `sideEffectReactorSpec` / `sideEffectProcessor` / `runKirokuWorkerHost` slice.
- kioku-cli: the `kioku worker [--backfill] [--model <id>]` command.

End of Milestone 3:

- `kioku-core/src/Kioku/Recall.hs` (replacing EP-1's placeholder body; same module per
  MasterPlan IP-1):
  - `data RecallStrategy = Keyword | Embedding | Hybrid`
  - `data RecallRequest = RecallRequest { scope :: MemoryScope, query :: Text,
    strategy :: RecallStrategy, maxResults :: Int }`
  - `data RecallHit = RecallHit { memory :: MemoryRecord, score :: Double,
    ftsRank :: Maybe Int, vecRank :: Maybe Int }`
  - `recall :: (Hasql :> es, Error SessionError :> es, IOE :> es) =>
    EmbeddingModel -> VectorCapability -> RecallRequest -> Eff es [RecallHit]`
  - the pure helpers `rrf`, `recencyDecay`, `priorityWeight`, `confidenceWeight`, and the named
    weight/budget constants (`k = 60`, `wRecency = 0.10`, `wPriority = 0.15`,
    `wConfidence = 0.05`, `candidatePoolSize = 50`, `defaultMaxResults = 8`,
    `perMemoryCharCap = 2000`, `totalCharCap = 12000`, `halfLifeDays = 30`).
- kioku-cli: the `kioku recall "<query>" --scope <scope> [--strategy …] [--limit …]
  [--show-scores]` command, with `--scope` parsing `namespace[:kind:id]` into `MemoryScope`.

**Dependencies on prior work.** This plan hard-depends on EP-1
(`docs/plans/1-kioku-scaffold-and-core-extraction.md`) for the `kioku_memories` table (incl.
the `content_tsv` FTS column and GIN index), the inline projection, the `Kioku.Memory` write API,
the placeholder `Kioku.Recall`, the `MemoryScope`/`MemoryRecord` types in `kioku-api`, and the
`kioku-migrations` package. It extends — never re-defines — EP-1's `Kioku.Recall` and
`kioku_memories` table. The exact EP-1 column names and the priority always-inject sentinel
representation are an EP-1↔EP-2 contract; if they differ from the names used here, reconcile in
the Decision Log and adjust the SQL accordingly.


## Revision History

- 2026-06-24 — Initial authoring of the full plan from the skeleton. Filled every prose section
  and seeded the Progress checklist. Frontmatter left untouched. Grounded against: MasterPlan
  #17 (IP-1/IP-3/IP-4 and Decision Log — embeddings async, FTS inline); the ExecPlan spec
  (`/.claude/skills/exec-plan/PLANS.md`); EP-1 (`docs/plans/1-…`) for the table/projection/
  placeholder surface; `Baikai.Embedding` and the OpenAI embeddings SDK for the client shape;
  Rei's `WorkerHost.hs` + `GitSyncEnqueueProjection.hs` + `AgentMemory/Reactor/
  FilesystemProjection.hs` for the async/side-effect worker pattern; keiro's
  `Keiro.Projection.AsyncProjection`; and kizashi's `Migrations.hs` + read-model SQL for the
  migration/`kiroku`-schema conventions. Reason: convert the binding MasterPlan integration
  points into a self-contained, novice-followable execution plan for hybrid retrieval.


## Coding Conventions (haskell-jitsurei)

All Haskell in this plan follows the binding conventions in
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/` (the `shinzui/haskell-jitsurei` cookbook —
browse with `mori registry docs haskell-jitsurei`), as mandated by MasterPlan #1 Integration
Point IP-7. The rules that bear on this plan:

- **Core standards** (`core/standards.md`): GHC 9.12+ with the `GHC2024` language edition; a
  `common common` cabal stanza enabling `DeriveAnyClass`, `DuplicateRecordFields`,
  `OverloadedLabels`, `OverloadedStrings`, plus `MultilineStrings` for embedded SQL, with every
  library/exe/test stanza doing `import: common`; postpositive `qualified` imports
  (`import Data.Text qualified as Text`, never `import qualified`).
- **Custom prelude** (`core/custom-prelude.md`): a project prelude (`Kioku.Prelude` for kioku)
  re-exports the common surface + `Control.Lens` behind a per-file `{-# LANGUAGE PackageImports #-}`
  pragma. It **must NOT re-export `Data.Generics.Labels`** — that orphan `IsLabel` instance
  collides with the **keiki DSL**'s own `#label` overloading that kioku's transducers rely on.
  Modules that need generic-lens `#label` import `"generic-lens" Data.Generics.Labels ()`
  per-module; keiki-DSL modules use the keiki instance instead. The shared `eventAesonOptions`
  lives in the prelude.
- **Record patterns** (`core/record-patterns.md`): no field prefixes, strict `!` fields,
  entity-ID-first on event/command records, explicit `deriving stock`/`anyclass`/`newtype`
  strategies, and lens operators (`^.`, `.~`, `?~`, `%~`, `at`, `ix`) over record-update syntax.
- **Multiline strings** (`core/multiline-strings.md`): embedded SQL uses `MultilineStrings`
  (`"""…"""`), not `unlines` or string concatenation.
- **Plan-specific:** the M1 migration, the embedding upsert, and the RRF/recall SQL all use
  `MultilineStrings`; the `EmbeddingConfig`/`EmbedError` records follow the record-pattern rules
  (strict fields, explicit deriving).
