---
id: 19
slug: fix-filtered-ann-starvation-in-vector-recall
title: "Fix filtered-ANN starvation in vector recall"
kind: exec-plan
created_at: 2026-07-11T19:57:52Z
intention: "intention_01kwyhabypepdt1mwemmf0dvqa"
master_plan: "docs/masterplans/3-kioku-follow-up-scene-freshness-and-filtered-ann-recall-quality.md"
---

# Fix filtered-ANN starvation in vector recall

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

kioku's `recall` blends a full-text search with a **vector search** — the half that finds a memory
whose *meaning* matches the query even when its words do not. On a large corpus with a selective
scope, that vector half can return **nothing**, silently, and the caller cannot tell.

The mechanism: the HNSW index (a graph that approximately answers "which vectors are nearest this
one?") indexes only the embedding column. The query also filters by namespace, by scope, and by
`status = 'active'`, and Postgres applies those filters **after** the index has picked its
candidates by distance alone. When the memories nearest the query happen to sit outside the
caller's scope, the index spends its whole budget on rows the filter then discards. The previous
initiative measured this precisely: 2000 in-scope memories, 2000 nearer decoys elsewhere, and the
vector query removed 1648 rows by filter and returned **zero**. Because the two channels are fused
by rank, an empty vector list simply contributes no ranks and the score decays into pure keyword
scoring — no error, no warning, nothing in the result recording that half the search vanished.

**After this plan, vector recall returns the right memories for a selective scope, and there is a
test that proves it.** That test already exists: it is the starvation case built by
docs/plans/18-build-a-recall-quality-harness-that-reproduces-filtered-ann-starvation.md, which
fails against today's code and must pass against this plan's.

**This plan deliberately does not name the fix.** It names the candidates, the evidence needed to
choose between them, and the bar the winner must clear. That is not indecision; it is the direct
lesson of the work that preceded it. The obvious remedy — raising `hnsw.ef_search` so the ANN scan
searches more widely — was prescribed with confidence by a previous plan, and measurement showed it
would have made things **worse**: it lured the planner off an exact plan that returned 50 *correct*
rows and onto an ANN scan that returned zero. The second-obvious remedy, pgvector's own
`hnsw.iterative_scan`, returned zero rows too on its one tested mode. Four plans in the preceding
initiative asserted something confident about a system their author never ran, and each was
falsified by execution. So this plan's central milestone is a **bake-off**: run every candidate
against a corpus that genuinely starves, measure recall quality and the chosen query plan, and let
the numbers pick the winner.

You will see it working when the harness's starvation case goes green:

```bash
nix develop --command cabal test kioku-core:test:kioku-test
```


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0: Confirm EP-2 has landed and read its Outcomes table (the characterisation sweep). If it is missing, stop — this plan's hard dependency is unsatisfied. (2026-07-11; table present, harness exports all four required functions, starvation case present and `expectFail`-marked.)
- [x] M1: Characterise the failure — establish from EP-2's harness where starvation begins and, critically, **which regime** it is. **Answer: the ANN regime.** Above ~2000 embedded rows the planner routinely picks the HNSW path, and the HNSW path starves whenever out-of-scope rows are nearer than in-scope ones. The exact plan protects only small corpora (200 rows) and one accidental cell. See Outcomes. (2026-07-11)
- [x] M2: Extend the harness with the prototyping seams the bake-off needs — `measureRecallQualityWith` (settings applied in the *same* transaction as the query, since `SET LOCAL` dies with its transaction) and `runDdl` (for the index candidates). Export `selectVectorCandidatesStmt`, `vectorCandidateQuery`, `memoryRecordColumns` and `candidatePoolSize` from `Kioku.Recall` so the harness drives the real statement rather than a copy. (2026-07-11)
- [x] M2: Prototyping bake-off — run each candidate remedy against the starving corpus, recording recall@10, rows returned, latency, and the chosen plan for each. Record the full table in this plan's Outcomes, including the losers. (2026-07-11)
- [x] M2: **Repeatability probe — added, not in the original plan, and it changed the answer.** The first bake-off round gave contradictory results for identical settings, so each candidate was re-run five times on a freshly built HNSW graph. See Surprises: `iterative_scan` is *non-deterministic* at 20000 rows, and a single sample of it is worthless. (2026-07-11)
- [x] M2: Choose the winner against the criteria in Decision 2, and record the choice with its evidence in the Decision Log. **Winner: `hnsw.ef_search` = pool size, plus an exact pre-filtered pass when the approximate pass comes back short. `iterative_scan` rejected — it is a lottery.** See Decision 5. (2026-07-11)
- [x] M3: Ship the winner. **No migration was needed** — the fix is a query change plus a `SET LOCAL`, not an index change, so Decision 3's rules never came into play. (2026-07-11, commit `0f3efad`)
- [x] M3: Add Decision 4's observability — `VectorChannelOutcome`, `vectorChannelStarved`, `selectVectorCandidatesDiagnosed`. Shipped as a return value rather than an emitted metric; see Decision 7 for why, and the limit is documented. (2026-07-11)
- [x] M3: The harness's starvation case passes; EP-2's `expectFail` marker removed. A second case ("a healthy scope never pays for the exact fallback") pins bar (b). (2026-07-11)
- [x] M3: Delete the throwaway bake-off module. Its output lives on as the table in Outcomes. (2026-07-11)
- [x] M4: Document the honest limits of the shipped remedy — what still starves, and under what conditions — at `candidatePoolSize` and in `docs/user/recall.md`. (2026-07-11)
- [x] M4: Full suite green (`cabal test all`, exit 0; kioku-test 115 tests). (2026-07-11)
- [x] M4: Update this plan's Outcomes and the MasterPlan's Progress/Registry/Outcomes. (2026-07-11)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (**Handed over from EP-2, 2026-07-11. Read this before anything else in this section, because
  it corrects the note immediately below it.**) EP-2's harness landed and its characterisation
  sweep is in that plan's Outcomes
  (docs/plans/18-build-a-recall-quality-harness-that-reproduces-filtered-ann-starvation.md).
  Four measured results change this plan's starting point:

  ```text
   in-scope  decoys   rows returned  recall@10   plan chosen                       rows removed
   --------  ------   -------------  ---------   -------------------------------   ------------
        200      0×              50       1.00   exact (seq scan + top-N sort)     --
        200      1×              50       1.00   exact (kioku_memories_scope_idx)  --
        200     10×              50       1.00   exact (kioku_memories_scope_idx)  --
       2000      0×              40       1.00   HNSW                              0
       2000      1×               0       0.00   HNSW                              40   <-- STARVED
       2000     10×              50       1.00   exact (kioku_memories_scope_idx)  --
      20000      0×              40       1.00   HNSW                              0
      20000      1×               0       0.00   HNSW                              40   <-- STARVED
      20000     10×               0       0.00   HNSW                              40   <-- STARVED
  ```

  1. **The reassurance below — "at the default, Postgres declined the ANN index entirely and got
     a perfect answer" — does not survive contact with a maximally adversarial corpus.** At 2000
     in-scope and 2000 nearer decoys, with **no `SET` at all**, the planner chose HNSW and
     returned **zero** rows. The exact plan's protection is a cost-model accident, not a
     guarantee, and it can be lost without anyone touching a setting. (EP-2's corpus is harsher
     than EP-5's by construction — *every* decoy is nearer than *every* in-scope row — so this is
     not evidence that EP-5 mis-measured. It is evidence that the safety it observed is not
     robust.)
  2. **The budget is exactly 40 and there is no re-probing.** Every starving cell reads
     `Rows Removed by Filter: 40`: the HNSW scan visits `hnsw.ef_search` (default 40) candidates,
     the post-filter discards the out-of-scope ones, and the scan does not go back for more.
  3. **The pool never fills, even with nothing to discard.** With 2000 (or 20000) in-scope rows
     and *zero* decoys, the vector channel still returns 40 candidates against a `LIMIT` of 50.
     This refutes the claim in `candidatePoolSize`'s own comment that "pgvector already searches
     with `ef = max(ef_search, LIMIT)`, so the pool fills at the default". **Do not plan around
     that sentence — it is false on pgvector 0.8.2.** Note the trap this sets: the natural cure
     for an under-filled pool is to raise `ef_search`, which is exactly the change EP-5 measured
     as *causing* starvation.
  4. **It is not monotonic.** At 2000 in-scope rows, 1× decoys starves to zero but 10× decoys
     returns 50 perfect rows — *more* interference made recall *better*, by tipping the planner
     off HNSW and back onto the exact plan. At 20000 in-scope the same 10× ratio starves. So the
     outcome is decided by **which plan Postgres picks**, not by corpus size or selectivity, and
     a remedy tuned on one cell can be wrong on its neighbour. M1's job is to identify the regime
     per cell, and M2 must bake off across the *whole* grid, not just the default corpus.

  Two mechanical notes for M3. EP-2 registered its known-red case with `expectFail` from
  `tasty-expected-failure`, wrapping **one** case, "the vector channel does not starve on a
  selective scope", in `kioku-core/test/Kioku/RecallSqlSpec.hs`. Remove that wrapper when the fix
  lands (tasty will force you to: an unexpected pass is reported as a failure). Leave the
  neighbouring unmarked case, "the captured plan describes the query that was measured", alone —
  it asserts the harness's own fidelity and must keep failing loudly if a change makes the
  captured plan stop describing the query under test. Second: EP-2 found that the EXPLAIN's
  **select list** changes which plan Postgres picks (row width sets the top-N sort's cost, which
  is what the planner weighs against the HNSW scan). If you change
  `selectVectorCandidatesStmt`'s projection, update `explainVectorStmt`'s copy in
  `kioku-core/test/Kioku/RecallHarness.hs` in the same commit or the harness will silently start
  measuring a different query. `planAgreesWithQuery` is the guard, and it is asserted.

- (**Implementation, M2, 2026-07-11. The most important measurement in this initiative, and it
  overturned the bake-off's own first-round winner.**) **`hnsw.iterative_scan` is
  non-deterministic, and a single sample of it is worthless.**

  Round 1 of the bake-off ran each candidate once and produced an apparent winner:
  `relaxed_order + max_scan_tuples=200000 + scan_mem_multiplier=4` returned 50 rows with
  recall@10 = 1.0 on both starving cells. It cleared every bar. It was, on that evidence, the fix.

  Round 2 re-ran the same settings with the variables isolated and produced *contradictory*
  results: `relaxed + mst=200k` returned 50 rows while `relaxed + mst=200k + mem4` returned **0**,
  and `strict + mst=1M + mem8` returned 0 while `strict + mst=200k + mem4` returned 50. More scan
  budget producing *fewer* rows is not a parameter effect — it is noise. The cause: every bake-off
  cell builds a fresh database, so it builds a **fresh HNSW graph**, and HNSW construction is
  randomized. Whether the iterative scan reaches the in-scope rows within its budget depends on
  the graph it happens to get.

  Round 3 measured it properly — same settings, five freshly built graphs, at 20000 in-scope ×
  20000 decoys:

  ```text
  candidate                     run1  run2  run3  run4  run5     rows returned (of 50)
  ---------------------------   ----  ----  ----  ----  ----     ---------------------
  baseline                         0     0     0     0     0     always starves
  relaxed + mst=200k + mem4        0    50     0     0    50     2 of 5   <-- COIN FLIP
  strict  + mst=200k + mem4        0    50    50    50    50     4 of 5   <-- still fails
  exact path (pre-filtered)       50    50    50    50    50     5 of 5   <-- deterministic
  ```

  So `iterative_scan` is not a fix; it is a lottery whose odds improve with budget. It fails bar
  (a) outright at 20000 rows and fails bar (c) — "the query plan is stable and understood" —
  catastrophically: a remedy that returns the right answer 40% of the time would pass any single
  test run and starve in production at random.

  **This is the fifth time in two initiatives that a confident claim about an unrun system was
  falsified by running it — and this time the confident claim was made by the bake-off itself.**
  Round 1 was a real measurement, on the real corpus, through the real statement, and it was still
  wrong, because n=1 against a randomized data structure is not a measurement. The lesson is not
  "measure" — this plan already said that. It is that **a measurement of a nondeterministic system
  needs a sample size, and nobody had asked whether the system was deterministic.** EP-5's single
  `relaxed_order` probe and this plan's own round 1 made exactly the same error, four months and
  one initiative apart.

- (Pre-implementation research, 2026-07-11. **Superseded in part — see the EP-2 handover above.**)
  **The single most important input to this plan is that
  the obvious fix was measured and it made recall worse.** From the previous initiative's EP-5,
  seeded with 2000 rows in the target namespace and 2000 nearer decoys in another:

  ```text
  ### DEFAULT ef_search (40)
  Limit (actual rows=50)                         <- CORRECT: 50 rows, all in scope
    ->  Sort (top-N heapsort)
          ->  Bitmap Heap Scan on kioku_memories (actual rows=2000)
                ->  Bitmap Index Scan on kioku_memories_scope_idx

  ### SET hnsw.ef_search = 200
  Limit (actual rows=0)                          <- the vector channel returns NOTHING
    ->  Index Scan using kioku_memories_embedding_hnsw (actual rows=0)
          Rows Removed by Filter: 1648
  ```

  Read that carefully, because it inverts the naive intuition. **At the default, Postgres declined
  the ANN index entirely** and used the *scope* B-tree index (`kioku_memories_scope_idx`) with an
  exact top-N sort — and got a perfect answer. Raising `ef_search` made the ANN path look cheaper
  to the planner, it took that path, and it starved. So "make the ANN scan work harder" and "keep
  the planner off the ANN scan when the filter is selective" are **opposite strategies**, and at
  least in that probe the second one was already winning by accident. M1 exists to determine which
  regime kioku is actually in before anything is changed.

  Also recorded there: the premise behind the `ef_search` bump was itself false. pgvector searches
  with `ef = max(ef_search, LIMIT)`, so the 40 default never prevented the 50-row pool from
  filling.

- (Pre-implementation research, 2026-07-11.) **pgvector 0.8.2 is available, and only one of its
  relevant knobs has ever been tried.** Verified against the locked nixpkgs:

  ```bash
  nix eval --impure --raw --expr \
    '(builtins.getFlake "/Users/shinzui/Keikaku/bokuno/kioku").inputs.nixpkgs.legacyPackages.aarch64-darwin.postgresql.pkgs.pgvector.version'
  # => 0.8.2
  ```

  EP-5 tried `hnsw.iterative_scan = relaxed_order` once, saw zero rows, and stopped — reasonably,
  since it was measuring something else at the time. **`strict_order` was never tried.
  `hnsw.max_scan_tuples` was never tried. `hnsw.scan_mem_multiplier` was never tried.** Nor was any
  pre-filtering approach. So the phrase "iterative_scan doesn't work", which the previous
  initiative's notes can be read as implying, is not supported: one mode of one option was measured
  once. Treat the option as **open**, not closed.

- (Pre-implementation research, 2026-07-11.) **There is no probe for pgvector's *version*, and one
  candidate remedy needs one.** `detectVectorCapability`
  (`kioku-core/src/Kioku/Recall/Capability.hs:41-46`) probes `to_regtype('vector')` and the
  embedding column's declared width, and `VectorCapability` has four constructors
  (`VectorAvailable`, `VectorExtensionUnavailable`, `VectorColumnsUnavailable`,
  `VectorDimensionMismatch`) — **none of which can express "pgvector is present but too old".** If
  the bake-off's winner is `iterative_scan` (pgvector ≥ 0.8), this plan must add a version probe
  (`SELECT extversion FROM pg_extension WHERE extname = 'vector'`) and a way to degrade gracefully
  on older installs, because kioku is a library and its hosts' databases are not all this dev
  shell. That is a real cost, and it belongs in the bake-off's scoring (Decision 2), not as an
  afterthought.

- (Pre-implementation research, 2026-07-11.) **Nothing in the codebase sets any `hnsw.*` GUC
  today**, and the insertion point for one is small and clean. `selectVectorCandidates`
  (`kioku-core/src/Kioku/Recall.hs:232-241`) is a one-shot `runTransaction $ Tx.statement …` — the
  transaction contains only the SELECT. A `SET LOCAL` would go there, and its scope would be
  exactly that transaction. Note the corollary: because it is `SET LOCAL` in a transaction that
  runs one statement, any GUC change is per-query and cannot leak into the rest of the connection.

- (Pre-implementation research, 2026-07-11.) **Two methodology traps, inherited from EP-2 and
  restated because this plan will be doing a great deal of EXPLAINing.** Rows inserted inside an
  **open transaction never get an HNSW index scan** (EP-5 lost three attempts to this), so every
  measurement must run on committed data. And a **partial index needs its predicate restated in the
  query** — the index is `WHERE embedding IS NOT NULL`, and the statement's matching predicate is
  load-bearing, not decoration. Both traps produce confidently-wrong numbers rather than errors.


## Decision Log

Record every decision made while working on the plan.

- Decision 1: This plan names the candidate remedies and the judging criteria, but **does not name
  the winner**. The winner is chosen in M2, by measurement, and recorded here at that time.
  Rationale: The remedy is genuinely unknown. The obvious one was prescribed with confidence by
  EP-5 and measurement showed it would have silently emptied the vector channel exactly when recall
  matters most; pgvector's own documented remedy returned zero rows on its one tested mode. Across
  the preceding initiative, four plans (EP-1, EP-4, EP-5, EP-6) asserted something confident about
  a system the author had not run, and all four were falsified by execution — the one plan whose
  claims all held (EP-7) made only *static* claims, checkable by grep. A performance claim about a
  query planner is the most dynamic claim there is. Writing a winner into this plan today would be
  making the same mistake a fifth time, with better vocabulary.
  Date: 2026-07-11

- Decision 2: The winner must clear all of these bars, and the bake-off table must show it:
  (a) **recall@10 ≥ 0.9 on the starving corpus** — the primary bar, and the whole point;
  (b) **no regression on the healthy corpora** — the non-starving cells of EP-2's grid must not get
  worse, because a fix that trades a rare failure for a common one is not a fix;
  (c) **the query plan is stable and understood** — a remedy that works only because the planner
  happens to choose a particular path, with no mechanism forcing it, is a coincidence and will
  regress silently on a different corpus (this is precisely what EP-5's "default `ef_search` gets
  the right answer" turned out to be);
  (d) **latency stays within the same order of magnitude** on the healthy corpora;
  (e) **portability cost is paid explicitly** — if the remedy needs pgvector ≥ 0.8, it must come
  with a version probe and a documented degradation path, because kioku is a library and its hosts'
  databases are not this dev shell.
  Rationale: Stating the bar before running the experiment is what stops the experiment from being
  rationalised afterwards. (c) and (e) are the two that a hurried implementer will want to skip, and
  they are the two that the previous initiative's failures were made of.
  Date: 2026-07-11

- Decision 3: If the remedy is an index change, it lands as a **new migration**, created with
  `just new-migration`. The two existing migrations that create the HNSW index
  (`2026-06-24-01-00-00-kioku-memory-embeddings.sql` and
  `2026-07-11-17-45-43-kioku-embedding-schema-heal.sql`) must **not** be edited.
  Rationale: Both have been applied to real databases, and codd keys applied migrations by filename
  with no checksums — so an in-place edit is a silent no-op on every database that already ran
  them, producing a fleet where the index differs by deployment date. (The preceding initiative's
  EP-6 hit the mirror image of this and had to edit a migration in place *because* that was the only
  way to fix fresh databases too; same mechanism, opposite conclusion here.) `just new-migration` is
  mandatory rather than stylistic: it also rewrites the `-- Last added:` line in
  `kioku-migrations/src/Kioku/Migrations.hs`, which is what defeats the Template Haskell stale-embed
  trap. `touch` does **not** work — GHC's recompilation check is content-based — and a hand-added
  migration that leaves the embed stale will now fail `kioku-migrations-test` with an actionable
  message, which is EP-6's guard doing its job.
  Date: 2026-07-11

- Decision 4: A remedy that makes the vector channel's emptiness *observable* is in scope even
  though it is not, strictly, a fix.
  Rationale: The deepest reason this defect survived is that an empty vector channel is silent — RRF
  fusion degrades to keyword-only with no error and nothing in `RecallHit` recording it. Whatever
  remedy wins, a starving vector channel will remain *possible* in some corner (see the honest-limits
  milestone). If it can happen, it should be visible: a log line, a metric, or a field. This is
  cheap, it is squarely within the initiative's purpose, and it is what converts the next occurrence
  of this bug from a two-plan investigation into a glance at a dashboard.
  Date: 2026-07-11

- Decision 5 (**the M2 choice, resolving Decision 1**): Ship **`hnsw.ef_search` set to the candidate
  pool size, plus an exact pre-filtered pass that runs whenever the approximate pass returns fewer
  rows than the pool.** Reject `hnsw.iterative_scan` in every mode and at every budget.
  Rationale: measured, five runs per cell on five freshly built HNSW indexes (see Outcomes for the
  full table and Surprises for why the sample size is not optional). The shipped remedy returns
  recall@10 = 1.00 on both starving corpora, 5 times out of 5, and leaves the healthy corpora
  strictly better than before (the pool fills, 40 → 50) at indistinguishable latency (0.127–0.158ms
  vs 0.138–0.161ms). It clears bars (a) through (e); notably (e) is free, because it needs no
  minimum pgvector version.
  `iterative_scan` was the obvious answer, it is pgvector's own remedy for precisely this problem,
  and **round 1 of this bake-off named it the winner on a single passing run.** Five runs showed it
  is a lottery at 20000 rows: 2 of 5 for `relaxed_order`, 4 of 5 for `strict_order`. HNSW graph
  construction is randomized. It fails bar (a) at scale and fails bar (c) — "stable and understood"
  — as completely as a remedy can, because it would pass any test you gave it and starve at random
  in production.
  Bar (c) deserves a specific note, because the shipped remedy satisfies it in an unusual way. It
  does not force the planner onto a particular path. It makes **both paths correct**: the ANN path
  fills its pool when it can, and when it cannot, the exact path — which cannot starve, because it
  filters before it ranks — supplies the answer. The planner's choice therefore no longer determines
  correctness at all, which is a stronger property than "the planner reliably chooses well" and is
  exactly what the previous initiative's `ef_search` result showed we could not have.
  Date: 2026-07-11

- Decision 6: The exact pass is fenced with `OFFSET 0`, not with a `MATERIALIZED` CTE.
  Rationale: Both stop the planner from pulling the subquery up and reaching the HNSW index with the
  outer `ORDER BY`, which is the point. But `MATERIALIZED` forces every in-scope row's
  1536-dimension embedding into memory — about 6KB per row, so roughly 120MB for a 20000-row scope —
  while the fence streams and the top-N sort holds only 50 rows. The `OFFSET 0` is load-bearing and
  is commented as such in the source, because it looks exactly like the kind of thing a future
  reader tidies away.
  Date: 2026-07-11

- Decision 7: Decision 4's observability ships as a return value (`VectorChannelOutcome`,
  `vectorChannelStarved`, and `selectVectorCandidatesDiagnosed`), not as an emitted metric or log
  line.
  Rationale: `Kioku.Recall`'s effect row is `(Store :> es)`. The tracer and the metrics handle live
  on `Kioku.App.AppEnv`, which recall does not take and which threading through would be a real API
  change to a module three hosts depend on — disproportionate to the goal. The additive return value
  gives a host everything it needs to emit its own metric, is testable (both new cases assert on it),
  and costs nothing. The limit is stated plainly in `docs/user/recall.md`: kioku does not emit a
  metric itself, and a host that wants one must call the diagnosed variant. If that proves too
  passive in practice, wiring it to the tracer is a small follow-up with a clear owner.
  Date: 2026-07-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

### M1 — which regime are we in?

**The ANN regime.** Above roughly 2000 embedded rows the planner routinely chooses the HNSW path,
and the HNSW path starves whenever out-of-scope rows sit nearer the query than in-scope ones. The
exact plan — the one EP-5 saw return 50 perfect rows — protects only small corpora (200 rows, where
it is chosen in every cell) and one accidental cell (2000 in-scope × 10× decoys, where the larger
table happens to make the exact plan look cheaper). At 20000 in-scope rows the planner takes HNSW
at every decoy ratio and starves at every non-zero one.

So the family of remedy that matters is "make the ANN path survive a filter", not "keep the planner
off it" — with the important caveat that the second family is still a valid *fallback*, and the
bake-off measured it.

The measured boundary and the full grid are in EP-2's Outcomes
(docs/plans/18-build-a-recall-quality-harness-that-reproduces-filtered-ann-starvation.md); they are
not repeated here. What matters for this plan is the one-sentence answer above and the fact that the
planner's choice is *not* a reliable protection: it is a cost-model accident that flips with corpus
size, and it flips towards starvation as the corpus grows.

### M2 — the bake-off

Every candidate was measured through EP-2's harness, against the same seeded corpora, with a
ground truth known by construction. `k = 10`; the candidate pool is 50, so "50 rows" is a full
pool. **Every figure below is the median of five runs on five freshly built HNSW indexes**, for the
reason given in Surprises — a single run of anything touching HNSW is not a measurement.

```text
candidate                       starving          starving        healthy         healthy      plan      portability
                                2000+2000         20000+20000     2000+0          200+200
                                rows / r@10       rows / r@10     rows / r@10     rows / r@10
-----------------------------   --------------    -----------     -----------     -----------  -------   -----------
(baseline, today)               0 / 0.00          0 / 0.00        40 / 1.00       50 / 1.00    HNSW      --
iterative_scan=strict_order     50 / 1.00         1 / 0.10        50 / 1.00       50 / 1.00    HNSW      pgvector>=0.8
iterative_scan=relaxed_order    50 / 1.00         1 / 0.10        50 / 1.00       50 / 1.00    HNSW      pgvector>=0.8
strict + max_scan_tuples 200k   50 / 1.00         FLAKY (4 of 5)  50 / 1.00       50 / 1.00    HNSW      pgvector>=0.8
relaxed + max_scan_tuples 200k  50 / 1.00         FLAKY (2 of 5)  50 / 1.00       50 / 1.00    HNSW      pgvector>=0.8
ef_search = 200                 50 / 1.00 (luck)  0 / 0.00        50 / 1.00       50 / 1.00    UNSTABLE  none
ef_search = 50 (= pool size)    0 / 0.00          0 / 0.00        50 / 1.00       50 / 1.00    HNSW      none
status in the index predicate   0 / 0.00          0 / 0.00        40 / 1.00       50 / 1.00    HNSW      none
exact pre-filtered pass         50 / 1.00         50 / 1.00       50 / 1.00       50 / 1.00    exact     none
per-namespace partial HNSW      40 / 1.00         40 / 1.00       40 / 1.00       50 / 1.00    HNSW      unshippable
SHIPPED (ef_search=50 + exact
  fallback when pool short)     50 / 1.00 (5/5)   50 / 1.00 (5/5) 50 / 1.00 (5/5) 50 / 1.00    both      none
```

Latency, measured on the same corpora: the approximate pass is 0.13–0.16ms and is what runs on a
healthy recall. The exact pass costs ~7ms at 2000 in-scope rows and ~73ms at 20000, growing
linearly, and runs only when the approximate pass came back short. The shipped path's healthy-corpus
latency (0.127–0.158ms) is indistinguishable from the baseline's (0.138–0.161ms), so bar (d) holds.

**The winner: set `hnsw.ef_search` to the candidate pool size, and run an exact pre-filtered pass
whenever the approximate pass returns fewer rows than the pool.** It clears every bar in Decision 2:
recall@10 = 1.00 on both starving corpora, five runs out of five (a); no regression on the healthy
corpora, and in fact an improvement — the pool now fills, 40 → 50 (b); the mechanism forces the
outcome rather than hoping for a planner choice, and the *plan* no longer determines correctness
because both paths now return the right answer (c); healthy-corpus latency is unchanged (d); no
pgvector version floor, so there is no portability cost to pay (e).

**Why each loser lost.**

- **`hnsw.iterative_scan`, in every mode and at every budget — rejected on evidence, and this is the
  finding worth carrying forward.** It is pgvector's own remedy for exactly this problem, and at
  2000 rows it works perfectly. At 20000 rows it is a *lottery*: `relaxed_order` with a generous
  budget returned the right answer 2 times in 5, `strict_order` 4 times in 5, on five freshly built
  indexes. HNSW graph construction is randomized, so whether the iterative scan reaches the in-scope
  rows within its budget depends on the graph it happened to get. Round 1 of this bake-off ran it
  once, saw 50 rows and recall 1.00, and named it the winner. It was wrong. Fails bar (a) at scale
  and fails bar (c) catastrophically — a remedy that works 40% of the time passes every single test
  run you will ever give it.
- **`ef_search = 200`** — the remedy the previous initiative prescribed. It "works" at 2000+2000, but
  only because it flips the planner onto the *exact* plan, which is a coincidence, not a mechanism:
  at 20000+20000 the planner stays on HNSW and it returns zero. It also imposes a 60× latency
  penalty on the *healthy* 2000+0 corpus (7.7ms vs 0.13ms) by forcing the exact plan there too.
  Fails (a), (b), (c), and (d). The original warning against it was right, and understated.
- **`status = 'active'` in the index predicate** — no effect whatsoever on starvation (0 rows on
  both starving corpora). Correctly predicted, and worth having measured: it proves essentially all
  of the discard is the *scope* filter, not the status filter, which is what rules out the whole
  family of "fold the fixed predicates into the index" remedies. Fails (a).
- **`ef_search = 50` alone** — fixes the pool under-fill (40 → 50) at no cost, and does nothing at
  all for starvation. Kept, as half of the shipped fix; rejected as a fix on its own.
- **Per-namespace partial HNSW index** — the ceiling, measured to establish what "fixed" looks like.
  Genuinely pre-filtered, so it cannot starve, and it is the fastest option (0.12ms). Unshippable:
  namespaces are host-supplied data, not schema, so this would mean creating indexes at runtime.
  Note it *still* returns only 40 rows, not 50, because the `ef_search` under-fill is orthogonal to
  starvation — which is how that second bug was found.

### M3 / M4 — what shipped

`selectVectorCandidatesDiagnosed` in `kioku-core/src/Kioku/Recall.hs` runs the two passes and
returns a `VectorChannelOutcome` (`annRows`, `exactFallbackFired`, `rowsReturned`) alongside the
rows; `selectVectorCandidates` keeps its old shape and signature, so no host sees an API change.
`selectVectorCandidatesExactStmt` is the exact pass: the same predicates, but fenced with `OFFSET 0`
so the planner cannot pull the subquery up and reach the HNSW index with the outer `ORDER BY`. A
`MATERIALIZED` CTE would also have fenced it and was rejected — materialising forces every in-scope
row's 1536-dimension embedding into memory (~6KB each, so ~120MB for a 20000-row scope), whereas the
fence streams and the top-N sort holds only 50 rows.

No migration was needed: the fix is a query change and a `SET LOCAL`, not an index change. Decision
3's rules about never editing the existing index migrations therefore never came into play.

Two cases in `kioku-core/test/Kioku/RecallSqlSpec.hs` guard it, and EP-2's `expectFail` marker is
gone. "The vector channel does not starve on a selective scope" asserts the outcome *and the
mechanism* — that the approximate pass really did starve and the fallback really did fire — so that
if a future change makes the ANN pass succeed on this corpus, the case fails and tells you it has
stopped testing what it was built to test, rather than passing vacuously. "A healthy scope never
pays for the exact fallback" is bar (b) as a test: it fails if the fallback fires on a corpus with
nothing to filter out, which is what would happen if anyone reverted the `ef_search` setting.

The honest limits are in `docs/user/recall.md` under "The vector channel's two passes" and at
`candidatePoolSize`, whose old comment — which asserted two things that turned out to be false — has
been rewritten rather than left to rot two lines from the fix.


## Context and Orientation

kioku is an event-sourced agent-memory library in Haskell (GHC 9.12, `cabal`, entered through a Nix
development shell). All commands run from the repository root,
`/Users/shinzui/Keikaku/bokuno/kioku`, and **must be run through `nix develop --command …`** — the
ephemeral test clusters take their Postgres binaries from `PATH`, and pgvector is only there inside
the dev shell. Format Haskell with `fourmolu -i <file>`.

### The vocabulary you need

An **embedding** is 1536 floats representing a text's meaning; similar meanings point in similar
directions. **Cosine distance** measures the angle between them: 0 identical, 1 perpendicular. In
SQL, pgvector spells it `<=>`.

**ANN** is *approximate nearest neighbour* search — finding the closest vectors without scanning
every row. **HNSW** is the index that does it: a navigable graph descended towards the query point,
visiting a bounded number of candidates. The bound is `hnsw.ef_search` (default 40; pgvector
actually searches with `max(ef_search, LIMIT)`).

**Post-filtered** means the `WHERE` clause is applied to rows the index has already chosen by
distance. **Pre-filtered** would mean restricting the candidate set *before* the distance search —
which a plain HNSW index cannot do, and which is the root of everything here.

**recall@k** (the metric, not kioku's `recall` function — an unfortunate name collision): of the `k`
truly nearest in-scope memories, what fraction did the search return? 1.0 is perfect.

### The query, the index, and the other index

The statement, `kioku-core/src/Kioku/Recall.hs:435-451`:

```haskell
selectVectorCandidatesStmt :: Statement VectorCandidateQuery [MemoryRecord]
selectVectorCandidatesStmt =
  preparable
    ( "SELECT " <> memoryRecordColumns <>
      """
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

`$5` is `candidatePoolSize = 50` (`Recall.hs:545-546`), whose comment records the original repro —
read it, it is the condensed version of this plan's problem statement.

The **HNSW index** (from `2026-07-11-17-45-43-kioku-embedding-schema-heal.sql`, and originally
`2026-06-24-01-00-00-kioku-memory-embeddings.sql`):

```sql
CREATE INDEX IF NOT EXISTS kioku_memories_embedding_hnsw
  ON kioku_memories USING hnsw (embedding vector_cosine_ops)
  WHERE embedding IS NOT NULL;
```

Note what is **not** there: no `status`, no `namespace`, no scope columns, and no build parameters
(`m` and `ef_construction` are pgvector defaults, 16 and 64). Every one of the query's other
predicates is therefore a post-filter.

The **scope index** (from `2026-06-24-00-00-00-kioku-base.sql`) — the one the planner used when it
declined the ANN path and got a *perfect* answer:

```sql
CREATE INDEX IF NOT EXISTS kioku_memories_scope_idx
  ON kioku_memories (namespace, scope_kind, scope_ref) WHERE status = 'active';
```

Both indexes exist simultaneously, and **which one Postgres picks is the crux of this plan.**

### Where a per-query setting would go

`selectVectorCandidates` (`kioku-core/src/Kioku/Recall.hs:232-241`) is a one-shot
`runTransaction $ Tx.statement …` containing only the SELECT. A `SET LOCAL hnsw.…` would go there
and would be scoped to that transaction alone, so it cannot leak into the rest of the connection.

### The capability probe, and the constructor it lacks

`kioku-core/src/Kioku/Recall/Capability.hs`:

```haskell
data VectorCapability
  = VectorAvailable
  | VectorExtensionUnavailable
  | VectorColumnsUnavailable ![Text]
  | VectorDimensionMismatch !Int !Int

detectVectorCapability :: (Store :> es) => Int -> Eff es VectorCapability
```

It probes `to_regtype('vector')` (deliberately — an extension installed into `public` satisfies
`pg_extension` but is still unusable on a connection whose `search_path` is `kiroku, pg_catalog`,
which is a real bug the previous initiative fixed) and the embedding column's declared width. **It
does not probe the extension's version**, and no constructor can say "present but too old". If the
winning remedy needs pgvector ≥ 0.8, you must add both.

### The instrument you will use — read EP-2 first

docs/plans/18-build-a-recall-quality-harness-that-reproduces-filtered-ann-starvation.md builds
`kioku-core/test/Kioku/RecallHarness.hs`, and **this plan is written entirely in terms of it**:

- `defaultStarvationCorpus :: CorpusConfig` and `seedCorpus :: CorpusConfig -> Eff es SeededCorpus`
  — build a corpus that starves, with a ground truth known by construction.
- `measureRecallQuality :: SeededCorpus -> Int -> Eff es RecallQuality`, returning `rowsReturned`,
  `recallAtK`, `k`, and `planText`.
- `explainVectorQuery :: SeededCorpus -> Eff es Text`.

**Read EP-2's Outcomes section before doing anything else.** It contains a characterisation table —
recall@10 and the chosen plan across corpus sizes and decoy ratios — that tells you which regime you
are in, and therefore which candidates are even plausible. If that table is missing, EP-2 is not
actually finished and this plan's hard dependency is unsatisfied; say so and stop.


## Plan of Work

Four milestones. M1 establishes *what kind of problem this is*, because the two families of remedy
are opposites and picking the wrong family is worse than doing nothing. M2 is a prototyping bake-off
— explicitly a prototype, in the sense PLANS.md sanctions: build the candidates cheaply, measure
them against the instrument, keep one, discard the rest, and write down why. M3 ships the winner.
M4 tells the truth about what the winner does not fix.

**Milestone 0 (a gate, not a milestone) — confirm the instrument exists.** Read EP-2's Outcomes
table. If it is absent, stop and finish EP-2. Everything below assumes you can seed a starving
corpus and measure recall@k against a known ground truth; without that you would be doing exactly
what this initiative was designed to prevent.

**Milestone 1 — which regime are we in?** The measured fact from EP-5 is that at the *default*
settings, Postgres declined the HNSW index and used the scope B-tree index with an exact top-N sort,
returning 50 perfectly correct rows — and that *forcing* the ANN path (by raising `ef_search`) is
what produced the zero-row disaster. If that generalises, then kioku's vector recall is mostly
saved by the planner's good judgement, and the failure mode is "sometimes the planner guesses wrong
and takes the ANN path". If it does not generalise — if at realistic corpus sizes the planner
routinely takes the ANN path and starves — then the failure is the ANN scan itself.

These call for opposite fixes. The first says: **keep the planner off the ANN path when the filter
is selective**, or make the exact path explicit rather than accidental. The second says: **make the
ANN path capable of surviving a filter**. Establishing which one is true is this milestone's entire
job, and it is a measurement, not an argument.

Use EP-2's grid and add the plan-shape question to it: for each cell, which index did Postgres
choose, and what was recall@10? Look especially for the boundary — the corpus size and selectivity
at which the planner flips from the exact plan to the ANN plan — because that boundary *is* the bug.
Record the answer in this plan's Outcomes before touching any code.

**Milestone 2 — the bake-off.** Build each candidate as a cheap prototype (a local edit, a `SET
LOCAL`, an extra index in a scratch migration — nothing shipped yet), run it against the starving
corpus and against the healthy corpora, and fill in a table: candidate, recall@10 on the starving
corpus, recall@10 on the healthy ones, latency, chosen plan, portability cost. Then apply Decision
2's bars.

The candidates, none of which is endorsed here:

1. **`hnsw.iterative_scan`** (pgvector ≥ 0.8; 0.8.2 is what the dev shell has). pgvector's own
   answer to exactly this problem: when the filter discards too much, keep scanning further into the
   graph rather than stopping at `ef_search` candidates. Two modes — `strict_order` and
   `relaxed_order` — plus `hnsw.max_scan_tuples` and `hnsw.scan_mem_multiplier`. **EP-5 tried
   `relaxed_order` once, saw zero rows, and stopped.** That is one mode of one option, measured
   once, while measuring something else. Try all of them properly. Cost if it wins: it pins a
   minimum pgvector version, which for a library means a version probe and a degradation path (see
   Decision 2(e) and the capability gap in Surprises).

2. **Put `status = 'active'` into the index predicate.** The index is already partial
   (`WHERE embedding IS NOT NULL`); making it `WHERE embedding IS NOT NULL AND status = 'active'`
   removes one post-filter entirely. This cannot help with the *scope* filter, which is dynamic — so
   on its own it is very unlikely to be sufficient. Measure it anyway: it is nearly free, and it
   tells you how much of the discard is status versus scope.

3. **Keep the planner on the exact path when the scope is selective.** If M1 shows the exact plan is
   the good one, the fix may be to make it *reliable* instead of accidental — for example by
   counting the in-scope embedded rows and, below a threshold, issuing a query the planner cannot
   answer with the ANN index (or by adjusting cost settings for that one transaction). This is the
   least fashionable candidate and possibly the right one: an exact scan over a few thousand rows is
   fast, correct, and has no failure mode at all. Its cost is an extra count query per recall, or a
   cached estimate, and that cost must be measured rather than assumed.

4. **Application-level iterative widening.** Query with the pool size; if the vector channel comes
   back short, re-query with a larger `LIMIT` (which raises pgvector's effective `ef`, since it
   searches with `max(ef_search, LIMIT)`). Simple, portable, no new pgvector version required, and
   pays its cost only in the rare bad case. Its risk is unbounded work on a pathological corpus, so
   it needs a cap — and a capped widening that still returns nothing is still a starvation, which
   makes Decision 4's observability requirement matter.

5. **A partial HNSW index per namespace.** Genuinely pre-filtered, and therefore genuinely
   starvation-proof within a namespace. Almost certainly rejected on operational grounds — namespaces
   are host-supplied data, not schema, so this would mean creating indexes at runtime — but it is the
   one candidate that attacks the root cause, so measure it once on the starving corpus to establish
   the *ceiling* the other candidates are being judged against. Even as a rejected candidate it is
   useful: it tells you what "fixed" would look like.

Write the whole table into Outcomes, **including the losers and why they lost.** EP-5's untabulated
single failure of `relaxed_order` is exactly why this plan had to reopen an option that reads as
closed; do not leave the next person the same puzzle.

**Milestone 3 — ship the winner.** Implement it properly: not the prototype, but the version with
the error handling, the capability probe (if it needs one), and the comments. If it needs a
migration, create it with `just new-migration` and never by hand (Decision 3). The acceptance is
simply that EP-2's starvation case now passes — and if EP-2 registered that case with `expectFail`,
**remove the marker**, or the suite will now fail on the unexpected pass. That is by design: it is
how EP-2 made this plan's success announce itself.

Add Decision 4's observability while you are here: whatever wins, a starving vector channel remains
possible in some corner, and it must stop being silent.

**Milestone 4 — the honest limits.** Whatever ships, something still starves; approximate search
under a dynamic filter has no total solution. Say what, precisely, and where a reader will find it:
update the long comment at `candidatePoolSize` (which currently documents the *unfixed* hazard and
will otherwise become a lie), and update `docs/user/recall.md` so a host integrator knows the
conditions under which the semantic channel degrades and what they would see. Then delete or rewrite
the MasterPlan's gap entry.

A plan that ships a fix and leaves a stale "this is broken" comment two lines from the fix has done
half its job. The previous initiative's most-cited artifacts are its honest limits sections; write
this one the same way.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/kioku`, inside the dev shell.

### M0 — the gate

1. Read docs/plans/18-build-a-recall-quality-harness-that-reproduces-filtered-ann-starvation.md,
   its Outcomes section in particular. Confirm the characterisation table is there and that
   `kioku-core/test/Kioku/RecallHarness.hs` exists and exports `defaultStarvationCorpus`,
   `seedCorpus`, `measureRecallQuality`, and `explainVectorQuery`.

2. Confirm the starvation case is present and currently failing (or `expectFail`-marked) in
   `kioku-core/test/Kioku/RecallSqlSpec.hs`:

   ```bash
   nix develop --command cabal test kioku-core:test:kioku-test 2>&1 | grep -i "starve"
   ```

   If any of this is missing, stop and say so. Do not "just build the harness quickly" as part of
   this plan — the separation is the whole point of the decomposition.

### M1 — characterise

1. Using EP-2's harness, run the grid (in-scope rows {200, 2000, 20000} × decoy ratio {0×, 1×,
   10×}) and record for each cell: rows returned, recall@10, and **which index the plan used**
   (grep the plan text for `kioku_memories_embedding_hnsw` versus `kioku_memories_scope_idx`).

   Every measurement runs on committed rows, after `ANALYZE kioku_memories`. See Surprises: rows in
   an open transaction get no index scan, and the resulting numbers are confidently wrong.

2. Find the flip. Narrow in on the corpus size / selectivity at which the planner switches from the
   exact plan to the ANN plan. That boundary is the bug's actual shape, and it decides which family
   of remedy is even relevant.

3. Write the table and the conclusion into this plan's Outcomes, and state in one sentence which
   regime kioku is in. Do this **before** writing any fix code. If you find yourself wanting to skip
   ahead, re-read the `ef_search` transcript in Surprises: that is what skipping ahead produced last
   time.

### M2 — the bake-off

1. For each candidate in the Plan of Work, build the cheapest possible prototype and measure it on
   (a) the starving corpus and (b) at least two healthy cells from the grid.

   For the GUC candidates, the insertion point is `selectVectorCandidates`
   (`kioku-core/src/Kioku/Recall.hs:232-241`), which is a one-shot transaction — a `SET LOCAL` there
   is scoped to that statement:

   ```haskell
   -- prototype only
   runTransaction do
     Tx.sql "SET LOCAL hnsw.iterative_scan = strict_order"
     Tx.sql "SET LOCAL hnsw.max_scan_tuples = 20000"
     Tx.statement query selectVectorCandidatesStmt
   ```

   Try `strict_order` and `relaxed_order`, and sweep `max_scan_tuples` and `scan_mem_multiplier`.
   **Do not stop at the first zero-row result** — that is precisely the mistake that left this
   option looking closed.

   For the index candidates, prototype in a scratch database with plain SQL (`CREATE INDEX …`) and
   `EXPLAIN` directly; do not create a migration until the winner is known.

2. Fill in the table, in Outcomes:

   ```text
   candidate                        | starving: rows/recall@10 | healthy: recall@10 | latency | plan chosen | portability
   ---------------------------------|-------------------------|--------------------|---------|-------------|-------------
   (baseline, today)                |                         |                    |         |             | —
   iterative_scan=strict_order      |                         |                    |         |             | pgvector>=0.8
   iterative_scan=relaxed_order     |                         |                    |         |             | pgvector>=0.8
   status in index predicate        |                         |                    |         |             | none
   exact-path strategy switch       |                         |                    |         |             | none
   application-level widening       |                         |                    |         |             | none
   per-namespace partial index      |                         |                    |         |             | operational
   ```

3. Apply Decision 2's bars, choose, and **write the choice and its evidence into the Decision Log**
   as a new dated entry. Name the losers and why. If nothing clears the bars, say so — that is a
   legitimate outcome, and it means the honest deliverable is a documented limit plus Decision 4's
   observability, not a fix. Do not ship something that fails bar (c) merely because it passes bar
   (a) on one corpus; a remedy that works by planner coincidence is what got us here.

### M3 — ship it

1. Implement the winner properly. If it needs a pgvector version probe, extend
   `kioku-core/src/Kioku/Recall/Capability.hs` (`SELECT extversion FROM pg_extension WHERE extname
   = 'vector'`) and add a `VectorCapability` constructor for "present but too old", with a
   degradation path that is at least as loud as the existing ones.

2. If it needs a migration:

   ```bash
   just new-migration kioku-recall-ann-fix
   ```

   **Never hand-create the file, and never edit the two existing index migrations** (Decision 3).
   `just new-migration` also rewrites the `-- Last added:` line in
   `kioku-migrations/src/Kioku/Migrations.hs`, which is what stops the Template Haskell embed from
   going stale. `touch` does not work — GHC's recompilation check is content-based — and
   `kioku-migrations-test` will fail with an actionable message if the embed goes stale, which is a
   guard doing its job rather than a bug.

3. Add Decision 4's observability: make an empty vector channel visible (a log line, a metric, or a
   field on the result). Keep it cheap.

