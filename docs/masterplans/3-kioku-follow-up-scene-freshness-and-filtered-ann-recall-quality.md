---
id: 3
slug: kioku-follow-up-scene-freshness-and-filtered-ann-recall-quality
title: "Kioku Follow-Up: Scene Freshness and Filtered-ANN Recall Quality"
kind: master-plan
created_at: 2026-07-11T19:57:47Z
intention: "intention_01kwyhabypepdt1mwemmf0dvqa"
---

# Kioku Follow-Up: Scene Freshness and Filtered-ANN Recall Quality

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

The review-remediation initiative
(docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md, complete as
of 2026-07-11) closed every finding from the 2026-07-07 review and, in doing so, recorded two
defects it deliberately did not fix. Both are real, both are reproducible, and both were left
open for a reason rather than by oversight. This initiative closes them.

The first is a staleness bug. A scope's L2 "scene" — an LLM-written summary of the memories in
that scope, stored in `kioku_scenes` and mirrored to a plaintext file under `.kioku/scenes/` —
is rebuilt whenever the set of memories feeding it changes. EP-2 of the previous initiative
made forgetting trigger that rebuild, so archiving a memory now removes its content from the
scene. But a memory's **confidence** is part of what the scene is built from (it is hashed into
the scene's source hash and rendered into the LLM prompt), and changing it triggers nothing:
`MemoryConfidenceUpdated` falls through to `pure ()` in the scheduling projection. So today, a
host that downgrades a memory from `high` to `low` confidence — the ordinary way an agent
expresses "I am no longer sure about this" — sees the scene keep asserting it at high
confidence indefinitely, until some unrelated memory happens to be recorded in the same scope.
After this initiative, a confidence change refreshes the scene and, through it, the persona.

The second is a recall-quality bug, and it is the harder one. kioku's vector recall asks
Postgres for the 50 nearest memories to a query embedding, filtered to the caller's namespace,
scope, and `status = 'active'`. The HNSW index that makes this fast indexes **only** the
embedding column (its only predicate is `WHERE embedding IS NOT NULL`), so the index picks its
candidates by distance alone and the namespace, scope, and status predicates are applied
**afterwards**, to rows the index already chose. This is called a *post-filtered* approximate
nearest-neighbour scan, and it has a failure mode: when the filter is selective and correlated
with distance — a small scope inside a large namespace, which is the normal shape of kioku data
— the index can spend its entire search budget on rows the filter then discards, and return
few or zero results. EP-5 of the previous initiative reproduced exactly this (2000 rows in the
target namespace, 2000 nearer decoys in another: 1648 rows removed by the filter, **zero
returned**) while measuring a different change, recorded the repro at `candidatePoolSize`, and
stopped. It also proved the obvious remedy is not one: pgvector 0.8's `hnsw.iterative_scan` in
`relaxed_order` mode returned zero rows on the same probe. After this initiative, vector recall
returns the right memories for a selective scope, and we can prove it does — with a measurement
harness, not an argument.

In scope: the `MemoryConfidenceUpdated` scheduling gap and everything needed to verify it; a
reusable, seedable recall-quality harness that can construct the starving corpus on demand and
report both query plans and answer quality; and a fix for the starvation that the harness
proves works. Out of scope: any change to what a scene or persona *says* (the prompts and the
LLM contract are untouched); recall's fusion scoring, weights, and RRF constants; the
`MemoryTagsUpdated` event, which correctly schedules nothing because tags are in neither the
scene source hash nor the prompt (see Surprises); and any change to kioku's public recall API
shape — hosts (rei, mori, shikigami) must see the same types and the same call, only better
answers.


## Decomposition Strategy

Three child plans, split by functional concern rather than by file. The two gaps have almost
nothing in common — one is a scheduling projection in the distillation pipeline, the other is a
query planner problem in recall — so the decomposition's only real work is deciding how to
handle the ANN gap, whose *fix is not known in advance*.

EP-1 (scene freshness) is a single, well-understood behavior change with an already-diagnosed
mechanism, and it stands alone. It is first only because it is unblocked and cheap; nothing
depends on it.

