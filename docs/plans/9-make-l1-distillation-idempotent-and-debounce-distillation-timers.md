---
id: 9
slug: make-l1-distillation-idempotent-and-debounce-distillation-timers
title: "Make L1 distillation idempotent and debounce distillation timers"
kind: exec-plan
created_at: 2026-07-07T14:58:23Z
intention: "intention_01kwyhabypepdt1mwemmf0dvqa"
master_plan: "docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md"
---

# Make L1 distillation idempotent and debounce distillation timers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

kioku distills agent sessions into durable memories ("L1 atoms") by running an LLM
extraction over the session's turns and consolidating each extracted atom against the
memories already active in the same scope. Distillation is driven by durable timers that
fire many times per session — at turn ramps (1, 2, 4, 8, 16, ...), thirty minutes after
every turn, and once at completion — and keiro's timer contract is explicitly
at-least-once, so every fire can also be repeated after a crash or a slow run. Today the
pipeline is not idempotent under that regime: each pass mints fresh memory ids, a
consolidation LLM failure silently stores the candidate anyway, a partially-failed merge
retries forever leaking one new memory per retry, and the duplicate detector only ever
sees the first five memories in a scope. On top of that, every recorded turn schedules its
own thirty-minute idle timer, so a 50-turn session buys roughly fifty full LLM
extraction+consolidation runs that add nothing.

After this change, re-running L1 distillation for a session is free and safe: a re-fire
with no new turns is a cheap database read that skips the LLM entirely (a per-session
"watermark" remembers the last distilled turn), a re-fire after a partial failure
converges to the same memories instead of duplicating them (memory ids are deterministic
functions of the session and atom content), consolidation failures are reported as
failures and retried rather than papered over, the consolidator sees relevance-ranked
candidates from the whole scope instead of an arbitrary five-row prefix, and each session
holds exactly one idle-flush timer that every new turn pushes forward — a true debounce.
You can see it working by running the new tests in
`kioku-core/test/Kioku/DistillSpec.hs` (they fail against the old code) and by running
`kioku distill session <sid>` twice against a live database: the second invocation reports
that the session is already distilled and creates no new rows.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1: deterministic atom/winner/audit identity in `Kioku.Distill.L1` (UUIDv5 helper, `recordAtom` uses it, self-merge guard, audit key derivation). — 2026-07-10
- [x] Milestone 1: consolidation failure returns `L1ConsolidationFailed` (delete `fallbackStoreDecision`); `FindMergeCandidates` propagates read errors; target existence filtered before recording the winner; audit rows record the applied (post-degrade) action. — 2026-07-10
- [x] Milestone 1: DistillSpec tests — re-run idempotency, consolidation-failure, multi-target merge with a missing target. — 2026-07-10 (commit `159bbf3`; `cabal test all` → 19 passed)
- [x] Milestone 1 (added): retired-winner guard — a deterministic winner id that already exists in a non-active state means the atom is already represented; skip rather than merge an active target into a tombstone. — 2026-07-10
- [x] Milestone 1 (added): `DistillSpec` no longer chdirs the process; tasty runs cases concurrently. — 2026-07-10
- [x] Milestone 2: migration `kioku-l1-watermarks` + `Migrations.hs` touch. — 2026-07-10 (`2026-07-10-14-41-38-kioku-l1-watermarks.sql`; embed count 26 → 27)
- [x] Milestone 2: watermark read/skip/write in `distillSessionL1`, new `L1RunMode` and `L1Outcome` types, call sites updated (worker fire, CLI distill `--force`, tests). — 2026-07-10
- [x] Milestone 2: single deterministic idle-timer id per session in `Kioku.Distill.Timer`; ramp/final ids keyed on stable inputs. — 2026-07-10
- [x] Milestone 2: DistillSpec tests — watermark skip without any LLM call; timer-row collapse (one idle row after N turns). — 2026-07-10 (commit `c6c3677`; timer test verified to fail with 3 idle rows against the old `fireAt`-keyed ids)
- [ ] Milestone 3: worker wires `recallCandidates` instead of `scopedScanCandidates 5`.
- [ ] Milestone 3: DistillSpec candidate-truncation test (duplicate outside the first five rows is found and merged).
- [ ] Milestone 4: real `Validatable` instances for `ExtractOutput` and `ConsolidationDecision` + unit tests.
- [ ] Milestone 5: full-suite validation, optional live end-to-end transcript, retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The fire-result type in the review finding and the MasterPlan is described as
  `Maybe UTCTime`, but the code returns `Maybe EventId`
  (`fireL1Timer :: ... -> Eff es (Maybe EventId)` in
  `kioku-core/src/Kioku/Distill/Timer/Worker.hs`). This plan is written against the real
  type and keeps it (the taxonomy replacement belongs to
  `docs/plans/11-harden-worker-resilience-with-ack-policy-bounded-retries-and-loop-supervision.md`).
- `Kioku.Memory.record` is already idempotent per memory id: it looks up the id first and
  returns `Right cmdData.memoryId` without emitting an event when the row exists
  (`kioku-core/src/Kioku/Memory.hs`, `record`, lines 56-66). Deterministic ids therefore
  make every re-recorded atom a no-op with zero framework changes.
- keiro's `scheduleTimerTx` upserts on `timer_id` and re-arms the row (updating `fire_at`
  and `payload`) only while it is still `scheduled`
  (`keiro/src/Keiro/Timer/Schema.hs`, `scheduleTimerStmt`, `ON CONFLICT (timer_id) DO
  UPDATE ... WHERE keiro_timers.status = 'scheduled'`). A stable idle-timer id per session
  therefore gives debounce semantics for free, and re-projection cannot resurrect a fired
  timer.
- Self-merge hazard: with deterministic winner ids, a re-run of a `MergeAtom` decision can
  name the previously stored copy of the same atom as a merge target — and that target's
  id now *equals* the winner's id. Without a guard, `Memory.merge target winner` would
  merge the memory into itself and transition the only active copy to the terminal
  `Merged` state, destroying it. Milestone 1 filters any target equal to the winner id.
- keiro's default worker policy never dead-letters (`defaultTimerWorkerOptions` has
  `maxAttempts = Nothing`, `requeueStuckAfter = Just 300`), so a fire that returns
  `Nothing` is retried every ~300 seconds forever. Every failure this plan converts from
  "silently succeed" to "return Nothing" must therefore be safe under unbounded retries —
  which the deterministic ids and the watermark provide.
