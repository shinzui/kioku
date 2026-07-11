---
id: 11
slug: harden-worker-resilience-with-ack-policy-bounded-retries-and-loop-supervision
title: "Harden worker resilience with ack policy, bounded retries, and loop supervision"
kind: exec-plan
created_at: 2026-07-07T14:58:23Z
intention: "intention_01kwyhabypepdt1mwemmf0dvqa"
master_plan: "docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md"
---

# Harden worker resilience with ack policy, bounded retries, and loop supervision

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

kioku is an event-sourced agent-memory library. Two background workers keep its derived
data fresh: an embedding worker that turns every recorded memory into a vector embedding
(so semantic recall works), and a distillation timer worker that fires durable timers to
summarize sessions into memory "atoms" (L1), scenes (L2), and personas (L3) using an LLM.
Today both workers treat every failure identically — and wrongly. A brief embedding-API
outage silently and permanently loses embeddings (the event is acknowledged as success). A
single transient database blip permanently halts the embedding pipeline. A distillation
timer whose LLM call fails for a structural reason (for example, a conversation that
exceeds the model's context window) retries forever at full LLM cost, every five minutes,
with no record that anything is wrong. And the worker loops themselves can die silently:
one thread runs on a bare `forkIO`, so its death leaves a zombie process that looks alive
while all distillation has stopped.

After this plan, both workers apply one uniform failure taxonomy: transient failures are
retried a bounded number of times with backoff; permanent failures are dead-lettered into
a visible, queryable record (kiroku's `dead_letters` table for events, keiro's
`keiro_timers.status = 'dead'` rows for timers); and work that does not belong to a
handler is left alone rather than swallowed. The worker process itself is supervised: a
loop that hits a transient store error retries with capped backoff and logs loudly, and if
either pipeline (embedding host or timer loop) stops for good, the whole process exits
non-zero so an operator or process supervisor notices. You can see it working by running
the test suite (new tests assert every acknowledgment decision and timer state
transition) and by running `kioku worker` against a database and observing the startup
backfill pass, the drain behavior, and the loud non-zero exit when a pipeline dies.


## Progress

- [x] M1: add `Kioku.Worker.Failure` (transient/permanent `StoreError` classification, embedding retry-delay schedule). — 2026-07-11
- [x] M1: refactor `kioku-core/src/Kioku/Memory/Embedding/Worker.hs` — injectable embed function (`EmbeddingWorkerEnv`), `EmbedOutcome`, ack-decision mapping (retry / dead-letter / halt), `guardKirokuHandler` wrap, stderr logging. — 2026-07-11
- [x] M1: extend `kioku-core/test/Kioku/EmbeddingWorkerSpec.hs` with pure classification tests and Postgres-backed ack-decision tests (provider failure → `AckRetry`; decode failure → `AckDeadLetter`; dimension mismatch → `AckHalt`; success → `AckOk` and stored embedding). — 2026-07-11 (7 cases, all green under pgvector; 3 skip without it)
- [x] M2: add `kioku-core/src/Kioku/Distill/Timer/Outcome.hs` with `FireOutcome` and delay schedules; register in `kioku-core.cabal`. — 2026-07-11
- [x] M2: convert `fireL1Timer` (Timer/Worker.hs), `fireL2SceneTimer` (L2.hs), `fireL3PersonaTimer` (L3.hs) to return `FireOutcome`. — 2026-07-11
- [x] M2: add `applyFireOutcome`, switch to keiro `runTimerWorkerWith` with `maxAttempts = Just 8`, handle unknown process-manager timers, delete unused `runL1TimerWorkerLoop`/`runL1TimerWorkerOnce`. — 2026-07-11
- [x] M2: new test module `kioku-core/test/Kioku/TimerWorkerSpec.hs` (outcome mapping, unknown-PM requeue, attempt-ceiling dead-letter, drain); register in cabal and `test/Main.hs`. — 2026-07-11 (6 cases green)
- [x] M3: add `drainKiokuTimers` to Timer/Worker.hs; drain-before-sleep test. — 2026-07-11
- [x] M3: restructure `kioku-cli/src/Kioku/Cli/Commands/Worker.hs` — per-iteration `runAppIO` with capped-backoff retry on store errors, `Control.Concurrent.Async.race` supervision, startup backfill pass, non-zero exit on pipeline death; add `async` to `kioku-cli.cabal`. — 2026-07-11
- [x] Final: full build + test sweep (43 tests green), manual CLI verification against a real database, living sections updated. — 2026-07-11


## Surprises & Discoveries

These were found while researching this plan against the pinned framework sources (all
verified at the exact commits in `cabal.project`); they shaped the design and correct two
statements in the master plan.

- The review finding "the app keeps living with a dead pipeline" after a store error is
  half right, and reality is worse in a different way. In
  `kioku-core/src/Kioku/Memory/Embedding/Worker.hs`, `embeddingHandler` returns
  `AckHalt (HaltFatal ...)` on any `StoreError`. In shibuya (pin `3f276ee1`,
  `shibuya-core/src/Shibuya/Runner/Supervised.hs`), a halt is converted to a graceful
  processor exit (`catch \(ProcessorHalt _) -> pure ()`), the processor's `done` TVar is
  set, and `waitApp` (which blocks until all processors are done) returns. So
  `runEmbeddingWorkerHost` returns `Right ()`, `runContinuousWorker` returns, and the
  whole `kioku worker` process exits with code 0 — silently killing the `forkIO`'d timer
  loop too. The opposite direction (timer-loop death while the embedding host lives)
  produces the zombie the review described. Both directions are silent-death modes; M3
  fixes both.
- keiro at the pinned commit (`f1d67a01`, `keiro/src/Keiro/Timer.hs`) already ships the
  dead-letter machinery this plan needs: `runTimerWorkerWith` takes `TimerWorkerOptions
  { maxAttempts :: Maybe Int, requeueStuckAfter :: Maybe NominalDiffTime }`, a claimed
  timer whose post-claim `attempts` exceeds `maxAttempts` is moved to status `dead` via
  `deadLetterTimer` with an explanatory `last_error`, and `deadLetterTimer` /
  `requeueStuckTimer` are exported. No keiro change is required for bounded retries or
  dead-lettering. (kioku today calls the convenience wrapper `runTimerWorker`, which uses
  `defaultTimerWorkerOptions`: `maxAttempts = Nothing` — never dead-letter — and
  `requeueStuckAfter = Just 300`.)
- The shibuya→kiroku adapter (kiroku pin `4312aa8c`,
  `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`) is **ack-coupled**: the kiroku
  subscription worker blocks until the handler's `AckDecision` is finalized. A synchronous
  exception escaping the handler therefore blocks the worker **forever** (the ack is never
  finalized). The adapter exports `guardKirokuHandler` for exactly this; kioku's embedding
  handler does not use it today. M1 adds it.
- `AckRetry` is already bounded upstream: the adapter maps it to kiroku's per-subscription
  `RetryPolicy` (default `retryMaxAttempts = 5` **total deliveries**), after which the
  event is recorded in kiroku's `dead_letters` table with reason `DeadLetterMaxAttempts`
  and the checkpoint advances. The envelope's `attempt` field carries the zero-based
  redelivery count, so the handler can pick per-attempt backoff delays. The adapter config
  at this pin does **not** expose `retryPolicy`, so the 5-delivery bound is fixed for now
  (noted as an optional dependency-repo improvement in the Decision Log).
- The master plan's Integration Points section says the timer fire functions return
  `Maybe UTCTime`. Reality: they return `Maybe EventId`
  (`kioku-core/src/Kioku/Distill/Timer/Worker.hs`), where `Just eid` marks the timer
  fired with that event id and `Nothing` leaves it `Firing` until keiro's stale-claim
  requeue (300 s) makes it claimable again. This plan is written against the real type.
- keiro's `scheduleTimerTx` upsert re-arms a timer **only while its status is
  `'scheduled'`** (`ON CONFLICT ... WHERE keiro_timers.status = 'scheduled'`). Combined
  with `requeueStuckTimer` (moves `firing` → `scheduled`, fire_at unchanged), this gives a
  two-step "reschedule with delay" using only public keiro API — the basis for
  retry-with-backoff on timers (see Decision Log entry 4).

Found during implementation (2026-07-11):

- **The M1 vector-gated tests cannot run in this repo's dev shell, and proving them
  required building a pgvector-enabled PostgreSQL out-of-tree.** `nix/haskell.nix:29`
  ships plain `pkgs.postgresql`, so `detectVectorCapability` reports
  `VectorExtensionUnavailable` and three of the four database-backed cases skip. Building
  `pkgs.postgresql.withPackages (ps: [ps.pgvector])` into a scratch out-link and putting
  its `bin` first on `PATH` runs them for real: all 7 embedding-worker cases pass, and the
  dimension-mismatch case produces exactly the predicted permanent error —
  `UnexpectedServerError "22000" "expected 1536 dimensions, not 8"` → `AckHalt (HaltFatal ...)`.
  Adding pgvector to the dev shell is docs/plans/13's M2, so the shell was left unchanged;
  the gating stays so the suite is green either way.
- **A pre-existing test asserts the *absence* of pgvector and will fail the moment
  docs/plans/13 M2 lands.** `kioku-core/test/Kioku/DistillSpec.hs:465`
  (`testRecallCandidateWindow`, added by docs/plans/9) asserts
  `capability @?= VectorExtensionUnavailable`, and its comment states that this absence
  "is what makes dummyEmbeddingModel safe" — with pgvector present, `recallCandidates`
  would call the embedding endpoint at the dummy base URL `http://embedding.invalid`. So
  docs/plans/13's pgvector work must also give that test an injected fake embedder rather
  than relying on the degraded environment. Verified by running the suite against the
  pgvector build: that one case fails (`expected: VectorExtensionUnavailable, but got:
  VectorAvailable`) while every other case, including all seven new ones, passes.


Found while verifying M3 against a real database (2026-07-11):

- **A halted embedding processor does not return gracefully; it crashes.** The plan's
  research (above) predicted that `AckHalt` makes shibuya exit the processor cleanly, so
  `waitApp` returns and `runEmbeddingWorkerHost` yields `Right ()`. What actually happens at
  this pin is that the halt tears its own machinery down and the `race` rethrows
  `ExceptionInLinkedThread ... thread blocked indefinitely in an STM transaction`. The
  supervision contract still holds — the process dies loudly and non-zero — but the clean
  `dieWorker "embedding worker stopped ..."` branch is not the one that fires. M3 therefore
  wraps the `race` in `try @SomeException` and routes the crash through `dieWorker` too, so
  the operator always gets a reason and exit 1 rather than an uncaught-exception dump. The
  `Right (Right ())` branch is retained for the case shibuya intends.
- **The embedding-columns migration fails hard when pgvector is already installed in
  `public`.** `2026-06-24-01-00-00-kioku-memory-embeddings.sql` runs `CREATE EXTENSION IF
  NOT EXISTS vector` and then `ALTER TABLE kioku_memories ADD COLUMN embedding vector(1536)`
  with an unqualified type name, but migrations run with `search_path` set to `kiroku`. If
  the extension already exists in `public` (the default, and the most common way an operator
  installs it), the `CREATE EXTENSION` is a no-op, the availability check passes, and the
  `ALTER TABLE` then dies with `42704: type "vector" does not exist` — the whole migration
  aborts instead of degrading. Reproduced while building the pgvector database for this
  plan's verification. This belongs to
  docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md's
  M2 (self-healing embedding-schema migration), which should either schema-qualify the type
  or create the extension into the target schema.

Manual verification evidence (2026-07-11), against a pgvector database built out-of-tree
and the repository's own dev database:

```text
$ kioku worker                      # VectorAvailable path
Startup backfill: embedded 0 missing memory embeddings.
kioku timer worker started.
kioku embedding worker started. Press Ctrl+C to stop.

# database stopped underneath the running worker — the loop survives and retries
kioku timer worker: store error (will retry): ConnectionLost "... Connection refused ..."
kioku timer worker: store error (will retry): ConnectionLost "... Connection refused ..."

# a permanent store error (worker run as a role denied SELECT on kioku_memories)
kioku-memory-embedding: fatal store error, halting: UnexpectedServerError "42501" "permission denied for table kioku_memories"
kioku worker: worker pipeline crashed: ExceptionInLinkedThread ...; exiting
$ echo $?
1

# drain: seven due timers, one pass (old loop: one timer per five-second poll)
6 x "attempt 1]: retrying in 30s"
1 x "attempt 2]: retrying in 60s"
due timers before: 7    due timers after: 0
```

## Decision Log

- Decision: The fire-outcome contract is a four-constructor sum type `FireOutcome`
  (`FireCompleted !EventId` / `FireRetryLater !NominalDiffTime !Text` /
  `FireFailedPermanently !Text` / `FireNotMine`), defined in a new bottom-of-the-graph
  module `Kioku.Distill.Timer.Outcome` so that `Kioku.Distill.L2`, `Kioku.Distill.L3`,
  and `Kioku.Distill.Timer.Worker` can all import it without cycles (Timer.Worker imports
  L2 and L3, so the type cannot live in Timer.Worker).
  Rationale: the current `Maybe EventId` conflates "transient failure", "permanent
  failure", and "not my timer" into `Nothing`, producing unbounded 300-second requeues.
  Four explicit constructors make the handler's intent total and make the migration of
  docs/plans/9-make-l1-distillation-idempotent-and-debounce-distillation-timers.md's
  handlers mechanical: every `Just eid` becomes `FireCompleted eid`, every error branch
  picks retry-later or permanent explicitly.
  Date: 2026-07-07
- Decision: This plan writes against the **actual** fire type `Maybe EventId`, not the
  `Maybe UTCTime` stated in the master plan's Integration Points.
  Rationale: verified in `kioku-core/src/Kioku/Distill/Timer/Worker.hs` and keiro's
  `runTimerWorker` signature (`TimerRow -> Eff es (Maybe EventId)`).
  Date: 2026-07-07
- Decision: Bounded timer attempts use keiro's existing `runTimerWorkerWith` with
  `TimerWorkerOptions { maxAttempts = Just 8, requeueStuckAfter = Just 300 }`. No keiro
  change is required.
  Rationale: `maxAttempts` and `deadLetterTimer` (terminal `dead` status with a visible
  `last_error`, queryable via `SELECT * FROM keiro_timers WHERE status = 'dead'`) already
  exist at the pinned keiro commit. Eight claims with the retry schedule below spans
  roughly an hour of retrying before giving up — long enough to ride out provider
  incidents, short enough to stop burning LLM tokens on structurally failing work.
  Date: 2026-07-07
- Decision: `FireRetryLater delay note` is implemented with two public keiro calls:
  `requeueStuckTimer row.timerId` (moves the claimed `firing` row back to `scheduled`,
  fire_at unchanged) followed by `runTransaction (scheduleTimerTx request')` where
  `request'` copies the row's fields with `fireAt = addUTCTime delay now` (the upsert
  re-arms because the row is now `scheduled`). The fire adapter then returns `Nothing` so
  keiro performs no further update.
  Rationale: keiro has no single-call "reschedule a firing timer" at this pin. The
  two-step has a benign race — another worker could claim the timer between the two calls
  and fire it once immediately — which is safe under keiro's documented at-least-once
  contract (handlers must be idempotent) and kioku runs one timer loop per process today.
  A `rescheduleFiringTimer :: TimerId -> UTCTime -> Text -> Eff es Bool` in keiro (one
  UPDATE, also able to record the note in `last_error`) is noted as an optional
  dependency-repo improvement; it is NOT required by this plan.
  Date: 2026-07-07