The ANN gap is split into EP-2 (measure) and EP-3 (fix), and that split is the substantive
decision in this MasterPlan. The temptation is to write one plan that says "fix the starvation",
but the previous initiative's most expensive lesson forbids it: **a plan's claim about a system
it never ran is a hypothesis, not an instruction.** EP-5 asserted a remedy (`SET LOCAL
hnsw.ef_search = 200`), and measurement showed shipping it would have silently emptied the
vector channel exactly when the corpus is large and the scope is selective — an exact plan
returning 50 correct rows became an ANN scan returning zero. EP-6's Decision Log made a
confident claim about cabal and the solver rejected it outright. Any plan I write today that
names the remedy for filtered-ANN starvation would be making the same class of claim about a
query planner I have not run against a seeded corpus.

So EP-2 builds the instrument and EP-3 uses it. EP-2's deliverable is not a fix; it is the
ability to *see* — a seedable corpus generator that can dial namespace size, scope selectivity,
and decoy distance, plus the ability to capture `EXPLAIN ANALYZE` output and to score answer
quality (how many of the true nearest in-scope memories did recall actually return?). Its
acceptance is that it reproduces the starvation on demand and fails loudly when the vector
channel starves. That makes EP-2 independently valuable even if EP-3 never ships: today nothing
in the suite can tell a healthy vector channel from an empty one, which is precisely how this
defect survived. EP-3 then evaluates the candidate remedies against that instrument as a
prototyping milestone, commits to whichever measures best, and ships it with the harness as its
proof. Its plan names the candidates and how to judge them; it deliberately does **not** name
the winner.

Alternatives considered. A single ANN plan with an internal prototyping milestone was the
serious alternative, and PLANS.md explicitly sanctions prototyping milestones for exactly this
situation. It was rejected because the instrument outlives the fix: the harness is a permanent
regression test for recall quality, not scaffolding to be discarded once the fix lands, and
giving it its own plan means it gets its own acceptance criteria and cannot be quietly reduced
to whatever was needed to make one experiment run. Folding EP-1 into the ANN work was rejected
as unrelated — they share no file, no type, and no test. Adding a fourth plan for the
`MemoryTagsUpdated` event was rejected because research showed there is no bug there: tags are
in neither the scene's source hash nor its prompt, so scheduling nothing is correct.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Refresh scenes and personas when a memory's confidence changes | docs/plans/17-refresh-scenes-and-personas-when-a-memory-s-confidence-changes.md | None | None | Complete |
| 2 | Build a recall-quality harness that reproduces filtered-ANN starvation | docs/plans/18-build-a-recall-quality-harness-that-reproduces-filtered-ann-starvation.md | None | None | Not Started |
| 3 | Fix filtered-ANN starvation in vector recall | docs/plans/19-fix-filtered-ann-starvation-in-vector-recall.md | EP-2 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 and EP-2 are independent of each other and of everything else; either can start
immediately, and they can run in parallel. They touch disjoint files (EP-1:
`kioku-core/src/Kioku/Distill/L2.hs` and `kioku-core/test/Kioku/DistillSpec.hs`; EP-2:
`kioku-core/src/Kioku/Recall.hs` at most, plus a new test-support module and
`kioku-core/test/Kioku/RecallSpec.hs`).

**EP-3 has a hard dependency on EP-2**, and it is a genuine one rather than a scheduling
preference. EP-3's central milestone is a bake-off: it must run each candidate remedy against a
corpus that actually starves and compare both the query plan and the answer quality, then
choose. Without EP-2's harness there is no corpus, no quality metric, and therefore no basis on
which to choose — EP-3 would degenerate into exactly the "confident claim about an unrun
system" that this decomposition exists to prevent. EP-3's acceptance criteria are stated in
terms of EP-2's harness (a starvation case that fails before the fix and passes after), so EP-3
literally cannot be verified until EP-2 exists.

Neither ANN plan blocks EP-1, and EP-1 blocks nothing. If only one plan is implemented, EP-1 is
the one that delivers user-visible value on its own; if only one *pair* is implemented, it must
be EP-2 then EP-3, in that order.