- (Milestone 1, 2026-07-10) The self-merge guard the plan specified is necessary but
  **not sufficient**. The plan's guard only drops a merge target whose id equals the
  winner id. The destructive case that actually shows up on the very first re-run of the
  existing fixture is different: atom A's deterministic winner `W_A` was *merged away*
  into atom B's winner `W_B` during pass 1. On pass 2, the scope's only active memory is
  `W_B`, so the consolidator returns `MergeAtom [W_B]` for atom A. Here `W_B /= W_A`, so
  the plan's guard does not fire; `Memory.record W_A` is a no-op (the row exists, status
  `merged`), and `Memory.merge W_B W_A` then merges the only *active* memory into a
  tombstone — leaving the scope with zero active memories. Evidence: without the extra
  guard, `testRerunIdempotent` fails with `active == 0` after the second pass.
  The fix is a second guard on the merge/update path: look up the winner id before
  writing anything, and if the row exists with `status /= 'active'`, treat the atom as
  already represented and skip. Deterministic identity plus "an id I have already retired
  means I have already processed this exact atom" is what makes the pass convergent.
- (Milestone 2, 2026-07-10) The plan's Validation section says to query
  `keiro.keiro_timers`. At the pinned keiro (`f1d67a01`) the timer table is **unqualified**
  and lives in the `kiroku` schema — `scheduleTimerStmt` in the pinned
  `keiro/src/Keiro/Timer/Schema.hs` reads `INSERT INTO keiro_timers`, and
  `keiro-migrations/sql-migrations/2026-05-17-00-00-00-keiro-bootstrap.sql` opens with
  `SET search_path TO kiroku, pg_catalog`. (keiro HEAD *has* relocated to a `keiro` schema
  — that is exactly the relocation
  `docs/plans/14-align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations.md`
  handles.) The timer test therefore queries `keiro_timers` unqualified and lets
  search_path resolve it; the CLI transcript in Validation and Acceptance needs the same
  correction until EP-6 lands.
- (Milestone 2, 2026-07-10) `Kioku.Session.Domain`'s transducer only accepts `RecordTurn`
  `B.from Running`, so the watermark test cannot append a turn to the completed fixture
  session. `writeFixtureSession` was split into `writeRunningFixtureSession` (start + turns,
  still `Running`) and the completing wrapper; the watermark test uses the former. Fixture
  turns are now recorded one minute apart so the single idle timer's `fire_at` is
  observably re-armed forward — with all turns sharing one `recordedAt`, the old
  `fireAt`-keyed ids would have collided and hidden the defect.
- (Milestone 2, 2026-07-10) Evidence that the timer test is a real regression test:
  temporarily restoring the `fireAt`-keyed idle id makes it fail with
  `expected: 1 / but got: 3` (three distinct idle rows for a 3-turn session; the start
  event's idle collides with turn 1's because they share a timestamp).
- (Milestone 1, 2026-07-10) `DistillSpec` wrapped its single test in
  `withSystemTempDirectory` + `withCurrentDirectory`. `withCurrentDirectory` mutates the
  process-wide working directory, and tasty runs test cases concurrently by default — the
  moment the spec grew a second database-backed case, cases raced and failed with
  `changeWorkingDirectory: does not exist`. The chdir was vestigial: `ephemeral-pg`'s
  `startCached` puts its cluster under `XDG_CACHE_HOME`/`~/.cache/ephemeral-pg`
  (`ephemeral-pg/src/EphemeralPg/Internal/Cache.hs`, `defaultCacheConfig`), never in the
  working directory, and no other spec in `kioku-core/test/` chdirs. Removed.


## Decision Log

Record every decision made while working on the plan.

- Decision: Atom identity is deterministic — a UUIDv5 over the session id and the exact
  extracted atom content, decorated into a `MemoryId` with `Data.KindID.V7.decorateKindID`
  (the same mechanism `parseIdAnyPrefix` in `kioku-api/src/Kioku/Id.hs` already uses).
  Rationale: `Memory.record` accepts an existing id as a no-op, so a deterministic id
  makes every re-run of "store this atom for this session" converge on one row. UUIDv5
  keyed on content (not a per-pass nonce) also collapses the common case where a later
  ramp pass re-extracts the identical sentence. Keying on the *candidate* content (not the
  consolidator's `resultContent`) keeps the id stable even when the consolidation rewrite
  varies between retries. Cross-session repeats of the same sentence stay distinct rows by
  design (the session id is in the key); cross-session dedup remains the consolidator's job.
  Date: 2026-07-07
- Decision: A merge/update target equal to the deterministic winner id is dropped before
  any command runs; if no targets remain the atom is treated as already represented
  (counted as skipped) rather than re-stored.
  Rationale: prevents the self-merge destruction described in Surprises & Discoveries;
  a decision whose only target is the atom's own prior copy is exactly "nothing to do".
  Date: 2026-07-07
- Decision: Consolidation failure is an error (`L1ConsolidationFailed`), not a fallback
  store. `fallbackStoreDecision` is deleted. The fire returns `Nothing`, keiro requeues,
  and the retry is safe because ids are deterministic and the watermark has not advanced.
  Rationale: the fallback converted every transient LLM blip on a re-fire into a permanent
  duplicate that nothing cleans up (finding 2). Retry-later is the correct shape; the
  bounded-retry policy itself is owned by
  `docs/plans/11-harden-worker-resilience-with-ack-policy-bounded-retries-and-loop-supervision.md`.
  Date: 2026-07-07
- Decision: For `UpdateAtom`/`MergeAtom`, target ids are resolved against the read model
  *before* the winner is recorded; targets that do not exist are dropped; if none remain
  the decision degrades to a store — and the audit row records the *applied* action
  ("store") with the degradation noted in the rationale, not the LLM's claimed action.
  Rationale: recording the winner first and failing on a nonexistent target afterwards is
  what leaked one memory per retry (finding 3): `parseIdAnyPrefix` accepts any
  syntactically valid TypeID, and `Memory.merge` then returns `MemoryNotFound`
  deterministically (`kioku-core/src/Kioku/Memory.hs`, lines 122-136), so the fire failed
  after the winner write, forever. Dropping hallucinated targets (instead of erroring)
  avoids wedging a timer on a decision that can never succeed, and fixing the audit text
  fixes the "audit trail lies" half of finding 6. With deterministic winner ids, a crash
  after recording the winner but before the merges is also safe: the retry re-records the
  same id (no-op) and re-attempts the merges (each idempotent — `Memory.merge` returns
  `Right` for non-active losers).
  Date: 2026-07-07
- Decision: A per-session distillation watermark table `kioku_l1_watermarks
  (session_id text primary key, last_turn_index integer, distilled_at timestamptz)` is
  added; `distillSessionL1` skips (returning a new `L1SkippedUpToDate` outcome, no LLM
  call) when the stored `last_turn_index` is at least the session's current maximum turn
  index, and writes the watermark only after a fully successful pass.
  Rationale: this is the real debounce — every stale idle fire, duplicate re-fire, and
  post-completion leftover becomes two indexed reads. It supersedes the dead `turnCount`
  payload guard (finding 4): comparing the payload against the read model would misjudge
  passes that failed mid-way, whereas the watermark records what actually succeeded. The
  payload keeps carrying `turnCount` as diagnostic information only.
  Date: 2026-07-07
- Decision: The idle-flush timer id becomes stable per session (UUIDv5 over process
  manager + session id + "idle", with `fireAt` removed from the key), so every
  `TurnRecorded` re-arms one row instead of inserting a new one. Ramp ids are keyed on the
  turn index, the final id on the session alone. No outstanding-timer cancellation is
  added at session completion: the single leftover idle timer fires once, hits the
  watermark, and completes as a cheap no-op.
  Rationale: keiro's `scheduleTimerTx` upsert gives exact debounce semantics for a stable
  id (see Surprises & Discoveries). Cancelling inside the projection transaction would
  require a new `cancelTimerTx` in keiro or raw SQL against `keiro.keiro_timers` from
  kioku — a framework-boundary violation not worth one cheap no-op fire per session. All
  ids remain deterministic over stable event data, so re-projection never double-schedules
  (constraint shared with
  `docs/plans/10-propagate-memory-forget-operations-to-scenes-personas-and-workspace-mirrors.md`).
  Date: 2026-07-07
- Decision: The worker's candidate finder becomes `recallCandidates` (hybrid FTS+vector
  recall over the atom content, limit 8) instead of `scopedScanCandidates 5`.
  `Kioku.Recall.recall` already degrades gracefully to FTS-only when pgvector is absent
  and to keyword-only when the embedding call fails, so no capability gating is needed at
  the call site. The `kioku distill` CLI keeps its `--candidates scan|recall` flag and its
  `scan` default (CLI surface changes belong to
  `docs/plans/15-tighten-cli-and-api-surface-validation.md`).
  Rationale: `scopedScanCandidates` ignores the query and returns the first 5 rows of a
  priority-ordered scan, so any duplicate outside that window is invisible and gets
  re-stored forever (finding 1). Recall ranks by relevance to the candidate text across
  the whole scope.
  Date: 2026-07-07