4. Run the starvation case. It must now pass:

   ```bash
   nix develop --command cabal test kioku-core:test:kioku-test
   ```

   If EP-2 registered it with `expectFail`, remove the marker now — otherwise the suite fails on the
   unexpected pass. (That is the forcing function working as intended.)

5. Commit: `fix(recall): <the winning remedy>` — and put the measured evidence in the commit body,
   not just the mechanism.

### M4 — the honest limits

1. Rewrite the long comment at `candidatePoolSize` (`kioku-core/src/Kioku/Recall.hs:528-546`). It
   currently documents the unfixed hazard and warns the next reader not to reach for `ef_search`;
   after M3 it will be describing a world that no longer exists. Replace it with: what the remedy
   does, what it does **not** fix, and the conditions under which the vector channel can still come
   back short.

2. Update `docs/user/recall.md` so a host integrator knows when the semantic channel degrades and
   what they would observe.

3. Update the MasterPlan
   (docs/masterplans/3-kioku-follow-up-scene-freshness-and-filtered-ann-recall-quality.md): Progress,
   the Registry row for EP-3, Surprises, and the Outcomes & Retrospective — and since EP-3 is the
   last plan in that MasterPlan, fill in its Outcomes & Retrospective fully.

4. Full suite:

   ```bash
   nix develop --command cabal test all
   ```

   Rerun once on a `ConnectionTimeout` before investigating.