Neither EP-1 nor EP-2 adds a SQL migration. EP-3 probably does (an index change is one of the
candidate remedies), and if it does, it mints a fresh timestamp for its filename — codd orders
migrations by filename timestamp, so no coordination beyond that is needed. Note for whoever
implements it: `just new-migration` is the only correct way to add one, because it also edits
`kioku-migrations/src/Kioku/Migrations.hs` to defeat the Template Haskell stale-embed trap
(`touch` does **not** work; GHC's recompilation check is content-based — this cost the previous
initiative a confusing false test failure, and EP-6 built a guard that will now fail the
`kioku-migrations-test` suite with an actionable message if a hand-added migration leaves the
embed stale).


## Integration Points

**The recall-quality harness (EP-2 defines, EP-3 consumes).** This is the only shared artifact
in the initiative, and the entire dependency graph hangs off it. EP-2 owns it and must land it
in a form EP-3 can build a bake-off on. Concretely, EP-2 creates a test-support module (proposed
path `kioku-core/test/Kioku/RecallHarness.hs`, exposed through the existing `kioku-test` suite)
exporting at minimum: a corpus seeder that takes the number of in-scope rows, the number of
out-of-scope decoy rows, and a knob controlling how much *nearer* the decoys are to the query
than the true answers (the correlation between the filter and distance is what causes
starvation — decoys must be nearer, or nothing starves); a deterministic embedding generator so
runs are reproducible without an embedding endpoint (the suite already uses an injected fake
embedder — EP-2 must reuse that seam, not invent a second one); a way to capture `EXPLAIN
(ANALYZE, BUFFERS)` for the vector candidate query as it is actually issued; and a quality
metric — given the seeded ground truth, how many of the true nearest in-scope memories did
`recall` return (recall@k), and how many rows did the filter discard. EP-3 must express its
acceptance purely in terms of these, and must not fork or reimplement the seeder.

**`selectVectorCandidatesStmt` and `candidatePoolSize` in `kioku-core/src/Kioku/Recall.hs`
(EP-2 reads, EP-3 owns).** EP-5 already exported `selectFtsCandidates`, `selectVectorCandidates`
and `vectorLiteral` as documented test seams — EP-2 should drive the query through those rather
than pasting the SQL into a test, so that when EP-3 changes the statement the harness measures
the new one automatically. EP-3 owns any change to the statement, the pool size, and the index.
EP-2 must not change them; if EP-2 finds it cannot measure without a change, that is a discovery
to record and hand to EP-3, not a change to make.

**The HNSW index (EP-3 only, but it is shared with the migration system).** The index is created
in two places today — `kioku-migrations/sql-migrations/2026-06-24-01-00-00-kioku-memory-embeddings.sql`
and again, self-healingly, in `2026-07-11-17-45-43-kioku-embedding-schema-heal.sql` — and both
create it as `USING hnsw (embedding vector_cosine_ops) WHERE embedding IS NOT NULL`. If EP-3's
remedy is an index change, it must not edit those files in place (they have been applied to real
databases; codd keys applied migrations by filename with no checksums, so an in-place edit is a
silent no-op on any database that already ran them). It must add a new migration that drops and
recreates, or creates an additional, index.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1 M1: confidence changes schedule a scene-regeneration timer with a per-event timer id (2026-07-11, commit `c22b7b5`)
- [x] EP-1 M2: end-to-end — a confidence change refreshes the scene row, the persona, and the mirror files (2026-07-11, commit `c22b7b5`)
- [ ] EP-2 M1: a seedable corpus generator with a deterministic fake embedder and a tunable decoy distance
- [ ] EP-2 M2: query-plan capture and a recall@k quality metric over the seeded ground truth
- [ ] EP-2 M3: a starvation regression case that fails loudly when the vector channel returns nothing
- [ ] EP-3 M1: characterise the starvation — where it starts, how it scales with corpus size and scope selectivity
- [ ] EP-3 M2: prototyping bake-off of the candidate remedies against EP-2's harness, with EXPLAIN evidence
- [ ] EP-3 M3: ship the winner (with its migration, if it needs one) and prove it on the starvation case
- [ ] EP-3 M4: document the honest limits of the shipped remedy


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

