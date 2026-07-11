---
id: 18
slug: build-a-recall-quality-harness-that-reproduces-filtered-ann-starvation
title: "Build a recall-quality harness that reproduces filtered-ANN starvation"
kind: exec-plan
created_at: 2026-07-11T19:57:52Z
intention: "intention_01kwyhabypepdt1mwemmf0dvqa"
master_plan: "docs/masterplans/3-kioku-follow-up-scene-freshness-and-filtered-ann-recall-quality.md"
---

# Build a recall-quality harness that reproduces filtered-ANN starvation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

kioku's `recall` finds memories relevant to a query by running two searches and blending them: a
full-text search, and a **vector search** that compares the query's embedding to each memory's
embedding to find semantically similar ones. The vector half is what makes recall work when the
user's words do not literally appear in the memory.

That vector half can silently return **nothing**, and when it does, nobody finds out.

The reason is a mismatch between the index and the query. The index — an HNSW index, a graph
structure that approximately answers "which vectors are nearest this one?" — indexes the
embedding column and nothing else. But the query also filters by namespace, by scope, and by
`status = 'active'`. Postgres applies those filters **after** the index has already chosen its
candidates by distance alone. So if the nearest 50 vectors in the whole table happen to belong to
some *other* namespace, the filter throws away all 50 and the vector search returns zero rows.
This is **filtered-ANN starvation**, and the previous initiative reproduced it exactly: with 2000
memories in the target namespace and 2000 nearer "decoy" memories in another, the vector query
removed 1648 rows by filter and returned **zero**.

The reason nobody finds out is that recall fuses the two channels by *rank*. A vector channel
that returns zero rows contributes zero ranks, and the blended score degrades smoothly into pure
keyword scoring. No error. No warning. Nothing in the returned `RecallHit` records that the
semantic half of a "hybrid" search came back empty. The caller gets plausible-looking keyword
results and has no way to know that the feature they are paying for silently switched itself off.

**This plan does not fix that. It builds the instrument that can see it.** After this plan, the
test suite contains a harness that constructs a starving corpus on demand — you dial in how many
memories are in the target scope, how many decoys sit outside it, and how much *nearer* the
decoys are to the query — and then measures what the vector search actually returned: how many
rows, how many of the truly nearest in-scope memories it found (a score called *recall@k*), how
many rows the filter discarded, and which query plan Postgres chose. It also adds a regression
test that fails loudly when the vector channel starves, so this class of defect can never again
be invisible.

The fix itself is the next plan
(docs/plans/19-fix-filtered-ann-starvation-in-vector-recall.md), which is written entirely in
terms of this harness and cannot be verified without it. That is why this plan exists separately:
the previous initiative established, expensively and four times over, that a plan's confident
claim about a system its author never ran is a hypothesis. The remedy for starvation is genuinely
unknown — the obvious one was measured and found to make recall *worse* — so the honest first
move is to build the thing that can tell a remedy from a wish.

You can see this plan working by running the suite; the new starvation case reports a diagnosis
rather than a bare assertion failure:

```bash
nix develop --command cabal test kioku-core:test:kioku-test
```


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: New module `kioku-core/test/Kioku/RecallHarness.hs` with a corpus seeder (in-scope rows, out-of-scope decoys, tunable decoy nearness) and a deterministic vector generator with an exactly-predictable cosine distance. (2026-07-11, commit `6247cec`)
- [x] M1: Register `Kioku.RecallHarness` in the `kioku-test` stanza's `other-modules` in `kioku-core/kioku-core.cabal`. (2026-07-11)
- [x] M1: Prove the instrument — a test asserting the distances Postgres computes match the ones the harness predicted, and that every decoy really is nearer than every in-scope row. Landed as "the harness seeds the geometry it claims". (2026-07-11)
- [x] M2: `EXPLAIN (ANALYZE, BUFFERS)` capture for the vector candidate query as it is actually issued. (2026-07-11, commit `d61791c`)
- [x] M2: A quality metric over the seeded ground truth — rows returned, recall@k, rows removed by filter — packaged as `measureRecallQuality`. (2026-07-11)
- [x] M2: **Added, not in the original plan** — a plan/query agreement self-check (`planAgreesWithQuery`), after the first EXPLAIN capture was found to describe a different query than the one under test. See Surprises; this is the most important thing M2 produced. (2026-07-11)
- [x] M3: A starvation regression case in `kioku-core/test/Kioku/RecallSqlSpec.hs` whose failure message reads as a diagnosis (rows returned, recall@k, plan text). (2026-07-11)
- [x] M3: Resolve Decision 4 (how a known-red case is registered) — `expectFail`, scoped to the known-red case alone. Recorded in Decision 6 below and in EP-3's Progress. (2026-07-11)
- [x] M3: Run the characterisation sweep and record the recall@k table in this plan's Outcomes — this is the deliverable EP-3 consumes. (2026-07-11)
- [x] M3: Full suite green (`cabal test all`, exit 0, all four suites PASS; kioku-test 114 tests). (2026-07-11)
- [x] M3: Update this plan's Outcomes and the MasterPlan's Progress/Registry. (2026-07-11)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (Pre-implementation research, 2026-07-11.) **An empty vector channel is undetectable through
  the public API, which is why the harness must reach past it.** `fuseRecallCandidates`
  (`kioku-core/src/Kioku/Recall.hs:263-278`) folds both candidate lists into a map keyed by memory
  id and scores each hit with
  `maybe 0 rrfTerm ftsRank + maybe 0 rrfTerm vecRank + 0.10*recency + 0.15*priority + 0.05*confidence`.
  A missing `vecRank` contributes `0`, which is indistinguishable from a low-ranked one. An
  individual `RecallHit` carries `vecRank :: Maybe Int` and so can say "I personally was not in
  the vector list", but nothing anywhere says "the vector list was empty", and a caller looking at
  plausible keyword results has no reason to check. The harness must therefore drive
  `selectVectorCandidates` directly — already exported as a test seam — rather than only going
  through `recall`.

- (Pre-implementation research, 2026-07-11.) **Two methodology traps that already cost the
  previous initiative three wrong measurements. Respect both, or every number this plan produces
  is fiction.**

  1. **Rows inserted inside an open transaction never get an HNSW index scan** — not even with
     `enable_seqscan = off` and a fresh `ANALYZE`. Every measurement must run against
     **committed** data. The existing seeding helpers in `RecallSqlSpec.hs` are safe because each
     `runTransaction` commits on its own, but a harness that batches all seeding into one open
     transaction to go faster would silently invalidate everything built on it. EP-5's first three
     attempts at this measurement drew the wrong conclusion from exactly this.
  2. **A partial index needs its predicate restated in the query**, or the planner cannot prove
     the index applies and falls back to a sequential scan. The HNSW index is built
     `WHERE embedding IS NOT NULL`, and recall's statement carries that predicate — it is
     load-bearing, not decoration. A harness that writes its own vector SQL and forgets it will
     measure a seq scan and conclude the index is broken.

