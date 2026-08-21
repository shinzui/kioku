# Recall & Hybrid Retrieval

Recall finds the active memories most relevant to a query **within a target**. This page explains
what a target is, the strategies, the fusion and scoring model, and the degradation behavior when
`pgvector` is unavailable.

## What a recall call targets

A recall call names two separate things, and keeping them separate is the point:

- The **target** says *what to search*. It is either one exact scope or every scope in one
  namespace, and it comes from you.
- The **memory space** says *whose memories those are*. It comes from the
  `MemoryAccessContext` that authorized the call, and nothing in the request can change it.

Widening a target — from one scope to a whole namespace — therefore never widens the tenancy. See
[Namespace organizes memory; memory space isolates it](../adr/namespace-is-not-a-security-boundary.md).

There are three targets:

| Target                            | What it searches                                             |
|-----------------------------------|--------------------------------------------------------------|
| `ExactScope (ScopeGlobal ns)`     | the **global bucket** of `ns`: rows recorded with no entity scope |
| `ExactScope (ScopeEntity ns k r)` | that entity scope and no other                                |
| `NamespaceWide ns`                | every scope in `ns`, the global bucket and entity scopes alike |

```haskell
data RecallTarget
  = ExactScope MemoryScope
  | NamespaceWide Namespace
```

On the wire each is a tagged object with a required discriminator, so no meaning is ever carried
by a missing field:

```json
{"kind": "exact_global",   "namespace": "mori"}
{"kind": "exact_entity",   "namespace": "mori", "scope_kind": "repo", "scope_ref": "shinzui/kikan"}
{"kind": "namespace_wide", "namespace": "mori"}
```

Decoding refuses an unknown `kind`, and refuses a variant carrying a field it has no meaning for
(an `exact_global` with a `scope_kind`, say).

### Migrating from `RecallRequest`

Before targets were explicit, a recall request carried a bare `MemoryScope`, and `ScopeGlobal ns`
meant *namespace-wide* to recall while the same value meant *the global bucket* to
`getActiveByScope`. That asymmetry is gone from the new API and preserved exactly in the
deprecated one.

| You have today                       | You want the same rows | You want the exact global bucket |
|--------------------------------------|------------------------|----------------------------------|
| `RecallRequest { scope = ScopeGlobal ns }`     | `NamespaceWide ns`     | `ExactScope (ScopeGlobal ns)`    |
| `RecallRequest { scope = ScopeEntity ns k r }` | `ExactScope (ScopeEntity ns k r)` | — (already exact)     |

`legacyRecallTarget :: MemoryScope -> RecallTarget` performs the left-hand mapping, so a
mechanical migration is one call per site:

```haskell
-- before
recall model capability
  RecallRequest {memorySpaceId = space, scope, query, strategy, maxResults = 8}

-- after: same rows, and the space now comes from the context rather than the request
case mkRecallQuery (legacyRecallTarget scope) query strategy 8 of
  Left invalidLimit -> ...
  Right request     -> recall model capability context request
```

`mkRecallQuery` validates the result count, which is now a `RecallLimit` bounded to **1–100**
rather than a bare `Int`. Zero silently returned nothing before; 100 is the most a fused result
set can hold, because each channel contributes at most 50 candidates.

`legacyRecall` runs an unmigrated `RecallRequest` unchanged. It is **deprecated**, so an
unmigrated call site is a compiler warning rather than a surprise in production.

> **Removal window.** The deprecated `RecallRequest`/`legacyRecall` pair survives for at least one
> released version, and is deleted only in a later PVP-breaking release, and only once every known
> dependent compiles against `RecallTarget`. See
> [An explicit recall target replaces the overloaded scope](../adr/an-explicit-recall-target-replaces-the-overloaded-scope.md)
> for the exact conditions.

All three targets execute. `ExactScope (ScopeGlobal ns)` was refused for one release, because the
candidate SQL then read NULL scope columns as *no scope filter* and the only rows it could have
reached were the namespace-wide ones; each target now compiles to its own statement, so it returns
the global bucket and nothing else. See
[Each recall target gets its own statement](../adr/each-recall-target-gets-its-own-statement.md).

### Known dependents