- Decision: Timers claimed for an unknown process-manager name (matching none of
  `kioku-l1-extract`, `kioku-l2-scene`, `kioku-l3-persona`) are requeued with a long fixed
  delay (600 s) and a stderr log naming the PM, and are eventually dead-lettered by the
  attempt ceiling. They are NOT dead-lettered immediately, and NOT marked fired.
  Rationale: keiro's `claimDueTimer` claims the earliest due timer regardless of PM name
  (verified in `keiro/src/Keiro/Timer/Schema.hs`; there is no PM-name filter at this
  pin), so an unknown-PM timer cannot be "skipped without claiming". Immediate
  dead-letter would destroy timers scheduled by a newer kioku version during a rolling
  deploy; the 600-second requeue gives a newer worker time to pick them up, while the
  ceiling guarantees the Finding-5 forever-cycle ends in a visible `dead` row. A keiro
  claim-time PM-name filter is noted as an optional dependency-repo improvement; the
  kioku-side mitigation above works without it.
  Date: 2026-07-07
- Decision: Embedding-API failures return `AckRetry` with an attempt-indexed delay
  schedule of 5 s, 20 s, 60 s, 180 s (indexed by the envelope's zero-based `attempt`;
  attempts ≥ 3 use 180 s), delegating bounding and dead-lettering to kiroku's
  subscription `RetryPolicy` (5 total deliveries, then the event lands in kiroku's
  `dead_letters` table with `DeadLetterMaxAttempts` and the checkpoint advances).
  Recovery from dead-lettered embeddings is `backfillMissingEmbeddings`, which M3 also
  runs automatically at continuous-worker startup, so an outage longer than the retry
  window (~4.5 minutes) self-heals on the next worker restart instead of requiring a
  human. Exposing `retryPolicy` through `KirokuAdapterConfig` is an optional
  dependency-repo improvement (kiroku repo), not required.
  Date: 2026-07-07