- Decision: `FindMergeCandidates` returns `Either ReadModelError [MemoryRecord]`; a read
  failure fails the atom (mapped to `L1MemoryReadFailed`) instead of being swallowed into
  an empty candidate list.
  Rationale: an empty list tells the consolidator "nothing exists in this scope", turning
  a transient read failure into a stored duplicate (finding 5, second half).
  Date: 2026-07-07
- Decision: Audit `decision_id` is deterministic — UUIDv5 over session id, the pass's
  maximum turn index, and the atom content — so the existing
  `ON CONFLICT (decision_id) DO NOTHING` finally does its job: re-fires of the same pass
  write one row, while a later pass over new turns writes a new row.
  Rationale: the guard was inoperative because the key was a fresh `genMemoryId` per call
  (finding 5, first half). Including the turn index keeps a per-pass audit trail without
  collapsing genuinely distinct passes.
  Date: 2026-07-07
- Decision: Validation policy for LLM outputs (finding 6): values with a safe canonical
  form are normalized (priority clamped into [0, 100]; `atomType`/`confidence` lowercased;
  `targetMemoryIds` cleared on `StoreAtom`/`SkipAtom`), values without one are rejected
  with `Left` (empty atom content; unknown `atomType`/`confidence` after lowercasing;
  `UpdateAtom`/`MergeAtom` with an empty or unparseable target list). Rejection surfaces
  as shikumi's `ValidationFailure`, i.e. a failed extraction/consolidation, i.e. a
  retryable fire.
  Rationale: clamping the priority floor to 0 stops a hallucinated `-1000000` from
  permanently dominating every `ORDER BY priority ASC` candidate and injection query;
  rejecting unknown enums is honest where silent coercion to defaults was not; rejecting
  bad target lists (instead of silently degrading inside L1) means the audit can no longer
  record a merge that never happened. Normalizing instead of rejecting wherever a
  canonical form exists avoids wedging a timer on output the model produces persistently.
  Date: 2026-07-07
- Decision: (Milestone 1, implementation) Add a *retired-winner* guard alongside the
  planned self-merge guard: on the `UpdateAtom`/`MergeAtom` paths, look up the
  deterministic winner id before any write, and if the row exists with a non-`active`
  status, return `AppliedSkipped` with the note "this atom was already distilled and is
  now <status>; already represented". The `StoreAtom` path needs no such guard —
  `Memory.record` already no-ops on an existing id regardless of status, so it can neither
  resurrect nor duplicate.
  Rationale: see Surprises & Discoveries. Without it, the second pass over an unchanged
  session merges the scope's only active memory into a tombstone. The rule generalizes
  cleanly: a deterministic id that has already been retired is proof that this exact atom
  was processed and folded into something else.
  Date: 2026-07-10
- Decision: (Milestone 1, implementation) `AppliedDecision` became a record carrying the
  applied action, the winner id, the surviving targets, and an optional degradation note,
  replacing the three-constructor sum. `writeAudit` derives the audit row's `decision`,
  `target_ids`, `result_memory_id`, and rationale suffix from it.
  Rationale: the plan required the audit to record the applied (post-degrade) action and
  the surviving targets. Threading an "effective action" argument alongside the old sum
  would have let the two drift; making the applied decision the single source for the
  audit row makes that impossible by construction.
  Date: 2026-07-10
- Decision: Keep the fire result as `Maybe EventId` and keep `Nothing` as the only failure
  signal, per the MasterPlan integration contract; classify nothing here.
  Rationale: `docs/plans/11-harden-worker-resilience-with-ack-policy-bounded-retries-and-loop-supervision.md`
  owns the succeed/retry-later/dead-letter taxonomy. This plan's job is to be correct
  under unbounded at-least-once re-fires no matter which retry policy sits above it. When
  implementing, check whether that plan has already landed (look at the return type of
  `fireL1Timer`); if it has, classify `L1ConsolidationFailed`/`L1ExtractionFailed` as
  retry-later and adapt mechanically.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

kioku is a Haskell workspace (`cabal.project` at the repository root, GHC 9.12.4) with
four packages: `kioku-api` (shared id/scope/record types), `kioku-core` (the runtime:
memory and session aggregates, recall, the distillation pyramid), `kioku-cli` (the `kioku`
executable), and `kioku-migrations` (codd migrations embedded via Template Haskell).
Events are stored in Postgres through the kiroku/keiro frameworks (pinned in
`cabal.project`; keiro source is checked out at `/Users/shinzui/Keikaku/bokuno/keiro`).
LLM calls go through shikumi "programs" (typed prompt/parse pipelines; source at
`/Users/shinzui/Keikaku/bokuno/shikumi`).