- (Pre-implementation research, 2026-07-11.) **The existing test vectors cannot express
  "nearer".** `RecallSqlSpec.hs:174-178` builds vectors with
  `unitVector i = Vector.generate 1536 (\j -> if j == i then 1 else 0)` — orthogonal basis
  vectors, so any two distinct ones sit at cosine distance exactly 1, and a vector is at distance
  0 from itself. That is ideal for "which of these two is nearer the query" and useless for
  starvation, which needs a *graded* scale: decoys strictly nearer the query than the true
  in-scope answers, by a margin the test controls. The harness needs a new generator; Decision 2
  gives the geometry.

- (Pre-implementation research, 2026-07-11.) **pgvector is 0.8.2 and every ephemeral test cluster
  has it — but only from inside the dev shell.** Verified against the locked nixpkgs rather than
  assumed:

  ```bash
  nix eval --impure --raw --expr \
    '(builtins.getFlake "/Users/shinzui/Keikaku/bokuno/kioku").inputs.nixpkgs.legacyPackages.aarch64-darwin.postgresql.pkgs.pgvector.version'
  # => 0.8.2
  ```

  `ephemeral-pg` takes `initdb` and `postgres` from `PATH`, so a shell entered *before* pgvector
  was added to `nix/haskell.nix` still spins up clusters without it and every vector case skips.
  **Always run this plan's tests as `nix develop --command cabal test …`.** The existing vector
  cases announce their skips out loud (`"  [skipped] no reachable pgvector on this cluster…"`)
  precisely because a silent skip is indistinguishable from a pass — and since this plan's entire
  purpose is to make an invisible failure visible, its own cases must be at least as loud.

- (Pre-implementation research, 2026-07-11.) **The suite's ephemeral-Postgres clusters lose a
  60-second startup race often enough to matter**, and this plan adds database-backed cases to a
  suite tasty already runs concurrently. A failing run reports
  `TimeoutError (ConnectionTimeout {durationSeconds = 60})` and takes ~65s where a healthy one
  takes ~15s. **Rerun before investigating.** This is contention, it pre-dates this work, and it
  is not caused by anything here.

- (Implementation, M2, 2026-07-11.) **The instrument lied on its first run, in exactly the way
  this plan warned instruments lie — and the plan's own sketch is what caused it.** This is the
  single most important thing this plan produced, so it is recorded in full.

  The plan's Concrete Steps said the `EXPLAIN` must reproduce "the query recall actually issues,
  not a paraphrase", and listed what to copy: the predicates, the `ORDER BY`, the `LIMIT`, and
  above all `embedding IS NOT NULL`. It said nothing about the **select list**, and the first
  implementation selected `memory_id` alone, with a confident comment explaining that Postgres
  chooses this plan from the `WHERE`, the `ORDER BY` and the `LIMIT`, and that the projection
  could not turn an HNSW scan into anything else.

  That is false, and the sweep caught it immediately. On the 2000-in-scope, 2000-decoy corpus:

  ```text
  rowsReturned=0  recall@10=0.0        <- the real query, via selectVectorCandidates
  Limit (actual rows=50)               <- the EXPLAIN of "the same" query
    -> Index Scan using kioku_memories_scope_idx (actual rows=2000)
  ```

  The real query returned **zero** rows; the EXPLAIN cheerfully reported **fifty**, on a
  different plan. The projection sets the row width, the width sets the cost of the top-N sort
  that the *exact* plan needs, and that cost is precisely what the planner weighs against the
  HNSW scan. A narrow projection made the sort look cheap, so the planner took the exact plan —
  and the instrument reported a healthy query while the real one starved.

  Two things follow. First, the fix: `explainVectorStmt` now restates recall's full thirteen-
  column projection, and with it every sweep cell's plan agrees with the real query's behaviour.
  Second, and more durably: the harness now carries `planAgreesWithQuery`, which parses the
  plan's top-node `actual rows=N` and asserts it equals the row count the real query returned.
  A divergence is no longer something a human has to notice in a wall of EXPLAIN output; it
  fails the suite. That check is asserted in "the captured plan describes the query that was
  measured", which is deliberately *not* marked `expectFail`.

  The lesson generalises past this plan. A measuring instrument's failure mode is not an error;
  it is a plausible number. This one was caught only because the sweep printed the real query's
  result *next to* the plan's, and they disagreed. An instrument that reports only one of the two
  cannot be checked at all.

- (Implementation, M3, 2026-07-11.) **The vector channel never fills its candidate pool, even
  with no decoys at all — which refutes a claim in the shipping code's own comment.** With 2000
  in-scope rows and *zero* out-of-scope rows, so nothing whatsoever for the filter to discard,
  the vector channel returns **40** candidates against a `LIMIT` of 50. Same at 20000 rows: 40.

  `candidatePoolSize`'s comment (`kioku-core/src/Kioku/Recall.hs:528-546`) says the opposite:

  > pgvector already searches with `ef = max(ef_search, LIMIT)`, so the pool fills at the default.

  It does not, on pgvector 0.8.2 as measured here. 40 is exactly the default `hnsw.ef_search`,
  and the HNSW scan returns at most that many rows regardless of the `LIMIT`. So the vector
  channel silently contributes 20% fewer candidates than the fusion is designed around, in the
  *healthy* case, entirely independently of starvation. **EP-3 must not rely on that sentence.**

- (Implementation, M3, 2026-07-11.) **Starvation is total and the budget is exactly 40 rows.**
  Every starving cell shows the same line — `Rows Removed by Filter: 40` — and returns zero rows.
  The mechanism is now unambiguous: the HNSW scan visits `hnsw.ef_search` (default 40) candidates,
  the post-filter discards whichever of them are out of scope, and **there is no re-probing**.
  When the decoys are nearer than every true answer, all 40 are decoys, all 40 are discarded, and
  the channel returns nothing.

  This differs from EP-5's recorded "1648 rows removed, zero returned", and the difference is
  explained rather than smoothed over: EP-5 measured with `SET hnsw.ef_search = 200` and a wider
  scan visits — and therefore discards — more rows. The phenomenon is the same; only the budget
  differs. Both end at zero.

- (Implementation, M3, 2026-07-11.) **Starvation is not monotonic in corpus size, and this is the
  finding that most constrains EP-3.** Adding *more* decoys can make recall *better*, by tipping
  the planner off the HNSW path and back onto the exact one. At 2000 in-scope rows: 1× decoys
  starves to zero, but 10× decoys returns 50 perfect rows on the exact plan. At 20000 in-scope
  rows the same 10× ratio stays on HNSW and starves.

  So there is no monotone "bigger corpus is worse" story, and a remedy tuned on one cell can be
  wrong on its neighbour. The variable that actually decides the outcome is **which plan Postgres
  picks**, and it picks by cost. "Make the ANN scan work harder" and "keep the planner off the ANN
  scan when the filter is selective" are opposite strategies, and the sweep says both regimes are
  live in ordinary-sized corpora. EP-3 must choose against the table in Outcomes, not against an
  intuition about scale.

