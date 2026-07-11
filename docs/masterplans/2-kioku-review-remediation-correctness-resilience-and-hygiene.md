---
id: 2
slug: kioku-review-remediation-correctness-resilience-and-hygiene
title: "Kioku Review Remediation: Correctness, Resilience, and Hygiene"
kind: master-plan
created_at: 2026-07-07T14:58:12Z
intention: "intention_01kwyhabypepdt1mwemmf0dvqa"
---

# Kioku Review Remediation: Correctness, Resilience, and Hygiene

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

A four-area review of kioku (memory/recall, sessions, distillation, API/CLI/migrations) on
2026-07-07 confirmed the event-sourcing core is sound but found the L1 distillation pipeline
non-idempotent under its own timer regime, worker error handling that either silently drops
work or silently stops working, a forget path that never propagates to derived artifacts,
several invariants enforced only by racy read-then-write prechecks, and a set of schema,
migration, and CLI hygiene gaps. After this initiative, distillation re-fires never duplicate
memories and never amplify LLM cost; archiving a memory actually removes its content from
scenes, personas, and workspace mirror files; every worker either retries transient failures
with bounded backoff or dead-letters permanent ones, and no worker thread can die silently;
lineage and resume invariants are enforced in the aggregate or the schema rather than in
prechecks; the reconciliation migration survives the pending keiro schema relocation; and the
riskiest logic in each of these areas is covered by tests that fail before the fix and pass
after.

In scope: every finding from the 2026-07-07 review, both major and minor, plus the test
coverage gaps the reviewers identified for the logic being fixed. Out of scope: new product
features (for example enforcing awaiting deadlines with a new timer — we only document that
gap), performance work beyond the specific index and query findings, and any change to the
public API surface that is not needed to fix a finding. The recall-versus-read-model
global-scope asymmetry is resolved by decision and documentation, not by silently changing
retrieval behavior hosts may depend on.


## Decomposition Strategy

The findings were grouped by functional concern rather than by the review area that reported
them, because several findings recur across areas (for example, scope-identity string
collisions were reported independently by the distillation and schema reviewers, and the
idempotent-accept-without-payload-comparison pattern appears in both the memory and session
command layers). Each work stream produces an independently verifiable behavior change and
can be tested without the others being complete.

Seven child plans resulted. EP-1 makes L1 distillation idempotent and stops the idle-timer
cost amplification — it is first because every other distillation defect is amplified by
re-fires. EP-2 makes forgetting real by propagating archive/supersede/merge into scenes,
personas, and mirrors — a privacy-shaped gap that stands alone. EP-3 reworks worker error
handling (embedding worker ack policy, timer retry bounds, loop supervision) — one plan
because the failure taxonomy (transient/permanent/not-mine) must be designed once and applied
uniformly. EP-4 moves invariants into the aggregate and fixes the racy prechecks across both
session and memory commands — one plan because it is the same pattern in both places. EP-5
hardens the schema and recall SQL (missing indexes, NULL-blind unique constraints, vector
dimension validation, scope-identity escaping) — grouped because these are all
migration-plus-query changes verified the same way. EP-6 fixes the reconciliation and
migration machinery (keiro schema relocation, dead schema registry list, TH embed staleness) —
grouped because all three are "the migration system lies to you" defects. EP-7 sweeps the CLI
and API surface (ID parsing, scope grammar, flag conflicts, demo guards, dead API) — grouped
as low-risk polish that touches no core logic.

Alternatives considered: decomposing by review area (memory, session, distill, schema) was
rejected because it would put the two halves of the worker-resilience fix and of the
idempotency-contract fix in different plans that must modify the same functions the same way.
A single "fix everything" ExecPlan was rejected as far beyond the five-milestone/ten-file
guidance. Folding EP-6 into EP-5 was rejected because EP-6's verification (fresh-database
bootstrap against both pinned and HEAD keiro) is entirely different from EP-5's
(query-plan and constraint tests).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Make L1 distillation idempotent and debounce distillation timers | docs/plans/9-make-l1-distillation-idempotent-and-debounce-distillation-timers.md | None | None | Complete |
| 2 | Propagate memory forget operations to scenes, personas, and workspace mirrors | docs/plans/10-propagate-memory-forget-operations-to-scenes-personas-and-workspace-mirrors.md | None | EP-1 | Complete |
| 3 | Harden worker resilience with ack policy, bounded retries, and loop supervision | docs/plans/11-harden-worker-resilience-with-ack-policy-bounded-retries-and-loop-supervision.md | None | None | Complete |
| 4 | Enforce aggregate invariants for lineage, resume correlation, and idempotent commands | docs/plans/12-enforce-aggregate-invariants-for-lineage-resume-correlation-and-idempotent-commands.md | None | None | Complete |
| 5 | Harden schema and recall with indexes, constraints, and scope identity fixes | docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md | None | None | Not Started |
| 6 | Align read-model reconciliation with keiro schema relocation and guard embedded migrations | docs/plans/14-align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations.md | None | None | Not Started |
| 7 | Tighten CLI and API surface validation | docs/plans/15-tighten-cli-and-api-surface-validation.md | None | EP-3 | Not Started |


