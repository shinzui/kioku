---
id: 12
slug: enforce-aggregate-invariants-for-lineage-resume-correlation-and-idempotent-commands
title: "Enforce aggregate invariants for lineage, resume correlation, and idempotent commands"
kind: exec-plan
created_at: 2026-07-07T14:58:23Z
intention: "intention_01kwyhabypepdt1mwemmf0dvqa"
master_plan: "docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md"
---

# Enforce aggregate invariants for lineage, resume correlation, and idempotent commands

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

kioku is an event-sourced agent memory and session library. Its session and memory write
APIs (`Kioku.Session`, `Kioku.Memory` in `kioku-core`) currently enforce several business
rules by reading a Postgres read-model row first and then, in a *separate* transaction,
running the command. That read-then-write shape has three user-visible failure modes that
this plan removes:

1. A session can be resumed against the *wrong wait*. `Session.resume` checks the awaited
   correlation key against a read-model row, but the aggregate itself accepts any
   `ResumeSession` while parked. Under keiro's optimistic-concurrency retry, a stale caller
   can resume a wait that was already resumed and re-parked with a different key. After
   this plan, the awaited key lives in the aggregate's own replayed state and a mismatched
   resume is rejected by the state machine itself, no matter how races interleave. Waiving
   the key becomes an explicit `Session.forceResume` call instead of a silently omitted
   field.

2. `Session.getChain` can hang forever. Nothing validates `previousSessionId` at
   `Session.start` (a session may point at itself, or two sessions may point at each
   other), and the recursive SQL that walks the chain has no cycle guard, so a cycle makes
   the query loop until timeout or OOM. After this plan, `start` rejects self-referential
   and malformed lineage, and the chain query is provably terminating even on adversarial
   data (a test inserts a cycle with raw SQL and proves the query returns).

3. "Idempotent" accepts lie. `Memory.record` on an existing id returns success even when
   the content differs; `Session.complete` on a *failed* session reports success;
   `supersede` by X followed by `supersede` by Y reports success for Y. After this plan,
   a duplicate request that matches what already happened returns success, and a
   conflicting request returns a distinct conflict error — and a caller who loses a
   concurrent duplicate race gets the idempotent success instead of a hard rejection.

Two smaller defects ride along: re-parking a session leaves the previous `resume_input`
visible in the read model (fixed by nulling it), and recorded turns have no identity
contract (fixed by an aggregate-enforced strictly-increasing turn index plus an honest
projection). Documentation that implies `awaiting_deadline` is enforced is corrected —
enforcement itself is out of scope by MasterPlan decision (see
`docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md`,
Decision Log).

You can see the whole plan working by running the `kioku-core` test suite: every milestone
adds tests that fail before its fix and pass after, including a transducer-level proof that
a mismatched resume is rejected regardless of read-model state, and a replay test proving
that event streams written before this change still rehydrate.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [x] M1: Run the pre-implementation data audit for `SessionResumed` correlation keys (see Concrete Steps, step 0) and record the result here. — 2026-07-11, **Audit A passed**: the `kioku` dev database holds 4 session streams (`SessionStarted` ×4, `SessionCompleted` ×4, `TurnRecorded` ×4) and **zero** `SessionAwaiting`/`SessionResumed` events, so no stream can carry a mismatched correlation key and the new guard cannot brick any existing stream. Guard is safe to ship.
- [x] M1: Add the `awaitedCorrelationKey` register to `SessionRegs` and initialize/set/clear it on the Start/AwaitInput/Resume edges in `kioku-core/src/Kioku/Session/Domain.hs`.
- [x] M1: Add `force :: Bool` to `ResumeSessionData` (command) and `SessionResumedData` (event) with the backward-compatible `FromJSON` default.
- [x] M1: Add the correlation guard to the `ResumeSession` edge.
- [x] M1: Update `Kioku.Session.resume` (drop the omitted-key bypass) and add `Kioku.Session.forceResume`.
- [x] M1: Null `resume_input` in `updateSessionAwaitingStmt` (re-park fix).
- [x] M1: Tests — aggregate-level mismatch rejection, force resume, keyless wait resume, re-park clears `resume_input`, replay of a pre-`force` event stream (raw JSON append). — 2026-07-11 (`77682c7`), 8 new cases in `kioku-core/test/Kioku/SessionInvariantsSpec.hs`; suite 47 → 55 passing.
- [x] M2: Lineage validation in `Session.start` (self-reference, negative/inconsistent/capped delegation depth) with `SessionInvalidLineage`.
- [x] M2: Cycle-proof `selectSessionChainStmt` (path-array guard + depth cap).
- [x] M2: Tests — validation rejections, raw-SQL cycle proof under a tasty timeout. — 2026-07-11 (`ed5b768`), 7 new cases; suite 55 → 62 passing.
- [x] M3: `SessionStatus` sum type and payload-matching idempotent accepts for `start`, `recordInteractive`, `awaitInput`, `resume`, `complete`, `failSession` with `SessionConflict`.
- [x] M3: Payload-matching idempotent accepts for `Memory.record`, `supersede`, `archive`, `merge` with `MemoryConflict`.
- [x] M3: Post-rejection re-read fallback so a concurrent duplicate loser gets the idempotent success.
- [x] M3: Tests — duplicate-vs-conflict for every accept listed above. — 2026-07-11 (`cd23156`), 17 new cases in `kioku-core/test/Kioku/IdempotencySpec.hs`; suite 62 → 79 passing.
- [x] M4: Run the turn-index monotonicity audit (Concrete Steps, step 0) and record the result here. — 2026-07-11, **Audit B passed**: zero rows returned (no session stream has a non-increasing `turnIndex` in stream order). The strict `lastTurnIndex` register guard ships as designed; no fallback to the command-layer-only contract is needed.
- [x] M4: `lastTurnIndex` register + strictly-increasing guard on the `RecordTurn` edge; command-layer turn dedup in `Session.recordTurn`; projection updates `turn_id` on `(session_id, turn_index)` conflict.
- [x] M4: Tests — idempotent re-record, conflicting re-record, turn-id reuse at a different index, aggregate rejection of a non-increasing index. — 2026-07-11 (`b3436c7`), 4 new cases; suite 79 → 83 passing. Fail-before verified: without `requireGt` the aggregate accepts a stale index.
- [ ] M5: ReiCompatSpec fixtures for `agent_session_completed`, `agent_session_failed`, `interactive_session_recorded`, plus native `SessionResumed`-without-`force` decoding.
- [ ] M5: Documentation truth pass — `docs/user/concepts.md`, `docs/user/library-api.md`, advisory-deadline code comments.
- [ ] Final: full `cabal build all` + `cabal test` green; update Outcomes & Retrospective.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

These were discovered while researching for this plan (against keiki pin `bc987f4` and
keiro pin `f1d67a0` from `cabal.project`); they shaped the design and are recorded up
front because they are non-obvious:

- **Transducer guards run during replay, not just at command time.** keiro hydration
  (`keiro/src/Keiro/Command.hs`, `hydrateFull`) replays each stored event through
  `Keiki.applyEventStreaming`, which inverts the event back into a candidate command via
  `solveOutput` and then checks `models (guard e) (regs, ci)`. Any guard we add is
  therefore retroactively applied to already-committed events. A committed event that
  fails a new guard makes hydration fail with `HydrationReplayFailed`, bricking the
  stream for all future commands. Every guard in this plan is designed so that all
  legitimately-committable historical events still pass it.

- **Literal (`lit`) event fields are neither recovered nor verified on replay.** In
  `keiki/src/Keiki/Core.hs`, `gatherInpEntries` skips `TLit` fields and
  `recomputeDerivedFields` keeps their *observed* value, so a literal field cannot
  discriminate between two edges emitting the same event type. Consequence: we cannot
  model "force resume" as a second edge emitting `SessionResumed` with a literal
  `Nothing` key — both edges would match the same stored event and
  `applyEventStreaming` would return `Nothing` (ambiguous), failing hydration. The
  `force` discriminator must be a real command field carried in the event payload.