- Decision: `StoreError` classification: `PoolAcquisitionTimeout`, `ConnectionLost`, and
  `ConnectionError` are transient (retry); every other constructor
  (`WrongExpectedVersion`, `EmptyAppendBatch`, `StreamNotFound`, `ReservedStreamName`,
  `StreamNameTooLong`, `StreamAlreadyExists`, `DuplicateEvent`, `EventAlreadyLinked`,
  `LinkSourceEventMissing`, `UnexpectedServerError`) is permanent. In the embedding
  handler, transient → `AckRetry`, permanent → `AckHalt (HaltFatal ...)` (a permanent
  store error there means schema/config breakage such as a vector dimension mismatch,
  which would fail identically for every subsequent event — halting is honest;
  dead-lettering would drain the entire stream into `dead_letters`).
  Rationale: matches the constructor documentation in kiroku's
  `kiroku-store/src/Kiroku/Store/Error.hs` ("Almost always retryable" /"Retryable in most
  cases" / "not generally retryable — investigate").
  Date: 2026-07-07
- Decision: Loop supervision uses `Control.Concurrent.Async.race` between the timer loop
  and the embedding host (replacing bare `forkIO`), with the timer loop restructured so
  each pass runs in its own `runAppIO` (its own `runErrorNoCallStack @StoreError` scope).
  A store error in a pass is logged to stderr and retried forever with capped exponential
  backoff (5 s doubling to a 60 s cap, reset on success) — a database outage should not
  permanently kill the worker, and restarting the process would not help. Any *other*
  escape (an exception, or the embedding host's `waitApp` returning because its processor
  halted) ends the `race`, is logged, and the process exits with code 1 so a process
  supervisor can restart it. The embedding handler is additionally wrapped in
  `guardKirokuHandler` so a stray synchronous exception becomes a retry instead of a
  forever-blocked kiroku subscription worker.
  Date: 2026-07-07
- Decision: Delete `runL1TimerWorkerLoop` and `runL1TimerWorkerOnce` from
  `Kioku.Distill.Timer.Worker`.
  Rationale: nothing in the repository calls them (verified by grep; only the CLI's
  `runKiokuTimerWorker*` variants are used), and an L1-only loop is precisely the
  Finding-5 foot-gun that claims-and-starves L2/L3 timers.
  Date: 2026-07-07
- Decision: `L1SessionNotFound` continues to complete the timer (now
  `FireCompleted (timerMarkerEventId ...)`), and bad payloads / unparseable correlation
  ids become `FireFailedPermanently` (dead-letter) instead of today's silent mark-fired.
  Rationale: a missing session is an expected state (session data may be deleted);
  refining its semantics belongs to
  docs/plans/9-make-l1-distillation-idempotent-and-debounce-distillation-timers.md. A
  corrupt payload, by contrast, can never succeed and deserves a visible `dead` row, not
  a fake success.
  Date: 2026-07-07
- Decision: Observability is plain `System.IO.hPutStrLn IO.stderr` lines prefixed with the
  worker name. kioku has no logging framework, and introducing one is out of scope.
  Date: 2026-07-07


## Outcomes & Retrospective

Delivered in three commits (`0400be1`, `39e4474`, `7ba500f`). Both workers now share one
failure taxonomy, and every failure lands somewhere an operator can see it. The test suite
grew from 31 to 43 cases; the new ones fail against the pre-plan code by construction (the
old handler returns `AckOk`/`AckHalt` where they expect retry/dead-letter, and the old fire
functions leave timers `firing` where they expect `scheduled`-with-backoff or `dead`).

Against the original findings:

- Findings 1–3 (embedding worker): a provider outage now retries with backoff and is
  recovered by the startup backfill instead of silently losing the embedding forever; a
  transient store error retries instead of halting the pipeline; a corrupt payload
  dead-letters with a reason instead of vanishing. Only a permanent store error halts, and
  the M1 dimension-mismatch test proves that path against a real `vector(1536)` column.
- Findings 4–5 (timers): `FireOutcome` replaced the three-way-ambiguous `Nothing`. Transient
  failures reschedule with exponential backoff, permanent ones dead-letter immediately, and
  keiro's attempt ceiling (8) turns a structurally failing distillation into a visible `dead`
  row instead of an unbounded LLM bill. Unknown-PM timers requeue 600s out and stop starving
  the queue.
- Finding 6 (supervision): verified end-to-end. A database outage is now survivable (the loop
  logs and retries forever), and a genuinely dead pipeline exits 1 with a reason. No bare
  `forkIO` remains.
- Finding 7 (throughput): seven due timers drained in one pass against the dev database.
- Finding 8 (coverage): thirteen new cases across two spec modules.

Two things did not go as designed, both recorded above in Surprises & Discoveries. A halted
processor crashes rather than returning cleanly, so the supervision code had to catch
exceptions as well as inspect return values — the contract (loud, non-zero, with a reason)
holds, but by a different route than planned. And proving M1's vector-gated cases required
building a pgvector PostgreSQL out-of-tree, because this repo's dev shell ships none; those
three cases skip in the default shell and are only green when pgvector is present.

Two gaps handed to siblings rather than fixed here, because they are squarely in
docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md's
scope: `DistillSpec`'s `testRecallCandidateWindow` asserts pgvector's *absence* and will fail
the moment the dev shell gains it, and the embedding-columns migration aborts outright when
pgvector is already installed in `public`. Both are load-bearing for that plan's M2 and both
are documented with reproductions.


## Context and Orientation

kioku is a Haskell cabal project with four packages: `kioku-api` (types and the shared
prelude), `kioku-core` (domain logic and the workers), `kioku-cli` (the `kioku`
executable), and `kioku-migrations` (codd SQL migrations plus a test-support library that
boots an ephemeral, fully migrated PostgreSQL). It builds on four pinned git dependencies
(see `cabal.project` at the repo root): **kiroku** (tag `4312aa8cc3e4...`) — a PostgreSQL
event store; **keiro** (tag `f1d67a01b745...`) — an event-sourcing framework providing
durable timers; **shibuya** (tag `3f276ee190e5...`) — a queue-processing framework with
explicit acknowledgment semantics; and **keiki** — event codecs. The local source
checkouts of these dependencies can be located with `mori registry show shinzui/kiroku
--full` (and likewise `shinzui/keiro`, `shinzui/shibuya`); always read them at the pinned
commit (`git show <tag>:<path>`), never search `/nix/store` or the filesystem root.

Terms used below, in plain language:

- An **event** is an immutable record appended to the kiroku store (a Postgres table).
  A **subscription** delivers events to a handler in order, tracking a **checkpoint** (the
  position it has processed up to).
- An **ack decision** (`Shibuya.Core.Ack.AckDecision`) is the handler's verdict on one
  delivered event: `AckOk` (done, advance the checkpoint), `AckRetry !RetryDelay`
  (redeliver the same event after the delay; the kiroku adapter bounds total deliveries
  at 5 by default, then dead-letters), `AckDeadLetter !DeadLetterReason` (record the event
  in kiroku's `dead_letters` table and advance past it), or `AckHalt !HaltReason` (cancel
  the subscription; no checkpoint advance, so the event replays on restart).
- A **dead letter** is a failed work item parked in a visible place instead of being
  retried or dropped: for events, a row in kiroku's `dead_letters` table; for timers, a
  `keiro_timers` row with `status = 'dead'` and a human-readable `last_error`.
- A **process manager** (PM) is a named saga that schedules **durable timers** — rows in
  keiro's `keiro_timers` table with a `process_manager_name`, `correlation_id`, `fire_at`
  time, JSON `payload`, an `attempts` counter (incremented on every claim), and a
  `status` lifecycle: `scheduled` → `firing` (claimed by a worker) → `fired` /
  `cancelled` / `dead`. keiro's `claimDueTimer` claims the earliest due `scheduled` timer
  with `FOR UPDATE SKIP LOCKED` **regardless of PM name**. A `firing` row whose fire
  action never completes is moved back to `scheduled` by the worker's stale-claim requeue
  (`requeueStuckAfter`, default 300 s).
- **effectful**: kioku uses the `effectful` effect system. `Eff es a` is a computation;
  `Store :> es` gives database access; `Error StoreError :> es` is a typed error channel
  that kiroku's store uses (`throwError`) for every database failure.
  `kioku-core/src/Kioku/App.hs` defines `runAppIO :: AppEnv -> Eff AppEffects a -> IO
  (Either StoreError a)` which runs one `runErrorNoCallStack @StoreError` over the whole
  computation — meaning any uncaught store error aborts the *entire* computation,
  including a `forever` loop inside it.

The files this plan touches, and their current defects:

`kioku-core/src/Kioku/Memory/Embedding/Worker.hs` — the embedding worker.
`embeddingWorkerProcessor` subscribes to the `kioku_memory` category filtered to
`MemoryRecorded` events (via the shibuya-kiroku adapter, `StrictInOrder`/`Serial`).
`embeddingHandler` (lines 110–124) calls `processRecordedEvent` and returns `AckOk`
unconditionally on success, and maps **every** `StoreError` to `AckHalt (HaltFatal ...)`.
`processRecordedEvent` (126–140) silently ignores decode failures (`Left _ -> pure ()`)
and voids the result of `embedMemoryContent`. `embedAndStore` (187–210) calls
`embedWithRetry model 3 content` (three in-process attempts ~0.6 s apart, defined in
`kioku-core/src/Kioku/Memory/Embedding.hs`) and on `Left _err` returns `False` — the
failure disappears and the event is acked. Consequences: an embedding-provider outage
longer than ~1.4 s permanently loses embeddings (Finding 1); one transient DB blip halts
the pipeline (Finding 2); corrupt payloads vanish without a trace (Finding 3).

`kioku-core/src/Kioku/Distill/Timer/Worker.hs` — the distillation timer worker.
`fireL1Timer` returns `Maybe EventId`: `Nothing` when the PM name is not
`kioku-l1-extract` (defined in `kioku-core/src/Kioku/Distill/Timer.hs`) **and also** for
every `distillSessionL1` error except `L1SessionNotFound`; a bad correlation id is marked
fired. `fireKiokuTimer` chains L1 → `fireL2SceneTimer`
(`kioku-core/src/Kioku/Distill/L2.hs`, PM `kioku-l2-scene`) → `fireL3PersonaTimer`
(`kioku-core/src/Kioku/Distill/L3.hs`, PM `kioku-l3-persona`), each with the same
conflation. The runner uses keiro's `runTimerWorker` (default options: no attempt
ceiling, 300 s stale requeue). Consequences: a persistently failing LLM extraction
retries forever every ~300 s at full LLM cost with no dead-letter (Finding 4); a timer
whose PM matches no handler is claimed anyway, all three handlers return `Nothing`, and
it cycles `firing` → requeue forever (Finding 5). The loops
`runKiokuTimerWorkerLoop`/`runL1TimerWorkerLoop` sleep unconditionally between passes
(max(0.1 s, poll) — the CLI passes 5 s), capping throughput at one timer per pass
(Finding 7). `runL1TimerWorkerLoop`/`runL1TimerWorkerOnce` have no callers.