The pieces this plan touches, all paths repository-relative:

*The L1 pass.* `kioku-core/src/Kioku/Distill/L1.hs` exposes `distillSessionL1`, which
loads the session row and its turns from the read model (`Kioku.Session.getById`,
`Kioku.Session.getTurns`), renders the turns into an `ExtractInput`, runs the extraction
LLM program (`Kioku.Distill.Extract`), and then folds over the extracted atoms. For each
atom, `applyAtom` asks a pluggable candidate finder (`FindMergeCandidates`, a newtype
around `MemoryScope -> Text -> Eff es [MemoryRecord]`) for possible duplicates, runs the
consolidation LLM program (`Kioku.Distill.Consolidate`) over candidate-plus-existing, and
applies the returned `ConsolidationDecision`: `StoreAtom` records a new memory,
`UpdateAtom`/`MergeAtom` record a "winner" memory and then merge the target(s) into it via
`Kioku.Memory.merge`, `SkipAtom` does nothing. Every atom also appends an audit row to the
`kioku_consolidation_decisions` table (created by
`kioku-migrations/sql-migrations/2026-06-24-02-00-00-kioku-distillation.sql`). The defects:
`recordAtom` calls `genMemoryId` for every atom (line 278), so every re-run mints new
rows; a `Left` from `runConsolidation` is replaced by `fallbackStoreDecision` (lines
216-219 and 339-346), which stores unconditionally; the winner is recorded before the
merges run (lines 242-265), so a failed merge (for example a hallucinated-but-parseable
target id, which `Memory.merge` deterministically rejects with `MemoryNotFound`) leaves
the winner behind and leaks another on each retry; the audit key is a fresh id per call
(line 310) so `ON CONFLICT (decision_id) DO NOTHING` (line 437) never fires; and
`scopedScanCandidates` (lines 123-133) swallows read errors into `[]` and truncates the
priority-ordered scope scan to its limit, blinding the consolidator to any duplicate
outside the first rows. An embedding/FTS-based finder, `recallCandidates` (lines 135-153,
built on `Kioku.Recall.recall`), already exists but is only reachable through the CLI's
`--candidates recall` flag — the production worker
(`kioku-cli/src/Kioku/Cli/Commands/Worker.hs`, lines 87 and 97) passes
`scopedScanCandidates 5`.

*Memory identity.* `MemoryId` is a `KindID "kioku_memory"` (a TypeID: prefix plus UUID;
`kioku-api/src/Kioku/Id.hs`). `parseIdAnyPrefix` shows how to build one from a raw UUID:
`KindID.decorateKindID (TypeID.getUUID tid)`. Crucially, `Kioku.Memory.record`
(`kioku-core/src/Kioku/Memory.hs`) checks the read model first and returns
`Right cmdData.memoryId` without emitting anything when the id already exists, and
`Kioku.Memory.merge` returns `Right loser` when the loser is no longer active — both
halves of the idempotency this plan needs are already in the aggregate layer.

*Timers.* `kioku-core/src/Kioku/Distill/Timer.hs` schedules L1 timers from session events
via an inline projection (`l1TimerScheduleProjection`, wired into every session command by
`kioku-core/src/Kioku/Session.hs`). `timerRequestsForEvent` emits: an idle timer at
`startedAt + 30min` on `SessionStarted`/`InteractiveSessionRecorded`; on every
`TurnRecorded` an idle timer at `recordedAt + 30min` (plus a ramp timer at `recordedAt`
when the turn index is 1, 2, 4, 8, 16, or a multiple of 16); and a final timer at
completion/failure. `l1TimerId` hashes the process-manager name, session id, kind, *and
fireAt* into a UUIDv5 — because `fireAt` differs per turn, every turn's idle timer is a
distinct row and none is ever superseded (finding 4). The `turnCount` written into the
payload (line 89) is read by nothing. keiro's timer machinery
(`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Timer.hs` and `Timer/Schema.hs`,
unchanged since the pinned tag `f1d67a01`) provides: `scheduleTimerTx` (an upsert on
`timer_id` that re-arms only `scheduled` rows), `claimDueTimer` (FOR UPDATE SKIP LOCKED),
`markTimerFired`, and a worker (`runTimerWorker`) that requeues rows stuck in `firing` for
more than 300 seconds and never dead-letters by default — at-least-once, so fire handlers
must be idempotent. `kioku-core/src/Kioku/Distill/Timer/Worker.hs` is the fire handler:
`fireL1Timer` parses the correlation id back into a `SessionId`, runs `distillSessionL1`,
and returns `Just` a marker `EventId` on success (or on `L1SessionNotFound`), `Nothing`
on any other error. It never reads the payload.

*LLM programs and validation.* `Kioku.Distill.Extract` and `Kioku.Distill.Consolidate`
define the shikumi input/output records. Output types derive shikumi's `Validatable` with
`deriving anyclass`, and the class default is `validate = Right`
(`shikumi/src/Shikumi/Schema.hs`, lines 331-333) — a no-op. Shikumi's adapters run
`fromModelChecked` on every parse (`shikumi/src/Shikumi/Adapter.hs`), which calls
`validate` and maps `Left` to `ValidationFailure :: ShikumiError` — so writing a real
`validate` body is all that is needed for bad outputs to surface as failed
extraction/consolidation calls. `ExtractedAtom.priority` flows unclamped into
`RecordMemoryData.priority` (L1.hs line 290) and from there into every
`ORDER BY priority ASC` read (for example `selectActiveByScopeStmt` in
`kioku-core/src/Kioku/Memory/ReadModel.hs`, lines 358-370) — a negative priority
dominates a scope forever (finding 6).

*Tests and tooling.* `kioku-core/test/Kioku/DistillSpec.hs` holds the single existing
distillation test. It gets a real Postgres from
`Kioku.Migrations.TestSupport.withKiokuMigratedDatabase` (ephemeral-pg + codd, no external
services needed), and replaces the LLM with a fixed-response interpreter run through
shikumi's trace/replay machinery (`replayProgram` builds a trace with `runTrace`/
`tracedLLM`, then re-runs the program through `runLLMReplay`). Study `replayRuntime`,
`writeFixtureSession`, and the raw-SQL helpers (`loadMemoryStatuses`,
`loadMergeAuditCount`) — every new test in this plan follows those patterns. Tests are run
with `cabal test kioku-core` from the repository root (inside the nix devShell; from
outside, prefix commands with `nix develop -c`). Migrations: `just new-migration
name=<slug>` scaffolds a correctly named file under `kioku-migrations/sql-migrations/`,
`just migrate` applies to the dev database; the embedded migration list in
`kioku-migrations/src/Kioku/Migrations.hs` is captured by Template Haskell at compile
time, so its "Last touched" comment must be edited whenever a SQL file is added.

