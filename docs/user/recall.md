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
   [Degradation](#degradation-when-pgvector-is-missing)).
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
     abandons the index for a sequential scan. The vector channel runs in two passes; see
     [The vector channel's two passes](#the-vector-channels-two-passes).
   Both queries filter `status = 'active'`, the request `namespace`, and — for entity scopes —
   the exact `scope_kind`/`scope_ref`.
4. **Fuse.** The two candidate lists are merged by memory id; each memory keeps its FTS rank
   and/or its vector rank.
5. **Score & sort.** Each fused candidate gets a blended score (below); results are sorted
   descending.
6. **Trim.** The top `maxResults` are taken, then a character budget is applied.

## The vector channel's two passes

The vector half of a hybrid recall can quietly return **nothing**, and this section explains when,
why, and what kioku does about it — including what it still does not fix.

**The hazard.** The HNSW index that makes vector search fast covers the embedding column and
nothing else. It picks its candidates by distance alone, and the `namespace`, scope, and
`status = 'active'` predicates are applied *afterwards*, to rows it has already chosen. So when the
memories nearest your query happen to sit outside the scope you asked about — a small scope inside a
large namespace, which is the normal shape of kioku data — the index can spend its entire search
budget on rows the filter then throws away, and the vector channel comes back empty. This is called
*filtered-ANN starvation*, and it is a property of approximate search under a filter, not a bug in
any one query.

It used to be invisible. Recall fuses its two channels by rank, so a vector channel that returns
zero rows contributes zero ranks and the blended score decays smoothly into pure keyword scoring:
no error, no warning, and nothing in the result recording that the semantic half of your "hybrid"
search vanished. You got plausible keyword results and had no way to tell.

**What kioku does.** The vector channel now runs in two passes:

1. The **approximate pass** is the HNSW scan, with `hnsw.ef_search` set to the candidate pool size
   so the pool actually fills. This is the fast path and it is what runs on almost every recall.
2. If the approximate pass comes back with fewer candidates than the pool, kioku runs an **exact
   pass**: the same query, but with the scope filter applied *before* the ranking rather than after
   it, so it cannot starve. Its results are authoritative.

The second pass only runs when the first came back short, so a healthy recall pays nothing for it.
When it does run, it scans every embedded memory in the scope you asked about — roughly 7ms per 2000
embedded rows, growing linearly. That is the price of a correct answer, and it is bounded by the
size of the scope you asked about, which is the set you wanted searched anyway.

**What this does not fix.** Three things, stated plainly:

- **A very large scope that also starves is slow, not wrong.** If a scope holds tens of thousands of
  embedded memories *and* the approximate pass starves on it, the exact pass will run and take tens
  of milliseconds. You get the right answer; you wait longer for it. If that matters for your
  workload, make the scope more selective.
- **The approximate pass can still return a *misleading* pool rather than a short one.** The
  fallback triggers on the pool coming back short. If the approximate scan returns a full pool of 50
  in-scope-but-mediocre matches while better ones existed, nothing detects that. In practice a
  filter selective enough to hide good matches is also selective enough to shorten the pool, but
  this is a genuine gap rather than a proof.
- **Ordering within the returned candidates is the approximate pass's ordering** when the fallback
  does not fire. That is the normal, intended behaviour of approximate search.
- **For a global scope, "the scope you asked about" is the whole namespace.** Recall's scope filter
  vanishes for a global scope (see [Global scope](#global-scope-namespace-wide-recall-vs-exact-scope-reads)),
  so if the approximate pass starves — which it still can, since the `namespace` and `status`
  predicates are *also* applied after the index picks — the exact pass scans every embedded row in
  the namespace.

**Seeing it.** `Kioku.Recall.selectVectorCandidatesDiagnosed` returns a `VectorChannelOutcome`
alongside the rows, recording how many candidates the approximate pass produced, whether the exact
fallback fired, and how many rows were finally returned. `vectorChannelStarved` is true when the
fallback found rows the approximate pass had missed. A host that wants a metric or a log line for
the health of its semantic channel should count those; kioku does not emit one itself, because
`Kioku.Recall` has no access to the host's tracer or metrics handle.

**`--show-scores` does not show it.** `Kioku.Recall.recall` — which is what the CLI calls — uses the
undiagnosed wrapper and discards the `VectorChannelOutcome`; a `RecallHit` carries only `score`,
`ftsRank`, and `vecRank`. So a `vec=-` in `--show-scores` means only "this hit was not in the vector
pool"; it is **not** a starvation signal, and no CLI flag reports one. Observability here is a
*library* affordance: call `selectVectorCandidatesDiagnosed` yourself if you want the metric.

**A note for anyone tempted by `hnsw.iterative_scan`.** pgvector 0.8 ships its own remedy for
starvation, and kioku does not use it. It was measured across five freshly built indexes on a
20000-row starving corpus and returned the right answer 2 times in 5 (`relaxed_order`) and 4 times
in 5 (`strict_order`). HNSW graph construction is randomized, so it is a lottery: it would pass any
single test run and starve at random in production. Do not reach for it again without a sample size.

## Global scope: namespace-wide recall vs exact-scope reads

The same `ScopeGlobal ns` value means **two different things** depending on which API you
hand it to. This is intentional, and it is the single most surprising thing about scopes, so
it is worth stating plainly:

| You call | `ScopeGlobal ns` means | You get |
|---|---|---|
| **Recall** — `recall`, and the CLI's `kioku recall --scope ns` | *no scope filter* | every active memory in the namespace, **entity-scoped rows included** |
| **Scoped reads** — `getActiveByScope`, `getGlobal`, scene and persona lookups | *the global bucket* | only rows recorded with **no** entity scope |

In one line: **recall searches namespace-wide for a global scope; scoped reads are
exact-scope.**

So a memory recorded under `mori:repo:web` **is** returned by `recall` with scope `mori`,
but is **not** returned by `getGlobal (Namespace "mori")`. Neither is a bug.

The reason they differ is that they want opposite things. Search wants the largest plausible
candidate surface — narrowing it to the global bucket would make a namespace-level query miss
almost everything the namespace knows. Reads want exact buckets — a caller asking for "the
global memories of `mori`" is asking for a specific set of rows, not for everything.

If you want the read-side equivalent of recall's breadth, use **`getActiveInNamespace`**,
which returns every active row in the namespace regardless of scope.

Concretely, recall's scope predicate is

```sql
(($3 IS NULL AND $4 IS NULL) OR (scope_kind = $3 AND scope_ref = $4))
```

— for a global scope both parameters are NULL, so the first disjunct is always true and the
scope filter vanishes. The scoped reads instead *require* the columns to be NULL.

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

- **Per-memory cap:** 2000 characters. Longer content is cut to 1997 characters plus a trailing
  `...` (three ASCII periods, not `…`), so the marker is spent from the cap rather than added to it.
- **Total cap:** 12000 characters across all returned hits. Hits are added until the next one
  would exceed the total; the rest are dropped.

This means a high `--limit` does not necessarily return that many hits — the character budget can
cut the list short. The budget is applied *after* ranking, so you always get the most relevant
memories first.

## Degradation when pgvector is missing

kioku detects one of four vector capabilities at runtime:

| Capability                    | Recall behavior                                            |
|-------------------------------|------------------------------------------------------------|
| **available**                 | Full hybrid: FTS + vector + RRF.                          |
| **extension unavailable**     | Keyword-only. `embedding`/`hybrid` silently become FTS.   |
| **columns unavailable**       | Keyword-only (the embedding column/index isn't present).  |
| **dimension mismatch**        | Keyword-only. `KIOKU_EMBEDDING_DIMENSIONS` disagrees with the declared width of the `embedding` column. |

In the keyword fallback the `vec` rank shows as `-` in `--show-scores` output, and the
embedding/distillation workers skip vector work. Recall keeps working — it just loses the
semantic channel.

A **dimension mismatch** is a *configuration* error rather than a missing feature, and the rest of
the system is louder about it than recall is: `kioku worker` prints
`embedding dimension mismatch: KIOKU_EMBEDDING_DIMENSIONS=N but kiroku.kioku_memories.embedding is
vector(M)` to stderr and runs distillation timers only, and `kioku worker --backfill` refuses to
start rather than embed every memory into a cast that must fail. Recall itself degrades quietly.
Fix the environment variable, or migrate the column — see
[Configuration](configuration.md#embeddings).

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
[Library API](library-api.md#recall-kiokurecall).