- (Implementation, 2026-07-11.) **The reassurance in `candidatePoolSize`'s comment — "The default
  kept the exact plan" — does not hold on this corpus, but that is not evidence EP-5 mis-measured.**
  At 2000+2000 with *no* `SET` at all, the planner chose HNSW and returned zero. The honest reading
  is that this harness's corpus is strictly more adversarial by construction than EP-5's: every
  decoy is nearer the query than every in-scope row, with no overlap, which is the worst case
  rather than a typical one. What the measurement establishes is not that EP-5 was wrong but that
  **the exact plan's protection is not robust** — it is a cost-model accident, not a guarantee, and
  it can be lost without anyone touching a setting.

- (Implementation, 2026-07-11.) **Seeding a 1536-dimension vector per row as a text literal is
  ruinously expensive, and the fix is safe only because the M1 case checks it.** `vectorLiteral`
  renders all 1536 components, of which 1534 are zero: roughly 6KB per row, so ~25MB of SQL for
  the default corpus and ~1.3GB for the largest sweep cell. `seedCorpus` instead sends the two
  significant components and lets Postgres append the zeros with `repeat(',0', 1534)`. The ground
  truth stays Haskell's — only the padding moves — and the M1 case asserts that the distances
  Postgres actually computes for the seeded rows match `1 - cos t` to within 1e-5, which is what
  makes the shortcut a measurement rather than a hope. (The tolerance is 1e-5 rather than
  something tighter because pgvector stores each component as a 4-byte float.)


## Decision Log

Record every decision made while working on the plan.

- Decision 1: The harness lives in the test suite as a new module
  `kioku-core/test/Kioku/RecallHarness.hs`, not in library code, and it drives the **exported test
  seams** (`selectVectorCandidates`, `selectFtsCandidates`, `vectorLiteral`) rather than
  hand-writing its own copy of the vector SQL.
  Rationale: It is an instrument, not a product feature — nothing a host links should depend on
  it. Driving the real exported statement means that when EP-3 changes that statement, the harness
  measures the *new* one automatically and cannot silently keep testing SQL that no longer runs in
  production. Those seams exist for exactly this purpose: their Haddock says they are "exported so
  the candidate SQL can be exercised directly against a real database rather than only through
  `recall`, which would drag in an embedding endpoint."
  Date: 2026-07-11

- Decision 2: Seeded vectors are generated by rotating a query vector towards a fixed orthogonal
  axis, giving an exact and tunable cosine distance — not by the existing orthogonal-basis
  `unitVector`.
  Rationale: Starvation requires decoys strictly *nearer* the query than the true answers, by a
  margin the test controls, and orthogonal basis vectors only produce distances of exactly 0 or 1.
  With `e0` the query axis and `e1` a fixed orthogonal axis, a vector at angle `t` is
  `cos t * e0 + sin t * e1`, whose cosine distance to `e0` is exactly `1 - cos t`. Distance
  becomes a pure, exactly-predictable function of one knob, which means the harness knows the
  ground-truth ranking **without querying the database** — and that is what makes recall@k a real
  measurement rather than a circular one. It is also fully deterministic: no RNG, no embedding
  endpoint, reproducible across machines.
  Date: 2026-07-11

- Decision 3: The quality metric is **recall@k against a ground truth known by construction**, not
  a comparison against a second database query.
  Rationale: The obvious alternative — run an exact search and compare the ANN result to it —
  measures the ANN path against the planner's *other* choice, which is precisely the thing under
  suspicion. EP-5 found the planner silently switching between an exact plan (50 correct rows) and
  an ANN plan (zero rows), and the switch *is* the bug. A ground truth computed in Haskell from
  the seed parameters is independent of Postgres entirely, so a disagreement is unambiguous.
  Date: 2026-07-11

- Decision 4: The starvation case asserts the *symptom* — that the vector channel returns a
  non-empty, decent-quality candidate list for a scope that genuinely contains matching memories —
  and must be registered so that a known-red assertion does not simply break CI for the (short)
  interval before EP-3 lands.
  Rationale: A test that is expected to fail is not a test; it is a comment that breaks the build.
  But the honest situation is that today's code *does* starve, so a case asserting a healthy
  vector channel is red on arrival. Two acceptable resolutions: tasty's `expectFail` (from
  `tasty-expected-failure`), which keeps the suite green *and* makes EP-3's success
  self-announcing — once the fix lands, the unexpected pass turns the case red until the marker is
  removed — or simply accepting a red suite across the EP-2→EP-3 boundary, which is a hard
  dependency and therefore short. **Prefer `expectFail`.** Whichever is chosen, record it here and
  in EP-3's Progress, because EP-3 must remove the marker.
  Date: 2026-07-11

- Decision 5: The harness seeds through raw SQL (following `RecallSqlSpec`'s existing
  `seedMemories` / `setEmbedding`), not through `Kioku.Memory.record` and the embedding worker.
  Rationale: The subject is the *query*, not the write path. Going through the domain commands
  would drag in the embedding worker and an embedding endpoint, make seeding thousands of rows
  slow, and couple this instrument to code it is not measuring. The existing helpers already work
  this way and already commit each statement, which the transaction trap in Surprises makes
  mandatory rather than incidental.
  Date: 2026-07-11

- Decision 6 (**resolves Decision 4**): The known-red starvation case is registered with
  `expectFail` from `tasty-expected-failure` (added to the `kioku-test` stanza's `build-depends`
  only), and the marker covers **exactly one case, which asserts exactly the thing that is
  known-red**. Everything that must hold both today and after the fix — that the scope filter
  never leaks an out-of-scope row, and that the captured plan describes the query that was
  actually run — lives in a second, *unmarked* case, "the captured plan describes the query that
  was measured".
  Rationale: `expectFail` was preferred for the reason the plan gave — the suite stays green
  across the EP-2→EP-3 boundary, and once the fix lands tasty reports the unexpected pass as a
  failure, which forces whoever lands it to delete the marker rather than relying on them
  remembering. But `expectFail` marks a *case*, not an assertion, so every failure inside a
  marked case is "expected". Had the invariants shared the case, a genuine regression — the scope
  filter leaking a decoy, say, which would be a correctness bug far worse than starvation — would
  have been silently absorbed as the failure the suite was already anticipating. Splitting them
  costs one extra ephemeral cluster (~6s) and buys back the ability to fail.
  **EP-3 must remove the `expectFail` wrapper in `kioku-core/test/Kioku/RecallSqlSpec.hs` and
  keep the unmarked case.**
  Date: 2026-07-11