Terms used below: a *watermark* is a per-session row remembering the highest turn index
that a fully successful distillation pass has covered; a *debounce* means many triggers
within a window collapse into one deferred execution (here: one idle timer per session
whose `fireAt` each turn pushes forward); *at-least-once* means the framework guarantees a
timer fires one or more times, never zero, so duplicate fires are normal operation.


## Plan of Work

The work is five milestones. Milestones 1 and 2 are the substance (identity/failure
semantics, then watermark/debounce); 3 and 4 are focused single-concern changes; 5 is
end-to-end proof. Each compiles and passes tests on its own.

### Milestone 1 — Deterministic identity and honest failure inside the L1 pass

Scope: `kioku-core/src/Kioku/Distill/L1.hs` only, plus tests. At the end, running
`distillSessionL1` twice over the same session state produces the same set of memory rows
and the same audit rows; a consolidation error fails the pass instead of storing; a
missing merge target is dropped (with an honest audit row) instead of poisoning retries.

In `kioku-core/src/Kioku/Distill/L1.hs`:

1. Add a deterministic id helper. Import `Data.UUID.V5 qualified as UUIDv5`,
   `Data.UUID qualified as UUID`, `Data.ByteString qualified as BS`, and
   `Data.KindID.V7 qualified as KindID` (the `mmzk-typeid` package is already a
   `kioku-core` dependency), plus a module-level UUID namespace constant in the same style
   as `l1TimerNamespace` in `kioku-core/src/Kioku/Distill/Timer.hs`:

   ```haskell
   l1AtomNamespace :: UUID
   l1AtomNamespace =
     fromMaybe UUID.nil $
       UUID.fromString "6b696f6b-752d-6c31-8000-61746f6d6964"

   l1AtomMemoryId :: SessionId -> Text -> MemoryId
   l1AtomMemoryId sid content =
     KindID.decorateKindID $
       UUIDv5.generateNamed l1AtomNamespace $
         BS.unpack (TE.encodeUtf8 (idText sid <> ":" <> content))
   ```

   In `recordAtom`, replace `memoryId <- genMemoryId` with
   `let memoryId = l1AtomMemoryId sid (unField atom.content)`. Because `Memory.record`
   accepts an existing id as a no-op, this alone makes `StoreAtom` idempotent.

2. Make consolidation failure an error. Add `L1ConsolidationFailed !Text` to `L1Error`.
   In `applyAtom`, replace the `fallbackStoreDecision` case with
   `pure (Left (L1ConsolidationFailed (Text.pack (show err))))` and delete
   `fallbackStoreDecision` entirely.

3. Propagate candidate-read errors. Change the newtype to
   `runFindMergeCandidates :: MemoryScope -> Text -> Eff es (Either ReadModelError [MemoryRecord])`.
   `scopedScanCandidates` returns the `Recall.getActiveByScope` result directly (still
   applying `take`); `recallCandidates` wraps its hits in `Right` (`Recall.recall` reports
   SQL failure through the `Store`/`StoreError` effects and degrades embedding failures
   internally, so it has no `Either` of its own). In `applyAtom`, a `Left err` from the
   finder becomes `Left (L1MemoryReadFailed err)`.

4. Restructure `applyDecision` for `UpdateAtom`/`MergeAtom` so nothing is written until
   the plan for the atom is known to be executable:
   - Compute `winnerId = l1AtomMemoryId sid (unField atom.content)` up front.
   - Parse target ids (`parsedTargetIds`), then drop any id equal to `winnerId` (the
     self-merge guard — see Surprises & Discoveries), then resolve each remaining id with
     `Memory.getMemoryRowById` and keep only those that exist. A read error here is
     `Left (L1MemoryReadFailed err)`.
   - If the surviving target list is empty and the original decision had targets: when
     the only reason is the self-guard (the atom's own prior copy was the target), the
     atom is already represented — return `AppliedSkipped`; otherwise (all targets
     hallucinated/missing) degrade to the `StoreAtom` path. Either way the audit must
     record what was *applied*.
   - Otherwise record the winner (idempotent) and run the merges; any merge `Left` still
     fails the pass, but a retry now converges: the winner re-records as a no-op and each
     already-done merge returns `Right`.

   To keep the audit honest, make `applyDecision` return the applied action alongside the
   result — extend `AppliedDecision` (or pass the effective action and effective target
   list to `writeAudit`) so the audit row's `decision` column says `store` when a
   merge degraded to a store, `skip` when the self-guard skipped, and its `target_ids`
   holds the surviving targets, with the rationale suffixed with a marker such as
   `" [targets missing; degraded to store]"`.

5. Deterministic audit key. Thread the pass's maximum turn index (see Milestone 2 — until
   then compute it locally: `maximum (0 : fmap (.turnIndex) turns)`; restructure
   `distillSessionL1`/`buildExtractInput` so the turns list is fetched once and shared).
   In `writeAudit`, replace the `genMemoryId` key with

   ```haskell
   auditKey =
     "kioku_consolidation_decision:"
       <> UUID.toText
         ( UUIDv5.generateNamed l1AtomNamespace
             (BS.unpack (TE.encodeUtf8 ("audit:" <> idText sid <> ":" <> Text.pack (show maxTurnIndex) <> ":" <> unField atom.content)))
         )
   ```

   The existing `ON CONFLICT (decision_id) DO NOTHING` is now a working idempotency guard;
   no SQL change is needed.

Tests (in `kioku-core/test/Kioku/DistillSpec.hs`, following the existing replay-runtime
pattern; each new test is its own `testCase` inside the existing group):

- *Re-run idempotency*: after the existing happy-path assertions, call `distillSessionL1`
  a second time with the same runtime and finder (in Milestone 2 this becomes
  `IgnoreWatermark`; before Milestone 2 lands no mode argument exists yet — write the test
  against whatever signature is current and update it in Milestone 2). Assert the total
  `kioku_memories` row count and the active count are unchanged, and the audit row count
  for the scope is unchanged. This test fails against the old code (the second pass stores
  another atom once candidates are exhausted, and always appends audit rows).
- *Consolidation failure stores nothing*: a runtime with
  `runConsolidate = \_ -> pure (Left (ValidationFailure "boom"))` (constructor from
  `Shikumi.Error`). Assert `distillSessionL1` returns `Left (L1ConsolidationFailed _)`,
  and that the scope has zero memories and zero audit rows.
- *Merge with a missing target*: seed one active memory A in the scope with
  `Memory.record` (a fresh `genMemoryId`), and build a consolidate response returning
  `MergeAtom` with `targetMemoryIds = [idText aId, idText ghostId]` where `ghostId` is a
  fresh, never-recorded `genMemoryId`. Assert the pass succeeds, A's status is `merged`,
  the winner is active, the audit row's decision is `merge` with only A in `target_ids`,
  and a second run leaves row counts unchanged.