Discovered while authoring this MasterPlan (2026-07-11), each verified against the working tree:

- **`MemoryTagsUpdated` scheduling nothing is correct, not a second instance of the bug.** The
  natural assumption is that EP-1's gap has a twin, since `scheduleSceneTimersForEvent`
  (`kioku-core/src/Kioku/Distill/L2.hs:114-126`) has two fall-through arms, not one. It does
  not. What a scene is built from is exactly `atomSource`
  (`kioku-core/src/Kioku/Distill/L2.hs:341-343`), which is
  `(memoryId, content, priority, confidence, createdAt)`, and what the LLM sees is `renderAtom`
  (`L2.hs:349-358`), which renders the memory id, type, confidence, and content. **Tags appear
  in neither.** A tag change therefore cannot change the scene, and scheduling a regeneration
  for it would burn an LLM call to produce a byte-identical row. EP-1 must add exactly one arm.
- **Fixing L2 fixes L3 for free.** `regenerateScene` calls `scheduleL3PersonaTimerTx` after it
  upserts the scene row (`kioku-core/src/Kioku/Distill/L2.hs:236`), so persona regeneration
  cascades from scene regeneration. EP-1 does not need to touch `Kioku/Distill/L3.hs` at all;
  it needs to *test* that the cascade happens, which is a different and much cheaper thing.
- **The scene source hash is what stops the fix from amplifying LLM cost, and it already
  exists.** `regenerateScene` computes `sceneSourceHash` (`L2.hs:337-339`) over the atoms and
  skips the LLM call when it is unchanged. This is why the existing design can afford to
  schedule one timer per recorded memory: the first timer to fire regenerates, and the rest see
  an unchanged hash and skip. EP-1 inherits that protection — a confidence change *does* alter
  the hash (confidence is in `atomSource`), so it regenerates exactly once, and a redundant
  timer costs a hash comparison rather than an LLM call.
- **EP-1's real difficulty is timer-id collision, and EP-2 of the previous initiative already
  wrote down the answer.** keiro's `scheduleTimerTx` re-arms a conflicting timer id only while
  that timer is still `scheduled`; once it has fired, re-scheduling the same id is **silently
  dropped** (`kioku-core/src/Kioku/Distill/L2.hs:133-136` records this, and it is why the forget
  events suffix their source id with the event kind). Confidence, unlike the terminal forget
  events, can change repeatedly on the same memory — so a source id of
  `<memoryId>:confidence` works the first time and is silently dropped every time after. EP-1's
  source id must vary per event. This is the whole reason the previous initiative deferred it.
- **The HNSW index makes every one of recall's predicates a post-filter.** Both migrations that
  create it (`2026-06-24-01-00-00-kioku-memory-embeddings.sql:31` and the self-healing
  `2026-07-11-17-45-43-kioku-embedding-schema-heal.sql:59`) create it as
  `USING hnsw (embedding vector_cosine_ops) WHERE embedding IS NOT NULL` — the index's only
  predicate is on nullity. `status = 'active'`, `namespace`, `scope_kind`, and `scope_ref`
  (`kioku-core/src/Kioku/Recall.hs:441-448`) are all applied to rows the index has already
  chosen by distance. `status = 'active'` is a fixed predicate and so is a candidate for the
  index's own `WHERE` clause; the scope columns are dynamic and are not. EP-3 should start here.
- **The previous initiative's `ef_search` result is the single most important input to EP-3, and
  it is counter-intuitive.** Raising `hnsw.ef_search` made recall *worse, not better*: it moved
  the planner off an exact plan that returned 50 correct rows and onto an HNSW scan that spent
  its budget on rows the scope filter discarded (1648 removed, zero returned). The lesson EP-3
  must internalise is that **the planner sometimes already does the right thing** — choosing an
  exact scan when the scope is small — and a remedy that forces the ANN path can *cause* the
  starvation it was meant to cure. "Make the ANN scan work harder" and "avoid the ANN scan when
  the filter is selective" are opposite strategies, and EP-3 must measure which regime it is in
  before choosing.