- Decision 7: `explainVectorQuery` restates recall's full thirteen-column projection, and the
  harness carries a `planAgreesWithQuery` self-check asserting the captured plan's top-node row
  count equals the row count the real query returned.
  Rationale: Forced by measurement, not chosen on principle. The first implementation selected
  `memory_id` alone and was wrong — the projection sets the row width, the width sets the cost of
  the top-N sort the exact plan needs, and that cost is what the planner weighs against the HNSW
  scan. The EXPLAIN reported 50 rows on the exact plan while the real query returned zero on the
  HNSW plan. See Surprises for the transcript. The self-check exists because a human noticing the
  discrepancy in a wall of EXPLAIN output is not a control; an assertion is.
  Date: 2026-07-11

- Decision 8: `seedCorpus` sends only the two significant vector components and lets Postgres
  append the 1534 zeros with `repeat(',0', 1534)`, rather than rendering a full 1536-element
  literal per row through `vectorLiteral`.
  Rationale: A full literal is ~6KB per row — about 25MB of SQL for the default corpus and over a
  gigabyte for the largest sweep cell, which would have made the sweep impractical. The ground
  truth stays in Haskell; only the zero padding moves into SQL. This is safe *because* the M1
  case independently verifies that the distances Postgres computes for the seeded rows match the
  closed form, so a mistake in the shortcut fails a test rather than quietly corrupting every
  number built on it.
  Date: 2026-07-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Complete, 2026-07-11.** Two commits: `6247cec` (the seeder and its geometry check) and
`d61791c` (the metric, the plan capture, and the regression cases). The full suite is green
(`cabal test all`, exit 0; kioku-test 114 tests).

### The characterisation sweep — the deliverable EP-3 consumes

Measured with `Kioku.RecallHarness` on pgvector 0.8.2, one fresh migrated cluster per cell, every
row committed and `ANALYZE`d before measuring. `k = 10`; the candidate pool is 50. "Plan" is the
plan Postgres actually chose, read from `EXPLAIN (ANALYZE, BUFFERS)` of the query as issued.

```text
 in-scope  decoys   rows returned  recall@10   plan chosen                    rows removed by filter
 --------  ------   -------------  ---------   ----------------------------   ----------------------
      200      0×              50       1.00   exact (seq scan + top-N sort)  --
      200      1×              50       1.00   exact (kioku_memories_scope_idx)  --
      200     10×              50       1.00   exact (kioku_memories_scope_idx)  --
     2000      0×              40       1.00   HNSW                           0
     2000      1×               0       0.00   HNSW                           40   <-- STARVED
     2000     10×              50       1.00   exact (kioku_memories_scope_idx)  --
    20000      0×              40       1.00   HNSW                           0
    20000      1×               0       0.00   HNSW                           40   <-- STARVED
    20000     10×               0       0.00   HNSW                           40   <-- STARVED
```

Four things in that table decide the shape of EP-3's fix, and none of them were known when this
plan was written.

**1. Starvation is total, not partial.** Every starving cell returns *zero* rows and recall@10 of
*zero*. There is no graceful degradation to argue about: the semantic half of hybrid recall is
either fine or entirely absent.

**2. The budget is exactly 40, and there is no re-probing.** Every starving cell reads
`Rows Removed by Filter: 40`. The HNSW scan visits `hnsw.ef_search` (default 40) candidates, the
post-filter discards the out-of-scope ones, and the scan does not go back for more. That is the
whole mechanism, stated exactly.

**3. The pool never fills, even with nothing to discard.** Look at the two `0×` rows: 2000 and
20000 in-scope memories, *no* decoys, and the channel still returns 40 candidates against a
`LIMIT` of 50. This is a defect in its own right, and it refutes the sentence in
`candidatePoolSize`'s own comment claiming that "pgvector already searches with
`ef = max(ef_search, LIMIT)`, so the pool fills at the default". It does not. EP-3 should not
plan around that sentence.

**4. It is not monotonic, which forbids the obvious fix.** At 2000 in-scope rows, 1× decoys
starves to zero but 10× decoys returns 50 perfect rows — *more* interference made recall *better*,
because the larger table tipped the planner off the HNSW path and back onto the exact one. At
20000 in-scope rows the same 10× ratio stays on HNSW and starves. So the outcome is not decided by
corpus size or by selectivity but by **which plan Postgres picks**, and it picks by cost.

That last point is the one to carry into EP-3. "Make the ANN scan work harder" (raise `ef_search`,
enable `hnsw.iterative_scan`) and "keep the planner off the ANN scan when the filter is selective"
(a partial index carrying `status`, a pre-filtering strategy, a cost nudge) are *opposite*
strategies, and this table shows both regimes occurring in corpora of entirely ordinary size.
Worse, they interact: finding 3 says the healthy HNSW path already under-fills its pool by 20%, so
the natural cure for that (raise `ef_search`) is the very change EP-5 measured as *causing*
starvation by tipping the planner onto HNSW. EP-3 must measure, not reason.

### What was built

`kioku-core/test/Kioku/RecallHarness.hs` (test-only; nothing a host links depends on it):
`vectorAtAngle` / `queryVector` / `cosineDistanceAtAngle` for the geometry, `CorpusConfig` /
`defaultStarvationCorpus` / `seedCorpus` / `SeededCorpus` for the corpus and its ground truth, and
`measureRecallQuality` / `RecallQuality` / `explainVectorQuery` / `describeRecallQuality` /
`usedHnswIndex` / `planAgreesWithQuery` for the measurement. Three cases in
`kioku-core/test/Kioku/RecallSqlSpec.hs`: the geometry check, the plan-fidelity check, and the
`expectFail`'d starvation case.

Against the plan's three acceptance checks: (1) the harness builds the geometry it claims —
Postgres's distances match `1 - cos t` to within 1e-5, and every decoy is strictly nearer than
every in-scope row; (2) the instrument reproduces the known result — zero rows returned, with a
large `Rows Removed by Filter`, and where the numbers differ from EP-5's the difference is
explained rather than smoothed (Surprises); (3) the starvation case fails for the right reason
with a readable message:

```text
the vector channel does not starve on a selective scope: FAIL (expected)
  the vector channel starved.
  the vector channel returned 0 candidates, recall@10 = 0.0
  plan: HNSW (approximate)
  Limit  (actual time=0.099..0.099 rows=0 loops=1)
    ->  Index Scan using kioku_memories_embedding_hnsw on kioku_memories  (actual rows=0)
          Filter: ((status = 'active') AND (namespace = 'harness_target'))
          Rows Removed by Filter: 40
```

### The lesson

The plan's premise was that this defect survived because an empty vector channel is silent, and
that the cure is an instrument that can see it. That was right, but it understated the problem by
one level: **the instrument itself was silently wrong on its first run, and for the same class of
reason.** The first `explainVectorQuery` selected one column instead of thirteen; the narrower row
made the exact plan look cheap; and it reported a healthy 50-row query while the real one returned
zero. It was caught only because the sweep happened to print the real result *beside* the plan, and
they disagreed.

