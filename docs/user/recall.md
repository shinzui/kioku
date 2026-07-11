# Recall & Hybrid Retrieval

Recall finds the active memories most relevant to a query **within a scope**. This page explains
the strategies, the fusion and scoring model, and the degradation behavior when `pgvector` is
unavailable.

## Strategies

A recall request carries a `scope`, a `query`, a `strategy`, and a `maxResults`. There are three
strategies:

| Strategy    | Full-text (FTS) | Vector (pgvector) | Needs query embedding |
|-------------|-----------------|-------------------|-----------------------|
| `keyword`   | ✔               | ✗                 | no                    |
| `embedding` | ✗               | ✔                 | yes                   |
| `hybrid`    | ✔               | ✔                 | yes                   |

`hybrid` is the default and what you almost always want. `keyword` is fast and needs no
embedding endpoint. `embedding` is pure semantic similarity.

## What happens during a hybrid recall

1. **Plan.** kioku inspects the runtime **vector capability**. If pgvector is unavailable, the
   plan is rewritten to keyword-only regardless of the requested strategy (see
   [Degradation](#degradation)).
2. **Embed the query** (if the plan needs it). The query is embedded via the configured
   embedding endpoint, with retries. If embedding fails, recall falls back to keyword-only for
   that request rather than erroring.
3. **Candidate selection.** Up to 50 candidates are pulled from each active channel, scoped to
   the request:
   - **FTS:** `content_tsv @@ websearch_to_tsquery('english', query)`, ordered by `ts_rank`
     then recency.
   - **Vector:** ordered by cosine distance (`embedding <=> queryVector`) — and by nothing
     else — over rows where `embedding IS NOT NULL`. An HNSW index can only produce the
     distance ordering, so any second sort key leaves the planner to make up the difference,
     and where it cannot (PostgreSQL before 13, or an incremental sort it declines) it
     abandons the index for a sequential scan.
   Both queries filter `status = 'active'`, the request `namespace`, and — for entity scopes —
   the exact `scope_kind`/`scope_ref`.
4. **Fuse.** The two candidate lists are merged by memory id; each memory keeps its FTS rank
   and/or its vector rank.
5. **Score & sort.** Each fused candidate gets a blended score (below); results are sorted
   descending.
6. **Trim.** The top `maxResults` are taken, then a character budget is applied.

## Scoring model

The blended score for a memory combines its two reciprocal-rank-fusion (RRF) terms with three
signal weights:

```text
score =  rrf(ftsRank)
       + rrf(vecRank)
       + 0.10 · recencyDecay(createdAt)
       + 0.15 · priorityWeight(priority)
       + 0.05 · confidenceWeight(confidence)
```

where:

- **RRF term:** `rrf(rank) = 1 / (60 + rank)`. A memory absent from a channel contributes `0`
  for that channel. The constant `60` is the standard RRF dampening `k`.
- **Recency decay:** exponential with a **30-day half-life** —
  `exp(-ln2 · ageDays / 30)`. A memory recorded today scores ~1.0; 30 days old ~0.5.
- **Priority weight:** `priority ≤ 0` ("always inject") → `1`. Otherwise
  `clamp01(1 − priority/100)`, so lower numeric priority = higher weight.
- **Confidence weight:** `high → 1.0`, `medium → 0.6`, `low → 0.3`.

Because RRF terms are small (≈0.016 at rank 1) while the signal weights are scaled down to match,
the result is a fusion dominated by *appearing high in either channel*, gently re-ordered by how
recent, important, and trusted each memory is.

> The weights and constants (RRF `k`, half-life, signal weights, candidate pool size) are
> internal tuning constants in `Kioku.Recall`. They are not currently exposed as configuration.

## Character budgets

After ranking, kioku enforces two budgets so recall output fits into an agent's context window:

- **Per-memory cap:** 2000 characters. Longer content is truncated with an `…` ellipsis.
- **Total cap:** 12000 characters across all returned hits. Hits are added until the next one
  would exceed the total; the rest are dropped.

This means a high `--limit` does not necessarily return that many hits — the character budget can
cut the list short. The budget is applied *after* ranking, so you always get the most relevant
memories first.

## Degradation when pgvector is missing

kioku detects one of three vector capabilities at runtime:

| Capability                    | Recall behavior                                            |
|-------------------------------|------------------------------------------------------------|
| **available**                 | Full hybrid: FTS + vector + RRF.                          |
| **extension unavailable**     | Keyword-only. `embedding`/`hybrid` silently become FTS.   |
| **columns unavailable**       | Keyword-only (the embedding column/index isn't present).  |

In the keyword fallback the `vec` rank shows as `-` in `--show-scores` output, and the
embedding/distillation workers skip vector work. Recall keeps working — it just loses the
semantic channel.

### Healing a degraded schema

The embedding columns are added by a migration that only runs its DDL if `CREATE EXTENSION
vector` succeeds. If your server had no pgvector at that moment, the migration was still
**recorded as applied** — so installing pgvector afterwards does not, on its own, bring the
columns back. The database stays keyword-only forever.

`2026-07-11-17-45-43-kioku-embedding-schema-heal.sql` is the catch-up: it re-attempts the
same DDL, so **any database that gains pgvector before its next migration run heals itself
on `just migrate`.** It is idempotent — a no-op on a healthy database and on one that still
has no pgvector.

For a database that has *already applied* every migration and only then gained the
extension, codd will not re-run anything. Apply the same file by hand; it is the identical
SQL, so it cannot drift from the migration:

```bash
psql -d "$PGDATABASE" -f kioku-migrations/sql-migrations/2026-07-11-17-45-43-kioku-embedding-schema-heal.sql
```

Then confirm:

```bash
psql -tAc "SELECT format_type(atttypid, atttypmod) FROM pg_attribute a
             JOIN pg_class c ON c.oid = a.attrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'kiroku' AND c.relname = 'kioku_memories'
              AND attname = 'embedding'"
# kiroku.vector(1536)
```

**Which schema pgvector lives in matters.** kioku connects with `search_path = kiroku,
pg_catalog`, and recall casts query vectors with a bare `$1::vector`. If the extension was
installed into `public` — the usual operator default — that cast cannot resolve the type,
and recall degrades to keyword-only even though the columns look perfectly healthy. The heal
migration creates the extension into `kiroku` when it is absent, and raises a `WARNING`
naming the schema when it finds it elsewhere. To fix an existing `public` install, either
move it:

```sql
ALTER EXTENSION vector SET SCHEMA kiroku;
```

or add `public` to the store's `extraSearchPath` when constructing the connection settings.

## CLI usage

```bash
# Hybrid (default)
kioku recall "how should I format commits" --scope mori:repo:web

# See the component ranks and fused score
kioku recall "commit style" --scope mori:repo:web --show-scores

# Keyword-only (no embedding endpoint needed)
kioku recall "release script" --scope mori:repo:web --strategy keyword
```

See the [CLI Reference](cli-reference.md#kioku-recall) for all flags.

## Library usage

`Kioku.Recall.recall` runs a request; the scope-scan helpers (`getActiveByScope`,
`getActiveInNamespace`, `getGlobal`, `getById`, `getBySession`, `getByType`) fetch active
memories without ranking when you just want everything in a scope. See
[Library API](library-api.md#recall).