- **An empty vector channel is silent, and that is the deepest reason this defect survived.**
  Recall fuses the two channels by rank (`fuseRecallCandidates`,
  `kioku-core/src/Kioku/Recall.hs:263-278`). A vector channel that returns zero rows contributes
  zero ranks, so the fused score degrades smoothly to pure full-text scoring: no error, no
  warning, and nothing in `RecallHit` records that the semantic half of a "hybrid" recall
  returned nothing. The caller gets plausible keyword results and cannot tell. **This is why
  EP-2's harness is not optional scaffolding**: a quality metric is the only thing that can
  distinguish a healthy hybrid recall from a silently keyword-only one, and no existing test can.

- **pgvector 0.8.2 is what the dev shell and every ephemeral test cluster actually get**, so
  `hnsw.iterative_scan` (`strict_order` and `relaxed_order`), `hnsw.max_scan_tuples`, and
  `hnsw.scan_mem_multiplier` are all live options rather than hypothetical ones. Verified
  against the locked nixpkgs rather than assumed:

  ```bash
  nix eval --impure --raw --expr \
    '(builtins.getFlake "/Users/shinzui/Keikaku/bokuno/kioku").inputs.nixpkgs.legacyPackages.aarch64-darwin.postgresql.pkgs.pgvector.version'
  # => 0.8.2
  ```

  **And EP-5 only ever tried `relaxed_order`.** `strict_order`, `max_scan_tuples`, and
  `scan_mem_multiplier` were never measured, nor was a pre-filtering approach (a partial HNSW
  index carrying `status = 'active'`, or dropping to an exact scan when the scope is selective).
  So the design space EP-3 inherits is much less explored than "iterative_scan doesn't work"
  suggests — one mode of one option was tried once. EP-3 must not treat EP-5's single negative
  result as having closed the option.

- **Two methodology traps that already cost the previous initiative time, and will cost EP-2 and
  EP-3 the same if they are not respected.** First, a partial index needs its predicate restated
  in the query or the planner cannot prove the index applies — recall's `embedding IS NOT NULL`
  is load-bearing, not decoration. Second, **rows inserted inside an open transaction never get
  an HNSW index scan**, even with `enable_seqscan = off` and a fresh `ANALYZE`; every `EXPLAIN`
  must run against committed data. EP-5's first three attempts at this measurement drew the
  wrong conclusion from exactly that. The existing `RecallSqlSpec` seeding helpers commit (each
  `runTransaction` is its own transaction), so they are safe — but a harness that batches seeding
  into one transaction to go faster would silently invalidate every measurement built on it.


Discovered while implementing EP-1 (2026-07-11), and relevant beyond it:

- **The MasterPlan's central methodological claim was itself tested, and it held.** This
  initiative's decomposition rests on the premise that a plan's confident claim about an unrun
  system is a hypothesis. EP-1 was the cheap case where the hypothesis could be checked directly:
  it *predicted* that the naive one-line fix (a fixed `<memoryId>:confidence` timer source id)
  would be silently swallowed by keiro's `ON CONFLICT … WHERE status = 'scheduled'` upsert on
  every confidence change after the first. Rather than trusting that, the implementation injected
  the naive fix and measured it — the due-timer count after two confidence changes stops at 2
  instead of 3:

  ```text
  two confidence changes schedule two distinct scene timers: FAIL
    test/Kioku/DistillSpec.hs:168:
    expected: 3
     but got: 2
  ```

  This matters for EP-3 in a way that is easy to miss. EP-1 is the *favourable* case for
  reasoning-without-running: a single case arm, in a mechanism (keiro's timer upsert) whose
  source we had read and quoted. Even there, the fix that "looks obviously right" is wrong, and
  only a differential test distinguishes it. EP-3 faces a query planner, which is a far less
  legible mechanism than a fifteen-line SQL upsert. The bar for "measure it" should be *higher*
  there, not lower — which is exactly why EP-2 exists.

- **`MemoryTagsUpdated` scheduling nothing is now pinned by a test, so the MasterPlan's
  out-of-scope claim is enforced rather than merely asserted.** The case "a tag change schedules
  nothing, because tags are not in the scene" passes both before and after EP-1's fix, which is
  correct and deliberate: it guards a non-behavior. It fails only if a future contributor "completes"
  the confidence fix by adding a tags arm, which would spend an LLM call rewriting a
  byte-identical scene row.

- **EP-1 touched no file EP-2 or EP-3 will touch, as the Dependency Graph predicted.** The commit
  is confined to `kioku-core/src/Kioku/Distill/L2.hs` and
  `kioku-core/test/Kioku/DistillSpec.hs`. No migration, no new dependency, and no change to
  `kioku-core/src/Kioku/Recall.hs`. The ANN work starts from an unchanged base.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Split the filtered-ANN gap into a measurement plan (EP-2) and a fix plan (EP-3),
  with a hard dependency, rather than writing one plan that names the remedy.
  Rationale: The remedy is genuinely unknown, and the previous initiative established — four
  times, expensively — that a plan's confident claim about a system its author never ran is a
  hypothesis. EP-5 measured the obvious remedy (`ef_search = 200`) and found it would have
  silently emptied the vector channel; pgvector's own `iterative_scan` returned zero rows on the
  same probe. Naming a winner today would repeat the error. Splitting also gives the instrument
  its own acceptance criteria, which matters because the harness is a permanent regression test
  for recall quality, not scaffolding: today nothing in the suite can distinguish a healthy
  vector channel from an empty one, which is exactly how this defect survived.
  Date: 2026-07-11

- Decision: EP-1 adds exactly one arm to `scheduleSceneTimersForEvent`
  (`MemoryConfidenceUpdated`), and deliberately leaves `MemoryTagsUpdated -> pure ()` alone.
  Rationale: A scene is built from `atomSource` = `(memoryId, content, priority, confidence,
  createdAt)` and rendered by `renderAtom`, which shows id, type, confidence, and content. Tags
  are in neither, so a tag change cannot alter the scene; scheduling a regeneration for it would
  spend an LLM call to rewrite a byte-identical row. Confidence is in both.
  Date: 2026-07-11

- Decision: EP-1's scene-timer source id must vary per confidence-change event (the event id or
  the update timestamp mixed in), not be a fixed `<memoryId>:confidence`.
  Rationale: keiro's `scheduleTimerTx` re-arms a conflicting timer only while it is still
  `scheduled`; once fired, a re-scheduled duplicate id is silently dropped. Confidence can change
  repeatedly on one memory, so a fixed source id would refresh the scene on the *first* change
  and silently never again — a bug strictly worse than today's, because it would look fixed.
  This is precisely why the previous initiative's EP-2 deferred this work rather than folding it
  into its forget-propagation arms, whose events are terminal and so can safely use a fixed
  `<memoryId>:<kind>` source id.
  Date: 2026-07-11

- Decision: EP-3 may not edit the two existing migrations that create the HNSW index; if its
  remedy is an index change it must add a new migration.
  Rationale: Both have been applied to real databases, and codd keys applied migrations by
  filename with no checksums — an in-place edit is a silent no-op on every database that has
  already run them, and would produce a fleet where the index differs by deployment date. (The
  previous initiative's EP-6 hit the mirror image of this and had to edit a migration in place
  *because* that was the only way to also fix fresh databases; the reasoning is the same
  mechanism, and it points the other way here.)
  Date: 2026-07-11

- Decision: The recall harness lives in the test suite (`kioku-core/test/`), not in library
  code, and reuses the existing injected fake embedder rather than adding a second seam.
  Rationale: It is an instrument, not a product feature — nothing a host links should depend on
  it. The suite already injects a fake embedder for vector-path tests (added by the previous
  initiative's EP-5, which had to give `DistillSpec` one when pgvector arrived in the dev shell);
  a second mechanism would be one more thing to keep honest. EP-2 must reuse that seam.
  Date: 2026-07-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