`mori registry dependents shinzui/kioku --packages` reports two:
`mori://shinzui/shikigami`, which links `kioku-core` directly, and `mori://shinzui/kikan`, the
umbrella portfolio. Shikigami is the compile check the removal window waits on, and its migration
is mechanical: `Shikigami.Memory.Scope.agentScope` builds a `ScopeEntity`, so
`legacyRecallTarget` maps it to `ExactScope` and it returns exactly the rows it returns today. It
has no namespace-wide recall to preserve — `sharedScope`, the one `ScopeGlobal` value in that
repository, is defined but never recalled against.

Shikigami is behind by more than a target, though: it still calls `recall` without a
`MemoryAccessContext` and builds a `RecallRequest` with no `memorySpaceId`, both of which changed
when memory spaces landed. Migrate it in its own repository, through its own process; see
[Upgrading to memory spaces](upgrading-to-memory-spaces.md) for that half.

## Strategies

A recall request carries a `target`, a `query`, a `strategy`, and a `maxResults`. There are three
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
     then recency. When `btree_gin` is available, the partial
     `kioku_memories_space_namespace_tsv_idx` GIN carries `memory_space_id`, `namespace`, and
     `content_tsv` together, so matching content owned by other spaces never enters the bitmap.
   - **Vector:** ordered by cosine distance (`embedding <=> queryVector`) — and by nothing
     else — over rows where `embedding IS NOT NULL`. An HNSW index can only produce the
     distance ordering, so any second sort key leaves the planner to make up the difference,
     and where it cannot (PostgreSQL before 13, or an incremental sort it declines) it
     abandons the index for a sequential scan. The vector channel runs in two passes; see
     [The vector channel's two passes](#the-vector-channels-two-passes).
   Both queries filter `status = 'active'`, the authorized `memory_space_id`, and the target's
   `namespace`, and then add the target's own scope clause — see
   [How a target reaches SQL](#how-a-target-reaches-sql).
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
   so the index can fill the pool.
2. If the approximate pass comes back with fewer candidates than the pool, kioku runs an **exact
   pass**: the same query, but with the scope filter applied *before* the ranking rather than after
   it, so it cannot starve. Its results are authoritative.

The second pass runs whenever the first returns fewer than 50 rows. That includes ordinary scopes
containing fewer than 50 eligible embedded memories, so `exactFallbackFired` by itself is **not** a
starvation diagnosis. When the pass runs, it scans every embedded memory in the requested scope —
roughly 7ms per 2000 embedded rows in the benchmark used for this implementation, growing linearly.
That is the price of a correct answer, and it is bounded by the set you asked to search.

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
- **For a namespace-wide target, "the scope you asked about" is the whole namespace.** The
  namespace-wide statement carries no scope clause (see
  [How a target reaches SQL](#how-a-target-reaches-sql)), so if the approximate pass starves —
  which it still can, since the `memory_space_id`, `namespace` and `status` predicates are *also*
  applied after the index picks — the exact pass scans every embedded row in the namespace.

**Seeing it.** `Kioku.Recall.selectVectorCandidatesDiagnosed` returns a `VectorChannelOutcome`
alongside the rows, recording how many candidates the approximate pass produced, whether the exact
fallback fired, and how many rows were finally returned. `vectorChannelStarved` is true when the
exact pass returns more rows than the approximate pass. A host that wants a metric or a log line
for the health of its semantic channel should count those; kioku does not emit one itself, because
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

## Recall targets vs scoped reads

Recall and the unranked scope scans are separate vocabularies, and each says plainly which set of
rows it means:

| You call | You get |
|---|---|
| `recall` with `NamespaceWide ns` | every active memory in the namespace, **entity-scoped rows included** |
| `recall` with `ExactScope scope` | only rows carrying exactly that scope |
| `getActiveByScope`, `getGlobal`, scene and persona lookups | only rows carrying exactly that scope |
| `getActiveInNamespace` | every active row in the namespace, the unranked equivalent of `NamespaceWide` |

So a memory recorded under `mori:repo:proj_01h4...` **is** returned by `recall` with
`NamespaceWide (Namespace "mori")`, and is **not** returned by `getGlobal (Namespace "mori")`.
They are now different words for different things.

They want opposite defaults, which is why both exist. Search wants the largest plausible candidate
surface — narrowing a namespace-level query to the global bucket would make it miss almost
everything the namespace knows. Reads want exact buckets — a caller asking for "the global
memories of `mori`" is asking for a specific set of rows.

**Before `RecallTarget`, one value carried both meanings.** A `ScopeGlobal ns` handed to `recall`
meant "no scope filter" and the same value handed to `getActiveByScope` meant "the global bucket".
Both behaviours were wanted; the defect was that the type could not tell you which one you were
getting. `legacyRecall` preserves the old reading exactly — see
[Migrating from `RecallRequest`](#migrating-from-recallrequest).

### How a target reaches SQL

Each target compiles to its own statement, and the difference between them is a whole SQL clause
rather than a parameter value. Every statement starts from the same bound — `status = 'active'`,
`memory_space_id = $2`, `namespace = $3` — and then adds:

| Target                            | Scope clause                                       |
|-----------------------------------|----------------------------------------------------|
| `ExactScope (ScopeGlobal ns)`     | `AND scope_kind IS NULL AND scope_ref IS NULL`     |
| `ExactScope (ScopeEntity ns k r)` | `AND scope_kind = $4 AND scope_ref = $5`           |
| `NamespaceWide ns`                | *(none)*                                            |

There are nine statements in all: three channels — full text, the approximate vector pass, the
exact vector pass — times these three clauses. They are generated from one template per channel,
so the space, namespace and status predicates cannot drift apart between them.

**Why nine rather than three parameterised statements.** Recall used to carry one scope predicate,
`(($4 IS NULL AND $5 IS NULL) OR (scope_kind = $4 AND scope_ref = $5))`, in which passing NULL
silently dropped the scope filter. A caller who meant *the global bucket* and a caller who meant
*the whole namespace* then issued the identical query with the identical parameters — so the exact
global bucket could not be asked for at all, and no artifact anywhere could show a reviewer which
meaning a call had. Splitting the statements puts the difference in the statement's name and in
its query plan.

**All three are partition-led.** `memory_space_id` is the first mandatory predicate in every one.
For full-text recall, migration `0013-partition-aware-fts-index` prefers the active-only
`kioku_memories_space_namespace_tsv_idx` GIN on
`(memory_space_id, namespace, content_tsv)`. Its first two text columns require PostgreSQL's
`btree_gin` extension. The migration tries to install that extension, but treats it as an optional
performance capability: if the database role cannot install it, the migration succeeds and keeps
the historical content-only `kioku_memories_tsv_idx`. Results and space isolation are identical
on the fallback; the degraded path can enumerate matching content from unrelated spaces before
the heap filter removes it, so its cost can grow with the whole database.

The exact vector pass and unranked scope access continue to use
`kioku_memories_space_scope_idx` on `(memory_space_id, namespace, scope_kind, scope_ref)`: the two
exact bounds as four-column index conditions, the namespace-wide bound as a two-column prefix. A
B-tree takes `scope_kind IS NULL` as an index condition rather than as a filter, which is why the
exact global bucket needs no index of its own. To inspect the installed FTS path, run
`SELECT to_regclass('kioku.kioku_memories_space_namespace_tsv_idx');`; a NULL result means the
content-only fallback remains active.

The scoped reads (`getActiveByScope` and friends) *require* the scope columns to be NULL for a
global scope, which is the same set of rows `ExactScope (ScopeGlobal ns)` now returns — ranked
instead of unranked.

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

The relevance channels determine which memories enter the candidate set, but the metadata terms
can dominate the final ordering: the two best possible RRF terms total about `0.0328`, while
recency, priority, and confidence can contribute up to `0.30`. Priority `0` therefore gives the
maximum priority boost; its "always inject" label is a host convention and does **not** bypass
candidate selection or force a memory into the result.

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
| **columns unavailable**       | Keyword-only (one or more required embedding columns are absent). |
| **dimension mismatch**        | Keyword-only. `KIOKU_EMBEDDING_DIMENSIONS` disagrees with the declared width of the `embedding` column. |

In the keyword fallback the `vec` rank shows as `-` in `--show-scores` output, and the embedding
worker skips vector work. Distillation still runs, using FTS-only recall where applicable. Recall
keeps working — it just loses the semantic channel.

Capability detection verifies that the vector type can be resolved, that all four embedding
columns exist, and that the declared vector width matches the configured dimension. It does **not**
check for the HNSW index. A missing `kioku_memories_embedding_hnsw` index therefore does not cause
keyword fallback; vector recall remains correct but may use a much slower sequential scan.

A **dimension mismatch** is a *configuration* error rather than a missing feature, and the rest of
the system is louder about it than recall is: `kioku worker` prints
`embedding dimension mismatch: KIOKU_EMBEDDING_DIMENSIONS=N but kioku.memories.embedding is
vector(M)` to stderr and runs distillation timers only, and `kioku worker --backfill` refuses to
start rather than embed every memory into a cast that must fail. Recall itself degrades quietly.
Fix the environment variable, or migrate the column — see
[Configuration](configuration.md#embeddings).

### Healing a degraded schema

The original embedding migration only ran its DDL if `CREATE EXTENSION vector` succeeded. If your
server had no pgvector then, that migration was still recorded as applied, so installing pgvector
later does not by itself create the columns.

The catch-up migration `kioku/0009-kioku-embedding-schema-heal` (the checked-in file
`kioku-migrations/migrations/0009-kioku-embedding-schema-heal.sql`) re-attempts the DDL. If 0009 is
still pending when pgvector becomes available, the next `kioku-migrate up` or `just migrate` heals
the schema. It is idempotent: a no-op on a healthy database and on one that still has no pgvector.

For a database that has *already applied* every migration and only then gained the
extension, pg-migrate correctly treats the checksummed history as immutable and will not
re-run it. Apply the same checked-in file by hand:

```bash
psql "$PG_CONNECTION_STRING" --set=ON_ERROR_STOP=1 \
  --file=kioku-migrations/migrations/0009-kioku-embedding-schema-heal.sql
```

Then confirm:

```bash
psql "$PG_CONNECTION_STRING" -tAc "SELECT format_type(atttypid, atttypmod) FROM pg_attribute a
             JOIN pg_class c ON c.oid = a.attrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'kioku' AND c.relname = 'memories'
              AND attname = 'embedding'"
# kiroku.vector(1536)
```

**Which schema pgvector lives in matters, and it is not the schema the table is in.** kioku
names its own relations explicitly — `kioku.memories` — but it casts query vectors with a bare
`$1::vector`, which resolves through the connection's `search_path = kiroku, pg_catalog`. The
relocation of the projections into the `kioku` schema deliberately did not move the extension:
extensions are database-wide objects a host may share. So the two questions stay separate — where
the table is, and where the type resolves from. If the extension was
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

Each of the three targets has its own flag, and exactly one of them is required:

```bash
# One entity scope, exactly (hybrid is the default strategy)
kioku recall "how should I format commits" --scope mori:repo:proj_01h4...

# Only the rows recorded against `mori` itself, with no entity scope
kioku recall "how do we work here" --global-bucket mori

# Every scope in `mori`, the global bucket and every entity under it
kioku recall "how do we work here" --namespace-wide mori

# See the component ranks and fused score
kioku recall "commit style" --scope mori:repo:proj_01h4... --show-scores

# Keyword-only (no embedding endpoint needed)
kioku recall "release script" --scope mori:repo:proj_01h4... --strategy keyword
```

See the [CLI Reference](cli-reference.md#kioku-recall) for all flags.

**`--scope mori` no longer parses.** A bare namespace used to mean namespace-wide here — and the
global bucket in `kioku scenes --scope mori`, the same text and the opposite meaning. Rather than
quietly re-read it as the narrower one, the CLI refuses it and names both replacements:

```text
$ kioku recall "how do we work here" --scope mori
option --scope: a bare namespace is ambiguous for recall, so --scope will not accept one.
  --global-bucket mori   rows in mori recorded with no entity scope
  --namespace-wide mori  every scope in mori (what --scope mori returned before)
--scope takes a full NAMESPACE:KIND:REF entity scope.
```

Every run announces what it searched on stderr, so a widening is visible in a terminal while a
script reading stdout sees exactly the lines it saw before:

```text
kioku recall: searching every scope in mori, in memory space kioku_legacy
```

The memory space comes from `KIOKU_MEMORY_SPACE` (default `kioku_legacy`), never from the target
— see [Configuration](configuration.md).

## Library usage

`Kioku.Recall.recall` takes a `MemoryAccessContext` and a `RecallQuery`; the scope-scan helpers
(`getActiveByScope`, `getActiveInNamespace`, `getGlobal`, `getById`, `getBySession`, `getByType`)
take a `MemorySpaceId` and fetch active memories without ranking when you just want everything in
a scope. See [Library API](library-api.md#recall-kiokurecall).