So the harness now asserts its own fidelity (`planAgreesWithQuery`) rather than trusting it, and
that assertion lives in an unmarked case where `expectFail` cannot absorb it. An instrument that
reports a single number cannot be checked; one that reports two things that must agree can be. That
is worth more than the sweep table, and it is the part of this plan most likely to matter to
whatever comes after EP-3.


## Context and Orientation

kioku is an event-sourced agent-memory library in Haskell (GHC 9.12, built with `cabal`, entered
through a Nix development shell). "Event-sourced" means every write is an immutable event appended
to a Postgres-backed log, and the tables you query are *read models* rebuilt from that log. All
commands in this plan run from the repository root, `/Users/shinzui/Keikaku/bokuno/kioku`.

**Run everything through `nix develop --command …`.** The test clusters take their Postgres
binaries from `PATH`, and pgvector is only on that `PATH` inside the dev shell (see Surprises).
Format any Haskell you edit with `fourmolu -i <file>` (config: `fourmolu.yaml`). The only package
this plan touches is `kioku-core`, and within it only the test suite.

### The vocabulary you need

An **embedding** is a list of 1536 floating-point numbers representing a piece of text's meaning;
two texts with similar meanings have embeddings pointing in similar directions. **Cosine distance**
measures that: 0 means identical direction, 1 means perpendicular ("unrelated"), 2 means opposite.
pgvector spells it `<=>`, so `embedding <=> $1::vector` reads as "how far is this memory from the
query".

**ANN** means *approximate nearest neighbour* — finding the closest vectors without comparing
against every row. **HNSW** is the index pgvector uses for it: a navigable graph you descend
towards the query point. It is fast because it is approximate, and it is approximate because it
only visits a bounded number of candidates (bounded by a setting called `hnsw.ef_search`).

**Post-filtered** means the `WHERE` clause is applied to rows the index has *already* chosen.
Since the index chose them by distance alone, a `WHERE` that rejects most of them leaves you with
few or none. That is this plan's whole subject.

**recall@k** is a search-quality metric: of the `k` truly nearest in-scope memories, how many did
the search actually return? 1.0 is perfect, 0.0 means it found none of them. (Note the unfortunate
name collision with kioku's own `recall` function. This plan always writes "recall@k" when it means
the metric.)

### The query under test

In `kioku-core/src/Kioku/Recall.hs`, `selectVectorCandidatesStmt` (lines 435-451):

```haskell
selectVectorCandidatesStmt :: Statement VectorCandidateQuery [MemoryRecord]
selectVectorCandidatesStmt =
  preparable
    ( "SELECT "
        <> memoryRecordColumns
        <> """
            FROM kiroku.kioku_memories
           WHERE status = 'active'
             AND namespace = $2
             AND (($3 IS NULL AND $4 IS NULL) OR (scope_kind = $3 AND scope_ref = $4))
             AND embedding IS NOT NULL
           ORDER BY embedding <=> $1::vector
           LIMIT $5
           """
    )
    vectorCandidateQueryEncoder
    (D.rowList memoryRecordDecoder)
```

`$1` is the query vector as a text literal, `$2`–`$4` are the scope, `$5` is
`candidatePoolSize = 50` (`Recall.hs:545-546`). Three of the four predicates (`status`,
`namespace`, and the scope pair) are **post-filters** applied to whatever the index returned. The
fourth, `embedding IS NOT NULL`, is there so the planner can prove the *partial* index applies —
drop it and you get a sequential scan.

The exported seams the harness drives (`Recall.hs:22-26`):

```haskell
selectVectorCandidates :: (Store :> es) => RecallRequest -> Vector Double -> Eff es (Either StoreError [MemoryRecord])
selectFtsCandidates   :: (Store :> es) => RecallRequest -> Eff es (Either StoreError [MemoryRecord])
vectorLiteral         :: Vector Double -> Text
```

(Check the exact effect row and error type in the source before using them; the shapes above are
indicative.)

### The two indexes that matter

The HNSW index, created by
`kioku-migrations/sql-migrations/2026-07-11-17-45-43-kioku-embedding-schema-heal.sql` (and
originally by `2026-06-24-01-00-00-kioku-memory-embeddings.sql`), effectively:

```sql
CREATE INDEX IF NOT EXISTS kioku_memories_embedding_hnsw
  ON kioku_memories USING hnsw (embedding vector_cosine_ops)
  WHERE embedding IS NOT NULL;
```

Operator class `vector_cosine_ops` (which is what `<=>` uses), partial on nullity, and **no build
parameters** — `m` and `ef_construction` are pgvector's defaults (16 and 64). Nothing in the
repository sets `hnsw.ef_search`; it appears only in a comment.

And the plain B-tree index the *exact* plan uses, from `2026-06-24-00-00-00-kioku-base.sql`:

```sql
CREATE INDEX IF NOT EXISTS kioku_memories_scope_idx
  ON kioku_memories (namespace, scope_kind, scope_ref) WHERE status = 'active';
```

Remember this second one. EP-5's measurement showed the planner choosing a bitmap scan on it — and
returning 50 **correct** rows — when it declined the HNSW path. The two plans coexist, and *which
one Postgres picks* is the crux of the entire problem. A measurement that does not record which
plan was chosen has not measured the thing that matters.

### The existing test module you are extending

`kioku-core/test/Kioku/RecallSqlSpec.hs` — six database-backed cases exercising the candidate SQL
against a real Postgres. Read all of it; it is short. The pieces to reuse:

```haskell
-- Seeding: raw SQL, and each runTransaction COMMITS on its own (RecallSqlSpec.hs:180-215)
seedMemories :: (Store :> es) => [(Text, MemoryScope, Text, Text)] -> Eff es ()
seedMemories rows =
  runTransaction . Tx.sql . encodeUtf8 $
    "INSERT INTO kioku_memories (memory_id, agent_id, namespace, scope_kind, scope_ref, memory_type, content, status, created_at, updated_at) VALUES "
      <> Text.intercalate ", " (row <$> rows)

-- Embeddings injected directly, never computed (RecallSqlSpec.hs:217-224)
setEmbedding :: (Store :> es) => Text -> Vector Double -> Eff es ()
setEmbedding memoryId embedding =
  runTransaction . Tx.sql . encodeUtf8 $
    "UPDATE kioku_memories SET embedding = '" <> vectorLiteral embedding <> "'::vector WHERE memory_id = '" <> memoryId <> "'"

-- The distance geometry you are replacing (RecallSqlSpec.hs:174-178)
unitVector :: Int -> Vector Double
unitVector i = Vector.generate 1536 (\j -> if j == i then 1 else 0)

-- The skip probe. Note the comment: a silent skip is indistinguishable from a pass.
vectorTypeIsReachable :: (Store :> es) => Eff es Bool

-- The fixture: one migrated ephemeral cluster per case (RecallSqlSpec.hs:242-248)
withRecallFixture :: (...) -> IO a
```