### Milestone 2 — Per-session watermark and debounced timers

Scope: a new migration, `kioku-core/src/Kioku/Distill/L1.hs`,
`kioku-core/src/Kioku/Distill/Timer.hs`, `kioku-core/src/Kioku/Distill/Timer/Worker.hs`,
`kioku-cli/src/Kioku/Cli/Commands/Distill.hs`, and
`kioku-migrations/src/Kioku/Migrations.hs`. At the end, a session accumulates exactly one
idle timer row however many turns it has, and any fire that finds no new turns returns
without an LLM call.

1. Migration. Run `just new-migration name=kioku-l1-watermarks` (this mints a fresh UTC
   timestamp — do not reuse a timestamp from this document; sibling plans also mint
   migration files and codd orders by filename). Fill the scaffolded file with:

   ```sql
   -- codd: in-txn

   -- Migration: kioku-l1-watermarks
   -- Created: <scaffolded timestamp> UTC
   -- Per-session L1 distillation watermark: highest turn index covered by a
   -- fully successful pass. Used to skip re-extraction on timer re-fires.
   SET search_path TO kiroku, pg_catalog;

   CREATE TABLE IF NOT EXISTS kioku_l1_watermarks (
     session_id text PRIMARY KEY,
     last_turn_index integer NOT NULL DEFAULT 0,
     distilled_at timestamptz NOT NULL DEFAULT NOW()
   );
   ```

   Then edit the "Last touched" comment above `embeddedKiokuFiles` in
   `kioku-migrations/src/Kioku/Migrations.hs` (for example: `Last touched: 2026-07-07 l1
   watermarks migration.`) so Template Haskell re-embeds the directory.

2. Watermark logic in `L1.hs`. Add two private statements in the existing hasql style:
   a select of `last_turn_index` by `session_id`, and an upsert
   (`INSERT ... ON CONFLICT (session_id) DO UPDATE SET last_turn_index =
   GREATEST(kioku_l1_watermarks.last_turn_index, EXCLUDED.last_turn_index), distilled_at =
   EXCLUDED.distilled_at`). Introduce:

   ```haskell
   data L1RunMode = RespectWatermark | IgnoreWatermark
     deriving stock (Generic, Eq, Show)

   data L1Outcome = L1Distilled !L1Summary | L1SkippedUpToDate
     deriving stock (Generic, Eq, Show)

   distillSessionL1 ::
     (IOE :> es, Store :> es, Error StoreError :> es) =>
     L1RunMode -> DistillRuntime -> FindMergeCandidates es -> SessionId ->
     Eff es (Either L1Error L1Outcome)
   ```

   Flow: load session, load turns (once), compute
   `maxTurnIndex = maximum (0 : fmap (.turnIndex) turns)`; under `RespectWatermark`, if a
   watermark row exists with `last_turn_index >= maxTurnIndex`, return
   `Right L1SkippedUpToDate` before any LLM work; otherwise run the pass (Milestone 1
   shape) and, only when the fold completes with `Right`, upsert the watermark to
   `maxTurnIndex` and return `L1Distilled summary`. A failed pass leaves the watermark
   alone so the retry re-runs. Zero-turn sessions get watermark 0, so their re-fires skip
   too.

3. Call sites. `fireL1Timer` in `Timer/Worker.hs` passes `RespectWatermark` and treats
   both `L1Distilled _` and `L1SkippedUpToDate` as success (return the marker `EventId`).
   `runDistill` in `kioku-cli/src/Kioku/Cli/Commands/Distill.hs` gains a `--force` switch
   mapping to `IgnoreWatermark` (default `RespectWatermark`) and prints
   `"Session already distilled (no new turns); use --force to re-run."` on
   `L1SkippedUpToDate`. Update `DistillSpec` to the new signature (the happy-path and
   Milestone 1 tests pass `IgnoreWatermark` where they intend to force re-runs).

4. Debounced timer ids in `Timer.hs`. Replace `l1TimerId sid kind fireAt` with ids that
   omit `fireAt`:

   ```haskell
   l1IdleTimerId :: SessionId -> TimerId    -- raw: pm <> ":" <> sid <> ":idle"
   l1RampTimerId :: SessionId -> Int -> TimerId -- raw: pm <> ":" <> sid <> ":ramp:" <> show turnIndex
   l1FinalTimerId :: SessionId -> TimerId   -- raw: pm <> ":" <> sid <> ":final"
   ```

   (same `l1TimerNamespace`, same UUIDv5 construction). `timerRequestsForEvent` keeps its
   event->request mapping, only the ids change: every `SessionStarted`/
   `InteractiveSessionRecorded`/`TurnRecorded` idle request now shares the session's
   single idle id, so keiro's upsert re-arms the one row with the newer `fireAt` and
   payload — the debounce. Ramp requests keep firing at `recordedAt` with a per-turn-index
   id (stable under re-projection because the raw string is a function of event data
   only). Keep the payload exactly as today (`kind` + `turnCount`); it is diagnostic.
   Do not rename `l1ExtractProcessManagerName` and do not touch
   `timerRequestsForEvent` in `kioku-core/src/Kioku/Distill/L2.hs` (owned by
   `docs/plans/10-propagate-memory-forget-operations-to-scenes-personas-and-workspace-mirrors.md`).
   Pre-existing scheduled timers with old-style ids simply fire once, hit the watermark,
   and complete — no data migration.

Tests:

- *Watermark skip without LLM*: after a successful pass, run again with
  `RespectWatermark` and a runtime whose `runExtract = \_ -> pure (Left (ValidationFailure
  "extractor must not run"))`. Assert the result is `Right L1SkippedUpToDate` — if the
  extractor had been invoked the pass would have failed, so success proves no LLM call.
  Then record one more turn, run again with the same failing runtime, and assert the
  result is now `Left (L1ExtractionFailed _)` — proving new turns re-enable extraction.
