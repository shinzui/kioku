---
title: "Embedding worker, per-space backfill, and graceful vector degradation"
type: Capability
description: "Embed new memories through a subscription worker with a documented retry and dead-letter schedule, backfill missing or stale vectors across every space or one tenant, and detect at runtime when pgvector is unusable so recall falls back to keyword instead of failing."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-7
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-core
interface:
  - Kioku.Memory.Embedding
  - Kioku.Memory.Embedding.Worker
  - Kioku.Recall.Capability
  - Kioku.Worker.Failure
requires:
  - CAP-1
  - CAP-4
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/EmbeddingWorkerSpec.hs
    proves: "The worker skips only when the embedding exists and the content hash matches, backs off on the documented schedule, dead-letters an undecodable payload and an envelope naming another space, halts on a dimension mismatch, and bounds a one-space backfill to that space."
  - kind: test
    resource: kioku-core/test/Kioku/RecallSpec.hs
    proves: "The execution plan fails open to keyword when vectors are unavailable, and capability classification names the reason they are unusable."
  - kind: test
    resource: kioku-core/test/Kioku/RecallSqlSpec.hs
    proves: "A vector round-trip ranks the nearest embedding first and capability detection reads the canonical memories table's real column width."
  - kind: guide
    resource: docs/user/recall.md
    proves: "The four vector capabilities and what recall does under each, plus how to heal a database that gained pgvector after the embedding migration was recorded as applied."
  - kind: module
    resource: kioku-core/src/Kioku/Memory/Embedding/Worker.hs
    proves: "The worker environment, the event handler, the backfill entry point and its scope type, and the skip predicate."
---

# Embedding worker, per-space backfill, and graceful vector degradation

Semantic recall needs vectors, and vectors are produced out of band. The embedding
worker subscribes to the [memory event stream (CAP-1)](event-sourced-memory-records.md),
embeds new content, and writes the vector back alongside a content hash. A host runs it, or
hybrid [recall (CAP-5)](hybrid-recall-with-explicit-targets.md) quietly degrades to keyword.
Like every background component it discovers its own work, so it takes a
`MemoryContextProvider` rather than an [access context (CAP-4)](memory-space-isolation.md)
and reads the space from the delivered event; an envelope whose space disagrees with the memory row it names dead-letters
without writing.

`backfillMissingEmbeddings` fills gaps. It takes an `EmbeddingBackfillScope` —
`BackfillEverySpace` or `BackfillOneSpace` — so an operator can repair one tenant
without re-scanning the rest, and both the explicit and the startup backfill select only
active rows whose embedding is missing or whose stored content hash is stale. That
predicate runs in PostgreSQL, so a settled corpus sends no unchanged content to the
worker merely to skip it in Haskell.

`detectVectorCapability` classifies the runtime, and the classification is what makes
degradation predictable rather than mysterious:

| Capability | Recall behaviour |
|---|---|
| available | full hybrid |
| extension unavailable | keyword only |
| columns unavailable | keyword only, naming the missing columns |
| dimension mismatch | keyword only — a *configuration* error |

Detection takes the configured dimensions and **fails closed** on a mismatch. The rest of
the system is louder about that case than recall is: the continuous worker prints the
mismatch to stderr and runs timers only, and `--backfill` refuses to start rather than
embed every memory into a cast that must fail.

`Kioku.Worker.Failure` carries the classification a host's own loop needs —
`isTransientStoreError` and `embeddingRetryDelay` — and deliberately has no wildcard, so
a new upstream store constructor forces a decision rather than defaulting to permanent.

## Shape

```bash
kioku worker                              # embeddings + timers, supervised
kioku worker --backfill                   # every space, then exit
kioku worker --backfill --space space_prod
```

## Limits

- Failed embedding events retry at `5s, 20s, 60s, 180s` and dead-letter after five
  deliveries. That schedule is a constant, not configuration.
- The stored vector width is 1536. Changing the embedding model requires re-embedding the
  corpus: a model name change migrates no stored vector, and semantic recall, candidate
  lookup, and embedding writes all refuse a space that mixes vectors labelled with
  different models.
- Capability detection does **not** check for the HNSW index. A missing
  `kioku_memories_embedding_hnsw` leaves vector recall correct but potentially on a
  sequential scan.
- The `vector` type resolves through the connection's `search_path`, not through the
  schema the table lives in. An extension installed into `public` degrades recall to
  keyword even when the columns look healthy.
- On the default branch the embedding endpoint is configured through the versioned AI
  file of [host-owned AI execution (CAP-17)](host-owned-ai-execution.md); the released
  0.5.2.0 line still reads `KIOKU_EMBEDDING_*` environment variables.