- **Legacy Rei streams contain no awaiting/resume/turn events.**
  `kioku-core/src/Kioku/Session/EventStream.hs` (`parseLegacySessionEvent`) decodes only
  `agent_session_started`, `agent_session_completed`, `agent_session_failed`, and
  `interactive_session_recorded`. So the replay-compatibility surface for the new resume
  guard and the turn-index guard is native kioku events only (written since 2026-06).

- **The session chain CTE uses `UNION ALL`; the memory supersession CTE uses `UNION`.**
  `selectSessionChainStmt` (`kioku-core/src/Kioku/Session/ReadModel.hs`) loops forever on
  a cycle. `selectSupersessionChainStmt` (`kioku-core/src/Kioku/Memory/ReadModel.hs`)
  deduplicates whole rows via `UNION`, so it terminates even on cyclic data — the memory
  side needs no cycle fix from this plan.

- **The chain query needs no new index.** Its recursive arm joins
  `s.session_id = c.previous_session_id`, a primary-key lookup on `kioku_sessions`.
  The MasterPlan's suggestion to coordinate a `previous_session_id` index with
  `docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md`
  turns out to be moot for `getChain` (recorded as a cross-plan note; see Interfaces and
  Dependencies).

Discovered during implementation:

- **The tasty timeout does not rescue the unfixed chain query — it hangs the whole suite.**
  The plan predicted the cycle test would "time out" against the unfixed
  `selectSessionChainStmt`. It does not: the run reaches
  `getChain terminates on a cyclic chain:` and then hangs *indefinitely*, straight through
  `mkTimeout 10_000_000` (observed: killed manually after 11 minutes). tasty's timeout
  cancels a Haskell thread, but this thread is blocked in a foreign call to libpq, which is
  not interruptible. This makes the defect more severe than reviewed, not less: **no
  client-side timeout saves a caller from the runaway CTE** — not tasty's, and not an
  application's. With the path-array guard the same test returns in milliseconds. Evidence:
  the fail-before run was killed at exit 144 with no OK/FAIL line ever printed; the
  pass-after suite completes in 9.63s.