- *Timer collapse*: after `writeFixtureSession` (3 turns + complete), query
  `keiro.keiro_timers` for `process_manager_name = 'kioku-l1-extract'` and the session's
  correlation id, grouping by payload kind. Expect exactly one `idle` row (with `fire_at`
  equal to the last turn's `recordedAt + 30min`), ramp rows for turns 1 and 2 only, and
  one `final` row. Against the old code this returns four idle rows — the test fails
  before, passes after.

### Milestone 3 — Recall-based merge candidates in the worker

Scope: `kioku-cli/src/Kioku/Cli/Commands/Worker.hs` (a local edit — the file's structure
is owned by
`docs/plans/11-harden-worker-resilience-with-ack-policy-bounded-retries-and-loop-supervision.md`)
plus one test. In `runTimerOnce`, detect the vector capability (same
`detectVectorCapability` call the other paths already make) and build the finder as
`recallCandidates (toEmbeddingModel config) capability 8`; thread `config` into
`runTimerOnce` and `runTimerLoop` (the surrounding `runWorker` already resolves it). Both
call sites at lines 87 and 97 stop referencing `scopedScanCandidates`. No capability
gating: `recall` runs FTS-only when pgvector is unavailable and keyword-only when the
embedding call fails.

Test (*candidate truncation*, the regression test for finding 1): in the ephemeral
database, seed six filler memories with priority 10 and one duplicate-of-the-atom memory
(content `"The user prefers concise answers."`) with priority 90 — the priority-ordered
scan's first five rows are all fillers, so `scopedScanCandidates 5` cannot see the
duplicate. Run one pass with `recallCandidates dummyModel capability 8` where `dummyModel`
is any `EmbeddingModel` value (ephemeral-pg has no pgvector, so `detectVectorCapability`
reports unavailability and no embedding call is made; FTS matches the duplicate). Assert
the consolidator received the duplicate (the replay consolidate response returns
`MergeAtom` when `existing` is non-empty) and the duplicate's status became `merged` — no
second copy stored. For contrast (optional but cheap), assert that the same fixture with
`scopedScanCandidates 5` stores a duplicate — documenting the exact failure being fixed.

### Milestone 4 — Real validation for distillation LLM outputs

Scope: `kioku-core/src/Kioku/Distill/Extract.hs` and
`kioku-core/src/Kioku/Distill/Consolidate.hs`. Replace the derived no-op `Validatable`
instances with hand-written ones implementing the policy from the Decision Log:

- `instance Validatable ExtractOutput`: map over atoms; strip and reject empty `content`
  (`Left "atom content must be non-empty"`); lowercase `atomType` and require one of
  `fact|pattern|preference|constraint|instruction` (else `Left` naming the value);
  lowercase `confidence` and require `high|medium|low`; clamp `priority` with
  `max 0 . min 100`. Return the normalized output. (Field values are `Field desc a`
  wrappers — use `unField`/`field` from `Shikumi.Schema.Types` to rewrap.)
- `instance Validatable ConsolidationDecision`: for `UpdateAtom`/`MergeAtom`, require a
  non-empty `targetMemoryIds` whose every element parses via
  `Data.TypeID.V7.parseText`-style checking — reuse `parseIdAnyPrefix @"kioku_memory"`
  from `Kioku.Id` (kioku-api is not a dependency of the two Distill modules today via
  anything but `Kioku.Prelude`; `Kioku.Id` is importable since `kioku-core` depends on
  `kioku-api`) — else `Left`; for `StoreAtom`/`SkipAtom`, normalize by clearing
  `targetMemoryIds`.

Because L1's `atomMemoryType`/`atomConfidence` defaults and `parsedTargetIds`'s
`mapMaybe` remain as belt-and-braces, no L1 change is required here; the difference is
that invalid outputs now fail the LLM call (shikumi `ValidationFailure` -> `Left` from
`runExtraction`/`runConsolidation` -> `L1ExtractionFailed`/`L1ConsolidationFailed` ->
retryable fire) instead of silently coercing.

Tests: pure `testCase`s (no database) asserting `validate` behavior directly — a
priority of `-1000000` clamps to 0 and `250` clamps to 100; `atomType "Preference"`
normalizes to `preference`; `atomType "vibe"` is `Left`; empty content is `Left`;
`MergeAtom` with `[]` or with an unparseable id is `Left`; `StoreAtom` with stray targets
comes back with `targetMemoryIds = []`. Also update the replay fixtures in `DistillSpec`
if any fixture output violates the new rules (the current fixtures are valid).

### Milestone 5 — End-to-end verification and evidence

Run the full suite and capture evidence into this plan (Progress, Surprises &
Discoveries, Outcomes). Where a live database and API keys are available, walk the
narrated CLI scenario in Validation and Acceptance and paste the transcript. Update the
MasterPlan's Progress section (`docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md`)
for EP-1's milestones.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kioku`. If not
already inside the project's nix devShell, prefix each command with `nix develop -c`.

Build and test cycle (after each milestone):

```bash
cabal build all
cabal test kioku-core --test-show-details=direct
```

Expected tail of a passing test run (test names will grow as milestones add cases):

```text
kioku
  ...
  Distillation pyramid
    replay distills duplicate turns into merged atom scene and persona: OK
    re-running distillSessionL1 creates no new memories or audit rows:  OK
    consolidation failure stores nothing and fails the pass:            OK
    merge with a missing target drops it and stays convergent:          OK
    watermark skips re-extraction until a new turn arrives:             OK
    a session accumulates one idle timer however many turns:            OK
    recall candidates find a duplicate outside the scan window:         OK
    extract/consolidate outputs are clamped and rejected:               OK

All 24 tests passed
```

To run only the distillation group while iterating:

```bash
cabal test kioku-core --test-show-details=direct --test-options='-p "Distillation"'
```

Milestone 2 migration scaffolding:

```bash
just new-migration name=kioku-l1-watermarks
# -> Created kioku-migrations/sql-migrations/<UTC-timestamp>-kioku-l1-watermarks.sql
```

Fill the file per Milestone 2, then edit the "Last touched" comment in
`kioku-migrations/src/Kioku/Migrations.hs`. The test suite applies embedded migrations
itself (`withKiokuMigratedDatabase`); for the dev database run `just migrate` and expect
codd to report the new migration applied:

```text
Applying 2026-07-XX-XX-XX-XX-kioku-l1-watermarks.sql (in-txn)
```

Commit after each milestone with conventional-commit messages, for example:

```text
fix(distill): deterministic atom identity and honest consolidation failure in L1
feat(distill): per-session L1 watermark and debounced idle timers
fix(cli): wire recall-based merge candidates into the timer worker
feat(distill): real validation for extract and consolidate LLM outputs
```


## Validation and Acceptance

Primary acceptance is the test suite: every test named in the milestones fails against
the pre-plan code (re-run duplicates rows; consolidation failure stores; ghost target
loops; fifty idle timers; scan misses the sixth memory; `validate = Right`) and passes
after. Run:

```bash
cabal build all && cabal test kioku-core --test-show-details=direct
```

and confirm the transcript matches the Concrete Steps expectation, with zero failures.

Narrated live scenario (optional; requires a Postgres from the devShell, plus
`ANTHROPIC_API_KEY` for the live extraction model). This demonstrates the user-visible
behavior beyond tests:

```bash
just create-database
export PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE"
cabal run kioku -- demo-session
# -> Recorded session kioku_session_<...> with status completed
cabal run kioku -- worker --timers-once     # fires the ramp/final timer: runs the LLM
# -> Processed one due kioku distillation timer.
cabal run kioku -- worker --timers-once     # next due timer for the same session
# -> Processed one due kioku distillation timer.   (cheap: watermark skip, no LLM)
cabal run kioku -- worker --timers-once
# -> No due kioku distillation timers.
cabal run kioku -- distill session <sid>
# -> Session already distilled (no new turns); use --force to re-run.
cabal run kioku -- distill session <sid> --force
# -> Distilled session <sid>: extracted=N stored=0 merged=M skipped=K
psql "$PG_CONNECTION_STRING" -c "SELECT count(*) FROM kiroku.kioku_memories WHERE session_id = '<sid>';"
# -> the same count before and after the --force re-run
psql "$PG_CONNECTION_STRING" -c "SELECT count(*) FROM keiro.keiro_timers WHERE correlation_id = '<sid>' AND payload->>'kind' = 'idle';"
# -> 1
```

The load-bearing observations: the forced re-run's `stored=0` (deterministic ids +
consolidation converge), the unchanged memory count, and the single idle-timer row.