`kioku-cli/src/Kioku/Cli/Commands/Worker.hs` — the `kioku worker` command.
`runContinuousWorker` (66–81): under `VectorAvailable` it runs the timer loop on a bare
`forkIO` and the embedding host on the main thread; the timer loop's entire `forever`
lives inside a single `runAppIO`, so one store error aborts it, `runTimerLoop` calls
`ioError`, and that exception kills only the forked thread — the embedding host keeps
the process looking alive while distillation is dead (Finding 6). Conversely (see
Surprises), an embedding halt makes the process exit 0 silently. `runContinuousWorker`
never runs a backfill; recovering lost embeddings requires a human to run
`kioku worker --backfill`.

`kioku-core/src/Kioku/App.hs` — `runAppIO` as described above. Not modified by this plan,
but the reason M3 must run each timer pass in its own `runAppIO`.

`kioku-core/test/Kioku/EmbeddingWorkerSpec.hs` — currently tests only the pure
`shouldSkipEmbedding` (Finding 8). Postgres-backed tests elsewhere
(`kioku-core/test/Kioku/DistillSpec.hs`) show the fixture pattern:
`withKiokuMigratedDatabase` from `kioku-migrations:test-support`
(`kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs`) boots a cached
ephemeral PostgreSQL and runs all kiroku + keiro + kioku migrations, handing the test a
connection string; tests then use `withStore (defaultConnectionSettings connStr)`,
`AppEnv`/`noopTracer`/`runAppIO` exactly like the CLI. The LLM is faked by building
`newDistillRuntime` and overriding its `runExtract`/`runScene`/`runPersona` fields
(`DistillRuntime` in `kioku-core/src/Kioku/Distill/Runtime.hs` is a record of plain
`input -> IO (Either ShikumiError output)` functions). The embedding provider has no
fake today — M1 makes the embed function injectable for the same reason.