Test modules are registered in `kioku-core/test/Main.hs`, and every module must also be listed in
`other-modules` of the `kioku-test` stanza in `kioku-core/kioku-core.cabal`.


## Plan of Work

Three milestones. M1 builds the ability to *construct* the pathological corpus. M2 builds the
ability to *see* what the database did with it. M3 turns the two into a regression test and into a
characterisation of the defect that EP-3 will use to choose a fix.

**Milestone 1 — a corpus you can aim.** Create `kioku-core/test/Kioku/RecallHarness.hs`. Its heart
is a vector generator with an exact, predictable geometry (Decision 2): pick a query axis `e0` and
one fixed orthogonal axis `e1`; a vector at angle `t` is `cos t * e0 + sin t * e1`, and its cosine
distance to the query is exactly `1 - cos t`. So `t = 0` sits on top of the query (distance 0) and
larger `t` is farther away. Every seeded row's distance is therefore known in Haskell, exactly,
without asking Postgres — which is what makes the ground truth trustworthy rather than circular.

On top of that sits a seeder taking a small config record: how many memories in the target scope,
how many decoys outside it, the angular band the in-scope memories occupy, and the (nearer)
angular band the decoys occupy. The default configuration reproduces EP-5's probe — 2000 in-scope,
2000 decoys, decoys strictly nearer — because reproducing a known result is the first thing that
proves an instrument works.

Two constraints, both from Surprises, both fatal if ignored. Every seeded row must be **committed**
(batching into one open transaction silently disables the index scan, and every number after that
is fiction). And the harness must go through the exported `selectVectorCandidates` seam rather than
its own SQL, or it will forget the partial index's `embedding IS NOT NULL` predicate and measure a
sequential scan.

M1's verification is a test of the *instrument*, not of recall: seed a small corpus, ask Postgres
for the actual distances, and assert they agree with what the harness predicted and that the decoys
really are nearer than the in-scope rows. If that does not hold, nothing downstream means anything.

**Milestone 2 — an instrument that reports.** Add two capabilities. First, plan capture: run
`EXPLAIN (ANALYZE, BUFFERS)` on the vector candidate query *as it is actually issued* and return
the plan text, so a test can print it in a failure message and a human can see the cause at a
glance. The most diagnostic line in that output is `Rows Removed by Filter`, which is starvation
made visible. Second, the quality metric: given the seed config (hence the ground truth) and the
rows the query returned, compute how many rows came back, recall@k against the true nearest
in-scope memories, and how many rows the filter discarded.

Package both behind one `measureRecallQuality` returning a small record, so that a test reads as
one call plus a few assertions rather than a page of plumbing. An instrument nobody wants to use
does not get used.

**Milestone 3 — make the invisible failure loud, and characterise it.** Add the regression case to
`kioku-core/test/Kioku/RecallSqlSpec.hs`: seed the starving corpus, run the vector channel, and
assert it returned a non-empty candidate list containing a decent share of the true nearest
in-scope memories. Against today's code it will fail — read Decision 4 before writing it, because
how a known-red case is registered so that it does not simply break CI is a real decision that must
be made and recorded. When it fails, the message must read as a *finding*: rows returned, rows
removed by filter, recall@k, and the plan.