5. Commit: `docs(recall): record what the ANN fix does and does not fix`


## Validation and Acceptance

The primary acceptance is a single, unambiguous behavior: **the starvation case passes.**

```bash
nix develop --command cabal test kioku-core:test:kioku-test
```

It seeds 2000 in-scope memories and 2000 nearer decoys outside the scope, runs the vector channel,
and asserts a non-empty candidate list with recall@10 ≥ 0.5. Against today's code it fails
(reporting zero rows returned and ~1648 removed by filter); against this plan's code it must pass.
That is the whole plan, expressed as one test.

Beyond it, four things must hold, and each is checkable:

1. **No regression on healthy corpora.** Re-run EP-2's grid and compare against the M1 baseline
   recorded in Outcomes. The non-starving cells must not get worse. A fix that trades a rare
   failure for a common one is not a fix, and this is the check that catches it.
2. **The plan is chosen for a reason, not by luck.** The plan text for the fixed query must be
   stable across the grid and explicable. If the remedy works on the starving corpus but the plan
   flips between index scans depending on corpus size, it will regress silently — that is exactly
   what "the default `ef_search` happens to give the right answer" was.
3. **The bake-off table is in Outcomes, losers included**, with the reason each lost.
4. **The honest-limits documentation exists** and the `candidatePoolSize` comment no longer
   describes an unfixed bug.