Framework facts you must not re-derive (verified at the pins): shibuya's `AckDecision`
constructors and semantics are in `shibuya-core/src/Shibuya/Core/Ack.hs`
(`RetryDelay` wraps `NominalDiffTime`; `DeadLetterReason` = `PoisonPill` /
`InvalidPayload` / `MaxRetriesExceeded`; `HaltReason` = `HaltOrderedStream` /
`HaltFatal`). The kiroku adapter's ack coupling, retry bounding, `dead_letters` behavior,
`guardKirokuHandler`, and the envelope `attempt :: Maybe Attempt` (zero-based) are
documented in `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` and
`shibuya-core/src/Shibuya/Core/Types.hs`. keiro's timer API — `TimerRow(..)`,
`TimerWorkerOptions(..)`, `runTimerWorkerWith`, `deadLetterTimer`, `requeueStuckTimer`,
`scheduleTimerTx`, `claimDueTimer` — is in `keiro/src/Keiro/Timer.hs` and
`keiro/src/Keiro/Timer/Schema.hs`. kiroku's `StoreError` constructors are in
`kiroku-store/src/Kiroku/Store/Error.hs`. The `keiro_timers` table lives in the `kiroku`
schema at this pin (keiro's bootstrap migration pins `search_path TO kiroku`); kioku code
and tests refer to it unqualified, exactly as keiro's own statements do, so the store
connection's search_path resolves it.

Sibling-plan constraints (reference by path only; see Interfaces and Dependencies):
this plan owns the fire-outcome contract and the CLI worker-loop restructuring;
docs/plans/9-make-l1-distillation-idempotent-and-debounce-distillation-timers.md consumes
the contract; docs/plans/15-tighten-cli-and-api-surface-validation.md rebases its small
flag-parsing fix on this plan's Worker.hs changes. Do **not** rename the process-manager
names `kioku-l1-extract`, `kioku-l2-scene`, `kioku-l3-persona` — other plans and the
read-model reconciliation migration key on them.


## Plan of Work

The work is three milestones. M1 fixes the embedding worker's acknowledgment policy
(Findings 1, 2, 3, and the embedding half of 8). M2 introduces the fire-outcome taxonomy
for the distillation timer workers (Findings 4, 5, and the timer half of 8). M3 fixes
loop supervision, drain, and startup backfill in the CLI (Findings 6, 7). Each milestone
compiles, passes tests, and is observable on its own; M3 depends on M2's
`runKiokuTimerWorkerOnce` changes but M1 and M2 are independent of each other.


### Milestone 1 — Embedding worker ack policy

Scope: after this milestone, an embedding-provider failure causes the `MemoryRecorded`
event to be redelivered with backoff and, if the outage persists, dead-lettered visibly
in kiroku's `dead_letters` table (recoverable by backfill); a transient store error no
longer halts the pipeline; a corrupt payload is dead-lettered with a reason instead of
vanishing; and a vector-dimension mismatch (a permanent, systemic store error) halts the
processor with `HaltFatal`. New tests prove each decision.

First create `kioku-core/src/Kioku/Worker/Failure.hs` (add to `exposed-modules` in
`kioku-core/kioku-core.cabal`). It exports two things. `isTransientStoreError ::
StoreError -> Bool` returns `True` exactly for `PoolAcquisitionTimeout`,
`ConnectionLost _`, and `ConnectionError _`, and `False` for every other constructor —
write the match with explicit constructors (no wildcard on the transient side) so
`-Wincomplete-patterns` flags any future kiroku constructor for classification.
`embeddingRetryDelay :: Maybe Attempt -> RetryDelay` (types from `Shibuya.Core.Types` and
`Shibuya.Core.Ack`) maps the zero-based delivery attempt to the schedule 5 s, 20 s,
60 s, 180 s (attempt 0→5, 1→20, 2→60, anything else including `Nothing`→180; kiroku's
default `RetryPolicy` dead-letters on the fifth delivery, so at most four delays are ever
consumed). Both functions get Haddock comments explaining the kiroku coupling.

Then refactor `kioku-core/src/Kioku/Memory/Embedding/Worker.hs`:

Introduce an environment record so tests can fake the provider:

```haskell
data EmbeddingWorkerEnv = EmbeddingWorkerEnv
  { model :: !EmbeddingModel,
    dimensions :: !Int,
    embed :: !(Text -> IO (Either EmbedError (Vector Double)))
  }

mkEmbeddingWorkerEnv :: EmbeddingModel -> Int -> EmbeddingWorkerEnv
mkEmbeddingWorkerEnv model dims =
  EmbeddingWorkerEnv { model, dimensions = dims, embed = embedWithRetry model 3 }
```

Introduce `data EmbedOutcome = EmbedSkipped | EmbedStored | EmbedFailed !EmbedError`
(derive `Eq`, `Show`, `Generic`). Change `embedAndStore` and `embedMemoryContent` to take
`EmbeddingWorkerEnv` instead of `EmbeddingModel -> Int` and to return `Eff es
EmbedOutcome` instead of `Bool`: the `Left err` branch of the embed call becomes
`pure (EmbedFailed err)`, the not-found/skip branches become `EmbedSkipped`, the
successful upsert becomes `EmbedStored`. `backfillMissingEmbeddings` keeps its exported
signature `VectorCapability -> EmbeddingModel -> Int -> Eff es Int` (the CLI calls it),
builds the env internally with `mkEmbeddingWorkerEnv`, and counts a candidate only when
the outcome is `EmbedStored`; on `EmbedFailed` it logs one stderr line and continues to
the next candidate (a backfill pass must not abort on one bad item).

Rewrite `embeddingHandler` (new signature `VectorCapability -> EmbeddingWorkerEnv ->
Ingested es RecordedEvent -> Eff es AckDecision`) around the taxonomy. Structure:

```haskell
embeddingHandler capability env ingested =
  EffError.catchError @StoreError run \_cs storeErr ->
    if isTransientStoreError storeErr
      then do
        logWorker ("transient store error, retrying: " <> Text.pack (show storeErr))
        pure (AckRetry (embeddingRetryDelay ingested.envelope.attempt))
      else do
        logWorker ("fatal store error, halting: " <> Text.pack (show storeErr))
        pure (AckHalt (HaltFatal ("kioku embedding worker store error: " <> Text.pack (show storeErr))))
  where
    run = case decodeRecorded memoryCodec ingested.envelope.payload of
      Left codecErr -> do
        logWorker ("undecodable event, dead-lettering: " <> Text.pack (show codecErr))
        pure (AckDeadLetter (InvalidPayload (Text.pack (show codecErr))))
      Right (MemoryRecorded d) -> do
        outcome <- embedMemoryContent capability env (idText (d.memoryId :: MemoryId)) d.content
        case outcome of
          EmbedFailed err -> do
            logWorker ("embedding failed, retrying: " <> Text.pack (show err))
            pure (AckRetry (embeddingRetryDelay ingested.envelope.attempt))
          _ -> pure AckOk
      Right _ -> pure AckOk
```

`logWorker` is a private helper `liftIO . IO.hPutStrLn IO.stderr . ("kioku-memory-embedding: " <>) . Text.unpack`.
The `Right _` branch stays `AckOk` because the subscription is already filtered to
`MemoryRecorded` (`eventTypeFilter` in `embeddingAdapterConfig`); a different decodable
event type cannot occur, and acking is harmless if the filter ever widens. Delete
`processRecordedEvent` (its job is absorbed into the handler). In
`embeddingWorkerProcessor`, build the env with `mkEmbeddingWorkerEnv model dims` and wrap
the handler: `handler = guardKirokuHandler (embeddingHandler capability env)` (import
`guardKirokuHandler` from `Shibuya.Adapter.Kiroku`) — this converts any stray synchronous
exception into `AckRetry (RetryDelay 1)` instead of leaving the ack-coupled kiroku worker
blocked forever. Export `embeddingHandler`, `EmbeddingWorkerEnv (..)`,
`mkEmbeddingWorkerEnv`, and `EmbedOutcome (..)` from the module for the tests.
`runEmbeddingWorkerHost` is unchanged in this milestone.

Tests, in `kioku-core/test/Kioku/EmbeddingWorkerSpec.hs`. Add to the test-suite
`build-depends` in `kioku-core/kioku-core.cabal`: `shibuya-core`, `shibuya-kiroku-adapter`
is NOT needed, `unordered-containers >=0.2` (for `HashMap.empty` in envelopes), and
`uuid >=1.3` if event-id construction needs it. Pure tests (no database): every
`StoreError` constructor through `isTransientStoreError` (use simple values such as
`PoolAcquisitionTimeout`, `ConnectionLost "x"`, `UnexpectedServerError "22000" "dim"`),
and the `embeddingRetryDelay` schedule including `Nothing`.

Postgres-backed tests use the DistillSpec fixture pattern: `withKiokuMigratedDatabase
\connStr -> withStore (defaultConnectionSettings connStr) \st -> do tr <- noopTracer; let
env = AppEnv {store = st, tracer = tr, metrics = Nothing} ...`, then `runAppIO env` for
each step, unwrapping `Either StoreError` with a helper. To obtain a real
`RecordedEvent`, record a memory through the domain API (`Kioku.Memory.record` with a
`RecordMemoryData` — see `kioku-core/src/Kioku/Memory/Domain.hs` for the fields; give it
a fresh `MemoryId` via `Kioku.Id`, any namespace scope) and read it back with
`readStreamForward` from `Kiroku.Store.Read` (as `DistillSpec` imports) — the
`MemoryRecorded` event will be the head of the memory's stream. Build the handler input
manually:

```haskell
mkIngested :: RecordedEvent -> Maybe Word -> Ingested es RecordedEvent
mkIngested recorded attemptN =
  Ingested
    { envelope =
        Envelope
          { messageId = MessageId "test", cursor = Nothing, partition = Nothing,
            enqueuedAt = Nothing, traceContext = Nothing, headers = Nothing,
            attempt = Attempt <$> attemptN, attributes = HashMap.empty,
            payload = recorded },
      ack = AckHandle (\_ -> pure ()),
      lease = Nothing }
```

The vector-dependent cases must be gated on capability: run `detectVectorCapability`
(from `Kioku.Recall.Capability`) once in the fixture; when it is not `VectorAvailable`
(ephemeral PostgreSQL built without the pgvector extension — the embedding-columns
migration is conditional), print a skip notice and assert only the ungated cases. The
cases:

1. Provider failure → retry: env with `embed = \_ -> pure (Left (EmbedTransport "boom"))`,
   capability `VectorAvailable`, attempt `Just 0`; expect
   `AckRetry (embeddingRetryDelay (Just (Attempt 0)))` (5 s). Gated on pgvector.
2. Decode failure → dead-letter: take the real `RecordedEvent` and corrupt it,
   `recorded {payload = Aeson.String "garbage"}` (record-update); expect the result to be
   `AckDeadLetter (InvalidPayload _)` (match the constructor, not the exact text). Not
   gated (the handler dead-letters before touching the memories table).
3. Success → `AckOk` and stored embedding: env with
   `embed = \_ -> pure (Right (Vector.replicate 1536 0.1))`; expect `AckOk`, then assert
   via a small `runTransaction` select that `embedding IS NOT NULL` and `content_hash` is
   set for the memory row (query `kiroku.kioku_memories`). Gated on pgvector.
4. Dimension mismatch → halt: env with `embed = \_ -> pure (Right (Vector.replicate 8 0.1))`
   against the `vector(1536)` column; the upsert raises a Postgres error that kiroku maps
   to `UnexpectedServerError`, which is permanent; expect `AckHalt (HaltFatal _)`. Gated
   on pgvector. (This is also the direct regression test for Finding 2's requirement that
   halt is *reserved* for genuinely unrecoverable states.)

Acceptance: `cabal build kioku-core` warning-clean; `cabal test kioku-core:test:kioku-test`
passes with the new cases listed in the tasty output.


### Milestone 2 — Fire-outcome taxonomy for distillation timers

Scope: after this milestone, every distillation timer fire reports one of four explicit
outcomes; transient errors reschedule the timer with exponential backoff; permanent
errors dead-letter it with a visible reason; retries are bounded at 8 claims by keiro's
attempt ceiling (then a `dead` row with `last_error`); and unknown-PM timers stop
starving the queue. New tests prove the state transitions against a real database.

Create `kioku-core/src/Kioku/Distill/Timer/Outcome.hs` (add to `exposed-modules`):

```haskell
module Kioku.Distill.Timer.Outcome
  ( FireOutcome (..),
    fireRetryDelay,
    unknownTimerRetryDelay,
    timerMarkerEventId,
  )
where

data FireOutcome
  = FireCompleted !EventId
  | FireRetryLater !NominalDiffTime !Text
  | FireFailedPermanently !Text
  | FireNotMine
  deriving stock (Generic, Eq, Show)

-- | Exponential backoff by post-claim attempt count: 30s * 2^(n-1), capped at 900s.
fireRetryDelay :: Int -> NominalDiffTime

-- | Requeue delay for timers no handler owns (rolling-deploy grace).
unknownTimerRetryDelay :: NominalDiffTime
unknownTimerRetryDelay = 600

timerMarkerEventId :: TimerId -> EventId
timerMarkerEventId (TimerId uuid) = EventId uuid
```

`FireCompleted eid` means "mark the timer fired with this event id". Distillation timers
do not append a dedicated domain event today, so the existing marker convention (the
timer's own UUID as the event id) is preserved via `timerMarkerEventId`, moved here from
its three duplicated private definitions (delete the copies in `Timer/Worker.hs`, `L2.hs`,
`L3.hs`). `FireRetryLater delay note` means "transient failure: reschedule me `delay`
from now; log `note`". `FireFailedPermanently reason` means "dead-letter me with
`reason`". `FireNotMine` means "this timer's `process_manager_name` is not mine; I did
not touch it".

Convert the three fire handlers to `TimerRow -> Eff es FireOutcome` (same effect
constraints as today):

- `fireL1Timer` in `kioku-core/src/Kioku/Distill/Timer/Worker.hs`: PM mismatch →
  `FireNotMine`. Unparseable correlation id → `FireFailedPermanently ("L1 timer
  correlation id is not a session id: " <> row.correlationId)` (today this is silently
  marked fired). `distillSessionL1` `Right _` and `Left (L1SessionNotFound _)` →
  `FireCompleted (timerMarkerEventId row.timerId)` (unchanged semantics; see Decision
  Log). Any other `Left err` → `FireRetryLater (fireRetryDelay row.attempts) (Text.pack
  (show err))` — this covers `L1ExtractionFailed` (the LLM call), the read-model errors,
  and `L1MemoryWriteFailed`; all are bounded by the attempt ceiling, so a structurally
  failing extraction ends as a `dead` row after 8 claims instead of burning LLM cost
  forever.
- `fireL2SceneTimer` in `kioku-core/src/Kioku/Distill/L2.hs`: PM mismatch →
  `FireNotMine`; `Aeson.Error` on the payload → `FireFailedPermanently` naming the error
  (today: silent mark-fired); `regenerateScene` `Right _` → `FireCompleted`; `Left err`
  → `FireRetryLater (fireRetryDelay row.attempts) ...`.
- `fireL3PersonaTimer` in `kioku-core/src/Kioku/Distill/L3.hs`: identical shape.

`fireKiokuTimer` chains them: if L1 says `FireNotMine`, try L2; then L3; the final
`FireNotMine` is returned as-is (the runner decides unknown-PM policy).

In `Timer/Worker.hs`, add the runner-side mapping:

```haskell
kiokuTimerWorkerOptions :: TimerWorkerOptions
kiokuTimerWorkerOptions =
  TimerWorkerOptions { maxAttempts = Just 8, requeueStuckAfter = Just 300 }

applyFireOutcome ::
  (IOE :> es, Store :> es) => TimerRow -> FireOutcome -> Eff es (Maybe EventId)
applyFireOutcome row = \case
  FireCompleted eid -> pure (Just eid)
  FireRetryLater delay note -> do
    logTimer row ("retrying in " <> ... <> ": " <> note)
    rescheduleClaimedTimer row delay
    pure Nothing
  FireFailedPermanently reason -> do
    logTimer row ("dead-lettering: " <> reason)
    void (deadLetterTimer row.timerId reason)
    pure Nothing
  FireNotMine -> do
    logTimer row "no handler for this process manager; requeueing"
    rescheduleClaimedTimer row unknownTimerRetryDelay
    pure Nothing
```

`rescheduleClaimedTimer` is the two-step from the Decision Log: `requeued <-
requeueStuckTimer row.timerId; when requeued do now <- liftIO getCurrentTime;
runTransaction (scheduleTimerTx TimerRequest { timerId = row.timerId,
processManagerName = row.processManagerName, correlationId = row.correlationId, fireAt =
addUTCTime delay now, payload = row.payload })`. Returning `Nothing` to keiro means keiro
performs no further update on the row (verified: `runTimerWorkerWith` only calls
`markTimerFired` on `Just`). `logTimer` writes one stderr line including the timer id, PM
name, and attempt count. Rewire `runKiokuTimerWorkerOnce` (keep its exported signature,
`Maybe KeiroMetrics -> DistillRuntime -> FindMergeCandidates es -> UTCTime -> Eff es
(Maybe TimerRow)`) as `runTimerWorkerWith metrics kiokuTimerWorkerOptions now (\row ->
fireKiokuTimer rt finder row >>= applyFireOutcome row)`. keiro's ceiling check runs at
claim time: when a claimed timer's post-claim `attempts` exceeds 8, keiro dead-letters it
with "timer exceeded attempt ceiling of 8" before the fire action runs. Delete
`runL1TimerWorkerLoop` and `runL1TimerWorkerOnce` (no callers; Finding-5 foot-gun) and
`fireL1Timer` stays (used by `fireKiokuTimer`; also exported for plan 9). Keep
`runKiokuTimerWorkerLoop` compiling for now (M3 replaces its body with the drain loop).

Tests: new module `kioku-core/test/Kioku/TimerWorkerSpec.hs` (add to `other-modules` in
the cabal test suite, import it in `kioku-core/test/Main.hs`'s test group; add `keiro`
and `aeson` — already present — to the test-suite `build-depends`, plus `keiro` which is
currently missing there). Use the `withKiokuMigratedDatabase`/`withStore`/`runAppIO`
fixture. Helpers: `scheduleTestTimer` inserts via `runTransaction (scheduleTimerTx ...)`
with a chosen PM name, correlation id, payload, and a past `fireAt`;
`fetchTimer` reads `SELECT status, attempts, fire_at, last_error FROM keiro_timers WHERE
timer_id = $1` via a small hasql statement (unqualified table name, same search_path as
keiro itself). A fake runtime comes from `newDistillRuntime` with overridden fields
(DistillSpec pattern); `scopedScanCandidates 5` (from `Kioku.Distill.L1`) is the finder,
as in the CLI. The cases:

1. Permanent failure dead-letters: schedule a timer with PM `kioku-l1-extract` and
   correlation id `"not-a-session-id"`; run `runKiokuTimerWorkerOnce`; assert it returned
   `Just` a row and the row is now `status = 'dead'` with `last_error` containing
   "correlation id".
2. Transient failure reschedules with backoff: schedule an L1 timer whose correlation id
   is a real session (create one with `Session.start` as `DistillSpec` does) and whose
   runtime has `runExtract = \_ -> pure (Left <some ShikumiError>)` (construct any
   constructor of `ShikumiError` — check `Shikumi.Error` for a simple one, or reuse the
   error produced by `replayProgram` machinery; the specific value is irrelevant, only
   `Left`). Run once; assert `status = 'scheduled'`, `attempts = 1`, and `fire_at` is
   between now+25 s and now+35 s (the attempt-1 delay is 30 s).
3. Unknown PM requeues with the long delay: schedule a timer with PM `"kioku-nonexistent"`;
   run once; assert `status = 'scheduled'`, `attempts = 1`, `fire_at ≈ now + 600 s`.
4. Attempt ceiling dead-letters: schedule the unknown-PM timer, then
   `UPDATE keiro_timers SET attempts = 8, fire_at = now() - interval '1 second' WHERE
   timer_id = $1` via `runTransaction`; run once; assert `status = 'dead'` and
   `last_error` mentions "attempt ceiling".
5. Success marks fired: schedule an L2 timer (PM `kioku-l2-scene`, payload
   `Aeson.toJSON` of a scope with no memories — `regenerateScene` returns
   `Right Nothing` without calling the LLM); run once; assert `status = 'fired'` and
   `fired_event_id` equals the timer's own UUID (the marker convention).

Acceptance: build warning-clean; the new spec passes; `grep -rn "runL1TimerWorkerLoop"`
finds nothing outside docs.


### Milestone 3 — Loop supervision, drain, and startup backfill

Scope: after this milestone, the timer loop drains all due timers before sleeping; each
pass runs in its own error scope so a transient store error is logged and retried with
capped backoff instead of killing the loop; the timer loop and embedding host run under
`Control.Concurrent.Async.race` so the death of either is loud and terminal (exit code
1); and the continuous worker runs one embedding backfill pass at startup so embeddings
dead-lettered during an outage self-heal on restart.

In `kioku-core/src/Kioku/Distill/Timer/Worker.hs`, add and export

```haskell
-- | Claim and fire due timers until none remain, returning how many were processed.
drainKiokuTimers ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  Maybe KeiroMetrics -> DistillRuntime -> FindMergeCandidates es -> Eff es Int
```

implemented as a loop: `now <- liftIO getCurrentTime; res <- runKiokuTimerWorkerOnce
metrics rt finder now; case res of Nothing -> pure n; Just _ -> go (n + 1)` — recomputing
`now` on every iteration. This cannot spin on a failing timer: every non-`FireCompleted`
outcome moves the row's `fire_at` at least 30 s into the future or into a terminal
status, so it is not claimable again within the same drain. Delete
`runKiokuTimerWorkerLoop` (the CLI owns the loop now; keeping a second loop in core with
different supervision semantics invites drift).

Rewrite `kioku-cli/src/Kioku/Cli/Commands/Worker.hs` (add `async >=2.2` to the library
`build-depends` in `kioku-cli/kioku-cli.cabal`). Keep `WorkerOptions`,
`workerOptionsParser`, `runWorker`'s env setup, `runBackfill`, and `runTimerOnce`
(rewire its import: `runKiokuTimerWorkerOnce` still exists with the same signature) —
docs/plans/15-tighten-cli-and-api-surface-validation.md patches the parser in this file
and rebases on this milestone, so avoid gratuitous churn there. Replace
`runContinuousWorker` and `runTimerLoop`:

```haskell
runContinuousWorker :: AppEnv -> KirokuStore -> VectorCapability -> EmbeddingConfig -> IO ()
runContinuousWorker env store capability config = do
  let model = toEmbeddingModel config
  case capability of
    VectorAvailable -> do
      startupBackfill env capability model config
      outcome <-
        race
          (runTimerLoop env)
          (runAppIO env (runEmbeddingWorkerHost store capability model config.dimensions))
      case outcome of
        Left () ->
          dieWorker "timer loop stopped unexpectedly"
        Right (Left storeErr) ->
          dieWorker ("embedding worker stopped with store error: " <> show storeErr)
        Right (Right ()) ->
          dieWorker "embedding worker stopped (processor halted or subscription ended)"
    VectorExtensionUnavailable -> do ... -- unchanged message; then runTimerLoop env
    VectorColumnsUnavailable missing -> do ... -- unchanged message; then runTimerLoop env
```

`dieWorker msg = hPutStrLn stderr ("kioku worker: " <> msg <> "; exiting") >> exitWith
(ExitFailure 1)` (import `System.Exit`). `race` (from `Control.Concurrent.Async`) also
rethrows any exception from either side, so an unexpected crash is equally loud and
non-zero. `startupBackfill` runs `runAppIO env (backfillMissingEmbeddings capability
model config.dimensions)` once, printing the count on success and a stderr warning
(without dying) on `Left` — a down database at startup should surface through the loops'
own retry/exit behavior, not a special case. Note the halt reason itself is printed by
the embedding handler at decision time (M1's `logWorker`), so the operator sees *why*
before the process exits.

The supervised timer loop, with per-pass error scope and capped backoff:

```haskell
runTimerLoop :: AppEnv -> IO ()
runTimerLoop env = do
  rt <- newDistillRuntime
  putStrLn "kioku timer worker started."
  let go failures = do
        result <- runAppIO env (drainKiokuTimers Nothing rt (scopedScanCandidates 5))
        case result of
          Left storeErr -> do
            hPutStrLn stderr ("kioku timer worker: store error (will retry): " <> show storeErr)
            threadDelay (storeErrorBackoffMicros failures)
            go (failures + 1)
          Right _ -> do
            threadDelay defaultTimerPollMicros
            go 0
  go 0

storeErrorBackoffMicros :: Int -> Int  -- 5s * 2^failures, capped at 60s
```

This loop never returns normally (so `race`'s `Left ()` genuinely means "impossible
stopped"), retries store errors forever (a long database outage should not require
operator intervention beyond fixing the database), resets backoff on success, and lets
non-`StoreError` exceptions propagate to `race`. `defaultTimerPollMicros` stays 5 s —
with draining, the poll interval no longer caps throughput (Finding 7).

Tests: add a drain test to `TimerWorkerSpec`: schedule three due timers with PM
`kioku-l1-extract` and invalid correlation ids; call `drainKiokuTimers` once; assert it
returns 3 and all three rows are `dead` — proving multiple timers are processed in one
pass without sleeping. Supervision itself is IO-process behavior; verify it manually per
Validation and Acceptance.

Acceptance: build warning-clean; full test suite passes; the manual CLI checks below
behave as described.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kioku` inside
the project's dev environment (the same shell you normally build in; ephemeral-pg needs
PostgreSQL binaries on PATH, which the dev shell provides).

Build and test after each milestone:

```bash
cabal build all
cabal test kioku-core:test:kioku-test --test-show-details=direct
```

Expected test output shape (counts grow per milestone; all green):

```text
Kioku
  Embedding worker
    skips only when the embedding exists and the content hash matches: OK
    classifies transient store errors:                                 OK
    retry delay schedule:                                              OK
    provider failure acks retry:                                       OK
    undecodable payload acks dead-letter:                              OK
    ...
  Timer worker
    permanent failure dead-letters the timer:                          OK
    transient failure reschedules with backoff:                        OK
    unknown process manager requeues with long delay:                  OK
    attempt ceiling dead-letters:                                      OK
    drain processes all due timers in one pass:                        OK
All N tests passed
```

If pgvector is absent from the ephemeral PostgreSQL, the gated embedding cases print a
skip notice instead of failing; run them in an environment with pgvector for full
coverage.

Manual verification of M3 against a real database (needs `PG_CONNECTION_STRING` pointing
at a migrated database; the embedding provider needs `KIOKU_EMBEDDING_API_KEY` or
`OPENAI_API_KEY`, and the distill runtime an Anthropic key — for a supervision smoke test
fake keys are fine, failures are the point):

```bash
PG_CONNECTION_STRING="postgres://..." cabal run kioku-cli:exe:kioku -- worker --timers-once
```

```text
No due kioku distillation timers.
```

```bash
PG_CONNECTION_STRING="postgres://..." cabal run kioku-cli:exe:kioku -- worker
```

```text
Startup backfill: embedded 0 missing memory embeddings.
kioku timer worker started.
kioku embedding worker started. Press Ctrl+C to stop.
```

(The two "started" lines may appear in either order.) To watch supervision: stop the
database while the worker runs — the timer loop prints
`kioku timer worker: store error (will retry): ...` lines with growing gaps (5 s → 60 s
cap) and resumes silently when the database returns; kill the embedding pipeline (e.g.
revoke table permissions to force a fatal store error) — the process prints the halt
reason, then `kioku worker: embedding worker stopped ...; exiting`, and `echo $?` shows
`1`. Dead-lettered items are visible with SQL:

```sql
SELECT reason FROM kiroku.dead_letters ORDER BY dead_lettered_at DESC LIMIT 5;
SELECT process_manager_name, attempts, last_error FROM kiroku.keiro_timers WHERE status = 'dead';
```

(Column names in `dead_letters` may differ slightly; `\d kiroku.dead_letters` in psql
shows the shape. Adjust the transcript in this plan if so — and record it in Surprises.)

Commit at each milestone boundary with conventional-commit messages, e.g.
`feat(worker): classify embedding failures into retry/dead-letter/halt ack decisions`,
`feat(distill): replace timer fire Maybe EventId with FireOutcome taxonomy`,
`feat(cli): supervise worker loops with race, drain, and startup backfill`.


## Validation and Acceptance

Behavioral acceptance, per finding:

- Finding 1: with a fake provider returning `Left`, `embeddingHandler` returns
  `AckRetry` (test 1 in M1); after kiroku's five deliveries the event appears in
  `kiroku.dead_letters` rather than being silently acked (upstream-bounded; asserted at
  the unit level via the decision, and end-to-end by the dead-letter SQL query above).
  A worker restart backfills the missing embedding (startup backfill line in the CLI
  transcript).
- Finding 2: `isTransientStoreError` unit tests plus M1 test 4 — a transient store error
  yields `AckRetry` (pipeline survives), and only a permanent error (dimension mismatch)
  yields `AckHalt (HaltFatal ...)`.
- Finding 3: M1 test 2 — corrupt payload yields `AckDeadLetter (InvalidPayload ...)` and
  a stderr line, never a silent `AckOk`.
- Finding 4: M2 tests 1, 2, 4 — errors are split into retry-with-backoff (bounded at 8
  claims) versus immediate dead-letter, each ending in an observable `keiro_timers` state
  (`scheduled` with pushed-back `fire_at`, or `dead` with `last_error`).
- Finding 5: M2 tests 3, 4 — an unknown-PM timer no longer cycles forever: it requeues
  600 s out (other due timers get claimed meanwhile, ending the starvation) and dies
  visibly at the ceiling.
- Finding 6: manual CLI checks — store-error retry lines with capped backoff; process
  exits 1 with a reason when a pipeline stops; no bare `forkIO` remains in
  `kioku-cli/src/Kioku/Cli/Commands/Worker.hs` (`grep -n forkIO` returns nothing).
- Finding 7: M3 drain test — three due timers processed in a single `drainKiokuTimers`
  call, no sleep between them.
- Finding 8: the test suite grows from one embedding-worker case to the full ack/outcome
  matrix; `cabal test kioku-core:test:kioku-test` is the single command that proves it.

The change is demonstrably more than compilation: every test above fails against the
pre-plan code (the old handler returns `AckOk`/`AckHalt` where the new tests expect
retry/dead-letter; the old fire functions leave timers `firing` where the new tests
expect `scheduled`-with-backoff or `dead`).


## Idempotence and Recovery

All edits are ordinary source changes on a git branch; re-running any milestone's steps
is safe. The test fixture creates a fresh ephemeral database per run (cached binaries,
fresh cluster), so tests are repeatable. `backfillMissingEmbeddings` is idempotent by
construction (`shouldSkipEmbedding` skips rows whose embedding exists with a matching
content hash), so the startup backfill can run on every start. Timer fires remain
governed by keiro's documented at-least-once contract: `rescheduleClaimedTimer`'s benign
race can at worst cause one extra fire attempt, which the (existing and plan-9-improved)
idempotency of the distillation handlers absorbs. No SQL migration is added by this plan,
so there is nothing to roll back in the database; reverting the commits restores the old
behavior completely. If a milestone is interrupted mid-edit, `cabal build all` pinpoints
the incomplete signatures (the `FireOutcome` conversion is deliberately type-driven: the
compiler lists every caller that still expects `Maybe EventId`).


## Interfaces and Dependencies

Libraries used (all already pinned in `cabal.project`; local sources discoverable via
`mori registry show shinzui/{shibuya,keiro,kiroku} --full`):

- `shibuya-core` (pin `3f276ee190e563fddb0bc81e01d62a96a1b31715`): `Shibuya.Core.Ack`
  (`AckDecision (..)`, `RetryDelay (..)`, `DeadLetterReason (..)`, `HaltReason (..)`),
  `Shibuya.Core.Types` (`Envelope (..)`, `Attempt (..)`), `Shibuya.Core.Ingested`.
- `shibuya-kiroku-adapter` (kiroku pin `4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a`):
  `guardKirokuHandler`, ack-coupled retry/dead-letter mechanics, default `RetryPolicy`
  of 5 total deliveries.
- `keiro` (pin `f1d67a01b7457387a4861e7268d1c521ef82287d`): `Keiro.Timer`
  (`TimerRow (..)`, `TimerRequest (..)`, `TimerWorkerOptions (..)`, `runTimerWorkerWith`,
  `deadLetterTimer`, `requeueStuckTimer`, `scheduleTimerTx`).
- `kiroku-store` (same kiroku pin): `Kiroku.Store.Error (StoreError (..))`.
- `async >=2.2` — **new dependency of `kioku-cli`** (`Control.Concurrent.Async.race`).
- Test suite of `kioku-core` gains `build-depends`: `shibuya-core`, `keiro`,
  `unordered-containers >=0.2`, `uuid >=1.3`.

Module-level interface at completion:

- `Kioku.Worker.Failure` (new, kioku-core): `isTransientStoreError :: StoreError -> Bool`;
  `embeddingRetryDelay :: Maybe Attempt -> RetryDelay`.
- `Kioku.Memory.Embedding.Worker`: exports gain `embeddingHandler :: VectorCapability ->
  EmbeddingWorkerEnv -> Ingested es RecordedEvent -> Eff es AckDecision`,
  `EmbeddingWorkerEnv (..)`, `mkEmbeddingWorkerEnv :: EmbeddingModel -> Int ->
  EmbeddingWorkerEnv`, `EmbedOutcome (..)`. `embeddingWorkerProcessor`,
  `runEmbeddingWorkerHost`, `backfillMissingEmbeddings`, `shouldSkipEmbedding` keep their
  existing signatures.
- `Kioku.Distill.Timer.Outcome` (new, kioku-core): `FireOutcome (..)`,
  `fireRetryDelay :: Int -> NominalDiffTime`, `unknownTimerRetryDelay ::
  NominalDiffTime`, `timerMarkerEventId :: TimerId -> EventId`.
- `Kioku.Distill.Timer.Worker`: `fireL1Timer`, `fireKiokuTimer :: ... -> TimerRow -> Eff
  es FireOutcome`; `applyFireOutcome :: TimerRow -> FireOutcome -> Eff es (Maybe
  EventId)`; `kiokuTimerWorkerOptions :: TimerWorkerOptions`; `runKiokuTimerWorkerOnce`
  (signature unchanged); `drainKiokuTimers :: Maybe KeiroMetrics -> DistillRuntime ->
  FindMergeCandidates es -> Eff es Int`. Removed: `runL1TimerWorkerLoop`,
  `runL1TimerWorkerOnce`, `runKiokuTimerWorkerLoop`.
- `Kioku.Distill.L2.fireL2SceneTimer` / `Kioku.Distill.L3.fireL3PersonaTimer`:
  `DistillRuntime -> TimerRow -> Eff es FireOutcome`.

Cross-plan contracts (reference by path; do not read state from those plans into this
one):

- **Fire-outcome contract (owned here).**
  docs/plans/9-make-l1-distillation-idempotent-and-debounce-distillation-timers.md
  consumes `FireOutcome`: its reworked handlers classify LLM extraction/consolidation
  errors into these constructors. The taxonomy is deliberately migration-mechanical: if
  plan 9 lands first with `Maybe EventId` handlers, this plan converts them by mapping
  `Just eid → FireCompleted eid` and choosing `FireRetryLater`/`FireFailedPermanently`
  per error branch; nothing in plan 9's idempotency work depends on which lands first.
- **Process-manager names are frozen**: `kioku-l1-extract`, `kioku-l2-scene`,
  `kioku-l3-persona` must not be renamed (plan 9, plan 10, and the read-model
  reconciliation migration key on them).
- **`kioku-cli/src/Kioku/Cli/Commands/Worker.hs` restructuring is owned here.**
  docs/plans/15-tighten-cli-and-api-surface-validation.md makes a small flag-parsing fix
  in the same file and rebases on this plan; keep `WorkerOptions`/`workerOptionsParser`
  untouched to minimize its rebase. Plan 9 swaps the candidate-lookup wiring
  (`scopedScanCandidates 5`) passed to the timer worker; this plan keeps that call
  exactly as-is.
- **Optional dependency-repo improvements (explicitly NOT required by this plan):**
  keiro: `rescheduleFiringTimer :: TimerId -> UTCTime -> Text -> Eff es Bool` (one-UPDATE
  reschedule that can also record the retry note in `last_error`), and a PM-name filter
  on `claimDueTimer`. kiroku: expose `retryPolicy` through `KirokuAdapterConfig`. Each
  has a kioku-side mitigation implemented here (two-step reschedule; requeue-plus-ceiling
  for unknown PMs; the default 5-delivery policy plus startup backfill).