## Dependency Graph

There are no hard dependencies: every plan compiles and is verifiable on its own, so all
seven can in principle proceed in parallel. The recommended order is a first wave of EP-1,
EP-3, EP-4, and EP-5 (the correctness and resilience fixes that stop active data duplication,
silent worker death, and hangable queries), followed by EP-2, EP-6, and EP-7.

The soft dependencies exist to reduce churn, not to gate work. EP-2 benefits from EP-1
landing first because both touch distillation timer scheduling (EP-1 rewrites the idle-timer
scheduling in `kioku-core/src/Kioku/Distill/Timer.hs`; EP-2 extends
`timerRequestsForEvent` in `kioku-core/src/Kioku/Distill/L2.hs` to fire on archive,
supersede, and merge events) — landing EP-1 first means EP-2 extends the final scheduling
shape instead of the one being replaced. EP-7 benefits from EP-3 landing first because both
modify `kioku-cli/src/Kioku/Cli/Commands/Worker.hs` (EP-3 restructures the worker loops and
their supervision; EP-7 only fixes flag parsing in the same file) — EP-7's change is trivial
to rebase, EP-3's is not.

Plans that add SQL migration files (EP-1 for the L1 watermark table; EP-5 for three schema
migrations) serialize trivially on migration timestamps: codd orders migrations by their
filename timestamp, so each plan mints a fresh timestamp when it creates its file and no
coordination beyond that is needed. Authoring research corrected the original assumption
here: EP-2 needs no migration (its fixes are DELETEs and code, no DDL), EP-4 needs no
migration and no read-model version bump (embedded statements only), and EP-6 edits the
existing reconciliation migration in place rather than adding one (codd keys applied
migrations by filename with no checksums, and only an in-place edit also fixes fresh
keiro-HEAD databases). EP-6's embedded-migration staleness guard, once landed, protects
every later plan that adds a migration file; landing EP-6 early in the second wave maximizes
that benefit.


## Integration Points

