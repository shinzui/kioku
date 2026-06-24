---
id: 3
slug: kioku-distillation-pyramid-l0-to-l3
title: "kioku Distillation Pyramid (L0 to L3)"
kind: exec-plan
created_at: 2026-06-24T16:31:00Z
intention: "intention_01kvx5py1yeanvyn7xh58epfnt"
master_plan: "docs/masterplans/1-kioku-reusable-agent-memory-session-library.md"
---

# kioku Distillation Pyramid (L0 to L3)

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

**kioku** (記憶, "memory") is a standalone Haskell library at `/Users/shinzui/Keikaku/bokuno/kioku`
that gives an AI agent a durable, event-sourced memory. Today (after the two prior plans, EP-1 and
EP-2) an agent can *record* a memory and *recall* memories by hybrid search. But the agent must
record every memory by hand, and nothing ever *summarizes* or *deduplicates* what it has learned.
Over weeks, the memory becomes a flat pile of near-duplicate facts with no higher-level structure.

This plan builds the **distillation pyramid**: an automatic pipeline that reads the raw record of an
agent's work (its conversation turns and recorded memories) and progressively distills it into
higher-level knowledge. The pyramid has four layers, named after the model in the TencentDB "Agent
Memory" paper but re-implemented here on top of event sourcing:

- **L0 — evidence.** The raw, immutable floor: the session-stream events, optional `TurnRecorded`
  events (one per conversation turn, opt-in), and explicitly-recorded memories. This already exists
  from EP-1; L0 is *consumed*, not built. It is the ground truth nothing is allowed to overwrite.
- **L1 — atoms.** Small, structured memory records (a fact, a preference, a constraint, …). This
  plan adds an **LLM extraction** step that reads recent L0 (a session's turns or a window of raw
  text) and proposes candidate atoms, then a **consolidation** step that decides, for each candidate,
  whether to **store** it as new, **update** an existing atom, **merge** several atoms into one, or
  **skip** it as a duplicate. Every decision is recorded as an *event* (so the history is auditable
  and replayable), and the resulting atoms land in the `kioku_memories` table EP-1 already owns.
- **L2 — scenes.** Markdown "scene blocks" that group related atoms (by scope and similarity/time)
  into a readable narrative — e.g. "Testing & CI practices for intention int_abc". This plan adds an
  async projection that writes scenes into a new `kioku_scenes` table and mirrors them to the
  filesystem.
- **L3 — persona.** A single distilled profile per scope — "who this agent is working with / what it
  has learned overall" — regenerated after scenes change. This plan adds a `kioku_personas` table and
  a `persona.md` filesystem mirror.

After this plan, a person who has never seen the codebase can feed kioku a multi-turn agent session,
run one command, and watch the pyramid build itself: atoms are extracted from the conversation, a
**duplicate atom is merged rather than re-stored** (visible in the event stream), a scene block is
written to `kioku_scenes` and to a markdown file, and a `persona.md` is produced — all of it
inspectable through new CLI commands (`kioku persona --scope …`, `kioku scenes --scope …`) and through
the underlying events. The headline observable proof is: a second, paraphrased copy of an existing
memory does **not** create a second row; instead a `MemoryMerged` event is appended to the loser
stream and `kioku_memories` still shows one active atom.

The LLM work is done with **shikumi** typed programs over **baikai-claude** (never hand-rolled
Anthropic HTTP calls). A shikumi *program* is a typed value `Program input output` whose output is a
Haskell record that derives a strict JSON schema; the model is forced to answer in exactly that
shape, which is what makes the pipeline testable. For deterministic tests we use shikumi's offline
trace-replay (`Shikumi.Trace.Replay.runLLMReplay`) so a recorded LLM answer can be replayed without
the network.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone M0 — wiring shikumi/baikai into kioku (prerequisite for everything):

- [x] Add `shikumi`, `shikumi-trace`, `baikai`, `baikai-claude`, `baikai-effectful` to
      `/Users/shinzui/Keikaku/bokuno/kioku/cabal.project` (local-path `packages:` entries for shikumi,
      Hackage for baikai; add the `blake3` / `postgresql-libpq` workaround stanzas needed by
      `shikumi-trace`). Completed 2026-06-24 with local `../shikumi/shikumi` and
      `../shikumi/shikumi-trace`, plus the existing Baikai source pin expanded to include
      `baikai-claude` and `baikai-effectful`.
- [x] Add `shikumi`, `shikumi-trace`, `baikai`, `baikai-claude`, `baikai-effectful` to
      `kioku-core/kioku-core.cabal` `build-depends`. Completed 2026-06-24.
- [x] Add `Kioku.Distill.Runtime` (the `ClaudeApi.register` + `runProgramWith` interpreter chain) and
      prove it compiles with a trivial program; `cabal build kioku-core` is green. Completed
      2026-06-24: `Kioku.Distill.Runtime` mirrors Handan's live routing/resilience chain and exposes
      `runtimeSmokeProgram`; `cabal build kioku-core` passed.

Milestone M1 — L1 extraction + LLM consolidation, recorded as events:

- [x] Add migration `<ts>-kioku-distillation.sql`: `kioku_scenes`, `kioku_personas`, and
      `kioku_consolidation_decisions` (audit) tables in the `kiroku` schema. Completed
      2026-06-24 as `2026-06-24-02-00-00-kioku-distillation.sql`.
- [x] Reserve/confirm the EP-1 `MemoryMerged` event; add the `MergeMemory` command + transducer edge
      (`Active → Merged`) and the `Kioku.Memory.merge` write API (records `MemoryMerged` on the
      losers), since EP-1 reserved the event but added no edge. Completed 2026-06-24: the public
      `Kioku.Memory.merge loser winner` API appends `MemoryMerged` on the loser stream and the
      existing read model marks the loser `status='merged'` / `superseded_by=winner`.
- [x] Add the extraction shikumi program `Kioku.Distill.Extract` (`Program ExtractInput ExtractOutput`)
      and the consolidation shikumi program `Kioku.Distill.Consolidate`
      (`Program ConsolidateInput ConsolidationDecision`). Completed 2026-06-24: both modules are
      exposed by `kioku-core`, use shikumi strict-schema records, and `cabal build kioku-core` passed.
- [x] Add `Kioku.Distill.L1` orchestration: read recent L0 for a session, run extraction, for each
      candidate run consolidation (candidate lookup via `Kioku.Recall` if present, else scoped scan),
      apply the decision via `Kioku.Memory` (record / merge / no-op), and write a
      `kioku_consolidation_decisions` audit row. Completed 2026-06-24: `distillSessionL1` composes
      `extractProgram` + `consolidateProgram`, exposes `recallCandidates` and `scopedScanCandidates`,
      writes through `Kioku.Memory`, and inserts audit rows.
- [x] Add the timer arming (inline projection `l1TimerScheduleProjection` on the session write path)
      + the `kioku-l1-extract` timer dispatcher (turn-count threshold with warm-up ramp + idle-timeout
      flush), modeled on Rei's `FireTimer.hs` / `DormancyTimer.hs`. Completed 2026-06-24:
      `Kioku.Distill.Timer` arms ramp/idle/final keiro timers; `Kioku.Distill.Timer.Worker` exposes
      `fireL1Timer`/`runL1TimerWorkerOnce`; `kioku worker --timers-once` claims at most one due L1 timer.
- [x] Integrate a continuous L1 timer loop into the default `kioku worker` host. Completed
      2026-06-24: plain `kioku worker` starts the L1 timer loop alongside the embedding worker when
      pgvector is available, or runs the L1 timer loop as the foreground worker when pgvector is
      unavailable; `--timers-once` remains available for one-pass operation.
- [x] Add `kioku distill session <session-id>` CLI to force an L1 pass. Completed 2026-06-24:
      `kioku distill session SESSION_ID [--candidates scan|recall] [--limit N]` builds a
      `DistillRuntime`, selects the scoped-scan or recall candidate finder, runs `distillSessionL1`,
      and prints the `L1Summary`. M1 acceptance still needs the sample transcript.
- [ ] M1 sample transcript acceptance: local migrated DB and `kioku demo-session` work, but the
      live L1 extraction proof is blocked in this environment until `ANTHROPIC_API_KEY` is set.
      Attempted 2026-06-24 with `kioku_session_01kvxf8y37eeptytbt18jc8b35`; after surfacing
      extraction errors, `kioku distill session ... --candidates scan --limit 5` reports
      `L1ExtractionFailed "ProviderFailure \"env var ANTHROPIC_API_KEY is not set\""`.

Milestone M2 — L2 scene generation:

- [x] Add the scene shikumi program `Kioku.Distill.Scene` (`Program SceneInput SceneOutput`,
      output a Markdown scene block). Completed 2026-06-24: the module is exposed by `kioku-core`,
      defines strict-schema `SceneInput`/`SceneOutput`, and compiles as a pure shikumi `sceneProgram`.
- [x] Add the L2 scene regeneration core and memory-write timer arming. Completed 2026-06-24:
      `Kioku.Distill.L2.regenerateScene` loads active atoms for a scope, skips unchanged inputs via
      `source_hash`, runs `sceneProgram`, and upserts the `kioku_scenes` default scene; memory
      `MemoryRecorded` writes now arm `kioku-l2-scene` timers.
- [ ] Add the L2 async reactor `Kioku.Distill.L2.sceneReactor`: a downward-only timer (or
      `AsyncWorkerSpec`) that, when atoms in a scope change, groups them and regenerates the scene,
      upserting `kioku_scenes`; plus a side-effect leg mirroring the scene to
      `<workspace>/.kioku/scenes/<scope>.md`. Partial 2026-06-24: `kioku worker` now routes both L1
      extract timers and L2 scene timers through the shared distillation timer worker. Remaining: add
      the filesystem mirror and expose the `kioku scenes --scope ...` read path.
- [ ] M2 acceptance: after the M1 pass, `kioku scenes --scope …` prints a scene block and the markdown
      file exists.

Milestone M3 — L3 persona generation:

- [ ] Add the persona shikumi program `Kioku.Distill.Persona` (`Program PersonaInput PersonaOutput`).
- [ ] Add the L3 reactor `Kioku.Distill.L3.personaReactor`: a threshold/mutex-gated regeneration that,
      after L2 scenes for a scope update, regenerates the single per-scope persona, upserts
      `kioku_personas`, and mirrors `persona.md`.
- [ ] M3 acceptance: `kioku persona --scope …` prints the persona and `<workspace>/.kioku/persona/<scope>.md`
      exists.

Milestone M4 — deterministic end-to-end test:

- [ ] Add `kioku-core/test/Kioku/DistillSpec.hs`: feed a fixed multi-turn session, replay recorded
      LLM answers via `Shikumi.Trace.Replay.runLLMReplay`, and assert atoms extracted, one merge (not
      a duplicate), a scene row, and a persona row — all from the events. `cabal test kioku-core`
      passes.

(M0 is complete; M1 is in progress.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The plan sketch was stale relative to Handan's current runtime.** Handan's live
  `Handan.Runtime` uses `runConcurrent . runRouting model . runLLMResilient cfg . routeLLM` for
  normal execution, and trace execution adds `runPrim . runTime . runTrace . tracedLLM`. EP-3 M0
  copied the normal live chain, not the older sketch.

- **Baikai is pinned as a source package, not resolved from Hackage here.** EP-2 had already pinned
  `baikai`; M0 expanded that source-repository-package to include `baikai-claude` and
  `baikai-effectful` at the same tag.

- **`MemoryMerged` is the merge event; no extra `MemorySuperseded` event is appended.** EP-1's
  read-model projection already handles `MemoryMerged` by setting `status='merged'` and
  `superseded_by=mergedInto`. Since `Merged` is terminal, appending a later `MemorySuperseded` on the
  same loser stream would fight the aggregate state machine. The public `merge` writer therefore
  emits the reserved `MemoryMerged` event only.

- **Keiro timer handlers must return an `EventId` marker for handled timers.** `runTimerWorker` only
  marks a claimed row `fired` when the fire action returns `Just eventId`; `Nothing` means "not handled"
  and leaves the row `firing` until stale recovery requeues it. The L1 timer fire action therefore
  returns a deterministic marker derived from the `TimerId` after successful/no-op handling.

- **Extraction failures must not look like successful empty extraction.** A local sample run without
  `ANTHROPIC_API_KEY` originally returned `extracted=0 stored=0 merged=0 skipped=0`, which would hide
  live-provider failures from operators and from M1 acceptance. `distillSessionL1` now returns
  `L1ExtractionFailed ...` when the extraction program fails, while consolidation failures still fall
  back to storing the already-extracted atom conservatively.

- **L2 timer ids cannot be one permanent id per scope.** `scheduleTimerTx` only re-arms a row while it
  is still `scheduled`; once a row is `fired`, reusing the same timer id will not resurrect it. The L2
  arming projection therefore uses deterministic source-scoped timer ids (`scope + memory id`) and
  relies on the `kioku_scenes.source_hash` guard to make repeated scene regeneration idempotent.


## Decision Log

Record every decision made while working on the plan. The MasterPlan
(`docs/masterplans/1-kioku-reusable-agent-memory-session-library.md`) fixed several binding
decisions this plan inherits (IP-1, IP-3, IP-4, and the Decision Log entries about opt-in L0 turns
and consolidation-as-events); they are restated here so this document is self-contained.

- Decision: All distillation LLM steps are **shikumi typed programs over baikai-claude**, never
  hand-rolled Anthropic HTTP calls. Each step is a `Program input output` where `output` is a Haskell
  record deriving `ToSchema`/`FromModel` (strict JSON schema), run through `runProgram` under the
  `runRouting model . runLLMResilient cfg . routeLLM` interpreter chain.
  Rationale: MasterPlan IP-4 mandates shikumi/baikai for distillation; strict-schema output is what
  makes the pipeline parseable and testable, and `runLLMResilient` gives retry/budget/rate-limit for
  free. (Inherited from MasterPlan #1 IP-4 + Decision Log.)
  Date: 2026-06-24

- Decision: Consolidation decisions are recorded as **events** on the memory streams, not as silent
  table mutations. `store` → a normal `MemoryRecorded` (via `Kioku.Memory.record`); `update`/`merge`
  → `MemoryMerged` on the loser memory streams, pointing the loser at the winner; `skip` → no memory
  event, only an audit row in `kioku_consolidation_decisions`. Every decision (including `skip`) also
  writes an audit row for inspectability.
  Rationale: MasterPlan Vision + Decision Log ("LLM-driven consolidation recorded as events"). Event
  sourcing means the merge history is replayable and the read model rebuildable; the audit table
  makes the LLM's reasoning visible for debugging.
  Date: 2026-06-24

- Decision: EP-1 reserves the `MemoryMerged` event constructor and the `Merged` terminal vertex but
  adds **no edge**. EP-3 (this plan) adds the `MergeMemory` command, the `Active → Merged` edge that
  emits `MemoryMerged`, and the `Kioku.Memory.merge` write API. The codec's event-type list is
  unchanged (EP-1 already listed `MemoryMerged`), so this is additive — no codec break.
  Rationale: EP-1 Decision Log explicitly reserved the event "so EP-3 adds only an edge and a command,
  never a breaking codec change."
  Date: 2026-06-24

- Decision: L0 turns are **opt-in**. The pyramid consumes whatever L0 exists: if a session recorded
  `TurnRecorded` events, extraction reads those; if it recorded none, extraction reads the explicitly
  recorded memories in that session's scope plus the session envelope (focus/summary). The pipeline
  never *requires* turns.
  Rationale: MasterPlan Decision Log ("Raw conversation turns are an optional, per-session
  capability"). Rei sessions record no turns; shikigami/mori may.
  Date: 2026-06-24

- Decision: Triggering is timer-driven (keiro durable timers), not synchronous. An L1 extraction pass
  fires on (a) session completion, OR (b) a **turn-count threshold with a warm-up ramp** (extract
  after 1 turn, then 2, then 4, …, doubling up to a cap of N=16, so a fresh session distills eagerly
  and a long one less often), OR (c) an **idle-timeout flush** (if a session is open but no turn has
  arrived for `idleFlushMinutes`, default 30, distill what is there). L2 and L3 are **downward-only**:
  L2 reacts to L1 atom changes, L3 reacts to L2 scene changes; they never trigger upward.
  Rationale: distillation is expensive (LLM calls) and must not block the write path. The warm-up
  ramp is the TencentDB-style policy that distills early sessions eagerly and amortizes later. keiro
  timers are the ecosystem's durable-scheduling tool (FireTimer.hs / DormancyTimer.hs are the
  templates).
  Date: 2026-06-24

- Decision: Candidate lookup for consolidation uses `Kioku.Recall` (EP-2's hybrid recall) when EP-2
  is present; if EP-2 is not yet done (`Kioku.Recall` is still the EP-1 placeholder), fall back to a
  **recency/scope SQL scan** (the most-recent active atoms in the candidate's scope). The
  consolidation orchestration depends only on a narrow internal interface
  `findMergeCandidates :: MemoryScope -> Text -> Eff es [MemoryRecord]` so the implementation can swap
  without touching the LLM step.
  Rationale: MasterPlan dependency graph — EP-3 soft-depends on EP-2 ("its LLM dedup step calls recall
  to find merge candidates; if absent it can fall back to a recency/scope SQL scan").
  Date: 2026-06-24

- Decision: Deterministic tests use shikumi's **offline trace replay** (`shikumi-trace`,
  `runLLMReplay :: Map CacheKey Value -> Eff (LLM : es) a -> Eff es a`). The test records (once) the
  LLM answers for the fixed fixture, stores the trace, and replays it so the assertions are
  reproducible despite LLM nondeterminism.
  Rationale: LLM output is nondeterministic; strict-schema output bounds the *shape* but not the
  *content*. Trace replay pins the content for tests. (shikumi ships `Shikumi.Trace.Replay`.)
  Date: 2026-06-24

- Decision: New read-model tables (`kioku_scenes`, `kioku_personas`, `kioku_consolidation_decisions`)
  live in the **`kiroku` schema**, like every other kioku read model (EP-1/IP-3 convention), and are
  added by a new codd migration in `kioku-migrations/sql-migrations/`.
  Rationale: the application queries read models on the event-store pool whose `search_path` is
  `kiroku`; consistency with EP-1's `kioku_memories`/`kioku_sessions`.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this codebase. Read it fully before editing.

### Where things live

You will edit the **kioku** repository at `/Users/shinzui/Keikaku/bokuno/kioku`. It is a four-package
Haskell project: `kioku-api` (shared wire types), `kioku-core` (aggregates, projections, read API,
and — after this plan — the distillation programs and reactors), `kioku-cli` (the `kioku` binary), and
`kioku-migrations` (the database schema, codd + Template-Haskell `embedDir`). This layout mirrors the
sibling project **kizashi** at `/Users/shinzui/Keikaku/bokuno/kizashi`, which is the reference for
every convention (migration packaging, worker hosting, CLI wiring).

This plan is **EP-3** of MasterPlan #1
(`docs/masterplans/1-kioku-reusable-agent-memory-session-library.md`). Two prior plans are checked in
and are referenced here by path only:

- **EP-1** — `docs/plans/1-kioku-scaffold-and-core-extraction.md` (a **hard dependency**). It builds
  the kioku project, the event-sourced Memory and Session aggregates, the generic `MemoryScope` model
  in `kioku-api`, the inline read-model projections, the `kioku_memories`/`kioku_sessions`/`kioku_turns`
  tables, the `Kioku.Memory`/`Kioku.Session` write APIs, the placeholder `Kioku.Recall`, and the
  `kioku-migrations` package. Crucially, EP-1 **reserves** the `MemoryMerged` event constructor and the
  `Merged` terminal vertex on the Memory aggregate but adds no edge that emits it — this plan adds that
  edge. EP-1 must be Complete and building before this plan starts.
- **EP-2** — `docs/plans/2-kioku-hybrid-retrieval-pgvector-fts-rrf.md` (a **soft dependency**). It
  replaces the placeholder `Kioku.Recall` with hybrid (vector + full-text) recall. This plan *uses*
  recall to find merge candidates during consolidation, but if EP-2 is not yet done it falls back to a
  recency/scope SQL scan (see the Decision Log). Reference EP-2 by path only.

The LLM library lives outside kioku and is read-only input:

- **shikumi** at `/Users/shinzui/Keikaku/bokuno/shikumi` — a typed-LLM-program library. Each subdir is
  a cabal package (`shikumi/shikumi`, `shikumi/shikumi-trace`, …). You depend on it; you do not modify
  it.
- **baikai** at `/Users/shinzui/Keikaku/bokuno/baikai` — the LLM transport. `baikai-claude` is the
  Anthropic provider; `baikai-effectful` is the effectful binding. shikumi dispatches through these.
- The **handan** project at `/Users/shinzui/Keikaku/bokuno/handan` is the canonical worked example of
  using shikumi over baikai-claude. Its `handan-core/src/Handan/Program/ReleaseClassify.hs` (a program
  definition) and `handan-core/src/Handan/Runtime.hs` (the interpreter wiring) are the templates this
  plan reproduces. Read them.

### Terms of art (defined in plain language)

- **Event sourcing.** The source of truth for an entity is an append-only sequence of immutable facts
  (*events*) on a named *stream* in the `kiroku` event store (a PostgreSQL-backed log). The queryable
  table is a *projection* — a derived view rebuilt from events. EP-1 set this up for Memory and
  Session.
- **Aggregate / keiki transducer.** An aggregate (here Memory, Session) has its write logic expressed
  as a pure state machine (a keiki `SymTransducer`): vertices (states), edges (which command is valid
  in which state and what event it emits). EP-1 built both transducers; this plan adds one edge to the
  Memory transducer.
- **Inline projection.** A function `event -> RecordedEvent -> Tx.Transaction ()` that upserts a
  read-model row **in the same transaction** as the event append, so a read right after the write sees
  it. Inline projections must be simple and never fail (no network calls). EP-1's
  `memoryInlineProjection` is the example.
- **Async projection / worker host.** keiro's `AsyncProjection` is a record
  `{ name, subscriptionName, applyRecorded :: RecordedEvent -> Tx.Transaction (), idempotencyKey }`.
  The application hosts workers; keiro ships no supervisor. Rei's
  `/Users/shinzui/Keikaku/bokuno/rei-project/rei/rei-core/src/Rei/Infrastructure/WorkerHost.hs` is the
  reference host (`runKirokuWorkerHost`). An async projection's `applyRecorded` runs in a database
  transaction, so it **cannot** make HTTP calls.
- **Side-effect leg.** A worker that reacts to an event by doing *non-transactional* work (file IO,
  HTTP) — it is **not** a plain async projection. It is built with `sideEffectReactorSpec` /
  `sideEffectProcessor` (in `WorkerHost.hs`); it always acks OK (best-effort) and must be
  content-idempotent. Rei's
  `/Users/shinzui/Keikaku/bokuno/rei-project/rei/rei-core/src/Rei/Modules/AgentMemory/Reactor/FilesystemProjection.hs`
  is the template (decode event → write file → ack OK).
- **keiro durable timer.** A row in the `keiro_timers` table (owned by `keiro-migrations`) scheduled
  to fire at a future time. You *arm* a timer with `scheduleTimerTx :: TimerRequest -> Tx.Transaction ()`
  (idempotent on a deterministic `timerId`), the host's timer loop claims due timers with
  `claimDueTimer`, and routes them to a *fire* action on the row's `processManagerName`. The fire
  action does work and may re-arm (self-rescheduling). Rei's
  `/Users/shinzui/Keikaku/bokuno/rei-project/rei/rei-core/src/Rei/Modules/Reminder/Reactor/FireTimer.hs`
  (arming from an inline projection) and
  `/Users/shinzui/Keikaku/bokuno/rei-project/rei/rei-core/src/Rei/Modules/Intention/Reactor/DormancyTimer.hs`
  (a self-rescheduling daily-eval timer) and
  `/Users/shinzui/Keikaku/bokuno/rei-project/rei/rei-core/src/Rei/Infrastructure/ReiTimers.hs`
  (the shared dispatcher + bootstrap) are the templates.
- **shikumi program.** A typed value `Program input output` (a deep-embedded GADT). The simplest is
  `predict sig` where `sig :: Signature input output`. The `output` type is a Haskell record deriving
  `ToSchema` (so the LLM is forced to answer in exactly that JSON shape) and `FromModel` (so the answer
  decodes back to the record). You run it with `runProgram :: (LLM :> es, Error ShikumiError :> es) =>
  Program i o -> i -> Eff es o`.
- **MemoryScope.** kioku's host-agnostic addressing (from `kioku-api`, `Kioku.Api.Scope`):
  `data MemoryScope = ScopeGlobal Namespace | ScopeEntity Namespace ScopeKind Text`, decomposed in the
  read-model tables into `namespace`/`scope_kind`/`scope_ref` columns. A distillation pass always
  operates within one scope.
- **L0/L1/L2/L3.** The four pyramid layers defined in Purpose: evidence (raw), atoms (structured
  memories), scenes (markdown groupings), persona (one profile per scope).

### What EP-1 already built that this plan extends

Before this plan starts, EP-1 has produced (read EP-1 for the exact code):

- The Memory aggregate (`Kioku.Memory.Domain`) with vertices `NotCreated | Active | Superseded |
  Merged | Archived` (terminal: `Superseded`, `Merged`, `Archived`) and events `MemoryRecorded`,
  `MemorySuperseded`, `MemoryArchived`, `MemoryTagsUpdated`, `MemoryConfidenceUpdated`, and the
  **reserved** `MemoryMerged` (no edge emits it yet). `MemoryRecorded` carries
  `memoryId, agentId, sessionId :: Maybe SessionId, scope :: MemoryScope, memoryType :: MemoryType,
  content :: Text, priority :: Int, confidence :: Confidence, tags :: Set Text,
  supersedes :: Maybe MemoryId, recordedAt :: UTCTime`; `MemorySuperseded` carries
  `memoryId, supersededBy :: MemoryId, supersededAt`; `MemoryMerged` (reserved) carries
  `memoryId, mergedInto :: MemoryId, mergedAt`.
- The Session aggregate (`Kioku.Session.Domain`) with events `SessionStarted`, `SessionCompleted`,
  `SessionFailed`, `InteractiveSessionRecorded`, and the opt-in `TurnRecorded`; the `Running` vertex is
  non-terminal so turns append while the session is open.
- The `kioku_memories`, `kioku_sessions`, `kioku_turns` tables in the `kiroku` schema, the inline
  projections, and the `kioku-migrations` package.
- The `Kioku.Memory` write API (`record`, `supersede`, `archive`, `updateTags`, `updateConfidence`)
  and the `Kioku.Recall` read API (placeholder scoped queries in EP-1; hybrid in EP-2).
- The `Kioku.App` effect stack `type AppEffects = '[Store, Error StoreError, Tracing, IOE]` and the
  `kioku` CLI binary.

Nothing in EP-1 imports shikumi or baikai. M0 of this plan adds those dependencies.

### What this plan creates (orientation map)

New SQL (in `kioku-migrations/sql-migrations/`): one migration adding `kioku_scenes`,
`kioku_personas`, `kioku_consolidation_decisions`. New Haskell (in `kioku-core/src/Kioku/`):
`Distill/Runtime.hs` (LLM interpreter wiring), `Distill/Extract.hs`, `Distill/Consolidate.hs`,
`Distill/Scene.hs`, `Distill/Persona.hs` (the four shikumi programs), `Distill/L1.hs`,
`Distill/L2.hs`, `Distill/L3.hs` (orchestration + reactors), and `Distill/Timer.hs` (the L1 trigger
timer). One edge added to `Kioku.Memory.Domain`; one writer (`merge`) added to `Kioku.Memory`. New CLI
(in `kioku-cli`): `kioku distill session <id>`, `kioku scenes --scope …`, `kioku persona --scope …`,
and the L2/L3 reactors registered into the `kioku worker` host that EP-2 introduced. New test
(`kioku-core/test/Kioku/DistillSpec.hs`).


## Plan of Work

The work is five milestones. M0 wires shikumi/baikai into kioku and proves the LLM path compiles —
nothing user-visible, but it is the prerequisite. M1 delivers L1 extraction + consolidation recorded
as events, with the headline merge-not-duplicate behavior. M2 adds L2 scenes. M3 adds L3 persona. M4
pins everything with a deterministic replay test. Each milestone leaves the tree building
(`cabal build all`) and is independently verifiable.

Throughout, follow the templates named in Context: handan for shikumi programs + runtime, Rei's
`FireTimer.hs`/`DormancyTimer.hs`/`ReiTimers.hs` for timers, Rei's `WorkerHost.hs` for the worker host
and side-effect legs, Rei's `FilesystemProjection.hs` for filesystem mirrors, and kizashi's
`Migrations.hs` for migration packaging.


### Milestone M0 — wire shikumi/baikai into kioku

**Scope and result.** At the end of M0, kioku-core can build and run a shikumi typed program against
baikai-claude. No distillation logic yet — just the dependency wiring and a runtime module that any
later milestone can call. This de-risks the single biggest unknown (does the LLM stack compile inside
kioku's cabal solver?) before any feature work.

**`cabal.project`.** Add the shikumi packages as local-path `packages:` entries and let baikai resolve
(handan consumes shikumi by relative path and baikai from Hackage; mirror that). Append to
`/Users/shinzui/Keikaku/bokuno/kioku/cabal.project`:

```text
packages:
  -- (EP-1's four kioku packages stay above this)
  ../../shikumi/shikumi
  ../../shikumi/shikumi-trace

-- shikumi-trace pulls blake3 (content-addressed cache keys) and hasql/libpq.
package blake3
  flags: -avx512 -avx2 -sse41 -sse2
  ghc-options: -optc-DBLAKE3_USE_NEON=0

package postgresql-libpq
  flags: +use-pkg-config
```

The relative path is `../../shikumi/shikumi` because kioku's `cabal.project` lives at
`/Users/shinzui/Keikaku/bokuno/kioku/cabal.project` and shikumi is at
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi`. If the solver complains the `baikai*` versions are
not on the configured Hackage index, add local-path entries `../../baikai/baikai`,
`../../baikai/baikai-claude`, `../../baikai/baikai-effectful` the same way and record that in the
Decision Log. shikumi requires **GHC 9.12.4** (the kikan pin-set in EP-1 already uses
`with-compiler: ghc-9.12.4`, so this is consistent).

**`kioku-core.cabal`.** Add to the library `build-depends`:
`shikumi`, `shikumi-trace`, `baikai`, `baikai-claude`, `baikai-effectful`,
plus `effectful-core` (for `Concurrent`) if not already present, and `containers` (for the replay
`Map`, already present). Add `shikumi`, `shikumi-trace` to the `test-suite`'s `build-depends` too (M4
uses replay).

**`kioku-core/src/Kioku/Distill/Runtime.hs`.** Copy the shape of handan's `Handan/Runtime.hs`. It
registers the Claude provider once and exposes the interpreter chain. The exact pattern (from the
research on `Handan.Runtime`):

```haskell
module Kioku.Distill.Runtime
  ( DistillRuntime (..)
  , newDistillRuntime
  , runDistillProgram
  ) where

import Baikai.Model (Model)
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.Claude.Api qualified as ClaudeApi
import Baikai.Provider.Registry (globalProviderRegistry)
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLMConfig, defaultLLMConfig, runLLMResilient)
import Shikumi.Program (Program, runProgram)
import Shikumi.Routing (routeLLM, runRouting)

data DistillRuntime = DistillRuntime
  { config       :: !LLMConfig
  , defaultModel :: !Model
  }

newDistillRuntime :: IO DistillRuntime
newDistillRuntime = do
  ClaudeApi.register   -- idempotent; installs the Anthropic handler in the global registry
  pure DistillRuntime
    { config       = defaultLLMConfig globalProviderRegistry
    , defaultModel = Models.anthropic_claude_haiku_4_5
    }

-- | Run one typed program at the edge (IO). The interpreter order is load-bearing:
-- runRouting is OUTER of runLLMResilient which is OUTER of routeLLM.
runDistillProgram :: DistillRuntime -> Program i o -> i -> IO (Either ShikumiError o)
runDistillProgram rt prog input =
  runEff
    . runErrorNoCallStack @ShikumiError
    . runConcurrent
    . runRouting (defaultModel rt)
    . runLLMResilient (config rt)
    . routeLLM
    $ runProgram prog input
```

**Prove it.** Add a throwaway `Program Text Text` (a `predict (mkSignature "echo the input")` with a
one-field input/output record) behind a `#ifdef`-free helper in the same module or a scratch test, run
`cabal build kioku-core`, and verify it compiles. (Calling it for real needs `ANTHROPIC_API_KEY` /
baikai-claude's configured key; compilation is the M0 gate.)

**Acceptance for M0.** `cabal build kioku-core` exits 0 with the shikumi/baikai deps in place and
`Kioku.Distill.Runtime` compiling.


### Milestone M1 — L1 extraction + consolidation, recorded as events

**Scope and result.** At the end of M1, kioku can take a multi-turn session and distill it into L1
atoms: an LLM **extraction** step proposes candidate atoms from the session's L0, and an LLM
**consolidation** step decides `store | update | merge | skip` per candidate. Decisions are applied as
*events*: `store` records a new memory; `merge`/`update` records `MemoryMerged` on the loser streams;
`skip` records only an audit row. The headline observable: feeding a near-duplicate of an existing
atom produces a **merge** (one active row and a `MemoryMerged` event on the loser stream), not a second
row. A `kioku distill session <id>` command forces a pass; a keiro timer
fires passes automatically.

**The migration.** Create
`kioku-migrations/sql-migrations/<UTC-timestamp>-kioku-distillation.sql` (timestamp `YYYY-MM-DD-HH-MM-SS`,
sorting *after* EP-1's and EP-2's migrations). Because codd's `embedDir` bakes the directory at compile
time, after adding the file force a rebuild (`cabal clean kioku-migrations` then build) — the kizashi/Rei
`embedDir` caveat. SQL (all three tables this plan needs are added here; M2/M3 only write rows):

```sql
-- codd: in-txn
-- kioku distillation pyramid read models (EP-3): scenes (L2), personas (L3),
-- and an audit of every consolidation decision (L1). Read models live in the
-- `kiroku` schema; pin search_path so unqualified names resolve there.
SET search_path TO kiroku, pg_catalog;

-- L2 scenes: one markdown scene block per (scope, scene_key).
CREATE TABLE IF NOT EXISTS kioku_scenes (
  scene_id     text PRIMARY KEY,
  namespace    text NOT NULL,
  scope_kind   text,
  scope_ref    text,
  scene_key    text NOT NULL,           -- a stable grouping key within the scope (e.g. a topic slug)
  title        text NOT NULL,
  body_md      text NOT NULL,           -- the rendered markdown scene block
  atom_ids     jsonb NOT NULL DEFAULT '[]',  -- the memory ids this scene summarizes
  source_hash  text NOT NULL,           -- hash of the inputs, for idempotent regeneration
  created_at   timestamptz NOT NULL DEFAULT NOW(),
  updated_at   timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (namespace, scope_kind, scope_ref, scene_key)
);
CREATE INDEX IF NOT EXISTS kioku_scenes_scope_idx
  ON kioku_scenes (namespace, scope_kind, scope_ref);

-- L3 persona: exactly one row per scope.
CREATE TABLE IF NOT EXISTS kioku_personas (
  persona_id   text PRIMARY KEY,
  namespace    text NOT NULL,
  scope_kind   text,
  scope_ref    text,
  body_md      text NOT NULL,           -- the rendered persona profile markdown
  scene_count  integer NOT NULL DEFAULT 0,
  source_hash  text NOT NULL,           -- hash of the scenes that produced it (regen guard)
  created_at   timestamptz NOT NULL DEFAULT NOW(),
  updated_at   timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (namespace, scope_kind, scope_ref)  -- one persona per scope
);

-- L1 audit: every consolidation decision (incl. skip), for inspectability.
CREATE TABLE IF NOT EXISTS kioku_consolidation_decisions (
  decision_id      text PRIMARY KEY,
  session_id       text,
  namespace        text NOT NULL,
  scope_kind       text,
  scope_ref        text,
  candidate_content text NOT NULL,      -- the extracted atom that was being decided
  decision         text NOT NULL,       -- 'store' | 'update' | 'merge' | 'skip'
  target_ids       jsonb NOT NULL DEFAULT '[]',  -- existing memory ids touched (merge/update)
  result_memory_id text,               -- the memory id stored/kept (NULL for skip)
  rationale        text,               -- the LLM's one-line reason
  decided_at       timestamptz NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS kioku_consolidation_session_idx
  ON kioku_consolidation_decisions (session_id);
```

**The MemoryMerged edge.** In `kioku-core/src/Kioku/Memory/Domain.hs`, EP-1 declared the `Merged`
terminal vertex and the `MemoryMerged` event but no edge. Add a `MergeMemory` command carrying
`MergeMemoryData { memoryId :: MemoryId, mergedInto :: MemoryId, mergedAt :: UTCTime }` and the edge
out of `Active`:

```haskell
    B.from Active do
      -- (existing supersede/archive/updateTags/updateConfidence edges stay)
      B.onCmd inCtorMergeMemory $ \d -> B.do
        B.emit wireMemoryMerged MemoryMergedTermFields { {- copy memoryId/mergedInto/mergedAt from d -} }
        B.goto Merged
```

The codec's `eventTypes` already lists `MemoryMerged` (EP-1), so no codec change. The inline projection
already maps `MemoryMerged` → status `'merged'` (EP-1 wrote it to handle all six constructors).

**The merge writer.** In `kioku-core/src/Kioku/Memory.hs`, add:

```haskell
-- Mark `loser` as merged into `winner`. Records MemoryMerged on loser's stream,
-- so recall stops returning the loser once the read model projects status='merged'.
merge :: (es-row) => MemoryId -> MemoryId -> Eff es (Either CommandError ())
merge loser winner = do
  now <- liftIO getCurrentTime
  runMemoryCommand loser (MergeMemory (MergeMemoryData loser winner now))
```

(Exact constructor names follow EP-1's `MemoryCommand`.)

**The two shikumi programs.** Model both on handan's `ReleaseClassify.hs`. Add
`kioku-core/src/Kioku/Distill/Extract.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
module Kioku.Distill.Extract
  ( ExtractInput (..), ExtractedAtom (..), ExtractOutput (..)
  , extractProgram
  ) where

import Shikumi.Adapter (ToPrompt)
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema)
import Shikumi.Schema.Types (Field)
import Shikumi.Signature (Signature, mkSignature)
-- plus your Text import

-- The recent L0 for one session, flattened to text the model can read.
data ExtractInput = ExtractInput
  { focus         :: Field "the session focus / topic, free text" Text
  , scopeLabel    :: Field "human label of the scope, e.g. rei/intention/int_abc" Text
  , conversation  :: Field "recent turns or recorded memories, newline-joined" Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data ExtractedAtom = ExtractedAtom
  { atomType   :: Field "one of: fact | pattern | preference | constraint | instruction" Text
  , content    :: Field "the atom as one concise sentence" Text
  , priority   :: Field "0=always inject (highest), 100=normal, larger=lower" Int
  , confidence :: Field "one of: high | medium | low" Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newtype ExtractOutput = ExtractOutput
  { atoms :: [ExtractedAtom] }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

extractProgram :: Program ExtractInput ExtractOutput
extractProgram = predict (mkSignature
  "You read an agent's recent conversation/memories for one scope and extract durable, \
  \reusable memory atoms (facts, preferences, constraints, patterns, instructions). \
  \Be conservative: only extract things worth remembering across sessions. Return [] if none.")
```

Add `kioku-core/src/Kioku/Distill/Consolidate.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
module Kioku.Distill.Consolidate
  ( ConsolidateInput (..), ExistingMemory (..)
  , ConsolidationAction (..), ConsolidationDecision (..)
  , consolidateProgram
  ) where
-- imports as above

data ConsolidationAction = StoreAtom | UpdateAtom | MergeAtom | SkipAtom
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel)

-- One extracted atom plus the existing atoms it might duplicate (found via recall/scan).
data ExistingMemory = ExistingMemory
  { memoryId   :: Field "existing memory identifier" Text
  , memoryType :: Field "existing memory type or category" Text
  , content    :: Field "existing memory content" Text
  , priority   :: Field "existing memory priority where lower is more important" Int
  , confidence :: Field "existing confidence label" Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data ConsolidateInput = ConsolidateInput
  { scopeLabel :: Field "human-readable memory scope label" Text
  , candidate  :: ExtractedAtom
  , existing   :: [ExistingMemory]
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data ConsolidationDecision = ConsolidationDecision
  { action          :: ConsolidationAction
  , targetMemoryIds :: [Text]
  , resultContent   :: Maybe Text
  , rationale       :: Field "one concise reason for the decision" Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

consolidateProgram :: Program ConsolidateInput ConsolidationDecision
consolidateProgram = predict (mkSignature
  "Decide how a newly extracted memory atom relates to existing nearby memories. \
  \store: it is genuinely new. update: it refines exactly one existing memory. \
  \merge: it and one-or-more existing memories should become a single memory. \
  \skip: it is an exact duplicate adding nothing. Prefer merge/update/skip over \
  \storing near-duplicates.")
```

**The L1 orchestration.** Add `kioku-core/src/Kioku/Distill/L1.hs`. It is the glue (no LLM types
leak out of `Distill.*`). Its public entry:

```haskell
-- Run one L1 pass for a session: extract atoms from L0, consolidate each, apply as events,
-- write audit rows. Returns a summary for the CLI.
distillSessionL1 ::
  (Store :> es, Error StoreError :> es, IOE :> es) =>
  DistillRuntime ->
  FindMergeCandidates es ->    -- EP-2 recall finder or scoped scan fallback
  SessionId ->
  Eff es (Either L1Error L1Summary)

data L1Summary = L1Summary
  { extracted :: !Int, stored :: !Int, merged :: !Int, skipped :: !Int }
  deriving stock (Show, Eq)

newtype FindMergeCandidates es =
  FindMergeCandidates { runFindMergeCandidates :: MemoryScope -> Text -> Eff es [MemoryRecord] }

recallCandidates :: EmbeddingModel -> VectorCapability -> Int -> FindMergeCandidates es
scopedScanCandidates :: Int -> FindMergeCandidates es
```

Its algorithm, step by step (resolve all ambiguity here, per the spec):

1. Load the session: fold the session stream for `focus`, `scope`, and `agentId`; load its
   `TurnRecorded` events from `kioku_turns` (opt-in L0) ordered by `turn_index`. If there are no turns,
   load the session's recorded memories from `kioku_memories` filtered to the session's scope as the L0
   text instead (the opt-in fallback). Build `ExtractInput { focus, scopeLabel = render scope,
   conversation = newline-join of turns-or-memories }`.
2. Run extraction: `out <- liftIO (runDistillProgram rt extractProgram extractInput)`; on `Left err`
   return a zero `L1Summary` (extraction is best-effort, never wedges the caller). Get
   `atoms = atoms out`.
3. For each extracted atom: find merge candidates with the internal interface
   `findMergeCandidates :: MemoryScope -> Text -> Eff es [MemoryRecord]`. **EP-2 present:** call
   `Kioku.Recall.recall model cap (RecallRequest scope (content atom) Hybrid 5)` and map hits to
   records. **EP-2 absent (placeholder):** run a scoped SQL scan
   `SELECT … FROM kiroku.kioku_memories WHERE status='active' AND namespace=$ns AND (scope predicate)
   ORDER BY created_at DESC LIMIT 5`. (The L1 module depends only on `findMergeCandidates`; provide
   both bodies as `recallCandidates` and `scopedScanCandidates`; the CLI/worker chooses the right
   finder from runtime capability.
4. Run consolidation: `dec <- liftIO (runDistillProgram rt consolidateProgram (ConsolidateInput …))`.
   On `Left err`, default the decision to `store` (so a consolidation outage degrades to "record it"
   rather than dropping the atom) and note it in the audit `rationale`.
5. Apply the decision (all writes through `Kioku.Memory`, i.e. as events):
   - `store`: `Kioku.Memory.record …` with the atom's fields → a `MemoryRecorded` event + a row.
   - `update`: treat as record-the-resolved-content-then-supersede-the-single-target — i.e.
     `winner <- record (resolved fields)`; `merge target winner` for the one target id.
   - `merge`: `winner <- record (mergedContent/mergedType/mergedPriority)`; then for each id in
     `targetMemoryIds`, `Kioku.Memory.merge id winner` (records `MemoryMerged` on each loser). This is
     the headline path.
   - `skip`: do nothing to memory streams.
   In all four cases write one `kioku_consolidation_decisions` audit row (`decision`, `target_ids`,
   `result_memory_id`, `rationale`) via a `Tx.statement` on the store pool.
6. Tally into `L1Summary` and return.

**The trigger timer.** Distillation fires from keiro durable timers, not synchronously. Add
`kioku-core/src/Kioku/Distill/Timer.hs`, modeled jointly on Rei's `FireTimer.hs` (arming from an inline
projection) and `DormancyTimer.hs` (debounced durable timer fire). Three pieces:

- A constant `l1ExtractProcessManagerName :: Text = "kioku-l1-extract"` and a deterministic
  `l1TimerId :: SessionId -> Text -> UTCTime -> TimerId` (UUIDv5 of `"<pm>|<session>|<kind>|<show fireAt>"`,
  exactly as `reminderTimerId` in `FireTimer.hs`).
- An inline projection `l1TimerScheduleProjection :: InlineProjection SessionEvent` added to the
  **session write path** (the projection list passed to `runCommandWithProjections` in
  `Kioku.Session`). On `SessionStarted` it arms the first timer; on each `TurnRecorded` it re-arms,
  pushing the idle deadline forward and tracking the turn count; on `SessionCompleted`/`SessionFailed`
  it arms an immediate final-pass timer. The `TimerRequest` carries
  `correlationId = idText sessionId`, `payload = {"turnCount": n, "kind": "ramp"|"idle"|"final"}`,
  `fireAt` = the next ramp threshold time or `now + idleFlushMinutes`. Use `scheduleTimerTx` (re-arms
  while still Scheduled). The warm-up ramp: fire after turn counts 1, 2, 4, 8, 16, then every 16.
- A fire dispatcher branch. `Kioku.Distill.Timer.Worker.fireL1Timer` routes only
  `processManagerName == l1ExtractProcessManagerName`: recover the `SessionId` from `correlationId`,
  choose `recallCandidates` or `scopedScanCandidates`, run `distillSessionL1 rt finder sessionId`, and
  return `Just` a deterministic marker `EventId` derived from the `TimerId` so keiro marks the timer
  `fired`. Return `Nothing` only for timers this fire action does not handle, or for retryable L1
  failures. The dispatcher needs the `DistillRuntime` — build it once at host startup
  (`newDistillRuntime`) and close over it, exactly as Rei closes over `WorkspaceConfig`.

The current implementation exposes a one-pass dispatcher through `kioku worker --timers-once`; a later
slice should integrate a continuous timer loop into the default `kioku worker` host. No global bootstrap
timer is needed — the session write path arms per-session timers, like Rei's reminders. The
`keiro_timers` table is owned by `keiro-migrations` (already in kioku's migration set via EP-1), so no
schema work.

**The force-a-pass CLI.** Add `kioku distill session <session-id>` to kioku-cli: it opens the store,
builds `newDistillRuntime`, selects `scopedScanCandidates` or `recallCandidates`, calls
`distillSessionL1`, and prints the `L1Summary` (`extracted=… stored=… merged=… skipped=…`). This is
what the M1 acceptance transcript uses (it does not wait for a timer).

**Acceptance for M1.** `cabal build all` exits 0. The Concrete Steps M1 transcript: start a session,
record two near-duplicate turns/memories, run `kioku distill session <id>`, and observe (a) the summary
shows at least one `merged`, (b) `SELECT memory_id, content, status FROM kiroku.kioku_memories WHERE
scope_ref = '…'` shows one active row (the loser is `merged`/`superseded`), (c)
`SELECT decision, rationale FROM kiroku.kioku_consolidation_decisions` shows a `merge` row, and (d) the
loser's kiroku stream contains a `MemoryMerged` event.


### Milestone M2 — L2 scene generation

**Scope and result.** At the end of M2, when L1 atoms in a scope change, kioku regenerates a Markdown
**scene block** grouping the related atoms and writes it to `kioku_scenes` and to a markdown file. A new
`kioku scenes --scope …` CLI prints the scene.

**The scene program.** Add `kioku-core/src/Kioku/Distill/Scene.hs` (same shikumi shape):

```haskell
data SceneInput = SceneInput
  { scopeLabel :: Field "human label of the scope" Text
  , atoms      :: Field "the active memory atoms in this scope, newline-joined" Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data SceneOutput = SceneOutput
  { title  :: Field "a short scene title, e.g. 'Testing & CI practices'" Text
  , bodyMd :: Field "a markdown scene block summarizing the atoms as a narrative" Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

sceneProgram :: Program SceneInput SceneOutput
sceneProgram = predict (mkSignature
  "Summarize a set of related agent memory atoms for one scope into a single readable \
  \markdown 'scene' block with a short title and a few bullet points / short paragraphs.")
```

**The L2 reactor.** Add `kioku-core/src/Kioku/Distill/L2.hs`. L2 is **downward-only**: it reacts to L1
atom changes (memory events) for a scope, not to anything upward. Two parts:

- A regeneration function
  `regenerateScene :: (Store :> es, IOE :> es) => DistillRuntime -> MemoryScope -> Eff es ()` that:
  loads the active atoms for the scope from `kioku_memories`; computes `source_hash = sha256` of the
  ordered atom ids+contents; if the existing `kioku_scenes` row for the scope's `scene_key` already has
  that `source_hash`, no-op (idempotent regen guard); else runs `sceneProgram`, and **upserts**
  `kioku_scenes` (one row per `(scope, scene_key)`; for v1 use a single `scene_key = "default"` per
  scope, and note that multi-scene grouping by topic is a follow-up). The upsert is via a `Tx.statement`
  on the store pool.
- The worker registration. Because regen calls an LLM (HTTP) it **cannot** be an inline or plain async
  projection. Register it as a **timer** (a per-scope `kioku-l2-scene` timer armed by the memory write
  path's inline projection, debounced — re-arm on each memory event, fire after a short quiet window) OR
  as a side-effect leg (`sideEffectReactorSpec`) that reacts to memory events by calling `regenerateScene`
  off-transaction. Use the **timer** approach for debouncing (many atoms recorded in one L1 pass → one
  scene regen), modeled on the L1 timer: a `kioku-l2-scene` `processManagerName`, `correlationId` = the
  scope label, fire = `regenerateScene rt (parse scope)`. This keeps regen off the write path and
  coalesces bursts.
- A filesystem mirror. Add a side-effect leg (`sideEffectReactorSpec`, kind `"filesystem_mirror"`,
  unique subName `"kioku-scene-filesystem"`) modeled **verbatim** on Rei's `FilesystemProjection.hs`:
  decode the scene-related event, render the scene markdown, and write
  `<workspace>/.kioku/scenes/<scope-slug>.md` (content-idempotent, always ack OK). Since scenes are a
  read-model not an aggregate, the simplest mirror reacts to the same memory events and reads the freshly
  upserted `kioku_scenes` row to write the file; register it after the L2 timer.

**The CLI.** Add `kioku scenes --scope <scope>` to kioku-cli: parse `namespace[:kind:ref]` into a
`MemoryScope` (same parser EP-2 uses for `kioku recall --scope`), `SELECT title, body_md, updated_at
FROM kiroku.kioku_scenes WHERE (scope predicate)`, and print each scene block.

**Acceptance for M2.** `cabal build all` exits 0. After the M1 pass and running `kioku worker` briefly
(so the L2 timer fires) — or after a direct `kioku distill session <id>` followed by a force-scene step —
`kioku scenes --scope …` prints a titled markdown scene block summarizing the scope's atoms, and the
file `<workspace>/.kioku/scenes/<scope-slug>.md` exists with the same body.


### Milestone M3 — L3 persona generation

**Scope and result.** At the end of M3, after L2 scenes for a scope change, kioku regenerates a single
per-scope **persona** profile, upserts it into `kioku_personas` (one row per scope), and mirrors a
`persona.md`. A `kioku persona --scope …` CLI prints it.

**The persona program.** Add `kioku-core/src/Kioku/Distill/Persona.hs`:

```haskell
data PersonaInput = PersonaInput
  { scopeLabel :: Field "human label of the scope" Text
  , scenes     :: Field "the scene blocks for this scope, newline-joined" Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newtype PersonaOutput = PersonaOutput
  { bodyMd :: Field "a single distilled persona/profile markdown for this scope" Text }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

personaProgram :: Program PersonaInput PersonaOutput
personaProgram = predict (mkSignature
  "Distill all the scene blocks for one scope into a single concise persona/profile: \
  \who the agent is working with here, their preferences, constraints, and the durable \
  \patterns learned. One markdown document.")
```

**The L3 reactor.** Add `kioku-core/src/Kioku/Distill/L3.hs`. L3 is **downward-only** and **threshold/
mutex-gated**: regeneration is expensive and there is exactly one persona per scope, so it must not run
concurrently for the same scope and should only run when scenes actually changed.
`regeneratePersona :: (Store :> es, IOE :> es) => DistillRuntime -> MemoryScope -> Eff es ()`:
loads the scope's `kioku_scenes` rows; computes `source_hash` over their ids+`updated_at`; if the
existing `kioku_personas` row has that hash, no-op (the regen guard is the mutex's threshold check);
else runs `personaProgram` and upserts `kioku_personas` (one row per scope, `UNIQUE` enforces it). Wire
it as a `kioku-l3-persona` timer armed when a scene upsert happens (the L2 regen arms an L3 timer for the
scope after it writes a scene), debounced the same way. Add a filesystem mirror side-effect leg writing
`<workspace>/.kioku/persona/<scope-slug>.md` (kind `"filesystem_mirror"`, unique subName
`"kioku-persona-filesystem"`), modeled on `FilesystemProjection.hs`.

**The CLI.** Add `kioku persona --scope <scope>`: parse the scope, `SELECT body_md, updated_at FROM
kiroku.kioku_personas WHERE (scope predicate)`, print it (or "no persona yet" if absent).

**Acceptance for M3.** `cabal build all` exits 0. After the L1→L2 pipeline has produced scenes and the
worker has run, `kioku persona --scope …` prints the distilled persona markdown and
`<workspace>/.kioku/persona/<scope-slug>.md` exists with the same body.


### Milestone M4 — deterministic end-to-end test

**Scope and result.** At the end of M4, a test in `kioku-core/test` exercises the whole pyramid against
a fixed multi-turn session **without hitting the network**, by replaying recorded LLM answers with
shikumi's offline trace replay, and asserts: atoms extracted, one merge (not a duplicate), a scene row,
a persona row — all visible from the events/tables.

**The test.** Add `kioku-core/test/Kioku/DistillSpec.hs` (wired into the existing tasty entry). It uses
the kioku test database (EP-1's `withKiokuMigratedDatabase`) and runs each shikumi program under
`Shikumi.Trace.Replay.runLLMReplay :: Map CacheKey Value -> Eff (LLM : es) a -> Eff es a` instead of
`runLLMResilient . routeLLM`. The replay index maps each program call's content-addressed `CacheKey` to
a recorded `Response` value. Build the index once: run the fixture once for real with
`runProgramTraced`-style tracing (handan's `runProgramTraced` pattern) to capture a `TraceTree`, turn it
into a replay index with `Shikumi.Trace.Store.replayIndex`, and embed it (or check in the JSON). The test
body:

1. `withKiokuMigratedDatabase $ \store -> do` — fresh migrated DB.
2. Start a session in scope `rei/intention/int_test`; record three `TurnRecorded` turns, two of which
   express the same preference in different words ("I like short answers" / "keep replies brief").
3. Run `distillSessionL1` with the replay runtime (the LLM steps answer from the recorded trace: the
   extraction returns the atoms; the consolidation returns a `merge` for the second near-duplicate).
4. Assert: `kioku_memories` for the scope has exactly one active "concise answers" atom; the loser has
   status `merged`/`superseded`; `kioku_consolidation_decisions` has a `merge` row; the loser's stream
   has a `MemoryMerged` event.
5. Run `regenerateScene` and `regeneratePersona` (replay) and assert one `kioku_scenes` row and one
   `kioku_personas` row exist for the scope, each with non-empty `body_md`.

To make the LLM answers deterministic the test substitutes `runLLMReplay idx` for the resilient
interpreter; everything else (extraction record decode, consolidation decision parse, the event writes,
the table upserts) runs identically to production. A cache miss raises `ReplayDivergence`, which fails
the test loudly (so a changed prompt/schema is caught).

**Acceptance for M4.** `cabal test kioku-core` runs and the `Distill` test group passes. Temporarily
flipping the recorded consolidation answer from `merge` to `store` makes the "exactly one active row"
assertion fail (proving the merge path is genuinely exercised), then restore it.


## Concrete Steps

Run all commands from the kioku repo root `/Users/shinzui/Keikaku/bokuno/kioku` unless stated
otherwise, inside the nix dev shell (which exports the PG env vars and GHC 9.12.4). Assume EP-1 is
Complete (kioku builds, migrates, `kioku` CLI works) and that EP-2 is either Complete (hybrid recall) or
not (placeholder recall — the L1 fallback scan applies). Set the LLM key once:

```bash
export ANTHROPIC_API_KEY=sk-ant-...   # baikai-claude uses this; the distillation steps need it
```

### Step 0 — M0: wire shikumi/baikai and build

```bash
cd /Users/shinzui/Keikaku/bokuno/kioku
# 1) Edit cabal.project: add the shikumi packages + blake3/libpq stanzas (Plan of Work M0).
# 2) Edit kioku-core/kioku-core.cabal: add shikumi, shikumi-trace, baikai, baikai-claude,
#    baikai-effectful to build-depends (lib + test-suite).
# 3) Write kioku-core/src/Kioku/Distill/Runtime.hs (Plan of Work M0).
direnv allow                          # or: nix develop
cabal build kioku-core
```

Expected tail:

```text
[ N of M] Compiling Kioku.Distill.Runtime ...
Linking ... (or "Up to date")
```

If the solver rejects the `baikai*` versions, add `../../baikai/baikai`, `../../baikai/baikai-claude`,
`../../baikai/baikai-effectful` to `packages:` and rebuild; record it in the Decision Log.

### Step 1 — M1: migration, merge edge, programs, orchestration, timer, CLI

```bash
# 1) Add kioku-migrations/sql-migrations/<ts>-kioku-distillation.sql (Plan of Work M1 SQL).
cabal clean kioku-migrations          # embedDir is baked at compile time; force a rebuild
cabal run kioku-migrations:kioku-migrate
psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt kiroku.kioku_*'
```

Expected (the three new tables alongside EP-1/EP-2's):

```text
 kiroku | kioku_consolidation_decisions | table | ...
 kiroku | kioku_memories                | table | ...
 kiroku | kioku_personas                | table | ...
 kiroku | kioku_scenes                  | table | ...
 kiroku | kioku_sessions                | table | ...
 kiroku | kioku_turns                   | table | ...
```

Then add the merge edge (`Kioku.Memory.Domain`), the merge writer (`Kioku.Memory`), the two programs
(`Kioku.Distill.Extract`, `Kioku.Distill.Consolidate`), the orchestration (`Kioku.Distill.L1`), the
timer (`Kioku.Distill.Timer`), and the CLI (`kioku distill session`). Build:

```bash
cabal build all
```

Drive the headline scenario (force a pass, no timer wait):

```bash
# Start a session and record two near-duplicate turns (EP-1 session/turn write CLI;
# exact subcommand names from EP-1/EP-2 — shown here as the kioku session API):
SID=$(kioku session start --scope rei:intention:int_demo --focus "code review" --print-id)
kioku session turn "$SID" --role user      "I really prefer short, concise answers."
kioku session turn "$SID" --role assistant "Noted; I'll keep replies brief and to the point."
kioku distill session "$SID"
```

Expected:

```text
distilled session kioku_session_… : extracted=2 stored=1 merged=1 skipped=0
  stored : kioku_memory_…  "prefers concise answers"
  merged : kioku_memory_…  -> kioku_memory_…
```

Verify one active row + the merge event + the audit:

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "SELECT left(content,40), status FROM kiroku.kioku_memories WHERE scope_ref='int_demo' ORDER BY created_at;"
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "SELECT decision, rationale FROM kiroku.kioku_consolidation_decisions WHERE scope_ref='int_demo';"
```

Expected (one active, one merged; a merge decision):

```text
 prefers concise answers | active
 keep replies brief …    | merged
---
 merge | the second turn restates the same preference
```

### Step 2 — M2: scenes

After adding the scene program/reactor/CLI and building, run the worker briefly (so the L2 timer fires)
or force-regenerate, then:

```bash
kioku scenes --scope rei:intention:int_demo
ls -1 .kioku/scenes/
```

Expected:

```text
## Communication preferences

- Prefers short, concise, to-the-point answers.
---
rei__intention__int_demo.md
```

### Step 3 — M3: persona

After adding the persona program/reactor/CLI and building, run the worker (L2→L3 cascade) or
force-regenerate, then:

```bash
kioku persona --scope rei:intention:int_demo
ls -1 .kioku/persona/
```

Expected:

```text
# Working with this intention

This agent values brevity: keep answers short and to the point. …
---
rei__intention__int_demo.md
```

### Step 4 — M4: deterministic test

```bash
cabal test kioku-core
```

Expected tail:

```text
Distill
  L1 extraction + merge (replay): OK
  L2 scene generation (replay):   OK
  L3 persona generation (replay): OK
All N tests passed
```


## Validation and Acceptance

Acceptance is behavioral, demonstrated by the Step 1–4 transcripts and the M4 test.

The four observable facts, each tied to a specific input/output:

1. *Atoms are extracted from L0.* After `kioku distill session <id>` on a two-turn session, the summary
   reports `extracted>=1` and `kioku_memories` gains at least one new active atom whose content
   paraphrases what the turns said. This proves the LLM extraction step ran and produced structured
   atoms (not raw text).
2. *A duplicate is merged, not duplicated.* The second near-duplicate turn yields a `merge` decision:
   `kioku_consolidation_decisions` shows a `merge` row, the loser memory has status `merged`/`superseded`,
   the scope shows **one** active "concise answers" atom, and the loser's kiroku stream carries a
   `MemoryMerged` event. This is the headline proof that consolidation works and is recorded as events.
3. *A scene block is written.* `kioku scenes --scope …` prints a titled markdown scene summarizing the
   scope's atoms, and `<workspace>/.kioku/scenes/<scope-slug>.md` holds the same body. This proves L2.
4. *A persona file is produced.* `kioku persona --scope …` prints the distilled persona and
   `<workspace>/.kioku/persona/<scope-slug>.md` exists. This proves L3.

Tests (`cabal test kioku-core`):

- The M4 `Distill` group replays recorded LLM answers (`runLLMReplay`) over the fixed fixture and
  asserts facts 1–4 from the tables/events, deterministically. Flipping the recorded consolidation
  answer from `merge` to `store` flips the "exactly one active row" assertion (the merge path is
  genuinely exercised). A `ReplayDivergence` failure means the prompt or output schema changed and the
  recorded trace must be regenerated — that is a deliberate, loud signal, not a flake.
- Pure unit assertions where practical: the warm-up ramp threshold function (1,2,4,8,16,…), the
  scope→slug rendering used for filenames, and the `source_hash` idempotency guards (same inputs → same
  hash → no regen) are pure and tested without the LLM or a database.

Because LLM output is nondeterministic, the *live* CLI transcripts (Steps 1–3) are illustrative — the
exact wording of atoms/scenes/personas will vary run to run. The **structural** facts (a merge happened,
one active row remains, a scene/persona row exists) are stable and are what acceptance asserts; the M4
replay test makes those facts reproducible in CI.

Acceptance is met when `cabal build all` and `cabal test kioku-core` pass and the Step 1–4 structural
outcomes reproduce.


## Idempotence and Recovery

Every step is safe to repeat.

- **The migration** uses `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`, and codd dedups
  by filename, so re-applying it is a no-op. It is purely additive (three new tables); to roll back,
  `DROP TABLE IF EXISTS kiroku.kioku_consolidation_decisions, kiroku.kioku_scenes, kiroku.kioku_personas;`
  — the distillation code then has nowhere to write but the memory aggregate is unaffected.
- **The merge edge** is additive to the transducer and the codec event-type list is unchanged (EP-1
  reserved `MemoryMerged`), so existing streams replay identically. `Kioku.Memory.merge` is idempotent:
  re-merging an already-`Merged` loser is a transducer no-op (the `Active → Merged` edge is unavailable
  in a terminal vertex), exactly like EP-1's other writers' pre-checks.
- **An L1 pass** is repeatable: re-running `kioku distill session <id>` re-extracts and re-consolidates;
  already-merged duplicates stay merged (consolidation sees one active atom and decides `skip`), so a
  second pass is near-idempotent (it writes new audit rows, which is intended — the audit is a log). If
  a pass crashes mid-way, the events already appended stand (event sourcing); re-running continues.
- **L2/L3 regeneration** is guarded by `source_hash`: if the inputs (atom ids/contents for a scene; scene
  ids/updated_at for a persona) are unchanged, regeneration is skipped. So re-running the worker, or a
  redelivered timer, recomputes the hash, finds a match, and does nothing. To **force** a regen (e.g.
  after changing a prompt), clear the hash: `UPDATE kiroku.kioku_scenes SET source_hash='';` (or the
  persona table) and re-run the worker.
- **The timers** arm on deterministic `timerId`s (UUIDv5 of `(pmName, entity, fireAt)`), so re-arming is
  an idempotent `ON CONFLICT` upsert and a redelivered fire re-runs an idempotent pass. The keiro timer
  worker is at-least-once, so every fire path (L1/L2/L3) is written to be idempotent as above.
- **Filesystem mirrors** are content-idempotent (write the same bytes), always ack OK, and never wedge
  the worker (the `FilesystemProjection.hs` pattern). A redelivery re-writes identical content.
- **The replay test** is read-only against the recorded trace; it never calls the network and is safe to
  run any number of times.

If the LLM provider is down: extraction returns `Left` → the L1 pass logs and returns a zero summary
(no atoms lost, no events written); consolidation returns `Left` → the atom defaults to `store` (so it
is kept, not dropped); scene/persona regen returns `Left` → the existing row/file is left in place. No
LLM outage corrupts state or blocks the write path.


## Interfaces and Dependencies

**Libraries and services.**

- **shikumi** (`/Users/shinzui/Keikaku/bokuno/shikumi`) — typed LLM programs. Used:
  `Shikumi.Module.predict :: (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i,
  ToPrompt o) => Signature i o -> Program i o`; `Shikumi.Signature.mkSignature :: (GFieldMetas (Rep i),
  GFieldMetas (Rep o)) => Text -> Signature i o`; `Shikumi.Program.runProgram :: (LLM :> es, Error
  ShikumiError :> es) => Program i o -> i -> Eff es o`; `Shikumi.Schema.{ToSchema, FromModel}` (derived
  via `deriving anyclass` on a `Generic` record); `Shikumi.Schema.Types.Field (desc :: Symbol) a`
  (per-field schema descriptions; needs `DataKinds`) with `field`/`unField`;
  `Shikumi.LLM.{LLMConfig, defaultLLMConfig, runLLMResilient}` (`runLLMResilient :: (IOE :> es,
  Concurrent :> es, Error ShikumiError :> es) => LLMConfig -> Eff (LLM : es) a -> Eff es a`);
  `Shikumi.Routing.{runRouting, routeLLM}`. For tests: `shikumi-trace`
  (`Shikumi.Trace.Replay.runLLMReplay :: Map CacheKey Value -> Eff (LLM : es) a -> Eff es a`,
  `Shikumi.Trace.Store.replayIndex`, `Shikumi.Trace.{runTrace, tracedLLM, withSpan}` for capturing a
  trace). The canonical worked example is handan's
  `/Users/shinzui/Keikaku/bokuno/handan/handan-core/src/Handan/Program/ReleaseClassify.hs` and
  `/Users/shinzui/Keikaku/bokuno/handan/handan-core/src/Handan/Runtime.hs`.
- **baikai** (`/Users/shinzui/Keikaku/bokuno/baikai`) — `baikai-claude`
  (`Baikai.Provider.Claude.Api.register :: IO ()`, call once at startup), `Baikai.Models.Generated`
  (`anthropic_claude_haiku_4_5` etc. — the ambient `Model`), `Baikai.Provider.Registry.globalProviderRegistry`,
  `baikai-effectful`. Keyed by `ANTHROPIC_API_KEY`.
- **keiro** — durable timers (`Keiro.Timer`: `TimerRequest{ timerId, processManagerName, correlationId,
  fireAt, payload }`, `scheduleTimerTx :: TimerRequest -> Tx.Transaction ()`,
  `claimDueTimer :: (Store :> es) => UTCTime -> Eff es (Maybe TimerRow)`,
  `runTimerWorker :: (IOE :> es, Store :> es) => Maybe KeiroMetrics -> UTCTime -> (TimerRow -> Eff es
  (Maybe EventId)) -> Eff es (Maybe TimerRow)`; the `keiro_timers` table is owned by `keiro-migrations`,
  no schema-init at startup). The worker host and side-effect-leg/async-projection/timer-spec machinery
  are modeled on Rei's
  `/Users/shinzui/Keikaku/bokuno/rei-project/rei/rei-core/src/Rei/Infrastructure/WorkerHost.hs`
  (`runKirokuWorkerHost :: Tracer -> KirokuStore -> Int -> [AsyncWorkerSpec] -> [ReactorWorkerSpec] ->
  [TimerWorkerSpec] -> Int -> MVar () -> IO ()`, `sideEffectReactorSpec`, `sideEffectProcessor`,
  `AsyncProjection{ name, subscriptionName, applyRecorded, idempotencyKey }`,
  `TimerWorkerSpec{ ..., fire :: TimerRow -> Eff '[Store, Error StoreError, Tracing, IOE] (Maybe
  EventId) }`). The timer-arming-from-inline-projection pattern is Rei's
  `.../Reminder/Reactor/FireTimer.hs`; the self-rescheduling fire is `.../Intention/Reactor/DormancyTimer.hs`;
  the shared dispatcher + bootstrap is `.../Infrastructure/ReiTimers.hs`; the filesystem-mirror
  side-effect leg is `.../AgentMemory/Reactor/FilesystemProjection.hs`.
- **codd + `Data.FileEmbed.embedDir`** — migration packaging, as kizashi's
  `/Users/shinzui/Keikaku/bokuno/kizashi/kizashi-migrations/src/Kizashi/Migrations.hs`. Adding a `.sql`
  requires `cabal clean kioku-migrations` then rebuild (embedDir bakes at compile time).
- **hasql** (`Hasql.Statement`/`Encoders`/`Decoders`/`Transaction`) — the scoped-scan candidate query
  (when EP-2 absent), the audit/scene/persona upserts (via `Tx.statement` on the store pool, the
  `store ^. #pool` single-pool trick), and the read queries behind the CLIs.

**Modules and signatures that must exist at the end of each milestone (full paths under
`/Users/shinzui/Keikaku/bokuno/kioku`).**

End of M0:

- `kioku-core/src/Kioku/Distill/Runtime.hs`:
  - `data DistillRuntime = DistillRuntime { config :: LLMConfig, defaultModel :: Model }`
  - `newDistillRuntime :: IO DistillRuntime`
  - `runDistillProgram :: DistillRuntime -> Program i o -> i -> IO (Either ShikumiError o)`
- `cabal.project` + `kioku-core.cabal` carry the shikumi/baikai deps.

End of M1:

- `kioku-migrations/sql-migrations/<ts>-kioku-distillation.sql` (the three tables above).
- `Kioku.Memory.Domain`: the `MergeMemory` command + the `Active → Merged` edge emitting `MemoryMerged`
  (`MemoryMerged` event + `Merged` vertex were reserved by EP-1).
- `Kioku.Memory`: `merge :: MemoryId -> MemoryId -> Eff es (Either CommandError ())`.
- `kioku-core/src/Kioku/Distill/Extract.hs`: `ExtractInput`, `ExtractedAtom`, `ExtractOutput` (each
  `deriving anyclass (ToSchema, FromModel, ToPrompt)`); `extractProgram :: Program ExtractInput
  ExtractOutput`.
- `kioku-core/src/Kioku/Distill/Consolidate.hs`: `ConsolidateInput`, `ExistingMemory`,
  `ConsolidationAction`, `ConsolidationDecision`; `consolidateProgram :: Program ConsolidateInput
  ConsolidationDecision`.
- `kioku-core/src/Kioku/Distill/L1.hs`: `distillSessionL1 :: (Store :> es, Error StoreError :> es,
  IOE :> es) => DistillRuntime -> FindMergeCandidates es -> SessionId -> Eff es (Either L1Error L1Summary)`;
  `data L1Summary = L1Summary { extracted, stored, merged, skipped :: Int }`; the internal
  `FindMergeCandidates` interface with `recallCandidates` and `scopedScanCandidates` implementations.
- `kioku-core/src/Kioku/Distill/Timer.hs`: `l1ExtractProcessManagerName :: Text`;
  `l1TimerId :: SessionId -> Text -> UTCTime -> TimerId`;
  `l1TimerScheduleProjection :: InlineProjection SessionEvent` (the L1-arming inline projection on the
  session write path).
- `kioku-core/src/Kioku/Distill/Timer/Worker.hs`: `fireL1Timer` and `runL1TimerWorkerOnce`; kioku-cli:
  `kioku worker --timers-once`.
- kioku-cli: `kioku distill session <session-id>` printing an `L1Summary`.

End of M2:

- `kioku-core/src/Kioku/Distill/Scene.hs`: `SceneInput`, `SceneOutput`; `sceneProgram :: Program
  SceneInput SceneOutput`.
- `kioku-core/src/Kioku/Distill/L2.hs`: `regenerateScene :: (Store :> es, IOE :> es) => DistillRuntime
  -> MemoryScope -> Eff es ()`; the `kioku-l2-scene` timer fire branch; the scene filesystem-mirror
  side-effect leg (`sideEffectReactorSpec`, kind `"filesystem_mirror"`, subName
  `"kioku-scene-filesystem"`).
- kioku-cli: `kioku scenes --scope <scope>`.

End of M3:

- `kioku-core/src/Kioku/Distill/Persona.hs`: `PersonaInput`, `PersonaOutput`; `personaProgram ::
  Program PersonaInput PersonaOutput`.
- `kioku-core/src/Kioku/Distill/L3.hs`: `regeneratePersona :: (Store :> es, IOE :> es) => DistillRuntime
  -> MemoryScope -> Eff es ()`; the `kioku-l3-persona` timer fire branch; the persona filesystem-mirror
  side-effect leg (subName `"kioku-persona-filesystem"`).
- kioku-cli: `kioku persona --scope <scope>`.

End of M4:

- `kioku-core/test/Kioku/DistillSpec.hs`: the replay-based end-to-end test asserting facts 1–4.

**Dependencies on prior work.** This plan **hard-depends** on EP-1
(`docs/plans/1-kioku-scaffold-and-core-extraction.md`) for the Memory/Session aggregates, the reserved
`MemoryMerged` event + `Merged` vertex, the L0 streams + `TurnRecorded`, the
`kioku_memories`/`kioku_sessions`/`kioku_turns` tables, the `Kioku.Memory`/`Kioku.Session` write APIs,
the `MemoryScope`/`MemoryRecord` types, and `kioku-migrations`. It **soft-depends** on EP-2
(`docs/plans/2-kioku-hybrid-retrieval-pgvector-fts-rrf.md`): the consolidation candidate lookup uses
`Kioku.Recall.recall` when present and a recency/scope SQL scan otherwise (the L1 module isolates this
behind `findMergeCandidates`). It also depends on EP-2 having introduced the `kioku worker` host (this
plan registers L2/L3 timers/side-effect legs and the L1 timer into it); if EP-2 is not done, this plan
must add the worker host itself by porting the `runKirokuWorkerHost` slice from Rei's `WorkerHost.hs`
(call this out and reconcile in the Decision Log). The exact EP-1 command/event constructor names are an
EP-1↔EP-3 contract; if EP-1's `MemoryCommand`/`MemoryEvent` constructor names differ from those used
here, match EP-1's and note it in the Decision Log.


## Revision History

- 2026-06-24 — Initial authoring of the full plan from the skeleton. Filled every prose section and
  seeded the Progress checklist; frontmatter left untouched. Grounded against: MasterPlan #1 (IP-1,
  IP-3, IP-4, and the Decision Log entries on opt-in L0 turns and consolidation-as-events); the ExecPlan
  spec (`.claude/skills/exec-plan/PLANS.md`); EP-1 (`docs/plans/1-…`) for the aggregates, the reserved
  `MemoryMerged` event, the L0 streams, the read-model tables, and the write APIs; EP-2 (`docs/plans/2-…`)
  for the soft recall dependency and the `kioku worker` host; shikumi (`Shikumi.{Program, Module,
  Signature, Schema, Routing, LLM}` and `shikumi-trace`'s `Shikumi.Trace.Replay`) and handan's
  `ReleaseClassify.hs` + `Runtime.hs` for the typed-program + interpreter pattern; and Rei's
  `FireTimer.hs` + `DormancyTimer.hs` + `ReiTimers.hs` + `WorkerHost.hs` + `FilesystemProjection.hs`
  (plus keiro's `Keiro.Timer`) for the durable-timer / async-reactor / side-effect-leg / filesystem-
  mirror patterns. Reason: convert the binding MasterPlan integration points into a self-contained,
  novice-followable execution plan for the L0→L3 distillation pyramid.


## Coding Conventions (haskell-jitsurei)

All Haskell in this plan follows the binding conventions in
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/` (the `shinzui/haskell-jitsurei` cookbook —
browse with `mori registry docs haskell-jitsurei`), as mandated by MasterPlan #1 Integration
Point IP-7. The rules that bear on this plan:

- **Core standards** (`core/standards.md`): GHC 9.12+ with the `GHC2024` language edition; a
  `common common` cabal stanza enabling `DeriveAnyClass`, `DuplicateRecordFields`,
  `OverloadedLabels`, `OverloadedStrings`, plus `MultilineStrings` for embedded SQL, with every
  library/exe/test stanza doing `import: common`; postpositive `qualified` imports
  (`import Data.Text qualified as Text`, never `import qualified`).
- **Custom prelude** (`core/custom-prelude.md`): a project prelude (`Kioku.Prelude` for kioku)
  re-exports the common surface + `Control.Lens` behind a per-file `{-# LANGUAGE PackageImports #-}`
  pragma. It **must NOT re-export `Data.Generics.Labels`** — that orphan `IsLabel` instance
  collides with the **keiki DSL**'s own `#label` overloading that kioku's transducers rely on.
  Modules that need generic-lens `#label` import `"generic-lens" Data.Generics.Labels ()`
  per-module; keiki-DSL modules use the keiki instance instead. The shared `eventAesonOptions`
  lives in the prelude.
- **Record patterns** (`core/record-patterns.md`): no field prefixes, strict `!` fields,
  entity-ID-first on event/command records, explicit `deriving stock`/`anyclass`/`newtype`
  strategies, and lens operators (`^.`, `.~`, `?~`, `%~`, `at`, `ix`) over record-update syntax.
- **Multiline strings** (`core/multiline-strings.md`): embedded SQL uses `MultilineStrings`
  (`"""…"""`), not `unlines` or string concatenation.
- **Plan-specific:** the `shikumi` extraction/consolidation output records (the schema types that
  derive `ToSchema`/`FromModel`) follow the record-pattern rules; embedded prompts and SQL use
  `MultilineStrings`.