- **The plan's timestamp decision was wrong, and an existing test proved it within minutes.**
  The Decision Log had caller-supplied timestamps participate in conflict detection, on the
  premise that "a genuine retry re-delivers the identical record value (ids and timestamps
  are caller-generated in these APIs)". That premise is false in kioku itself:
  `kioku-core/src/Kioku/Distill/L1.hs` `recordAtom` derives a **deterministic** memory id
  (EP-1's whole idempotency mechanism) but stamps `recordedAt = now` at each pass. So an
  idle-timer re-fire — precisely the regime EP-1 exists to survive — re-records the same
  atom with a later clock, and the strict comparison classified it as a hard
  `MemoryConflict`. `DistillSpec`'s "merge with a missing target drops it and stays
  convergent" failed with
  `L1MemoryWriteFailed (MemoryConflict "record: recordedAt differs from the recorded memory")`.
  **Resolution:** call-time timestamps (`recordedAt`, `startedAt`, `completedAt`,
  `failedAt`, `resumedAt`) are excluded from conflict detection; the id is the identity, and
  a retry that re-reads the clock is the normal shape of a retry. Every semantic field is
  still compared, so the review's actual complaint (a reused id with different *content*
  reporting success) is still fixed. `awaitingDeadline` stays compared — it is a payload the
  caller *asked for*, not a record of when it called. A regression test ("a record retried
  with a fresh clock is a duplicate") pins the contract. Note the plan had already carved out
  exactly this exception for `merge`; the mistake was not seeing that `record` has the same
  shape.
- **The suite flaked once under parallelism and it was not the code.** A `-j` run failed one
  case while a serial run passed all 79. Cause: the killed-but-still-running Postgres backend
  from the fail-before cycle experiment was saturating CPU (that run took 61s; clean parallel
  runs take ~15s). Two subsequent parallel runs passed. If a database-backed case flakes
  after a deliberately-hung query experiment, check for stray backends before suspecting the
  diff.
- **`mkTimeout` is exported from `Test.Tasty`**, not `Test.Tasty.Runners` (which the plan's
  Concrete Steps implied) and not `Test.Tasty.Options`.
- **The pinned keiro really does take a bare `EventStream`**, as the plan's Interfaces
  section says — but the working checkout at `/Users/shinzui/Keikaku/bokuno/keiro` is HEAD
  and takes `ValidatedEventStream`. Read pinned framework sources from
  `dist-newstyle/src/<pkg>-<hash>/`, not from the sibling working checkouts, or you will
  write against the wrong signature.


## Decision Log

Record every decision made while working on the plan.

- Decision: **Carry the awaited correlation key as a keiki register
  (`awaitedCorrelationKey :: Maybe Text`), set from the `SessionAwaiting` event payload,
  and enforce resume matching with a transducer guard.**
  Rationale: keiki registers are rebuilt purely from events during replay (keiro's
  `hydrate` runs `applyEventStreaming`, which recovers the command from the event via
  `solveOutput` and re-applies register updates), so the key is derived from the same
  `SessionAwaiting` events that already exist in production streams — old streams
  rehydrate the register correctly with no data migration. Putting the key in the
  `SessionVertex` state constructor is not possible: vertices are a plain enum
  (`Eq/Show/Enum/Bounded` required by `buildTransducer`).
  Date: 2026-07-07

- Decision: **Model force-resume as an explicit `force :: Bool` field on both the
  `ResumeSession` command and the `SessionResumed` event, with the resume guard
  `(d.force .== lit True) .|| (d.correlationKey .== reg @"awaitedCorrelationKey")`, and
  decode old `SessionResumed` JSON (no `force` key) as `force = isNothing correlationKey`.**
  Rationale: (a) the guard's inputs must be recoverable from the event during replay, so
  `force` must be a real event field (see Surprises: literal fields are not verified);
  (b) a separate `ForceResumeSession` command emitting the same event type would make
  replay ambiguous, and emitting a *new* event type would leave historical key-omitted
  resumes unreplayable under the strict guard; (c) the chosen `FromJSON` default is
  historically honest — under the old code, a resume that omitted the key *was* a bypass,
  so decoding it as `force = True` replays it through the force arm, while old keyed
  resumes decode as `force = False` and replay through the match arm (their key matched
  the read-model precheck when committed, so the register matches on replay). The only
  streams that cannot replay are ones already corrupted by the exact race being fixed
  (a *mismatched* `Just`-key resume); a pre-implementation audit query checks production
  for those (Concrete Steps, step 0).
  Date: 2026-07-07

- Decision: **`Session.resume` no longer bypasses on an omitted key; `Session.forceResume`
  is the explicit override.** `resume` always sends `force = False`: a keyed wait requires
  the matching key, a keyless wait requires `correlationKey = Nothing` (exact `Maybe`
  equality in the guard covers both), and everything else is rejected — by the aggregate,
  not by a precheck. `forceResume` sends `force = True` with `correlationKey = Nothing`
  and is documented as an operator/host override that is inherently last-writer-wins.
  The read-model precheck in `resume` is retained only to shape a friendly
  `SessionCorrelationMismatch` error early; the aggregate is the enforcement point.
  Date: 2026-07-07

- Decision: **Idempotent-accept contract: a write against an already-satisfied state
  returns `Right` only when the request payload matches what already happened (including
  caller-supplied timestamps); otherwise a new conflict error (`SessionConflict !Text` /
  `MemoryConflict !Text`) is returned.** Timestamps are included in the comparison because
  a genuine retry re-delivers the identical record value (ids and timestamps are
  caller-generated in these APIs); excluding them would misclassify some conflicting
  writes as retries. `merge` is the one exception: its `mergedAt` is generated inside
  `Kioku.Memory.merge`, so its idempotency check matches on `supersededBy` (the merge
  target) only.
  Date: 2026-07-07
  **SUPERSEDED 2026-07-11 during M3 — the parenthesized premise is false.** See the
  replacement decision immediately below.

- Decision (supersedes the above, 2026-07-11): **Call-time timestamps do not participate in
  conflict detection. The entity id is the identity; every *semantic* field is compared.**
  Excluded: `recordedAt`, `startedAt`, `completedAt`, `failedAt`, `resumedAt` (and, as
  before, `merge`'s `mergedAt` and `supersede`/`archive`'s `supersededAt`/`archivedAt`).
  Still compared: content, scope, memory type, priority, confidence, tags, `supersedes`,
  the merge/supersession target, agent, focus, subject, lineage, awaiting reason/key, and
  `awaitingDeadline` (a deadline is a payload the caller *asked for*, not a record of when
  it called).
  Rationale: the original premise — that a retry re-delivers the identical timestamp — is
  contradicted by kioku's own most important `record` caller.
  `kioku-core/src/Kioku/Distill/L1.hs` `recordAtom` derives a deterministic memory id
  (EP-1's entire idempotency mechanism) but stamps `recordedAt = now` on every pass, so an
  idle-timer re-fire — the exact regime EP-1 was built to survive — re-records the same atom
  under a later clock. Comparing the timestamp turned that into a hard `MemoryConflict`,
  which `DistillSpec`'s "merge with a missing target drops it and stays convergent" caught
  immediately. Generalizing: any host retrying a write after a transient failure will
  naturally re-read its clock, so a timestamp comparison converts routine retries into hard
  failures — the opposite of what an idempotency contract is for. The plan had already
  carved out this exception for `merge`; the error was not seeing that `record` and the
  session writes have the same shape. The review's actual finding — a reused id with
  different *content* reporting success — remains fixed, and a regression test pins the new
  contract.
  Date: 2026-07-11

- Decision: **After a `CommandRejected` from the aggregate, the command layer re-reads the
  read model and returns the idempotent `Right` if the observed state now matches the
  request.** This makes concurrent duplicate delivery converge: the OCC loser's rejection
  is translated into the same success the winner got, while a genuinely conflicting loser
  still gets the conflict error. Implemented once as a helper and applied uniformly.
  Date: 2026-07-07

- Decision: **Lineage validation policy: pure, command-time checks only — reject
  `previousSessionId == sessionId`, `parentSessionId == sessionId`,
  `delegationDepth < 0`, `delegationDepth > 64`, and parent/depth inconsistency
  (`parentSessionId` present requires depth ≥ 1; absent requires depth 0). No existence
  checks for the referenced sessions.** Existence checks would be read-model reads with
  their own races and would forbid legitimate out-of-order ingestion; dangling pointers
  are harmless to the chain query (the walk just stops). Because existence is not checked,
  a cycle can still be *constructed* by writing A→B before B exists and then B→A, so the
  chain query gets a defense-in-depth cycle guard (path array + depth cap 10000) that
  bounds damage regardless of what the data contains. These checks live in
  `Kioku.Session.start` (not the transducer): they involve only the command's own fields,
  and command-layer validation never executes during replay, so there is zero
  compatibility risk.
  Date: 2026-07-07

- Decision: **Turn identity contract: `(session_id, turn_index)` is the turn's identity;
  `turn_id` is an idempotency token. The aggregate enforces strictly-increasing
  `turn_index` via a `lastTurnIndex` register guard; `Session.recordTurn` compares a
  re-delivered turn against the stored row (identical → idempotent `Right`; same index
  with any differing field, or same `turn_id` at a different index → `SessionConflict`);
  the projection upsert also updates `turn_id` on `(session_id, turn_index)` conflict so
  a projection rebuild reflects the winning event.** Cross-session `turn_id` reuse remains
  a raw primary-key violation surfaced as `StoreFailed` — accepted, documented limitation
  (turn ids are host-generated ULIDs; cross-session collision is a caller bug, and mapping
  that specific SQL error inside keiro's projection transaction is not worth the
  machinery). The strict guard is gated on a data audit (Concrete Steps, step 0); if
  production streams contain non-monotonic turn indexes, the guard is dropped and only the
  command-layer contract ships (recorded here if it happens).
  Date: 2026-07-07

- Decision: **Introduce an internal `SessionStatus` sum type in `Kioku.Session` and use it
  for all status case analysis; `SessionRow.status` stays `Text`.** The row type is part
  of the read-model shape consumed by the CLI and other read paths; changing its field
  type would ripple through decoders and hosts for no correctness gain. Parsing at the
  point of decision (`parseSessionStatus :: Text -> Maybe SessionStatus`) removes the
  stringly-typed comparisons flagged in the review while keeping the diff contained.
  Date: 2026-07-07

- Decision: **`awaiting_deadline` stays advisory; documentation and code comments say so
  explicitly.** Per the MasterPlan decision (2026-07-07): enforcement is a feature with
  real design questions, not a remediation.
  Date: 2026-07-07

- Decision: **No SQL migration and no read-model version bump in this plan.** All SQL
  changes are to statements embedded in Haskell (`selectSessionChainStmt`,
  `updateSessionAwaitingStmt`, `insertTurnStmt`); the `kioku_sessions`/`kioku_turns`
  table shapes are unchanged, and keiro's read-model registry keys on
  name/version/shapeHash of the *table shape*, not query text. If implementation
  unexpectedly needs a migration after all, follow the convention in Interfaces and
  Dependencies (fresh UTC timestamp + touch `kioku-migrations/src/Kioku/Migrations.hs`).
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/kioku`) is a Haskell cabal project with
four packages: `kioku-api` (shared vocabulary types: ids, scopes), `kioku-core` (the
library: sessions, memories, recall, distillation), `kioku-cli` (demo/worker commands),
and `kioku-migrations` (embedded SQL migrations plus a test-support library that boots an
ephemeral, fully-migrated Postgres). Postgres access is via `hasql`. Event sourcing comes
from three in-house frameworks pinned in `cabal.project`: **keiki** (pure state-machine
"transducers"), **kiroku** (the Postgres event store), and **keiro** (the command runner,
projections, and read models on top of both).

Concepts you need, in plain language:

- An **aggregate** is one entity whose history is an append-only list of **events** in its
  own **stream** (a named sequence in the kiroku `events`/`stream_events` tables; session
  streams are named `kioku_session-<id>`). Current state is recovered by **replaying**
  (re-reading) those events.

- A **transducer** (keiki) is the aggregate's state machine. It has **vertices** (named
  states — for sessions: `NotCreated`, `Running`, `Awaiting`, `Completed`, `Failed`,
  `Interactive` in `kioku-core/src/Kioku/Session/Domain.hs`), **registers** (a typed,
  named record of extra state alongside the vertex — sessions currently have none:
  `type SessionRegs = '[]`), and **edges**. Each edge says: from this vertex, on this
  command, if this **guard** (a predicate over registers and the command payload) holds,
  emit these events, update these registers, go to that vertex. Edges are written with the
  builder DSL in `Keiki.Builder` (`B.from`, `B.onCmd`, `B.emit`, `B.goto`,
  `slot @"name" .= term`, `B.requireGuard`).

- **Running a command** (keiro, `Keiro.Command`): (1) *hydrate* — replay the stream's
  events through the transducer to recover `(vertex, registers)`; (2) *transduce* — step
  the transducer with the command; if no edge matches (wrong vertex or failed guard) the
  command fails with `CommandRejected`; (3) *append* — write the emitted events at the
  expected stream version. A concurrent writer causes an optimistic-concurrency conflict,
  which keiro retries by re-hydrating and re-running the command (up to 3 times by
  default). **This retry is why read-model prechecks are unsound**: the precheck ran
  against the world before the conflict, but the command is re-applied to the world after
  it.

- **Replay inverts events into commands.** During hydration, keiki does not have the
  original command — it recovers one from each stored event (`solveOutput` in
  `keiki/src/Keiki/Core.hs`): every event field declared as `d.someField` in the edge's
  `emit` is read back into the corresponding command field, then the edge's guard is
  checked against `(registers, recovered command)` and the edge's register updates are
  re-applied. Two consequences drive this plan's design: **(a)** any command field a
  guard reads must be present in the emitted event's payload, or replay cannot recover it
  and hydration fails; **(b)** new guards are retroactively applied to old events, so they
  must accept every event that legitimate old code could have committed.

- An **inline projection** (`sessionInlineProjection` in
  `kioku-core/src/Kioku/Session/ReadModel.hs`) maintains the `kioku_sessions` and
  `kioku_turns` tables in the *same transaction* as each event append. **Read models**
  (same file) are named queries over those tables. The session write API
  (`kioku-core/src/Kioku/Session.hs`) prechecks read-model rows and then calls
  `runCommandWithProjections`; the memory write API
  (`kioku-core/src/Kioku/Memory.hs` over `kioku-core/src/Kioku/Memory/Domain.hs` and
  `Memory/ReadModel.hs`) has the same shape.

- **Legacy Rei events**: kioku inherited streams from an older system ("Rei"). The codec
  in `kioku-core/src/Kioku/Session/EventStream.hs` first tries the native JSON decoding
  and falls back to `parseLegacySessionEvent`, which understands the old
  `{"type": "agent_session_started", "data": {...}}` shapes for started / completed /
  failed / interactive only. Legacy streams contain no awaiting, resume, or turn events.

- **Tests** live in `kioku-core/test/` (tasty + HUnit), registered in
  `kioku-core/test/Main.hs` and the `kioku-test` test-suite stanza of
  `kioku-core/kioku-core.cabal`. `Kioku.Migrations.TestSupport.withKiokuMigratedDatabase`
  boots an ephemeral migrated Postgres per test run;
  `kioku-core/test/Kioku/AwaitingSpec.hs` is the model to imitate (it runs the real
  command pipeline against the real database and asserts on both read-model rows and raw
  stream events via `readStreamForward`).

The specific defects, with today's locations:

- `Session.resume` (`kioku-core/src/Kioku/Session.hs:120-138`): precheck-only correlation
  matching, `Nothing` key bypasses entirely; the transducer's `Awaiting` →
  `ResumeSession` edge (`Session/Domain.hs:346-356`) has no guard.
- `Session.start` (`Session.hs:69-78`): no lineage validation;
  `selectSessionChainStmt` (`Session/ReadModel.hs:425-452`): recursive CTE with
  `UNION ALL`, no cycle guard.
- Idempotent accepts without payload comparison: `Session.hs` `start` (line 77),
  `complete` (91), `failSession` (104), `awaitInput` (116), `resume` (130),
  `recordInteractive` (148); `Memory.hs` `record` (64), `supersede` (78), `archive` (91),
  `merge` (133).
- `updateSessionAwaitingStmt` (`Session/ReadModel.hs:563-573`): does not null
  `resume_input`.
- `insertTurnStmt` (`Session/ReadModel.hs:601-617`): upsert keyed only on
  `(session_id, turn_index)`; transducer `RecordTurn` edge (`Domain.hs:318-332`) has no
  dedup.
- `awaiting_deadline`: stored (`Domain.hs`, projection) but read nowhere;
  `docs/user/concepts.md` line ~88 implies deadline semantics.


## Plan of Work

The work is five milestones. Each is independently buildable and testable; each adds
tests that fail before its change and pass after. All file paths are repo-relative to
`/Users/shinzui/Keikaku/bokuno/kioku`.


### Milestone 1 — Resume correlation becomes an aggregate invariant

Scope: make the awaited correlation key part of replayed aggregate state, enforce the
match in the transducer, make force-resume an explicit API, and clear stale
`resume_input` on re-park. At the end, a mismatched `ResumeSession` command is rejected
by the state machine itself (proven by a test that bypasses the read-model precheck
entirely), `Session.forceResume` exists, a park→resume→re-park sequence shows
`resume_input = NULL`, and a hand-appended pre-change event stream (JSON without the new
`force` field) still hydrates and accepts new commands.

Work, in order:

1. In `kioku-core/src/Kioku/Session/Domain.hs`:
   - Change the register list:

     ```haskell
     type SessionRegs = '[ '("awaitedCorrelationKey", Maybe Text)]
     ```

   - Add `force :: !Bool` to `ResumeSessionData` (the command payload) and to
     `SessionResumedData` (the event payload), in both cases between `correlationKey`
     and `input` (field order matters only for readability; JSON is by name).
   - Replace `SessionResumedData`'s `deriving anyclass (FromJSON, ToJSON)` with
     `deriving anyclass (ToJSON)` plus a hand-written `FromJSON` that defaults `force`
     for pre-change events (see Concrete Steps for the exact instance). The default is
     `isNothing correlationKey`: an old resume that omitted the key *was* a bypass, so
     it replays through the force arm; an old keyed resume replays through the match arm.
   - Edit the transducer (`sessionTransducer`):
     - On the `NotCreated` → `StartSession` edge, initialize the register:
       `B.slot @"awaitedCorrelationKey" .= lit Nothing` (keiki's `emptyRegFile` binds
       uninitialized slots to a deferred error, so every path that can later read the
       register must write it first; `Running` is the only gateway to `Awaiting`).
       The `RecordInteractiveSession` edge does not need it — `Interactive` is terminal
       and has no outgoing edges.
     - On the `Running` → `AwaitInput` edge:
       `B.slot @"awaitedCorrelationKey" .= d.correlationKey`.
     - On the `Awaiting` → `ResumeSession` edge, add the guard and clear the register:

       ```haskell
       B.requireGuard
         ((d.force .== lit True) .|| (d.correlationKey .== B.reg @"awaitedCorrelationKey"))
       B.slot @"awaitedCorrelationKey" .= lit Nothing
       ```

       and extend the emitted `SessionResumedTermFields` with `force = d.force` — this is
       **mandatory for replay**, because the guard reads `d.force`, and replay can only
       recover command fields that appear in the event payload.
     - Imports needed: `import Keiki.Builder ((.=))` and extend the `Keiki.Core` import
       with `lit`, `(.==)`, `(.||)`.
2. In `kioku-core/src/Kioku/Session.hs`:
   - `resume` builds the command with the caller's record unchanged, but its docstring
     and precheck change: the `Nothing`-key bypass (`correlationMatches`) is deleted.
     The precheck keeps only a friendly fast-fail: while `awaiting`, if
     `not cmdData.force && row.awaitingCorrelationKey /= cmdData.correlationKey`, return
     `Left SessionCorrelationMismatch` (exact `Maybe` equality — a keyed resume of a
     keyless wait is also a mismatch). The aggregate guard is the real enforcement.
   - Add `forceResume`:

     ```haskell
     forceResume ::
       (IOE :> es, Store :> es, Error StoreError :> es) =>
       SessionId -> Text -> UTCTime -> Eff es (Either SessionWriteError SessionId)
     forceResume sid input resumedAt =
       resume ResumeSessionData
         { sessionId = sid, correlationKey = Nothing, force = True, input, resumedAt }
     ```

     and export it.
3. In `kioku-core/src/Kioku/Session/ReadModel.hs`, add `resume_input = NULL` to
   `updateSessionAwaitingStmt`'s `SET` list (re-park fix). The projection ignores the
   event's `force` field — no other projection change.
4. Update every `ResumeSessionData` construction site (`kioku-core/test/Kioku/AwaitingSpec.hs`
   fixtures and the correlation-mismatch test) with `force = False`.
5. Tests (extend `AwaitingSpec` and add `kioku-core/test/Kioku/SessionInvariantsSpec.hs`,
   registered in `test/Main.hs` and the cabal `other-modules`; add `keiro` to the
   test-suite `build-depends` for direct `Keiro.Projection` access):
   - *Aggregate-level rejection regardless of read model*: start, park with key `k1`,
     then call `runCommandWithProjections defaultRunCommandOptions sessionEventStream
     (sessionStream sid) (ResumeSession ... correlationKey = Just "k2", force = False ...)
     [sessionInlineProjection, l1TimerScheduleProjection]` directly (bypassing
     `Session.resume`'s precheck) and assert `Left CommandRejected`, and that the stream
     has no `SessionResumed` event.
   - *The race shape*: park `k1`, resume `k1`, park `k2`; a stale `Session.resume` with
     `Just "k1"` must fail (`SessionCorrelationMismatch`), and the direct command with
     `Just "k1"` must be `CommandRejected`; resume with `Just "k2"` then succeeds.
   - *Force*: park `k1`; `Session.forceResume` succeeds; the appended `SessionResumed`
     event has `force = True`.
   - *Keyless wait*: park with `correlationKey = Nothing`; `Session.resume` with
     `Nothing`/`force = False` succeeds; with `Just "x"` it is rejected.
   - *Re-park clears input*: park `k1`, resume, park `k2`; assert
     `row.resumeInput == Nothing` and `row.awaitingCorrelationKey == Just "k2"`.
   - *Replay of pre-change streams*: append, via `Kiroku.Store.Append.appendToStream`,
     hand-built `EventData` whose payloads are the *old* JSON shapes
     (`SessionStarted`, `SessionAwaiting` with key `k1`, `SessionResumed` **without** a
     `force` field and with `"correlationKey": null`; and a second stream where the
     resumed event carries the matching `"correlationKey": "k1"`), then run a real command
     (`Session.awaitInput`) against those streams and assert success — proving hydration
     replays both historical shapes through the new guard.

Acceptance: `cabal test kioku-core:kioku-test` green; the new tests fail if you revert
the Domain.hs guard (spot-check while developing).


### Milestone 2 — Lineage validation at start, and a cycle-proof chain query

Scope: `Session.start` validates its own lineage fields (pure checks, no reads), and
`selectSessionChainStmt` terminates on any data. At the end, a self-referential start is
rejected with a typed error, and a test that inserts a two-session cycle with raw SQL
proves `getChain` returns promptly.

Work:

1. In `kioku-core/src/Kioku/Session.hs`:
   - Add `SessionInvalidLineage !Text` to `SessionWriteError`.
   - In `start`, before the existence lookup, run pure validation and return
     `Left (SessionInvalidLineage reason)` on: `previousSessionId == Just sessionId`;
     `parentSessionId == Just sessionId`; `delegationDepth < 0`;
     `delegationDepth > maxDelegationDepth` (a new top-level constant, 64);
     `isJust parentSessionId && delegationDepth < 1`;
     `isNothing parentSessionId && delegationDepth /= 0`.
     Existence of the referenced sessions is deliberately *not* checked (Decision Log).
     These checks run only at command time — replay never executes them — so old events
     with any shape remain replayable.
2. In `kioku-core/src/Kioku/Session/ReadModel.hs`, rewrite `selectSessionChainStmt` to
   carry a visited-path array and a depth cap in the CTE (exact SQL in Concrete Steps).
   The outer `SELECT` lists only the row columns, so `sessionRowDecoder` is unchanged.
3. Tests (in `kioku-core/test/Kioku/SessionLineageSpec.hs`):
   - `start` with `previousSessionId = Just sessionId` → `SessionInvalidLineage`; same
     for self-parent, negative depth, depth 65, parent-with-depth-0, no-parent-with-depth-1.
   - Valid delegation still works (existing `testDelegationLineage` must keep passing —
     it uses parent+depth 1 and no-parent+depth 0).
   - *Cycle proof*: generate two session ids, insert two already-cyclic rows directly
     into `kioku_sessions` with `Kiroku.Store.Transaction.runTransaction` and a raw
     `Tx.sql` insert (bypassing `start` on purpose — the API now refuses to create
     cycles, so the test manufactures corrupt data), then call `Session.getChain` on one
     id under `localOption (mkTimeout 10_000_000)` (tasty, 10s) and assert it returns
     each session exactly once. Before the CTE fix this test times out; after, it passes
     in milliseconds.

Acceptance: the cycle test passes within the timeout; lineage rejections return
`SessionInvalidLineage` with a human-readable reason.


### Milestone 3 — Honest idempotent accepts for session and memory commands

Scope: every "already done → success" path compares the request against what actually
happened; mismatches return `SessionConflict`/`MemoryConflict`; concurrent-duplicate
losers converge to success; status strings become a sum type at the decision points.

Work:

1. In `kioku-core/src/Kioku/Session.hs`:
   - Add `SessionConflict !Text` to `SessionWriteError`.
   - Add the internal status type and parser:

     ```haskell
     data SessionStatus = StatusRunning | StatusAwaiting | StatusCompleted | StatusFailed | StatusInteractive
       deriving stock (Eq, Show)

     parseSessionStatus :: Text -> Maybe SessionStatus
     ```

     mapping exactly the five strings the projection writes (`"running"`, `"awaiting"`,
     `"completed"`, `"failed"`, `"interactive"`); an unrecognized status becomes
     `Left (SessionConflict "unrecognized session status: ...")` at use sites. Replace
     every `row.status == "..."` comparison in this module with case analysis on the
     parsed status.
   - Define one matcher per operation (pure `SessionRow -> Bool` given the command data)
     and rewrite the accepts:
     - `start` / `recordInteractive` on an existing row: `Right` only if the row matches
       the request on agent, focus, namespace/scope kind/scope ref (via
       `scopeNamespaceText`/`scopeKindText`/`scopeRefText`), `subjectRef`, lineage fields
       (start only), and `startedAt`; otherwise `SessionConflict` naming the first
       differing field.
     - `awaitInput` on `StatusAwaiting`: `Right` only if `awaitingReason`,
       `awaitingCorrelationKey`, and `awaitingDeadline` all match the request.
     - `resume` on `StatusRunning`: `Right` only if `resumeInput == Just cmdData.input`.
     - `complete` on `StatusCompleted`: `Right` only if `modelUsed`, `summary`, and
       `completedAt` match; on `StatusFailed`/`StatusInteractive`: `SessionConflict`
       (today these return `Right`!).
     - `failSession` on `StatusFailed`: `Right` only if `errorMessage` and `completedAt`
       (the projection stores `failedAt` there) match; on
       `StatusCompleted`/`StatusInteractive`: `SessionConflict`.
   - Add the post-rejection fallback and thread it through `runSessionCommand` call
     sites:

     ```haskell
     acceptRejectedIfMatches ::
       (IOE :> es, Store :> es) =>
       SessionId ->
       (SessionRow -> Bool) ->
       Either SessionWriteError SessionId ->
       Eff es (Either SessionWriteError SessionId)
     ```

     which, on `Left (SessionCommandRejected CommandRejected)`, re-reads the row and
     returns `Right sid` when the matcher accepts it (otherwise the original error).
     Apply it to `start`, `awaitInput`, `resume`, `complete`, `failSession`,
     `recordInteractive` (and `recordTurn` in M4).
2. In `kioku-core/src/Kioku/Memory.hs`:
   - Add `MemoryConflict !Text` to `MemoryWriteError`.
   - `record` on an existing row: `Right` only if the row matches on `agentId`,
     `sessionId`, namespace/scope kind/scope ref, `memoryType` (via `memoryTypeToText`),
     `content`, `priority`, `confidence` (via `confidenceToText`), `tags`, `supersedes`,
     and `createdAt == recordedAt`; else `MemoryConflict`.
   - `supersede` on non-active: `Right` only if `status == "superseded"` **and**
     `supersededBy == Just (idText cmdData.supersededBy)`; else `MemoryConflict`.
   - `archive` on non-active: `Right` only if `status == "archived"`; else
     `MemoryConflict`.
   - `merge` on non-active: `Right` only if `status == "merged"` and
     `supersededBy == Just (idText winner)` (the projection stores the merge target in
     `superseded_by`; timestamps are not compared — see Decision Log); else
     `MemoryConflict`.
   - Same post-rejection fallback helper, applied to all four.
   - (`updateTags`/`updateConfidence` already compare payloads; leave their
     `MemoryNotActive` behavior as is.)
3. Tests (new `kioku-core/test/Kioku/IdempotencySpec.hs`, registered like the others):
   for each operation, one "identical retry → `Right`, and the stream gained no extra
   event" case and one "differing payload → conflict error, and the stream gained no
   extra event" case. Cover explicitly: `start` (differing focus), `complete` after
   `failSession` (→ `SessionConflict`), `awaitInput` re-delivery with a different
   reason, `resume` re-delivery with different input, `Memory.record` with different
   content, `supersede` by X then by Y (→ `MemoryConflict`), `archive` after
   `supersede` (→ `MemoryConflict`), `merge` retry (→ `Right`).

Acceptance: the specific review examples behave as specified — e.g. superseding an
already-superseded-by-X memory with Y returns `Left (MemoryConflict ...)` and the stream
still shows exactly one `MemorySuperseded` event.


### Milestone 4 — Turn identity contract

Scope: turn recording gets a real identity contract enforced coherently in the
aggregate, the command layer, and the projection.

Work (gated on the audit in Concrete Steps step 0; default path assumes the audit finds
all existing turn sequences strictly increasing, which is expected because the only
in-repo writer — `kioku-cli/src/Kioku/Cli/Commands/DemoSession.hs` — records 0,1,2,...):

1. `kioku-core/src/Kioku/Session/Domain.hs`:
   - Extend the registers:

     ```haskell
     type SessionRegs =
       '[ '("awaitedCorrelationKey", Maybe Text),
          '("lastTurnIndex", Int)
        ]
     ```

   - Initialize on the `StartSession` edge: `B.slot @"lastTurnIndex" .= lit (-1)`.
   - On the `Running` → `RecordTurn` edge:
     `B.requireGt d.turnIndex (B.reg @"lastTurnIndex")` and
     `B.slot @"lastTurnIndex" .= d.turnIndex`. (`turnIndex` is already in the event
     payload, so replay recovers it; existing strictly-increasing streams replay
     unchanged.)
2. `kioku-core/src/Kioku/Session.hs` — `recordTurn`: after the status precheck, read
   existing turns via the turns read model; if a row with the same `turnIndex` exists:
   identical on `turnId`, `role`, `content`, `toolSummary`, `promptTokens`,
   `outputTokens`, `recordedAt` → `Right` without running the command; otherwise
   `SessionConflict`. If the same `turnId` exists at a *different* index →
   `SessionConflict`. Then run the command with the M3 post-rejection fallback (matcher:
   the identical-turn-row predicate), so a concurrent duplicate loser converges to
   `Right`.
3. `kioku-core/src/Kioku/Session/ReadModel.hs` — `insertTurnStmt`: add
   `turn_id = EXCLUDED.turn_id` to the `DO UPDATE SET` list, so a rebuild that replays a
   superseding event does not silently keep the old id.
4. Tests (in `SessionInvariantsSpec` or a dedicated group): identical re-record →
   `Right`, exactly one `TurnRecorded` event in the stream; same index different content
   → `SessionConflict`, one event; same `turnId` at a different index →
   `SessionConflict`; direct `runCommandWithProjections` with a non-increasing index →
   `Left CommandRejected` (proving the aggregate guard, independent of prechecks).

Acceptance: all four behaviors observable via the tests; `getTurns` shows the expected
single row per index.


### Milestone 5 — Legacy decoder coverage and documentation truth

Scope: close the untested legacy decode paths and stop the docs from promising
unimplemented semantics.

Work:

1. `kioku-core/test/Kioku/ReiCompatSpec.hs`: add fixtures and assertions for
   `agent_session_completed`, `agent_session_failed`, and `interactive_session_recorded`
   (mirror the existing `agent_session_started` fixture style; the field names come from
   `parseLegacySessionCompleted`/`parseLegacySessionFailed`/
   `parseLegacyInteractiveSessionRecorded` in
   `kioku-core/src/Kioku/Session/EventStream.hs` — `sessionId`, `completedAt`,
   `modelUsed`, `summary`; `sessionId`, `failedAt`, `errorMessage`; `sessionId`,
   `agentId`, `focusType`, `intentionId`, `startedAt`). Also add two *native* fixtures
   for `SessionResumed` without a `force` key: one with `"correlationKey": null`
   asserting `force == True`, one with `"correlationKey": "k1"` asserting
   `force == False` (locking in the M1 upcast rule).
2. `docs/user/concepts.md`: line ~49 ("Writes are idempotent and guarded by the current
   read-model state") — rewrite to state the new contract: duplicates that match are
   accepted, conflicting duplicates return conflict errors, and session/memory
   invariants are enforced by the aggregate. Line ~88 — state that the deadline is
   stored for the host's bookkeeping and **kioku does not enforce it** (no timer fires,
   nothing expires). Lines ~96-97 — describe aggregate-enforced correlation matching and
   `forceResume`.
3. `docs/user/library-api.md`: update the writers paragraph (~line 71), add
   `forceResume` next to `resume` (~line 134), add the `force` field to the
   `ResumeSessionData` listing (~line 190), and update the resume-idempotency sentence
   (~line 230) to "idempotent only when the input matches the recorded resume".
4. Code comments: on `Continuation.deadline` and `AwaitInputData.deadline` in
   `kioku-core/src/Kioku/Session/Domain.hs` and on `updateSessionAwaitingStmt` in
   `Session/ReadModel.hs`, note: "advisory only — stored for hosts; kioku does not
   enforce awaiting deadlines (MasterPlan 2 decision, 2026-07-07)".

Acceptance: `cabal test` green; reading the two docs files gives no statement
contradicted by the code.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kioku` inside
the nix devShell (which provides `cabal`, `ghc`, and Postgres binaries for the ephemeral
test databases).

**Step 0 — data audits (before M1 and M4).** These run against the *production* database
(the one holding real kioku streams; for a dev-only checkout, run them against the dev DB
from `just create-database` — they will trivially pass). kiroku tables live in the
`kiroku` schema; session streams are named `kioku_session-<id>`.

```sql
-- Audit A (gates M1's guard): list awaiting/resume correlation keys per session stream,
-- in order. A stream is UNSAFE only if a SessionResumed row carries a NON-NULL key
-- differing from the nearest preceding SessionAwaiting key.
SET search_path TO kiroku;
SELECT s.stream_name, se.stream_version, e.event_type,
       e.data->'data'->>'correlationKey' AS key
FROM events e
JOIN stream_events se USING (event_id)
JOIN streams s ON s.stream_id = se.stream_id
WHERE s.stream_name LIKE 'kioku_session-%'
  AND e.event_type IN ('SessionAwaiting', 'SessionResumed')
ORDER BY s.stream_name, se.stream_version;

-- Audit B (gates M4's guard): any session whose TurnRecorded indexes are not strictly
-- increasing in stream order. Zero rows = safe to ship the strict guard.
SET search_path TO kiroku;
WITH turns AS (
  SELECT s.stream_name, se.stream_version,
         (e.data->'data'->>'turnIndex')::int AS turn_index
  FROM events e
  JOIN stream_events se USING (event_id)
  JOIN streams s ON s.stream_id = se.stream_id
  WHERE s.stream_name LIKE 'kioku_session-%'
    AND e.event_type = 'TurnRecorded'
)
SELECT * FROM (
  SELECT stream_name, stream_version, turn_index,
         lag(turn_index) OVER (PARTITION BY stream_name ORDER BY stream_version) AS prev_index
  FROM turns
) x
WHERE prev_index IS NOT NULL AND turn_index <= prev_index;
```

Expected: Audit A shows every non-null resumed key equal to its preceding awaiting key;
Audit B returns zero rows. Record the outcome in Progress. If Audit A finds a mismatched
non-null key, that stream was corrupted by the race this plan fixes — record it in
Surprises & Discoveries and decide (with evidence) between accepting
`HydrationReplayFailed` for that stream or widening the `FromJSON` default; if Audit B
finds rows, drop the M4 register guard and ship the command-layer contract only, per the
Decision Log.

**Step 1 — M1 code.** The `FromJSON` instance for the event payload (in
`kioku-core/src/Kioku/Session/Domain.hs`; `withObject`, `(.:)`, `(.:?)`, `(.!=)` are
already imported there, `isNothing` comes from `Kioku.Prelude`):

```haskell
data SessionResumedData = SessionResumedData
  { sessionId :: !SessionId,
    correlationKey :: !(Maybe Text),
    force :: !Bool,
    input :: !Text,
    resumedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

-- Pre-force events (written before ExecPlan 12) lack the "force" key. Under the old
-- code an omitted correlation key bypassed matching, so a keyless legacy resume decodes
-- as a force-resume; a keyed one decodes as a plain resume. This keeps every historical
-- stream replayable through the new correlation guard.
instance FromJSON SessionResumedData where
  parseJSON =
    withObject "SessionResumedData" \o -> do
      sessionId <- o .: "sessionId"
      correlationKey <- o .:? "correlationKey"
      force <- o .:? "force" .!= isNothing correlationKey
      input <- o .: "input"
      resumedAt <- o .: "resumedAt"
      pure SessionResumedData {sessionId, correlationKey, force, input, resumedAt}
```

(Enable `NamedFieldPuns` if the module doesn't already have it via the project defaults,
or construct positionally.) Mirror the `force` field on `ResumeSessionData`. Transducer
edits as described in Plan of Work M1. Build:

```bash
cabal build kioku-core
```

Expect: compiles; the TH splice (`deriveAggregate`) regenerates
`SessionResumedTermFields` with the new `force` field and the register machinery for the
non-empty `SessionRegs` — if you forget `force = d.force` in the `emit`, the record
construction fails to compile, and if you forget the event-payload field entirely,
hydration of new events fails at test time (the guard's input is unrecoverable).

**Step 2 — M1 projection + API.** `updateSessionAwaitingStmt` becomes:

```haskell
updateSessionAwaitingStmt :: Statement (Text, Text, Maybe Text, Maybe UTCTime) ()
updateSessionAwaitingStmt =
  preparable
    "UPDATE kioku_sessions SET status = 'awaiting', awaiting_reason = $2, awaiting_correlation_key = $3, awaiting_deadline = $4, resume_input = NULL, updated_at = NOW() WHERE session_id = $1"
    ...
```

`Session.resume`/`forceResume` per Plan of Work. Update `AwaitingSpec` fixture records
with `force = False`.

**Step 3 — M1 tests.** Add `Kioku.SessionInvariantsSpec` to
`kioku-core/kioku-core.cabal` (`other-modules` of `test-suite kioku-test`) and to
`kioku-core/test/Main.hs`; add `keiro` to the test-suite `build-depends` (the suite
already has `keiro-core`, `kiroku-store`, `hasql`, `hasql-transaction`). For the
pre-change-stream replay test, build raw `EventData` values with event type
`"SessionResumed"` and a payload like:

```json
{"type": "session_resumed",
 "data": {"sessionId": "kioku_session_...", "correlationKey": null,
          "input": "approved", "resumedAt": "2026-07-01T00:00:00Z"}}
```

(the outer `type`/`data` shape comes from `eventAesonOptions` in
`kioku-api/src/Kioku/Prelude.hs`: tagged-object encoding with snake_case constructor
tags), append with `appendToStream` from `Kiroku.Store.Append`, then drive
`Session.awaitInput` on that stream and assert `Right`. Run:

```bash
cabal test kioku-core:kioku-test --test-show-details=direct
```

Expect (shape):

```text
kioku
  Awaiting park-and-resume
    park then resume:                                    OK
    ...
  Session invariants
    aggregate rejects mismatched resume key:             OK
    stale resume after re-park is rejected:              OK
    forceResume bypasses the key explicitly:             OK
    keyless wait resumes with Nothing:                   OK
    re-park clears resume_input:                         OK
    pre-force event streams still hydrate:               OK
All ... tests passed
```

**Step 4 — M2.** `selectSessionChainStmt` recursive CTE becomes (only the CTE skeleton
shown; the column lists stay exactly as today, with `1 AS depth,
ARRAY[session_id] AS path` appended to the base arm and `c.depth + 1,
c.path || s.session_id` to the recursive arm):

```sql
WITH RECURSIVE chain AS (
  SELECT <all row columns>, 1 AS depth, ARRAY[session_id] AS path
  FROM kioku_sessions
  WHERE session_id = $1
  UNION ALL
  SELECT <all s.* row columns>, c.depth + 1, c.path || s.session_id
  FROM kioku_sessions s
  INNER JOIN chain c ON s.session_id = c.previous_session_id
  WHERE NOT s.session_id = ANY (c.path)
    AND c.depth < 10000
)
SELECT <all row columns>
FROM chain
ORDER BY started_at ASC
```

The path array makes revisiting a session impossible (terminates on any cycle); the
depth cap is defense in depth and is far above any legitimate continuation chain. The
final `SELECT` omits `depth`/`path`, so the decoder is untouched. Lineage validation and
tests per Plan of Work M2; for the cycle fixture inside the app-effects test monad:

```haskell
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Transaction (runTransaction)
-- inside Eff es with Store, after generating ids a and b:
void . runTransaction . Tx.sql . encodeUtf8 $
  "INSERT INTO kioku_sessions (session_id, agent_id, focus, namespace, delegation_depth, status, started_at, previous_session_id) VALUES "
    <> "('" <> idText a <> "','t','f','kioku-test',0,'completed',NOW(),'" <> idText b <> "'),"
    <> "('" <> idText b <> "','t','f','kioku-test',0,'completed',NOW(),'" <> idText a <> "')"
```

(match `runTransaction`'s actual signature from the pinned kiroku when writing this;
ids come from `genSessionId` so they are well-formed). Wrap the assertion test case in
`localOption (mkTimeout 10_000_000)`. Verify the fix works by *first* running this test
against the unfixed statement and observing the timeout failure, then applying the CTE
change and observing `OK`.

**Step 5 — M3.** Errors, `SessionStatus`, matchers, fallback helper, memory contract,
`IdempotencySpec` per Plan of Work M3. Run the suite; every new case name should state
the contract, e.g. `supersede by a different winner is a conflict`.

**Step 6 — M4.** Registers/guard/dedup/projection per Plan of Work M4 (only after
Audit B). Note the projection change is exercised by the "same index different content
under direct command" path in tests.

**Step 7 — M5.** Fixtures and docs per Plan of Work M5. Full gate:

```bash
cabal build all
cabal test kioku-core:kioku-test --test-show-details=direct
```

Commit per milestone with conventional-commit messages, e.g.:

```text
feat(session): enforce resume correlation in the aggregate with explicit forceResume
fix(session): validate lineage at start and cycle-proof the chain CTE
feat(core): honest idempotent accepts with conflict errors for session and memory writes
feat(session): aggregate-enforced turn identity contract
test(core): cover legacy Rei decoders; docs: advisory awaiting deadline
```


## Validation and Acceptance

Beyond compilation, acceptance is behavioral. From the repo root, with the devShell
active:

```bash
cabal test kioku-core:kioku-test --test-show-details=direct
```

must pass, and the following scenarios (each a named test) demonstrate the changes:

1. **Resume race is closed at the aggregate.** With a session parked on `k1`, a direct
   `runCommandWithProjections` carrying `ResumeSession {correlationKey = Just "k2",
   force = False}` returns `Left CommandRejected` and appends nothing — even though no
   read-model precheck ran. Before this plan, the same call appended a `SessionResumed`
   correlated to the wrong wait.
2. **Force is explicit.** `Session.forceResume sid "input" now` resumes a keyed wait and
   the stored event carries `"force": true`. Plain `resume` with an omitted key no longer
   bypasses anything.
3. **Old streams keep working.** A stream hand-appended with pre-change JSON (no `force`
   key) accepts new commands; `HydrationDecodeFailed`/`HydrationReplayFailed` never
   appear in test output.
4. **`getChain` terminates on cyclic data.** With a raw-SQL two-cycle inserted,
   `Session.getChain` returns each row once, in under the 10-second tasty timeout
   (observed: milliseconds). Reverting only the CTE change makes this test time out —
   that is the fail-before/pass-after proof.
5. **Lineage is validated.** `Session.start` with `previousSessionId = Just sessionId`
   returns `Left (SessionInvalidLineage ...)`; likewise the other five malformed shapes.
6. **Accepts are honest.** For every operation in M3's list: identical retry → `Right`
   with no new event; differing payload → `Left (SessionConflict ...)` /
   `Left (MemoryConflict ...)` with no new event. Specifically `complete` on a failed
   session and `supersede`-by-Y-after-X now return conflicts where they previously
   returned success.
7. **Re-park hygiene.** After park → resume("approved") → park(`k2`): the row has
   `status = "awaiting"`, `resumeInput = Nothing`, `awaitingCorrelationKey = Just "k2"`.
8. **Turn identity.** Identical `recordTurn` retry → `Right`, one event; same index with
   different content → `SessionConflict`; same `turnId` at a new index →
   `SessionConflict`; a non-increasing index pushed straight at the aggregate →
   `CommandRejected`.
9. **Legacy decoders.** `parseSessionEvent` decodes the three previously-untested Rei
   shapes to the expected payloads (ReiCompatSpec assertions).

Interpreting failures: a `HydrationReplayFailed` in any test means a guard rejected a
committed event — re-check the guard against the historical shapes table in the M1
Decision Log entry. A tasty timeout on the cycle test means the CTE guard is wrong.


## Idempotence and Recovery

Every step in this plan is a source-tree edit plus tests against throwaway ephemeral
databases (`withKiokuMigratedDatabase` creates a fresh instance per run), so all steps
can be re-run freely; nothing mutates shared state. There is no SQL migration and no
destructive operation. The two audits in Concrete Steps step 0 are read-only `SELECT`s.

Milestones are independently committable; if a milestone must be abandoned midway,
`git checkout -- <files>` restores a working tree (the repo is clean at start). The one
ordering constraint: M1's `force` field must land before or with any redeployment that
writes `SessionResumed` events, because M1's decoder change is what keeps *new* events
(which include `force`) and *old* events (which do not) simultaneously readable — the
decoder tolerates both, so deploying M1 is itself safe in either direction (new code
reads old events; note that *old* code cannot read *new* events, so do not roll back the
library after new-format events exist — record this in the deployment notes of whatever
host upgrades first).

If Audit A or B fails, do not ship the corresponding guard; follow the contingency named
in the audit step and Decision Log, and update this plan.


## Interfaces and Dependencies

Frameworks (pinned in `cabal.project`; read them from the paths below, never from
`/nix/store`):

- keiki `bc987f46393b604c335f034385b4c3c1ad118074`
  (source at `/Users/shinzui/Keikaku/bokuno/keiki`): `Keiki.Builder` (edge DSL: `onCmd`,
  `emit`, `goto`, `slot`, `(.=)`, `reg`, `requireGuard`, `requireGt`), `Keiki.Core`
  (`lit`, `(.==)`, `(.||)`, `HsPred`, `SymTransducer`, replay via
  `applyEventStreaming`/`solveOutput`), `Keiki.Generics` (`emptyRegFile`),
  `Keiki.Generics.TH` (`deriveAggregate`).
- keiro `f1d67a01b7457387a4861e7268d1c521ef82287d`
  (source at `/Users/shinzui/Keikaku/bokuno/keiro`): `Keiro.Command`
  (`CommandError (CommandRejected)`, OCC retry semantics), `Keiro.Projection`
  (`runCommandWithProjections` — the pinned version takes a bare `EventStream`, unlike
  keiro HEAD which takes `ValidatedEventStream`; write against the pin),
  `Keiro.ReadModel` (registry keys on name/version/shapeHash — unchanged here, so no
  version bump).
- kiroku (pin per `cabal.project`, source at
  `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`): `Kiroku.Store.Append`
  (`appendToStream` for the raw legacy-shape test), `Kiroku.Store.Read`
  (`readStreamForward` for stream assertions), `Kiroku.Store.Transaction`
  (`runTransaction` for the raw-SQL cycle fixture).

Module-level deliverables (types/signatures that must exist when the plan is done), all
full paths:

- `kioku-core/src/Kioku/Session/Domain.hs`:
  `type SessionRegs = '[ '("awaitedCorrelationKey", Maybe Text), '("lastTurnIndex", Int)]`;
  `ResumeSessionData` and `SessionResumedData` each with `force :: !Bool`; a hand-written
  `instance FromJSON SessionResumedData` defaulting `force` to
  `isNothing correlationKey`; guarded `ResumeSession` and `RecordTurn` edges.
- `kioku-core/src/Kioku/Session.hs`: exports `forceResume`;
  `SessionWriteError` gains `SessionConflict !Text` and `SessionInvalidLineage !Text`;
  internal `SessionStatus` + `parseSessionStatus`; `maxDelegationDepth :: Int` (= 64);
  payload matchers + `acceptRejectedIfMatches`.
- `kioku-core/src/Kioku/Session/ReadModel.hs`: `updateSessionAwaitingStmt` nulls
  `resume_input`; `selectSessionChainStmt` carries `path`/`depth`; `insertTurnStmt`
  updates `turn_id` on conflict. Row types, decoders, read-model versions: unchanged.
- `kioku-core/src/Kioku/Memory.hs`: `MemoryWriteError` gains `MemoryConflict !Text`;
  payload-matching accepts for `record`/`supersede`/`archive`/`merge`.
- Tests: `kioku-core/test/Kioku/SessionInvariantsSpec.hs` and
  `kioku-core/test/Kioku/IdempotencySpec.hs` (new), extensions to `AwaitingSpec`,
  `SessionLineageSpec`, `ReiCompatSpec`; test-suite `build-depends` gains `keiro`.

Cross-plan coordination (reference by path only):

- `docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md`
  owns schema-level index/constraint work. This plan needs **no** index on
  `kioku_sessions.previous_session_id` for `getChain` — the recursive join resolves
  through the `kioku_sessions` primary key (see Surprises & Discoveries). If plan 13
  nevertheless adds lineage indexes or constraints (e.g. a CHECK on `delegation_depth`),
  they are complementary; nothing here conflicts. This plan adds no migration, so there
  is no timestamp-ordering interaction; if that changes during implementation, mint a
  fresh UTC-timestamped file in `kioku-migrations/sql-migrations/` (use
  `just new-migration name=<slug>`) and update the "Last touched" comment in
  `kioku-migrations/src/Kioku/Migrations.hs` so the TH embed re-runs — per
  `docs/plans/14-align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations.md`,
  which owns the staleness guard.
- The memory supersession-chain query's *indexes* are plan 13's; its cycle behavior needs
  no fix here (its CTE uses `UNION`, which deduplicates and terminates).
- The MasterPlan (`docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md`)
  records the awaiting-deadline out-of-scope decision this plan's M5 documents.