Then sweep. Run the measurement across a grid — in-scope rows {200, 2000, 20000} crossed with decoy
ratios {0×, 1×, 10×} — and record the resulting recall@k table, with the chosen plan named per
cell, in this plan's Outcomes section. **That table is EP-3's starting point.** It answers the
question that decides the entire shape of the fix: is the problem "the ANN scan is too narrow" (a
case for iterative scan) or "the planner picks the ANN path when it should not" (a case for
pre-filtering or a strategy switch)? Those call for opposite remedies, and EP-5's `ef_search`
result — where forcing the ANN path *caused* the zero-row outcome — is a warning that guessing
wrong is worse than doing nothing. Do not skip the sweep; EP-3 is written assuming it exists.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/kioku`, inside the dev shell.

### M1 — the corpus generator

1. Read `kioku-core/test/Kioku/RecallSqlSpec.hs` end to end, and the `selectVectorCandidatesStmt`
   region of `kioku-core/src/Kioku/Recall.hs` (lines ~400-550, which also contains
   `candidatePoolSize` and its long comment recording the original repro). Everything you need to
   imitate is in those two places.

2. Create `kioku-core/test/Kioku/RecallHarness.hs`. Sketch — adapt names, the effect row, and the
   error type to match the existing code rather than pasting blindly:

   ```haskell
   -- | An instrument for measuring vector-recall quality against a corpus whose true answer is
   -- known by construction. See docs/plans/18-build-a-recall-quality-harness-…md.
   module Kioku.RecallHarness
     ( CorpusConfig (..),
       defaultStarvationCorpus,
       SeededCorpus (..),
       seedCorpus,
       vectorAtAngle,
       queryVector,
       RecallQuality (..),
       measureRecallQuality,
       explainVectorQuery,
     )
   where

   -- | The query sits on axis 0. A seeded vector at angle @t@ (radians) is
   -- @cos t * e0 + sin t * e1@, so its cosine distance to the query is exactly @1 - cos t@.
   -- Distance is a pure function of the knob, which is what lets the harness know the true
   -- ranking without asking Postgres — the property that makes recall@k a measurement rather
   -- than a tautology.
   vectorAtAngle :: Double -> Vector Double
   vectorAtAngle t =
     Vector.generate embeddingDimensions \j ->
       case j of
         0 -> cos t
         1 -> sin t
         _ -> 0

   queryVector :: Vector Double
   queryVector = vectorAtAngle 0

   cosineDistanceToQuery :: Double -> Double
   cosineDistanceToQuery t = 1 - cos t

   -- Must match the column: kioku_memories.embedding is vector(1536).
   embeddingDimensions :: Int
   embeddingDimensions = 1536

   data CorpusConfig = CorpusConfig
     { inScopeCount :: !Int,               -- memories in the scope the query asks for
       decoyCount :: !Int,                 -- memories in a DIFFERENT namespace, nearer the query
       inScopeAngles :: !(Double, Double), -- the angular band the in-scope rows occupy (radians)
       decoyAngles :: !(Double, Double)    -- the (nearer) band the decoys occupy
     }

   -- | EP-5's probe, which produced "1648 rows removed by filter, zero returned".
   -- Every decoy is strictly nearer the query than every in-scope row.
   defaultStarvationCorpus :: CorpusConfig
   defaultStarvationCorpus =
     CorpusConfig
       { inScopeCount = 2000,
         decoyCount = 2000,
         inScopeAngles = (0.8, 1.2),  -- cosine distance ~0.30 .. ~0.64
         decoyAngles = (0.05, 0.5)    -- cosine distance ~0.001 .. ~0.12  (strictly nearer)
       }

   -- | What was seeded, including the ground truth: in-scope memory ids ordered by true distance,
   -- nearest first. Computed in Haskell from the angles — never read back from the database,
   -- which is the thing under test.
   data SeededCorpus = SeededCorpus
     { targetScope :: !MemoryScope,
       trueNearestInScope :: ![Text]
     }
   ```

   Then `seedCorpus :: (Store :> es) => CorpusConfig -> Eff es SeededCorpus`, which spreads rows
   evenly across each angular band, inserts them with `seedMemories`-style raw SQL, sets each
   embedding with `setEmbedding`, and returns the ground truth.

   **Commit as you go.** Each `runTransaction` commits, so calling the existing helpers per batch
   is correct — but do not "optimise" the seeder by wrapping the whole corpus in one transaction.
   Rows in an open transaction get no HNSW index scan and every number afterwards is fiction
   (Surprises, trap 1). If seeding thousands of rows one statement at a time is too slow, batch
   the `INSERT` **values** into multi-row statements while keeping each statement its own committed
   transaction — that is both fast and safe.

   After seeding, run `ANALYZE kioku_memories`. Without statistics the planner uses defaults, and
   the plan it picks is not the plan production would pick — which for this plan is the entire
   subject.

3. Register the module: add `Kioku.RecallHarness` to `other-modules` in the `kioku-test`
   test-suite stanza of `kioku-core/kioku-core.cabal`.

4. Add the instrument's own test to `RecallSqlSpec.hs` — *"the harness seeds the geometry it
   claims"*. Seed a small corpus (20 in-scope, 20 decoys), then ask Postgres for the actual
   distances and assert that they match `1 - cos t` within a small epsilon, and that every decoy
   is nearer the query than every in-scope row. For *this* check you legitimately write your own
   SQL (`SELECT memory_id, embedding <=> $1 AS d FROM … ORDER BY d`), because the subject is the
   seeded data rather than recall's statement.

   Guard it with the existing `vectorTypeIsReachable` probe, and make the skip loud, exactly as
   the neighbouring cases do.

5. Run and commit:

   ```bash
   nix develop --command cabal test kioku-core:test:kioku-test
   ```

   Commit: `test(recall): add a seeded corpus harness with a known-by-construction ground truth`

### M2 — plan capture and the quality metric

1. Add `explainVectorQuery` to the harness. It must EXPLAIN **the query recall actually issues**,
   not a paraphrase: build the identical SQL text, with the same predicates and the same
   `ORDER BY … LIMIT`, prefixed with `EXPLAIN (ANALYZE, BUFFERS)`, and return the plan rows joined
   into one `Text`. Copy the predicate list verbatim from `selectVectorCandidatesStmt` (quoted in
   Context and Orientation) — **including `embedding IS NOT NULL`.** Omit it and you will measure a
   sequential scan and conclude the index is broken (Surprises, trap 2).

   Sanity-check the capture once by hand before trusting it: against a healthy small corpus it
   must show `Index Scan using kioku_memories_embedding_hnsw`. If it shows `Seq Scan`, you have
   either dropped the partial-index predicate or you are looking at uncommitted rows. Fix that
   before going further; every later number depends on it.

2. Add the metric:

   ```haskell
   data RecallQuality = RecallQuality
     { rowsReturned :: !Int,     -- how many candidates the vector channel produced (the pool is 50)
       recallAtK :: !Double,     -- of the k true nearest in-scope memories, what fraction came back
       k :: !Int,
       planText :: !Text         -- EXPLAIN (ANALYZE, BUFFERS) output, for the failure message
     }

   measureRecallQuality :: (Store :> es) => SeededCorpus -> Int -> Eff es RecallQuality
   ```

   It calls the exported `selectVectorCandidates` (Decision 1) with the corpus's target scope and
   `queryVector`, compares the returned memory ids against `trueNearestInScope` truncated to `k`,
   and attaches the plan text. `k = 10` is a reasonable default: the candidate pool is 50 and a CLI
   user asks for 8 hits by default.

   Surface **rows removed by filter** too. Parsing it out of the plan text (the line reads
   `Rows Removed by Filter: N`) is nice but brittle; simply carrying `planText` into the failure
   message is enough, because the goal is a human reading a failure and seeing the cause
   immediately.

3. Commit: `test(recall): measure vector-recall quality and capture the query plan`

### M3 — the regression case and the characterisation sweep

1. Add to `kioku-core/test/Kioku/RecallSqlSpec.hs` the case *"the vector channel does not starve on
   a selective scope"*, carrying a comment that explains itself:

   ```haskell
   -- The HNSW index is post-filtered: it picks candidates by distance alone, and the namespace,
   -- scope, and status predicates are applied afterwards. When the rows outside the scope are
   -- nearer the query than the in-scope answers, the index can spend its whole budget on rows the
   -- filter then discards — and the vector channel returns nothing, silently, because the RRF
   -- fusion degrades to keyword-only without an error.
   --
   -- This case fails against the unfixed query; the fix is
   -- docs/plans/19-fix-filtered-ann-starvation-in-vector-recall.md.
   ```

   Seed `defaultStarvationCorpus`, call `measureRecallQuality` with `k = 10`, and assert
   `rowsReturned > 0` and `recallAtK >= 0.5`. On failure print the whole `RecallQuality`, plan text
   included, so the message reads as a diagnosis:

   ```text
   the vector channel starved: 0 of 50 candidates returned, recall@10 = 0.00
   plan:
     Limit (actual rows=0)
       ->  Index Scan using kioku_memories_embedding_hnsw (actual rows=0)
             Rows Removed by Filter: 1648
   ```

2. **Resolve Decision 4** — how the known-red case is registered — and record the choice in the
   Decision Log above *and* in EP-3's Progress list, since EP-3 must remove any marker you add.
   `expectFail` (from `tasty-expected-failure`, added to the `kioku-test` stanza's `build-depends`
   only) is preferred: it keeps the suite green now, and once EP-3's fix lands the unexpected pass
   turns the case red until the marker is removed, which is a pleasant forcing function rather
   than a chore anyone can forget.

3. Run the characterisation sweep. This is a measurement exercise, not a permanent test: run it as
   a temporary tasty case or a scratch invocation, and record the results here rather than
   committing a slow 20000-row case into the suite. Grid: in-scope rows {200, 2000, 20000} × decoy
   ratio {0×, 1×, 10×}. For each cell record rows returned, recall@10, and **which plan was
   chosen** (HNSW index scan, or bitmap/exact on `kioku_memories_scope_idx`).

   Write the table into this plan's Outcomes section as a fenced ```text``` block. This is the
   deliverable EP-3 consumes, and the plan-chosen column is the load-bearing one: EP-5 found that
   Postgres sometimes picks the exact plan and returns *perfect* results, and sometimes picks the
   ANN plan and returns *nothing*. Knowing which regime each cell is in is what tells EP-3 whether
   to make the ANN scan work harder or to keep the planner off it.

4. Full suite:

   ```bash
   nix develop --command cabal test all
   ```

   Rerun once on a `ConnectionTimeout` before investigating (Surprises).

5. Commit: `test(recall): fail loudly when the vector channel starves on a selective scope`

6. Update this plan's Progress, Surprises, Decision Log, and Outcomes (with the sweep table), plus
   the Progress section and the Exec-Plan Registry row for EP-2 in
   docs/masterplans/3-kioku-follow-up-scene-freshness-and-filtered-ann-recall-quality.md.


## Validation and Acceptance

This plan's deliverable is an instrument, so acceptance means the instrument tells the truth. Three
checks, in order.

**1. The harness builds the geometry it claims.** The M1 case asserts that the distances Postgres
computes for the seeded rows match `1 - cos t` within epsilon, and that every decoy is nearer the
query than every in-scope row.

```bash
nix develop --command cabal test kioku-core:test:kioku-test
```

If this passes, the ground truth is trustworthy and everything built on it means something. If it
fails, stop — nothing downstream is worth reading.

**2. The instrument reproduces the known result.** Seeded with `defaultStarvationCorpus`, the
measurement must reproduce the shape EP-5 recorded: the vector channel returning far fewer than 50
rows (in EP-5's probe, zero) with a large `Rows Removed by Filter` in the plan. Reproducing a
previously-measured result with independently-written code is the strongest evidence available that
the instrument is sound.

Record the actual numbers in Outcomes. **If they differ materially from EP-5's (1648 removed, zero
returned), that is itself a finding** — write it down rather than smoothing it over. A corpus that
refuses to starve where it starved before would mean either the geometry is wrong or something
changed underneath, and both are things EP-3 must know.

**3. The starvation case fails for the right reason, with a readable message.** Run it and read the
output. It must name rows returned, recall@k, and the plan. A failure that says only
`expected: True, got: False` has not delivered this plan — the entire point is to convert an
invisible failure into a legible one.

The suite as a whole must be green (or green-with-`expectFail`, per Decision 4):

```bash
nix develop --command cabal test all
```

**Acceptance for the sweep**: this plan's Outcomes section contains a filled-in grid of recall@10
and chosen plan across corpus sizes and decoy ratios. Without it, EP-3 has no basis on which to
choose a remedy, and its hard dependency on this plan is unsatisfied in substance even if the code
compiles.


## Idempotence and Recovery

Every step is a test-only source edit plus a test run, and all of it is safe to repeat. No library
code changes. No SQL migration is added. Nothing writes to any persistent database: each case spins
up a throwaway ephemeral Postgres cluster via `withRecallFixture` (which migrates a fresh database
per case), so seeding thousands of rows leaves nothing behind and two runs cannot interfere with
each other.

The one real constraint is time. Seeding tens of thousands of rows into an ephemeral cluster is
slow, and the suite is already contended enough to lose a 60-second startup race under concurrency.
Keep the *committed* suite's corpus modest — the 2000+2000 default is enough to starve, and that is
all the regression case needs — and run the large grid cells manually during the M3 sweep rather
than committing them. If a sweep run is killed halfway, re-run it; nothing persists.

If the harness produces numbers that seem impossible — an HNSW scan returning every row, or a
sequential scan where the index should be used — suspect the two traps first, in this order:
uncommitted seed data, then a missing `embedding IS NOT NULL` predicate. Both produce
confidently-wrong measurements rather than errors, which is exactly what makes them dangerous, and
the previous initiative lost three attempts to the first one before spotting it.


## Interfaces and Dependencies

No new library dependency is required for the harness itself. One optional *test* dependency is in
play: `tasty-expected-failure` (for `expectFail`), if Decision 4 is resolved that way. If added, it
goes in the `kioku-test` suite's `build-depends` in `kioku-core/kioku-core.cabal` and nowhere else
— it must never become a dependency of a library component.

Signatures that must exist at the end of this plan, in the new module
`kioku-core/test/Kioku/RecallHarness.hs`:

- `vectorAtAngle :: Double -> Vector Double` and `queryVector :: Vector Double` — the geometry.
- `CorpusConfig (..)` and `defaultStarvationCorpus :: CorpusConfig` — the knobs, with a default
  that reproduces EP-5's probe.
- `seedCorpus :: (Store :> es) => CorpusConfig -> Eff es SeededCorpus`, seeding committed rows and
  returning the ground truth as `SeededCorpus (..)` (carrying `targetScope` and
  `trueNearestInScope`).
- `measureRecallQuality :: (Store :> es) => SeededCorpus -> Int -> Eff es RecallQuality`, with
  `RecallQuality (..)` carrying at least `rowsReturned`, `recallAtK`, `k`, and `planText`.
- `explainVectorQuery :: (Store :> es) => SeededCorpus -> Eff es Text`.

**What this plan must NOT change.** `kioku-core/src/Kioku/Recall.hs` belongs to EP-3. This plan
*reads* `selectVectorCandidates`, `selectFtsCandidates`, `vectorLiteral`, and `candidatePoolSize`;
it must not alter the statement, the pool size, or any index. If you find you cannot measure
without changing library code, that is a discovery to record in Surprises and hand to EP-3 — not a
change to make here.

There is one plausible instance of that, so it is called out in advance: if `explainVectorQuery`
cannot faithfully reproduce the issued SQL without duplicating it by hand, the clean answer is for
`Recall.hs` to export the statement's SQL text as a constant that both the statement and the
harness use. That would be a small, safe library change — but it is EP-3's call, and the right move
is to record it and let EP-3's plan absorb it, rather than for this plan to exceed its remit.

**Cross-plan constraints.** This plan is EP-2 of
docs/masterplans/3-kioku-follow-up-scene-freshness-and-filtered-ann-recall-quality.md.

- **EP-3 (docs/plans/19-fix-filtered-ann-starvation-in-vector-recall.md) has a hard dependency on
  this plan** and is written entirely in terms of the interfaces listed above. Reshaping them after
  EP-3 has begun is a cross-plan break; if it becomes necessary, update EP-3's text in the same
  commit.
- If Decision 4 is resolved with `expectFail`, **EP-3 must remove that marker** when its fix lands.
  EP-3's Progress list already carries an item for it — make sure the wording matches whatever you
  actually did.
- EP-1 (docs/plans/17-refresh-scenes-and-personas-when-a-memory-s-confidence-changes.md) is
  independent: it touches the distillation pipeline and `kioku-core/test/Kioku/DistillSpec.hs`, and
  shares no file with this plan.