Fire-outcome contract (EP-1, EP-3). Both plans touch how a distillation timer fire reports
failure in `kioku-core/src/Kioku/Distill/Timer/Worker.hs` (today: `Maybe EventId` — the
review text said `Maybe UTCTime`, corrected during plan authoring — where `Nothing` conflates
"transient failure", "permanent failure", and "not my timer", producing unbounded 300-second
requeues). EP-3 owns the replacement: `FireOutcome` in a new module
`kioku-core/src/Kioku/Distill/Timer/Outcome.hs` with constructors for completed /
retry-later / permanently-failed / not-mine, which the worker maps onto keiro's timer states
(`maxAttempts = Just 8`, dead-letter via keiro's terminal `dead` status). EP-1 consumes it:
its fire handlers classify LLM extraction and consolidation errors into that taxonomy. EP-1's
idempotency changes (deterministic atom identity, watermark staleness guard) are deliberately
correct under unbounded re-fires, so EP-1 does not need EP-3's contract to land first; if
EP-1 lands first it keeps returning `Maybe EventId` and EP-3 migrates its handlers
(mechanical by design).

Scope-identity rendering (EP-2, EP-5). `sceneRowId`, `personaRowId`, and the mirror-file
slugs derive row identity from unescaped namespace/kind/ref strings
(`kioku-core/src/Kioku/Distill/L2.hs` `renderScope`/slug logic and the same pattern in
`L3.hs`). EP-5 owns fixing the derivation (escaping or validation so distinct scopes cannot
collide). EP-2 must compute the rows and mirror paths it blanks or deletes by calling those
same functions — never by re-implementing the string format — so the two plans compose in
either order.

Distillation timer scheduling (EP-1, EP-2). Both extend timer-request emission driven by
projections: EP-1 changes L1 session-timer scheduling (`kioku-core/src/Kioku/Distill/Timer.hs`)
and EP-2 adds scene/persona regeneration triggers for archive/supersede/merge events
(`kioku-core/src/Kioku/Distill/L2.hs` `timerRequestsForEvent`). The shared artifact is the
set of timer IDs and process-manager names; both plans must keep timer IDs deterministic
(UUIDv5 over stable inputs) so re-projection never double-schedules, and neither may rename
an existing process-manager name (EP-3's dispatcher and EP-6's reconciliation both key on
them).

Migration directory and embed guard (EP-1, EP-5, EP-6). EP-1 and EP-5 add files under
`kioku-migrations/sql-migrations/` (EP-2 and EP-4 turned out to need none; EP-6 edits an
existing file in place). EP-6 owns the guard that the TH-embedded migration list
(`kioku-migrations/src/Kioku/Migrations.hs`) cannot silently go stale; until it lands, every
plan adding a migration must touch `Migrations.hs` (per the existing "Last touched" comment
convention) to force recompilation. No plan may hand-write registry-bump SQL: EP-6's
code-side reconciler (driven by `kiokuReadModelSchemas`) covers read-model version bumps
made by any sibling plan.

Worker CLI wiring (EP-1, EP-3, EP-7). `kioku-cli/src/Kioku/Cli/Commands/Worker.hs` is where
EP-1 swaps the L1 candidate lookup from `scopedScanCandidates 5` to recall-based candidates,
EP-3 restructures loop supervision, and EP-7 fixes the `--timers-once`/`--backfill` flag
conflict. EP-3 owns the file's structure; the other two make local edits and rebase.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1 M1: deterministic identity and honest failure inside the L1 pass — 2026-07-10 (`159bbf3`)
- [x] EP-1 M2: per-session watermark and debounced timers (kioku_l1_watermarks migration) — 2026-07-10 (`c6c3677`)
- [x] EP-1 M3: recall-based merge candidates in the worker — 2026-07-10 (`d63f93a`)
- [x] EP-1 M4: real validation for distillation LLM outputs — 2026-07-10 (`de9360a`)
- [x] EP-1 M5: end-to-end verification and evidence — 2026-07-10 (`cabal test all` → 31 passed, up from 19)
- [x] EP-2 M1: forget events schedule scene-regeneration timers — 2026-07-11 (`0ff7680`)
- [x] EP-2 M2: emptied scopes delete scene/persona rows and mirror files without the LLM — 2026-07-11 (`77c3c06`)
- [x] EP-2 M3: end-to-end — the timer worker propagates forgetting to every artifact — 2026-07-11 (`1ca8923`, asserted against the mirror files' real bytes)
- [x] EP-3 M1: embedding worker ack policy (retry/dead-letter/halt classification) — 2026-07-11 (`0400be1`)
- [x] EP-3 M2: FireOutcome taxonomy for distillation timers, bounded attempts, unknown-PM handling — 2026-07-11 (`39e4474`)
- [x] EP-3 M3: loop supervision, drain-before-sleep, startup backfill — 2026-07-11 (`7ba500f`, verified end-to-end against a real database)
- [x] EP-4 M1: resume correlation becomes an aggregate invariant (plus explicit forceResume) — 2026-07-11 (`77682c7`)
- [x] EP-4 M2: lineage validation at start and a cycle-proof chain query — 2026-07-11 (`ed5b768`)
- [x] EP-4 M3: honest idempotent accepts for session and memory commands — 2026-07-11 (`cd23156`)
- [x] EP-4 M4: turn identity contract — 2026-07-11 (`b3436c7`)
- [x] EP-4 M5: legacy decoder coverage and documentation truth — 2026-07-11 (`8ca34c1`, `cabal test all` → 88 passed, up from 43)
- [ ] EP-5 M1: schema-hardening migration (indexes, NULLS NOT DISTINCT, scope CHECKs)
- [ ] EP-5 M2: pgvector in the dev shell plus self-healing embedding-schema migration
- [ ] EP-5 M3: vector recall query fix (ORDER BY, ef_search) with EXPLAIN evidence
- [ ] EP-5 M4: embedding dimension validation at capability detection
- [ ] EP-5 M5: collision-free scope identity with legacy-id stability
- [ ] EP-5 M6: global-scope semantics documentation and haddocks
- [ ] EP-6 M1: location-agnostic reconciliation migration proven against both keiro layouts
- [ ] EP-6 M2: code-side read-model registry reconciler wired into kioku-migrate
- [ ] EP-6 M3: embed-staleness guard and just new-migration convention
- [ ] EP-6 M4: end-to-end sweep and library-api docs update
- [ ] EP-7 M1: strict ids at the CLI boundary, explicit lenient parser in the API
- [ ] EP-7 M2: scope grammar that can express colons
- [ ] EP-7 M3: bounded --limit options
- [ ] EP-7 M4: demo guard (--yes-write-events, demo-only scope, preflight print)
- [ ] EP-7 M5: worker --backfill/--timers-once mutual exclusion
- [ ] EP-7 M6: remove embedBatched and dead kioku-api dependencies, docs sweep


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

Discoveries made while authoring the child plans (2026-07-07), each verified against the
working tree or the pinned framework sources by the authoring pass:

- The distillation fire functions return `Maybe EventId`, not `Maybe UTCTime` as the review
  stated; all plan text was written against the real type.
- The embedding-worker failure mode is worse than reviewed but inverted: `AckHalt` makes
  shibuya exit the processor gracefully, `waitApp` returns, and the whole process exits 0
  silently — taking the forked timer loop with it. EP-3's supervision milestone fixes both
  the "process dies silently" and the "thread dies while process lives" directions.
- codd (v0.1.8) keys applied migrations by filename only, with no checksums — so EP-6 fixes
  the reconciliation migration by editing its body in place, the only approach that also
  works on fresh keiro-HEAD databases where the old body would fail before any new
  migration could run.
- The repository's own dev database is in the degraded no-pgvector state EP-5's finding 7
  describes (the Nix shell ships plain `pkgs.postgresql`), which makes EP-5's self-healing
  migration directly demonstrable — and means no vector-path test currently touches a real
  vector column. Also, `hnsw.ef_search` defaults to 40 while the candidate pool is 50, so
  the ORDER BY fix alone would not have filled the pool.
- EP-4's research invalidated one planned index: `getChain`'s recursive join resolves
  through the `kioku_sessions` primary key, and lineage validation is pure command-time
  checking, so the `previous_session_id` index EP-5 had staged was removed as write
  amplification. Likewise the memory supersession CTE needs no cycle guard (its `UNION`
  deduplicates and terminates); the session chain's `UNION ALL` is the only infinite loop.
- Deterministic L1 atom identity introduces a self-merge hazard (a re-run's MergeAtom
  target can equal the winner's own id, which would archive the only active copy); EP-1
  guards it by filtering targets equal to the winner id.
- keiki guards are re-run during replay and `TLit` event fields are not recovered by
  `solveOutput`, so EP-4's force-resume must be a real event payload field; old
  `SessionResumed` events decode with `force = isNothing correlationKey`. One deployment
  consequence: once new-format events exist, older library versions cannot decode them —
  no rollback across that boundary.
- Adjacent gap discovered by EP-2 and deferred: `MemoryConfidenceUpdated` changes scene
  source content but never triggers regeneration. Same mechanism as the forget events;
  candidate for a follow-up plan.
- The next keiro pin bump is a full cohort-migrate event (keiro HEAD renamed all migration
  filenames sentinel→timestamp and relocated its tables), not just the schema move EP-6
  handles; `Justfile`'s `CODD_SCHEMAS=kiroku` and TestSupport's `namespacesToCheck` will
  need `keiro` added then.
- Downstream consumers kikan and shikigami use neither `parseIdAnyPrefix` nor
  `embedBatched` (verified via `mori registry dependents shinzui/kioku --packages`), so
  EP-7's renames/removals are safe; hosts calling `runKiokuMigrations` as a library must
  adopt EP-6's `reconcileReadModelRegistry` (documented in EP-6 M4).

Discovered during EP-1 implementation (2026-07-10), affecting sibling plans:

- **The keiro timer table is `kiroku.keiro_timers`, not `keiro.keiro_timers`, at the
  current pin.** Verified against the pinned checkout (`f1d67a01`,
  `dist-newstyle/src/keiro-*/keiro/src/Keiro/Timer/Schema.hs` reads
  `INSERT INTO keiro_timers` unqualified, and `keiro-bootstrap.sql` opens with
  `SET search_path TO kiroku, pg_catalog`). keiro HEAD *has* relocated the tables — that
  relocation is exactly what EP-6 handles. Any plan writing SQL against keiro's tables
  before EP-6 lands must use `kiroku.keiro_timers` or rely on search_path. EP-1's plan
  text and this MasterPlan's original assumption both said `keiro.` and were wrong.
- **`Kioku.Distill.L1` signature changed** in ways EP-3 and EP-7 will meet:
  `distillSessionL1 :: L1RunMode -> DistillRuntime -> FindMergeCandidates es -> SessionId ->
  Eff es (Either L1Error L1Outcome)`; `FindMergeCandidates` now returns
  `Either ReadModelError [MemoryRecord]`; `L1Error` gained `L1ConsolidationFailed`.
  EP-3's `FireOutcome` migration should map `L1ExtractionFailed`, `L1ConsolidationFailed`,
  and `L1MemoryReadFailed` to retry-later, and both `L1Distilled`/`L1SkippedUpToDate` plus
  `L1SessionNotFound` to completed.
- **`kioku-cli` now depends on `effectful`** (EP-1 M3 needed the effect row in
  `mergeCandidateFinder`'s signature). EP-7's dead-dependency sweep should not remove it.
- **`Kioku.Distill.Timer` exports changed**: `l1TimerId` is gone, replaced by
  `l1IdleTimerId`, `l1RampTimerId`, and `l1FinalTimerId`. `l1ExtractProcessManagerName` is
  unchanged, as EP-3's dispatcher and EP-6's reconciliation both require.
- **`DistillSpec` no longer chdirs.** Tasty runs cases concurrently, and the spec's
  `withCurrentDirectory` raced as soon as a second database-backed case existed. Any
  sibling plan adding concurrent database tests should not reintroduce a process-wide
  chdir; `ephemeral-pg` keeps its cluster under `XDG_CACHE_HOME`, not the working directory.
- **The design pass missed a destructive case that a test caught immediately.** EP-1's
  planned self-merge guard (drop a target equal to the winner id) does not cover a winner
  id that was *already merged away* on a prior pass: the retry would then merge the scope's
  only active memory into a tombstone, leaving zero active rows. Plans that introduce
  deterministic identity over mutable rows (none of the remaining six do today) need the
  companion guard: a deterministic id found in a retired state means "already processed".


Discovered during EP-3 implementation (2026-07-11), affecting sibling plans:

- **EP-5 inherits two pgvector landmines, both reproduced.** First,
  `kioku-core/test/Kioku/DistillSpec.hs:465` (`testRecallCandidateWindow`, added by EP-1)
  asserts `capability @?= VectorExtensionUnavailable` — it hard-codes the *absence* of
  pgvector, and its comment says that absence "is what makes dummyEmbeddingModel safe". The
  moment EP-5 M2 adds pgvector to the dev shell, that case fails and would start calling a
  dummy embedding endpoint; EP-5 must give it an injected fake embedder. Verified by running
  the suite against a pgvector build: that one case fails while all 43 others pass. Second,
  the embedding-columns migration
  (`kioku-migrations/sql-migrations/2026-06-24-01-00-00-kioku-memory-embeddings.sql`)
  **aborts** rather than degrading when pgvector is already installed in `public`: it runs
  `CREATE EXTENSION IF NOT EXISTS vector` (a no-op), passes its availability check, then
  fails on the unqualified `vector(1536)` type because migrations run with `search_path` set
  to `kiroku` (`42704: type "vector" does not exist`). Since `public` is where operators
  usually install pgvector, EP-5's self-healing migration must schema-qualify the type or
  create the extension into the target schema.
- **The fire-outcome contract is landed and EP-1's handlers are migrated.**
  `Kioku.Distill.Timer.Outcome` exports `FireOutcome (..)`, `fireRetryDelay`,
  `unknownTimerRetryDelay`, and `timerMarkerEventId` (moved out of its three duplicated
  private definitions). All three fire handlers now return `FireOutcome`;
  `Kioku.Distill.Timer.Worker` exports `applyFireOutcome`, `kiokuTimerWorkerOptions`
  (`maxAttempts = Just 8`), `runKiokuTimerWorkerOnce`, and `drainKiokuTimers`. Removed:
  `runKiokuTimerWorkerLoop`, `runL1TimerWorkerLoop`, `runL1TimerWorkerOnce`. The
  process-manager names are unchanged, as EP-2 and EP-6 require.
- **EP-7's rebase surface in `Worker.hs` is larger than planned but its own edit is
  untouched.** `runContinuousWorker`/`runTimerLoop` were rewritten and `startupBackfill`,
  `dieWorker`, and `storeErrorBackoffMicros` added, but `WorkerOptions` and
  `workerOptionsParser` were deliberately left byte-identical, so EP-7's
  `--timers-once`/`--backfill` mutual-exclusion fix applies cleanly. `kioku-cli` gained an
  `async` dependency (alongside the `effectful` one EP-1 added); EP-7's dead-dependency sweep
  must keep both.
- **A halted shibuya processor crashes rather than returning.** EP-3's research predicted a
  graceful `waitApp` return on `AckHalt`; in reality the halt surfaces as
  `ExceptionInLinkedThread ... blocked indefinitely in an STM transaction`. The worker now
  catches it and still exits 1 with a reason. Any sibling plan reasoning about shibuya
  processor shutdown should not assume a clean return.
- **The dev database's stale distillation timers now dead-letter instead of retrying
  forever.** The repository's dev database held seven overdue `kioku-l1-extract` timers that
  fail for want of an `ANTHROPIC_API_KEY`. Under the new attempt ceiling they will reach
  `status = 'dead'` after eight claims rather than cycling indefinitely — the intended
  behavior, but worth knowing before anyone reads those rows as a regression.

Discovered during EP-2 implementation (2026-07-11), affecting sibling plans:

- **`DistillRuntime` gained a `workspaceRoot :: Maybe FilePath` field, and the mirror
  helpers now take the runtime.** `Nothing` means `getCurrentDirectory` — production
  behavior is unchanged and the CLI needed no edit — but every plan that record-updates a
  `DistillRuntime` should know the field exists, and any plan asserting on scene/persona
  mirror files must set it rather than reaching for `withCurrentDirectory`. This was forced
  by EP-1's discovery that `DistillSpec` can no longer chdir (tasty runs cases
  concurrently): without an injectable root there is no way to observe a mirror file from a
  test without racing or writing into the repository working directory.
  `Kioku.Distill.Runtime` now also exports `distillWorkspaceRoot`.
- **EP-1 had accidentally committed test output.** `kioku-core/.kioku/{scenes,persona}/…md`
  (added by `159bbf3`) were the suite's own mirror files — content identical to
  `DistillSpec`'s canned `sceneResponse`/`personaResponse` — written because the tests
  mirrored into whatever directory they ran in. EP-2 deletes them, gitignores `.kioku/`, and
  moves the pre-existing `testReplayDistillation` onto the temp workspace, so the suite now
  writes nothing into the repository. Any later plan that sees a `.kioku/` directory appear
  in the tree should treat it as a bug, not a fixture.
- **The three fire handlers needed no changes, which confirms EP-3's contract composed as
  designed.** `Right Nothing` from an emptied-scope regeneration already maps to
  `FireCompleted`, so an emptied-scope timer completes rather than looping — EP-2 extended
  the L2/L3 regeneration semantics without touching `FireOutcome` or the dispatcher, exactly
  the independence the Integration Points section predicted.
- **Process-manager names are unchanged** (`kioku-l2-scene`, `kioku-l3-persona`), as EP-6's
  reconciliation requires, and no SQL migration was added — confirming Decision 6 and the
  Dependency Graph's corrected note that EP-2 needs no migration-timestamp coordination.
- **The `MemoryConfidenceUpdated` staleness gap is still open** and is now the only known
  event that changes a scene's source content without refreshing it. EP-2 deliberately
  deferred it (its timer id needs the update timestamp mixed in, because confidence — unlike
  the terminal forget events — can change repeatedly). It remains a candidate follow-up plan.

Discovered during EP-4 implementation (2026-07-11), affecting sibling plans:

- **A plan-level design decision was falsified by EP-1's code, and the failure mode generalizes.**
  EP-4's Decision Log had caller-supplied timestamps participate in idempotency conflict
  detection, on the premise that "a genuine retry re-delivers the identical record value". False:
  `kioku-core/src/Kioku/Distill/L1.hs` `recordAtom` derives a **deterministic** memory id (EP-1's
  entire idempotency mechanism) but stamps `recordedAt = now` on every pass, so an idle-timer
  re-fire — the regime EP-1 exists to survive — re-records the same atom under a later clock.
  Comparing the timestamp turned EP-1's design into a hard `MemoryConflict`; `DistillSpec`'s
  "merge with a missing target drops it and stays convergent" caught it immediately.
  **Resolution:** call-time timestamps (`recordedAt`, `startedAt`, `completedAt`, `failedAt`,
  `resumedAt`) are excluded from conflict detection — the entity id is the identity, and a retry
  that re-reads its clock is still a retry. Every semantic field is still compared. **Cross-plan
  lesson: EP-4's plan had already carved out this exact exception for `merge`; the error was not
  noticing the reason generalized to `record`. Any remaining plan that grants one operation an
  exception should check whether the rationale applies more broadly before assuming it does not.**
- **The unfixed `getChain` CTE does not time out — it hangs forever, uninterruptibly.** EP-4
  predicted its cycle test would trip tasty's 10-second timeout without the fix. It does not:
  the run hangs indefinitely (killed manually after 11 minutes) because the thread is blocked in
  a non-interruptible foreign call to libpq, which tasty cannot cancel. **No client-side timeout
  saves a caller from a runaway recursive CTE.** Any sibling plan that reasons about query
  timeouts as a safety net (EP-5's recall work is the obvious one) should not assume an
  application-level deadline can rescue a pathological query — the guard has to be in the SQL.
- **Read pinned framework sources from `dist-newstyle/src/<pkg>-<hash>/`, not the sibling working
  checkouts.** `/Users/shinzui/Keikaku/bokuno/keiro` is HEAD and its
  `runCommandWithProjections` takes `ValidatedEventStream`; the pin (`f1d67a01`) takes a bare
  `EventStream`. EP-4's plan called this out and was right, but the trap is easy to fall into and
  costs a confusing type error. Same applies to keiki and kiroku.
- **`Kioku.Session` gained `forceResume` and three error constructors** (`SessionInvalidLineage`,
  `SessionConflict`; `Kioku.Memory` gained `MemoryConflict`). EP-7's API-surface sweep should
  expect these in the public surface. `ResumeSessionData` gained `force :: Bool` — any sibling
  plan constructing one needs the field.
- **`SessionRegs` is no longer `'[]`.** It now carries `awaitedCorrelationKey` and
  `lastTurnIndex`. A guard added to any session edge from here on runs during replay too, so it
  must accept every event legitimate old code could have committed (EP-4's Surprises section
  documents the mechanism).
- **Deployment note, unchanged from the plan but now real:** new `SessionResumed` events carry a
  `force` field. New code reads old events (the decoder defaults `force = isNothing
  correlationKey`), but **old code cannot read new events** — do not roll the library back across
  this boundary once new-format resume events exist.

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Group findings by functional concern (seven plans) rather than by the review
  area that reported them.
  Rationale: Several findings recur across review areas — scope-identity collisions were
  reported by both the distillation and schema reviewers, and the idempotent-accept pattern
  appears in both memory and session command layers. Grouping by concern keeps each fix in
  one plan; grouping by area would force two plans to edit the same functions the same way.
  Date: 2026-07-07

- Decision: No hard dependencies between child plans; use soft and integration dependencies
  only, with a recommended two-wave order (EP-1/EP-3/EP-4/EP-5, then EP-2/EP-6/EP-7).
  Rationale: Every plan compiles and verifies independently. Hard dependencies would
  serialize work for no correctness benefit; the wave order simply prioritizes active data
  duplication, silent worker death, and hangable queries over hygiene.
  Date: 2026-07-07

- Decision: EP-3 owns the fire-outcome taxonomy (succeed / retry-later / dead-letter) for
  distillation timers; EP-1 is written to be correct under unbounded re-fires regardless.
  Rationale: The retry policy must be designed once and applied to all three timer handlers
  plus the embedding worker, which is EP-3's whole subject. Making EP-1's idempotency
  independent of retry policy means neither plan blocks the other.
  Date: 2026-07-07

- Decision: Resolve the recall-versus-read-model global-scope asymmetry by decision and
  documentation (in EP-5), not by silently changing recall behavior.
  Rationale: The plan document docs/plans/2-kioku-hybrid-retrieval-pgvector-fts-rrf.md
  records the broad recall semantics as intentional; hosts (rei, mori, shikigami) may depend
  on it. The defect is that two public APIs give the same MemoryScope value different
  meanings without saying so.
  Date: 2026-07-07

- Decision: Enforcing awaiting deadlines (a new expiry sweep or timer) is out of scope;
  EP-4 only corrects the documentation that currently implies deadlines are enforced.
  Rationale: The review found the deadline is stored and never read. Building enforcement
  is a feature with real design questions (who resumes, with what input), not a remediation.
  Date: 2026-07-07

- Decision: The dead `generic-lens`/`uuid` dependencies in kioku-api.cabal are removed by
  EP-7 only; EP-5 was revised to drop its duplicate claim.
  Rationale: Both plans independently claimed the cleanup during parallel authoring. EP-7
  is the surface-hygiene plan and gates the removal on an implementation-time re-grep
  (EP-5's scope-validator work could conceivably introduce a use of one of them).
  Date: 2026-07-07

- Decision: No `kioku_sessions.previous_session_id` index; EP-5 was revised to remove it
  from its migration.
  Rationale: EP-4's research showed the chain CTE joins through the primary key and its
  lineage validation is pure command-time checking — the index would be write amplification
  with no reader, the same defect class EP-5 fixes by dropping `kioku_turns_session_idx`.
  Date: 2026-07-07

- Decision: EP-6 keeps `kiokuReadModelSchemas` and makes it load-bearing (a code-side
  registry reconciler wired into kioku-migrate) instead of generating per-bump SQL.
  Rationale: keiro's registry statements are compiled into whatever keiro version kioku
  links, so the reconciler finds the table wherever that version puts it — pin-bump-proof
  by construction — and sibling plans' future read-model version bumps are covered without
  hand-written migrations (the failure mode that caused the original outage).
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)

## Revision Notes

- 2026-07-10: EP-1 implemented and marked Complete (commits `159bbf3`, `c6c3677`,
  `d63f93a`, `de9360a`). Checked off EP-1's five Progress milestones. Recorded six
  implementation discoveries in Surprises & Discoveries, three of which change sibling
  plans' assumptions: keiro's timer table is `kiroku.keiro_timers` at the current pin (this
  document previously said `keiro.`), `distillSessionL1`/`FindMergeCandidates`/`L1Error`
  changed shape for EP-3 to migrate, and `kioku-cli` acquired an `effectful` dependency
  that EP-7's dead-dependency sweep must not remove. The Integration Points section's
  fire-outcome contract is unchanged: EP-1 kept `Maybe EventId` and is correct under
  unbounded re-fires, as designed.

- 2026-07-07: Post-authoring reconciliation pass after all seven child plans were written.
  Corrected the fire-outcome integration point to the real type (`Maybe EventId`, replaced
  by EP-3's `FireOutcome`); corrected the migration-coordination note (only EP-1 and EP-5
  add migration files; EP-2 and EP-4 need none; EP-6 edits one in place); resolved two
  cross-plan conflicts found during authoring (duplicate kioku-api.cabal cleanup → EP-7;
  `previous_session_id` index → dropped) with matching revisions to
  docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md;
  filled the Progress section from the actual 32 child milestones; and recorded the
  authoring discoveries in Surprises & Discoveries.

- 2026-07-11: EP-2 implemented and marked Complete (commits `0ff7680`, `77c3c06`,
  `1ca8923`). Checked off EP-2's three Progress milestones. Recorded five implementation
  discoveries in Surprises & Discoveries. The load-bearing one for sibling plans is that
  `DistillRuntime` gained a `workspaceRoot` field (production behavior unchanged, but the
  mirror helpers now take the runtime), forced by EP-1's removal of `DistillSpec`'s chdir —
  a concrete case of one child plan's discovery changing another's design rather than just
  its assumptions. EP-2 also removed two mirror files EP-1 had accidentally committed and
  gitignored `.kioku/`. The plan's own integration constraints held: no migration, no
  process-manager renames, no re-implementation of the scope-identity string format (rows
  are deleted by the looked-up row's primary key and mirror paths come from
  `sceneMirrorPath`/`personaMirrorPath`), so EP-5 and EP-6 compose in either order as
  designed.

- 2026-07-11: EP-3 implemented and marked Complete (commits `0400be1`, `39e4474`,
  `7ba500f`). Checked off EP-3's three Progress milestones. Recorded five implementation
  discoveries in Surprises & Discoveries. Two of them are load-bearing for EP-5, which now
  inherits a failing-on-pgvector test in `DistillSpec` and a migration that aborts when
  pgvector already lives in `public` — both reproduced, neither fixed here, because both sit
  in EP-5 M2's scope. The fire-outcome contract this MasterPlan's Integration Points assigned
  to EP-3 is landed, and EP-1's handlers were migrated onto it as designed (mechanical, as
  predicted). Loop supervision was verified end-to-end against a real database rather than by
  inspection: the process now survives a database outage and exits 1 with a reason when a
  pipeline genuinely dies.

- 2026-07-11: EP-4 implemented and marked Complete (commits `77682c7`, `ed5b768`, `cd23156`,
  `b3436c7`, `8ca34c1`). Checked off EP-4's five Progress milestones. The suite went from 43 to
  88 passing tests. Both pre-implementation data audits passed against the dev database (zero
  awaiting/resume events; zero non-monotonic turn indexes), so both new aggregate guards shipped
  as designed with no contingency needed.

  Two discoveries are load-bearing for the remaining plans. First, **EP-4's own Decision Log was
  wrong about timestamps and EP-1's code proved it**: comparing caller-supplied timestamps in the
  idempotency contract broke L1 distillation's re-fire path, because `recordAtom` pairs a
  deterministic memory id with a fresh `recordedAt`. The contract now excludes call-time
  timestamps and compares only semantic fields; the plan's Decision Log records the supersession
  with evidence. The generalizable lesson — a plan that grants one operation an exception should
  check whether the reason applies to its siblings — is recorded in Surprises for EP-5/6/7.
  Second, **the unfixed chain query hangs uninterruptibly rather than timing out**, because the
  thread blocks in libpq; EP-5 should not treat application-level timeouts as a backstop for
  pathological SQL.

  EP-4 added no migration and no read-model version bump, as its plan predicted, so it imposes no
  migration-timestamp coordination on EP-5 or EP-6.