## Idempotence and Recovery

Every step in this plan is itself re-runnable. The migration uses
`CREATE TABLE IF NOT EXISTS` and codd skips already-applied filenames. Code edits are
ordinary git-tracked changes; if a milestone goes wrong, `git checkout -- <file>` restores
the previous state and the tests pin the expected behavior on both sides. The new runtime
behavior is idempotent by construction — that is the point of the plan: re-firing any
timer, re-running any pass, and re-projecting session events onto the timer table all
converge on the same rows. The one behavioral hazard discovered during design (a
deterministic winner id colliding with its own merge target and self-merging the only
active copy) is guarded in Milestone 1 and covered by the re-run idempotency test; do not
remove that filter. If Milestone 2 lands before Milestone 1 for any reason, note that the
watermark alone does NOT make forced or failure-path re-runs safe — the deterministic ids
do — so keep the milestone order.


## Interfaces and Dependencies

Modules and the signatures that must exist at the end (full paths;
`es` rows always `(IOE :> es, Store :> es, Error StoreError :> es)` unless narrower today):

- `kioku-core/src/Kioku/Distill/L1.hs` exports (additions/changes):
  `data L1RunMode = RespectWatermark | IgnoreWatermark`;
  `data L1Outcome = L1Distilled !L1Summary | L1SkippedUpToDate`;
  `L1Error` gains `L1ConsolidationFailed !Text`;
  `distillSessionL1 :: L1RunMode -> DistillRuntime -> FindMergeCandidates es -> SessionId -> Eff es (Either L1Error L1Outcome)`;
  `newtype FindMergeCandidates es = FindMergeCandidates { runFindMergeCandidates :: MemoryScope -> Text -> Eff es (Either ReadModelError [MemoryRecord]) }`;
  `fallbackStoreDecision` is gone. Internal but load-bearing: `l1AtomMemoryId ::
  SessionId -> Text -> MemoryId` (UUIDv5, namespace constant `l1AtomNamespace`).
- `kioku-core/src/Kioku/Distill/Timer.hs`: `l1IdleTimerId :: SessionId -> TimerId`,
  `l1RampTimerId :: SessionId -> Int -> TimerId`, `l1FinalTimerId :: SessionId -> TimerId`
  replace `l1TimerId`; `l1ExtractProcessManagerName` unchanged (`"kioku-l1-extract"` —
  renaming it breaks the worker dispatch and downstream plans' reconciliation).
- `kioku-core/src/Kioku/Distill/Timer/Worker.hs`: `fireL1Timer` keeps its
  `TimerRow -> Eff es (Maybe EventId)` shape and maps both `L1Distilled`/
  `L1SkippedUpToDate` to `Just (timerMarkerEventId row.timerId)`.
- `kioku-core/src/Kioku/Distill/Extract.hs` / `Consolidate.hs`: hand-written
  `instance Validatable ExtractOutput` / `instance Validatable ConsolidationDecision`
  (shikumi class: `validate :: a -> Either Text a`, invoked by every adapter parse via
  `fromModelChecked`).
- `kioku-migrations/sql-migrations/<fresh-ts>-kioku-l1-watermarks.sql` creates
  `kiroku.kioku_l1_watermarks`; `kioku-migrations/src/Kioku/Migrations.hs` "Last touched"
  comment updated (embed-guard convention; the durable guard is owned by
  `docs/plans/14-align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations.md`).

Libraries used and why: `uuid` (`Data.UUID.V5.generateNamed`) for deterministic ids —
already used by `Timer.hs`/`L2.hs`; `mmzk-typeid` (`Data.KindID.V7.decorateKindID`) to
wrap raw UUIDs into `MemoryId` — the pattern `parseIdAnyPrefix` already uses; keiro's
`Keiro.Timer` (`scheduleTimerTx` upsert semantics) for the debounce; shikumi's
`Validatable`/`ValidationFailure` for output validation; ephemeral-pg + codd via
`Kioku.Migrations.TestSupport.withKiokuMigratedDatabase` and shikumi trace/replay for
tests.

Cross-plan integration constraints (reference by path only; verify current code state
when implementing, not the sibling plan text):

- Fire-outcome contract:
  `docs/plans/11-harden-worker-resilience-with-ack-policy-bounded-retries-and-loop-supervision.md`
  owns replacing the `Maybe EventId` fire result with a succeed/retry-later/dead-letter
  taxonomy. This plan keeps `Maybe EventId` and stays correct under unbounded at-least-once
  re-fires; if that plan has landed first (check `fireL1Timer`'s type), classify
  `L1ExtractionFailed`/`L1ConsolidationFailed`/`L1MemoryReadFailed` as retry-later and
  `L1SessionNotFound` as success, changing nothing else here.
- Timer scheduling:
  `docs/plans/10-propagate-memory-forget-operations-to-scenes-personas-and-workspace-mirrors.md`
  extends scene-timer scheduling in `kioku-core/src/Kioku/Distill/L2.hs`
  (`timerRequestsForEvent` there). This plan changes only the L1 session-timer scheduling
  in `kioku-core/src/Kioku/Distill/Timer.hs`, keeps all timer ids deterministic (UUIDv5
  over stable event data) so re-projection never double-schedules, and renames no
  process-manager name.
- Worker CLI wiring: `kioku-cli/src/Kioku/Cli/Commands/Worker.hs` is also edited by both
  plans above. This plan's edit is strictly the candidate-lookup wiring (and threading
  `config`/capability to it); do not restructure the loops.
- Migrations: any plan adding files under `kioku-migrations/sql-migrations/` mints a
  fresh UTC timestamp (codd orders by filename) and touches the "Last touched" comment in
  `kioku-migrations/src/Kioku/Migrations.hs`; this plan follows that convention for the
  watermark migration.