Full-suite regression:

```bash
nix develop --command cabal test all
```

Expect green. On `TimeoutError (ConnectionTimeout {durationSeconds = 60})`, rerun before
investigating — ephemeral-Postgres startup contention, pre-existing.

A legitimate alternative outcome: **no candidate clears the bars.** If that is what the numbers say,
the acceptance changes to (a) the bake-off table recording every candidate and its failure, (b)
Decision 4's observability shipped so the next occurrence is visible rather than silent, and (c) an
honest-limits document. Say so plainly and do not ship a remedy that passes one bar and fails
another — the whole reason this plan exists as a separate document is that someone did that, with
confidence, and measurement caught it.


## Idempotence and Recovery

The prototyping in M2 is deliberately disposable: local edits, `SET LOCAL` statements, and scratch
indexes created directly in a throwaway database. Nothing in M2 should be committed except the
Outcomes table. If a prototype is left behind by accident, `git status` will show it — check before
starting M3.

Measurements are safe to repeat and cost nothing but time; every test case builds its own ephemeral
Postgres cluster and discards it. If a measurement produces an impossible number, suspect the two
traps in Surprises first, in this order: uncommitted seed data, then a missing `embedding IS NOT
NULL` predicate.

M3 is the only milestone that changes shipped behavior. If it adds a migration, the migration must
be **additive and idempotent** — `CREATE INDEX IF NOT EXISTS`, or a `DROP INDEX IF EXISTS` followed
by a create, guarded so that re-running it on a database that already has the new index is a no-op.
Building an HNSW index on a large table is slow and takes a lock; if the remedy replaces the
existing index, say so explicitly in the migration's comment and consider `CREATE INDEX
CONCURRENTLY` (noting that codd runs migrations in a transaction by default, which forbids
`CONCURRENTLY` — check codd's no-txn migration support before committing to that path, and record
what you find).

Reverting is clean: M3 is one commit, so `git revert` restores the previous query, and if the
migration is additive the extra index is harmless until it is dropped. If the remedy turns out to
regress a host's production corpus in a way the grid did not predict, that is the scenario Decision
4's observability exists for — and it is also why bar (b) is a bar.


## Interfaces and Dependencies

**Hard dependency: docs/plans/18-build-a-recall-quality-harness-that-reproduces-filtered-ann-starvation.md
must be complete**, including its Outcomes characterisation table. This plan consumes, and must not
reimplement:

- `Kioku.RecallHarness.defaultStarvationCorpus :: CorpusConfig`
- `Kioku.RecallHarness.seedCorpus :: (Store :> es) => CorpusConfig -> Eff es SeededCorpus`
- `Kioku.RecallHarness.measureRecallQuality :: (Store :> es) => SeededCorpus -> Int -> Eff es RecallQuality`
- `Kioku.RecallHarness.explainVectorQuery :: (Store :> es) => SeededCorpus -> Eff es Text`

If EP-2 shipped its starvation case with `expectFail` (its Decision 4), **this plan must remove that
marker in M3** — the Progress list has an item for it.

**This plan owns** `kioku-core/src/Kioku/Recall.hs` (the vector statement, `candidatePoolSize`, and
any `SET LOCAL`), `kioku-core/src/Kioku/Recall/Capability.hs` (if a version probe is needed), and
any new migration under `kioku-migrations/sql-migrations/`. EP-2 must not have changed any of these;
if it did, reconcile before starting.

New dependencies: none expected. A pgvector **version** floor (≥ 0.8) is a possible outcome of the
bake-off — it is not a Haskell dependency but it is a real portability cost, it must be probed at
runtime rather than assumed, and Decision 2(e) requires it to be priced into the choice rather than
discovered afterwards.

Public API surface: `recall`, `RecallRequest`, `RecallStrategy`, and `RecallHit` should be
**unchanged in shape** — hosts (rei, mori, shikigami) call these, and this plan is about better
answers, not a different API. The one permissible addition is Decision 4's observability, and if that
takes the form of a new field on a result type, treat it as a breaking change and say so in the
commit.

EP-1 (docs/plans/17-refresh-scenes-and-personas-when-a-memory-s-confidence-changes.md) is
independent of this plan and shares no file with it.
