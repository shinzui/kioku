---
title: "Starvation-resistant vector recall with channel diagnostics"
type: Capability
description: "Detect when a filtered approximate-nearest-neighbour pass has been starved by a selective scope and re-run it exactly, so the semantic half of a hybrid search cannot silently vanish, and expose the per-call outcome a host can turn into a health metric."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-6
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-core
interface:
  - Kioku.Recall
requires:
  - CAP-5
  - CAP-7
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/RecallSqlSpec.hs
    proves: "The vector channel does not starve on a selective scope, nor on an exact entity scope inside a busy namespace, while a healthy scope never pays for the exact fallback."
  - kind: module
    resource: kioku-core/test/Kioku/RecallHarness.hs
    proves: "The reproducible corpus geometry the starvation cases are measured against, including that the harness seeds what it claims and that the captured plan describes the query measured."
  - kind: guide
    resource: docs/user/recall.md
    proves: "Why filtered ANN starves, what the two passes cost, the three things this does not fix, and why hnsw.iterative_scan was measured and rejected."
  - kind: module
    resource: kioku-core/src/Kioku/Recall.hs
    proves: "selectVectorCandidatesDiagnosed, VectorChannelOutcome, vectorChannelStarved, and the resolveRecall constructor that binds a query to one authorized space."
---

# Starvation-resistant vector recall with channel diagnostics

The HNSW index that makes vector search fast over
[the worker's embeddings (CAP-7)](embedding-worker-and-degradation.md) covers the embedding
column and nothing else. It picks candidates by distance alone, and the space, namespace, scope, and
`status = 'active'` predicates are applied *afterwards*, to rows it already chose. So
when the memories nearest a query sit outside the scope asked about — a small scope
inside a large namespace, the normal shape of Kioku data — the index can spend its whole
budget on rows the filter then discards, and the vector channel returns nothing. This is
filtered-ANN starvation: a property of approximate search under a filter, not a bug in
one query.

It used to be invisible. [Recall (CAP-5)](hybrid-recall-with-explicit-targets.md) fuses
by rank, so a channel returning zero rows contributes zero ranks and the blended score
decays smoothly into pure keyword scoring — no error, no warning, and nothing in the
result recording that the semantic half of a "hybrid" search vanished.

The vector channel therefore runs in **two passes**. The approximate pass is the HNSW
scan with `hnsw.ef_search` raised to the candidate pool size, because pgvector's default
of 40 sits below the pool of 50 and under-filled it by 20%. If that pass returns fewer
rows than the pool, an **exact pass** re-runs the query with the scope filter applied
ahead of the ranking, so it cannot starve; its results are authoritative. The exact pass
scans every embedded memory in the requested scope — roughly 7ms per 2000 embedded rows
in the benchmark this was built against, growing linearly, and bounded by the set you
asked to search.

`selectVectorCandidatesDiagnosed` returns the outcome alongside the rows, and
`vectorChannelStarved` is true when the exact pass returned more rows than the
approximate one.

## Shape

```haskell
data VectorChannelOutcome = VectorChannelOutcome
  { annRows :: Int, exactFallbackFired :: Bool, rowsReturned :: Int }

Right resolved <- pure (resolveRecall space query)
(outcome, rows) <- selectVectorCandidatesDiagnosed resolved queryVector
when (vectorChannelStarved outcome) (hostMetric "kioku.recall.vector_starved")
```

## Limits

- `exactFallbackFired` alone is **not** a starvation diagnosis. The second pass also runs
  for any ordinary scope holding fewer than 50 eligible embedded memories.
- The fallback triggers on a *short* pool, not a misleading one. If the approximate scan
  returns a full 50 in-scope-but-mediocre matches while better ones existed, nothing
  detects it. A filter selective enough to hide good matches is usually selective enough
  to shorten the pool, but that is practice, not a proof.
- A very large scope that also starves is slow, not wrong: the exact pass runs and takes
  longer. Make the scope more selective if that matters.
- Kioku emits **no metric of its own** — `Kioku.Recall` has no access to the host's
  tracer — and no CLI flag reports starvation. `--show-scores` shows `vec=-` for a hit
  that was not in the vector pool, which is a different fact.
- pgvector 0.8's own `hnsw.iterative_scan` is deliberately unused: measured across five
  freshly built indexes on a 20000-row starving corpus it returned the right answer 2
  times in 5 (`relaxed_order`) and 4 in 5 (`strict_order`).
