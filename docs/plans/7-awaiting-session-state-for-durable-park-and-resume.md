---
id: 7
slug: awaiting-session-state-for-durable-park-and-resume
title: "Awaiting session state for durable park-and-resume"
kind: exec-plan
created_at: 2026-06-27T16:24:02Z
intention: "intention_01kw4y99v6ebw9xxakqn4pwgk3"
master_plan: "docs/masterplans/1-kioku-reusable-agent-memory-session-library.md"
---

# Awaiting session state for durable park-and-resume

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today a kioku session can be `Running`, then it must march straight to `Completed` or
`Failed`. There is no way for an agent run to *pause itself* — to stop mid-flight, say "I am
waiting for a human to approve this", "I am waiting for the child agent I spawned to finish",
or "I am waiting for the human's next message" — and then *pick up exactly where it left off*
later, even after the process that was running it has crashed and been restarted.

After this change, a session gains one new lifecycle state, `Awaiting`, and two new
operations, `awaitInput` (park the session, recording *what* it is waiting for) and `resume`
(deliver the awaited input and continue). Because kioku sessions are **event-sourced** — every
state change is an immutable event appended to a durable log, and the current state is
recomputed by replaying that log — a parked session survives a crash for free: the park is a
committed event, and a fresh process can read the log, see the last event is `SessionAwaiting`,
and resume it. Nothing new and durable has to be built; we add events to a state machine that
already persists itself.

Concretely, after this change a developer (or an automated supervisor) can do this and observe
it working:

1. Start a session. Its row in the `kioku_sessions` table shows `status = 'running'`.
2. Call `awaitInput` with a *continuation* — a small record describing what is awaited (a
   reason such as `"approval"`, an optional *correlation key* the resumer will match on, and an
   optional deadline). The row flips to `status = 'awaiting'` and the awaiting columns fill in;
   a `SessionAwaiting` event is now the tail of the event log.
3. Query for awaiting sessions by correlation key and find the parked session — this is how a
   resumer locates the right session to wake.
4. Call `resume` with the delivered input. The row flips back to `status = 'running'`, the
   delivered input is recorded, and a `SessionResumed` event is appended.
5. Simulate a crash by throwing away the read-model row and rebuilding it purely by replaying
   the event log; the session lands back in exactly the same state. Re-deliver the same
   `resume` and nothing breaks — resume is idempotent.

This kioku change is a **prerequisite** for three planned consumer features in the
`shinzui/shikigami` repository, which is the project that *orchestrates* agent runs (kioku is a
library it composes):

- **"Agent runs as durable keiro workflows"** — its `awaitApproval` combinator suspends a run
  and records the park here (reason `"approval"`, correlation key = the approval request id).
- **"Conversational agent loop bound to danwa"** — a long-lived conversation parks between human
  turns (reason `"next_turn"`, correlation key = the `danwa` thread id).
- **"Multi-agent delegation primitive"** — a parent run parks awaiting a spawned child
  (reason `"child_result"`, correlation key = the child session id).

The API in this plan is designed to serve all three: a typed-but-open reason string, an
optional correlation key for the resumer to find the parked session, and an optional deadline a
watcher can use to time out a park.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 — Domain: add the `Awaiting` vertex, the `Continuation` payload, the `AwaitInput`
  and `ResumeSession` commands, the `SessionAwaiting` and `SessionResumed` events, and the
  transducer transitions (`Running → Awaiting → Running`, plus `Awaiting → Completed/Failed`)
  in `kioku-core/src/Kioku/Session/Domain.hs`. Completed 2026-06-27 after `cabal build
  kioku-core` succeeded; implementation flattens `AwaitInputData` to avoid hidden Keiki input
  fields during replay.
- [x] M2 — Codec: register the two new event types in
  `kioku-core/src/Kioku/Session/EventStream.hs` so they round-trip through the durable log.
  Completed 2026-06-27 after `cabal build kioku-core` succeeded.
- [x] M3 — Read model + migration: add the awaiting columns to `kioku_sessions` (new migration
  under `kioku-migrations/sql-migrations/`), extend `SessionRow`, project the two new events,
  add an awaiting-by-correlation-key query, clear park columns when an awaiting session completes
  or fails, and bump the session read-model shape to version 3 in
  `kioku-core/src/Kioku/Session/ReadModel.hs`. Completed 2026-06-27 after
  `cabal build kioku-core` succeeded; migration file
  `kioku-migrations/sql-migrations/2026-06-27-21-10-35-kioku-awaiting-session-state.sql`
  was scaffolded, filled in, and applied successfully with `just migrate`. A `psql \d+`
  spot-check showed `awaiting_reason`, `awaiting_correlation_key`, `awaiting_deadline`,
  `resume_input`, and `kioku_sessions_awaiting_corr_idx`.
- [x] M4 — Command API: add `awaitInput`, `resume`, and `getAwaitingByCorrelationKey` to
  `kioku-core/src/Kioku/Session.hs`, with the running/awaiting guards and idempotent resume.
  Completed 2026-06-27 after `cabal build kioku-core` succeeded.
- [x] M5 — Tests: add `kioku-core/test/Kioku/AwaitingSpec.hs` exercising park → query → resume,
  aggregate reconstruction after a simulated crash, and idempotent re-delivery; wire it into
  `kioku-core/test/Main.hs` and the test-suite stanza in `kioku-core/kioku-core.cabal`.
  Completed 2026-06-27 after `cabal test kioku-test` passed all 16 tests, including the seven
  awaiting park-and-resume cases.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-27: Keiki cannot recover a command on replay if an input field is only used through a
  derived `TApp1` term. The first implementation used `d.continuation.reason` in
  `SessionAwaitingTermFields`; `cabal build kioku-core` failed because Keiki term records do not
  support nested field projection:

```text
No instance for HasField "reason" (Keiki.Core.Term ... Continuation) ...
```

  Inspecting `Keiki.Core.solveOutput` showed that derived fields are skipped while gathering
  command inputs, and its comment calls a derived-only command slot the hidden-input case. The
  implementation therefore keeps `Continuation` as an exported semantic payload type but makes
  `AwaitInputData` carry `reason`, `correlationKey`, and `deadline` as top-level fields so the
  `SessionAwaiting` event can recover the command during replay.

- 2026-06-27: The checked-in `Justfile` defines `new-migration name=""` as a positional recipe
  parameter. Running `just new-migration name=kioku-awaiting-session-state` passes the literal
  text `name=...` to the recipe and fails validation; the working command is:

```text
just new-migration kioku-awaiting-session-state
```

- 2026-06-27: Kioku migrations are embedded with `file-embed`, so adding a new SQL file is not
  enough to make `kioku-migrate` see it if `Kioku.Migrations` does not recompile. The first
  `just migrate` run was clean but reported only the older delegation migration as pending.
  Touching the marker comment above `embeddedKiokuFiles` in
  `kioku-migrations/src/Kioku/Migrations.hs` forced recompilation, and the next `just migrate`
  applied `2026-06-27-21-10-35-kioku-awaiting-session-state.sql`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Model the awaited thing as a `Continuation` record with three fields — `reason`
  (`Text`), `correlationKey` (`Maybe Text`), `deadline` (`Maybe UTCTime`) — rather than a
  closed Haskell sum type of reasons.
  Rationale: The three consumer features in `shikigami` ("Agent runs as durable keiro
  workflows", "Conversational agent loop bound to danwa", "Multi-agent delegation primitive")
  each have their own reason vocabulary (`"approval"`, `"next_turn"`, `"child_result"`, and
  more to come). A closed enum in kioku would force every new consumer reason to edit kioku and
  ship a migration. A free-form-but-conventional `reason` string keeps kioku a stable library
  while remaining queryable. It is "typed/opaque": typed as `Text`, opaque to kioku, meaningful
  to the consumer.
  Date: 2026-06-27

- Decision: Legal transitions are `Running → Awaiting`, `Awaiting → Running` (via resume),
  `Awaiting → Completed`, and `Awaiting → Failed`. `Awaiting` is **not** a terminal vertex.
  Rationale: A parked run must be able to resume (the whole point), and must also be able to be
  abandoned (completed or failed) without first resuming — e.g. a deadline watcher fails a park
  that timed out, or a supervisor cancels it. Allowing complete/fail directly from `Awaiting`
  avoids a pointless resume-then-fail dance. Keeping `Awaiting` non-terminal means `isTerminal`
  in the transducer is unchanged.
  Date: 2026-06-27

- Decision: `resume` is idempotent on re-delivery, keyed by correlation key. If a session is
  already `running` when `resume` is called, the call returns success without emitting a second
  `SessionResumed` event. If a correlation key is supplied, it must match the parked
  continuation's key or the resume is rejected.
  Rationale: The resumer is typically a queue/stream consumer (pgmq via `keiro`) that may
  deliver the same "input ready" signal more than once (at-least-once delivery). Idempotent
  resume means a duplicate delivery is a harmless no-op, never a double-advance of the run.
  Matching the correlation key prevents a stale or misrouted signal from resuming the wrong
  park.
  Date: 2026-06-27

- Decision: `Awaiting` is distinct from the existing `Interactive` vertex and does not replace
  it.
  Rationale: `Interactive` is a *terminal* classification recorded by `recordInteractive` for
  sessions that were already conversational in the legacy `rei` system (see the legacy decoder
  in `kioku-core/src/Kioku/Session/EventStream.hs`); it marks a session as interactive at
  creation and never transitions further. `Awaiting` is a *live, non-terminal* park inside a
  normal `Running` lifecycle. The two answer different questions ("what kind of session is
  this" vs. "is this run currently parked"), so they coexist.
  Date: 2026-06-27

- Decision: Adding four columns to `SessionRow` requires bumping every session read model from
  `version = 2` / `shapeHash = "kioku-session-v2"` to `version = 3` /
  `shapeHash = "kioku-session-v3"`; `turnsBySessionReadModel` remains `version = 1` /
  `shapeHash = "kioku-turn-v1"` because `TurnRow` and `kioku_turns` do not change.
  Rationale: The current repository already uses `kioku-session-v2` after the delegation
  lineage migration added `parent_session_id` and `delegation_depth`. The awaiting migration
  changes the session read-model row shape again by adding `awaiting_reason`,
  `awaiting_correlation_key`, `awaiting_deadline`, and `resume_input`, so keeping v2 would
  make the read-model metadata lie about its shape.
  Date: 2026-06-27

- Decision: `complete` and `failSession` must dispatch commands from both `running` and
  `awaiting` rows, and completion/failure projections must clear `awaiting_*` columns.
  Rationale: The domain intentionally permits `Awaiting → Completed` and `Awaiting → Failed`
  so supervisors can abandon a park without first resuming it. If the command API kept the
  current "non-running means success without command" guard, those legal domain transitions
  would be unreachable through the public API. If the projection left `awaiting_*` populated
  after completion/failure, the read model would show a terminal row as still carrying an
  active park.
  Date: 2026-06-27

- Decision: `AwaitInputData` carries `reason`, `correlationKey`, and `deadline` as top-level
  fields instead of a nested `Continuation` field; `Continuation` remains exported as the
  library's semantic description of a park, but the transducer command uses the flat shape.
  Rationale: Keiki can only recover command fields from top-level `TInpCtorField` reads in the
  emitted event. A nested `Continuation` would require derived `TApp1` projections for the flat
  `SessionAwaiting` event fields, leaving the original `continuation` command slot hidden and
  unrecoverable during event replay. Flattening the command keeps `SessionAwaiting` flat on the
  durable wire and preserves aggregate reconstitution.
  Date: 2026-06-27


## Outcomes & Retrospective

2026-06-27: Implemented the awaiting lifecycle end to end. Kioku now has a live `Awaiting`
session vertex, `AwaitInput` and `ResumeSession` commands, `SessionAwaiting` and
`SessionResumed` events, durable codec registration, read-model projection columns, an
awaiting-by-correlation-key query, and public `Session.awaitInput`, `Session.resume`, and
`Session.getAwaitingByCorrelationKey` functions. The command API can also complete or fail an
awaiting session directly, and those terminal projections clear the active park columns.

Validation passed with:

```text
cabal build kioku-core
just migrate
psql -h "$PGHOST" -d "$PGDATABASE" -c "\d+ kiroku.kioku_sessions" | rg 'awaiting|resume_input'
cabal test kioku-test
```

The final test run reported `All 16 tests passed`, including the seven new
`Awaiting park-and-resume` cases. The main implementation lesson is that Keiki command payloads
used by emitted events must expose recoverable fields directly; hiding a nested record behind
derived projections breaks command recovery during replay.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**Event sourcing, in this repo.** A session's state is not stored as a mutable row that you
`UPDATE` in place as the source of truth. Instead, every change is an immutable *event* (for
example `SessionStarted`, `SessionCompleted`) appended to an append-only *event stream* (a
named, ordered log of events for one entity). The current state is computed by replaying the
events through a *transducer* — a small state machine that, given the current *vertex* (state)
and an incoming *command*, decides which *event(s)* to emit and which vertex to move to. The
human-friendly queryable form — a row in the `kioku_sessions` table — is a *read model* (also
called a *projection*): a derived cache built by feeding each event to a projection function.
The log is the truth; the table is rebuildable from it. This is why park-and-resume needs no
new durable infrastructure: a park is just another committed event on a log that already
persists and already replays.

**The session state machine lives in
`kioku-core/src/Kioku/Session/Domain.hs`.** Read it before changing it. Key pieces:

- `SessionVertex = NotCreated | Running | Completed | Failed | Interactive` — the set of states.
- `data SessionCommand = StartSession … | CompleteSession … | FailSession … |
  RecordInteractiveSession … | RecordTurn …` — the inputs that drive transitions, each carrying
  a `*Data` record (e.g. `StartSessionData`).
- `data SessionEvent = SessionStarted … | SessionCompleted … | SessionFailed … |
  InteractiveSessionRecorded … | TurnRecorded …` — the durable facts emitted, each with a
  `*Data` record that derives `FromJSON`/`ToJSON` (so it can be serialized into the log).
- `commandSessionId` and `eventSessionId` — total functions mapping each constructor to its
  `SessionId`; every new constructor must be added to both or the code will not compile.
- `$(deriveAggregate ''SessionCommand ''SessionRegs ''SessionEvent)` — a Template Haskell
  splice that generates, for every command constructor `Foo`, a predicate `inCtorFoo` and, for
  every event constructor `Bar`, a wire helper `wireBar` and a `BarTermFields` record used by
  the transducer builder. So adding a command `AwaitInput` automatically yields `inCtorAwaitInput`,
  and adding an event `SessionAwaiting` yields `wireSessionAwaiting` and `SessionAwaitingTermFields`.
- `sessionTransducer` — built with the `Keiki.Builder` DSL (imported as `B`). It reads
  `B.buildTransducer NotCreated emptyRegFile isTerminal do …`, then groups handlers by source
  vertex with `B.from <Vertex> do …`, each handler being `B.onCmd inCtor<Command> $ \d -> B.do {
  B.emit wire<Event> <Event>TermFields{…}; B.goto <Vertex> }`. The `isTerminal` helper at the
  bottom returns `True` for `Completed`, `Failed`, `Interactive`.

**Study the existing complete/fail transition end to end before writing the awaiting one — you
will mirror it exactly.** It threads through four files:

1. *Command → event → vertex* (`kioku-core/src/Kioku/Session/Domain.hs`): under `B.from
   Running`, `B.onCmd inCtorCompleteSession` emits `wireSessionCompleted` and `B.goto Completed`.
2. *Event registration in the codec* (`kioku-core/src/Kioku/Session/EventStream.hs`): the
   `sessionCodec` lists `"SessionCompleted"` in both `eventTypes` (the universe of types) and
   the `eventType` dispatch (mapping a value to its string tag). Events not registered here
   cannot be written or read.
3. *Read-model projection* (`kioku-core/src/Kioku/Session/ReadModel.hs`): `applySessionEvent`
   matches `SessionCompleted d` and runs `updateSessionCompletedStmt`, a hand-written SQL
   `UPDATE kioku_sessions SET status = 'completed', …`. `SessionRow` is the Haskell mirror of
   the table; `sessionRowDecoder`/`sessionRowEncoder` and every `SELECT` column list must agree
   with the table's columns *in order*.
4. *Command API* (`kioku-core/src/Kioku/Session.hs`): `complete` reads the current row via
   `getById`, guards on `row.status`, and on success calls `runSessionCommand` — which invokes
   `Keiro.Projection.runCommandWithProjections` with `sessionEventStream`, `sessionStream sid`,
   the command, and the projection list `[sessionInlineProjection, l1TimerScheduleProjection]`.
   Today `complete` and `failSession` only dispatch when `status == "running"` and otherwise
   return success as an idempotent no-op; this plan changes those guards so they dispatch when
   `status` is either `"running"` or `"awaiting"`. Note `runCommandWithProjections` *hydrates
   the aggregate by reading and replaying the event stream every time* (see `Keiro.Command` in
   the `keiro` dependency) — it does not trust the read model for the transition decision. This
   is the crash-safety guarantee in action.

**The table.** `kioku_sessions` is created in
`kioku-migrations/sql-migrations/2026-06-24-00-00-00-kioku-base.sql`. It already has a `status`
column (`text NOT NULL DEFAULT 'running'`) and a `kioku_sessions_status_idx` index. The
read-model tables live in the `kiroku` Postgres schema (the migrations run `SET search_path TO
kiroku, pg_catalog;`). Migrations are managed by **codd** (a Haskell migration tool); each file
begins with the directive `-- codd: in-txn` (run inside a transaction) and contains idempotent
DDL (`CREATE … IF NOT EXISTS`, and for us `ALTER TABLE … ADD COLUMN IF NOT EXISTS`). Migrations
are embedded into the `kioku-migrate` executable and applied with `just migrate`; the
`Justfile` recipe `just new-migration <slug>` scaffolds a correctly named, timestamped
file.

**Ids.** `SessionId` is defined in `kioku-api/src/Kioku/Id.hs` as `KindID "kioku_session"`;
`genSessionId` mints one, `idText` renders it as `Text`. Correlation keys in this plan are plain
`Text` supplied by the consumer (e.g. an approval id or a `danwa` thread id), not a kioku id
type.

**Tests.** The test suite is `kioku-test` (stanza in `kioku-core/kioku-core.cabal`, entry point
`kioku-core/test/Main.hs`). Tests spin up a real ephemeral Postgres and run kioku's embedded
migrations via `Kioku.Migrations.TestSupport.withKiokuMigratedDatabase` (in
`kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs`), then open a store with
`Kiroku.Store.Connection.withStore (defaultConnectionSettings connStr)`. The existing
`kioku-core/test/Kioku/DistillSpec.hs` is the closest model: it calls `Session.start`,
`Session.recordTurn`, `Session.complete` against a live DB and asserts results. Reuse its setup
shape.


## Plan of Work

The work is five milestones. Each compiles and is independently verifiable. Edits are additive
— we never remove an existing transition or column — so the build stays green throughout and
re-running any step is safe.


### Milestone 1 — Domain: the Awaiting vertex, continuation, commands, events, transitions

Scope: everything in `kioku-core/src/Kioku/Session/Domain.hs`. At the end, the session state
machine knows how to park and resume; the project still builds. There is no persistence wiring
yet, but the pure machine is complete and can be exercised by a transducer-level test.

First, add `Awaiting` to the vertex enum:

```haskell
data SessionVertex = NotCreated | Running | Completed | Failed | Interactive | Awaiting
  deriving stock (Eq, Show, Enum, Bounded)
```

Leave `isTerminal` unchanged — `Awaiting` is deliberately *not* terminal, so a parked session
can still receive commands.

Add the continuation payload — the description of what the session is waiting for. Place it near
the other `*Data` records:

```haskell
-- | What a parked session is waiting for.
--
-- * 'reason' is a typed-but-opaque label the consumer interprets, e.g.
--   "approval", "next_turn", "child_result". kioku does not enumerate reasons;
--   it stores and queries them as text so new consumers need no kioku change.
-- * 'correlationKey' is what a resumer matches on to find this park (an
--   approval id, a danwa thread id, a child session id). Optional because some
--   parks (e.g. "wait for any human") have no specific key.
-- * 'deadline' is an optional wall-clock time after which a watcher may fail or
--   escalate the park.
data Continuation = Continuation
  { reason :: !Text,
    correlationKey :: !(Maybe Text),
    deadline :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
```

Add the command payloads and constructors. `AwaitInputData` intentionally repeats the three
fields of `Continuation` instead of storing a nested `Continuation`: Keiki replay recovers
commands from top-level fields present in emitted events, and the emitted `SessionAwaiting`
event is flat.

```haskell
data AwaitInputData = AwaitInputData
  { sessionId :: !SessionId,
    reason :: !Text,
    correlationKey :: !(Maybe Text),
    deadline :: !(Maybe UTCTime),
    awaitedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data ResumeSessionData = ResumeSessionData
  { sessionId :: !SessionId,
    correlationKey :: !(Maybe Text),
    input :: !Text,
    resumedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
```

Extend `SessionCommand` with `| AwaitInput !AwaitInputData | ResumeSession !ResumeSessionData`,
and add the matching arms to `commandSessionId` (`AwaitInput d -> d.sessionId`,
`ResumeSession d -> d.sessionId`).

Add the event payloads (these must derive `FromJSON`/`ToJSON` — they are serialized to the log)
and constructors. Note the event flattens the continuation into named fields, mirroring how the
other `*Data` events are flat records:

```haskell
data SessionAwaitingData = SessionAwaitingData
  { sessionId :: !SessionId,
    reason :: !Text,
    correlationKey :: !(Maybe Text),
    deadline :: !(Maybe UTCTime),
    awaitedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data SessionResumedData = SessionResumedData
  { sessionId :: !SessionId,
    correlationKey :: !(Maybe Text),
    input :: !Text,
    resumedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
```

Extend `SessionEvent` with `| SessionAwaiting !SessionAwaitingData | SessionResumed
!SessionResumedData`, and add the matching arms to `eventSessionId`.

Finally, add the transitions in `sessionTransducer`. Under the existing `B.from Running do`
block add an `awaitInput` handler; add a new `B.from Awaiting do` block with the resume,
complete, and fail handlers:

```haskell
    B.from Running do
      -- … existing CompleteSession, FailSession, RecordTurn handlers …
      B.onCmd inCtorAwaitInput $ \d -> B.do
        B.emit
          wireSessionAwaiting
          SessionAwaitingTermFields
            { sessionId = d.sessionId,
              reason = d.reason,
              correlationKey = d.correlationKey,
              deadline = d.deadline,
              awaitedAt = d.awaitedAt
            }
        B.goto Awaiting

    B.from Awaiting do
      B.onCmd inCtorResumeSession $ \d -> B.do
        B.emit
          wireSessionResumed
          SessionResumedTermFields
            { sessionId = d.sessionId,
              correlationKey = d.correlationKey,
              input = d.input,
              resumedAt = d.resumedAt
            }
        B.goto Running

      B.onCmd inCtorCompleteSession $ \d -> B.do
        B.emit wireSessionCompleted SessionCompletedTermFields { … same fields as the Running arm … }
        B.goto Completed

      B.onCmd inCtorFailSession $ \d -> B.do
        B.emit wireSessionFailed SessionFailedTermFields { … same fields as the Running arm … }
        B.goto Failed
```

The exact `*TermFields` field names match the generated helpers; copy them verbatim from the
existing `Running` handlers for complete/fail. Acceptance: `cabal build kioku-core` succeeds.


### Milestone 2 — Codec: register the new events on the durable log

Scope: `kioku-core/src/Kioku/Session/EventStream.hs`, function `sessionCodec`. Events must be
declared here or they cannot be encoded into, or decoded from, the event log. At the end, the
two new events round-trip through the stream.

In `sessionCodec`, add `"SessionAwaiting"` and `"SessionResumed"` to the `eventTypes`
non-empty list, and add the two arms to the `eventType` dispatch:

```haskell
      eventType =
        EventType . \case
          SessionStarted {} -> "SessionStarted"
          SessionCompleted {} -> "SessionCompleted"
          SessionFailed {} -> "SessionFailed"
          InteractiveSessionRecorded {} -> "InteractiveSessionRecorded"
          TurnRecorded {} -> "TurnRecorded"
          SessionAwaiting {} -> "SessionAwaiting"
          SessionResumed {} -> "SessionResumed",
```

The `encode`/`decode` are generic (`toJSON` / `parseSessionEvent`) and need no change; the
legacy `rei` decoder (`parseLegacySessionEvent`) is for old data only and does not need the new
tags. Acceptance: `cabal build kioku-core` succeeds.


### Milestone 3 — Read model and migration: awaiting columns, projection, query

Scope: a new migration file plus `kioku-core/src/Kioku/Session/ReadModel.hs`. At the end, the
`kioku_sessions` table has columns describing the current park, the projection writes them when
the new events arrive, and a query can find awaiting sessions by correlation key.

Create the migration with the Justfile scaffolder (from the repo root):

```bash
just new-migration kioku-awaiting-session-state
```

Edit the generated file (path `kioku-migrations/sql-migrations/<timestamp>-kioku-awaiting-session-state.sql`)
to add idempotent column additions and an index for the awaiting-by-correlation-key query:

```sql
-- codd: in-txn

-- Migration: kioku-awaiting-session-state
-- Created: <timestamp> UTC
-- Adds park-and-resume columns to the session read model.
SET search_path TO kiroku, pg_catalog;

ALTER TABLE kioku_sessions ADD COLUMN IF NOT EXISTS awaiting_reason text;
ALTER TABLE kioku_sessions ADD COLUMN IF NOT EXISTS awaiting_correlation_key text;
ALTER TABLE kioku_sessions ADD COLUMN IF NOT EXISTS awaiting_deadline timestamptz;
ALTER TABLE kioku_sessions ADD COLUMN IF NOT EXISTS resume_input text;

CREATE INDEX IF NOT EXISTS kioku_sessions_awaiting_corr_idx
  ON kioku_sessions (namespace, awaiting_correlation_key)
  WHERE status = 'awaiting';
```

The partial index (only rows where `status = 'awaiting'`) keeps the resumer's lookup cheap and
small. Existing rows get `NULL` in the new columns, which is correct — they are not parked.

In `kioku-core/src/Kioku/Session/ReadModel.hs`:

- Add the four fields to `SessionRow` (all `Maybe`): `awaitingReason :: !(Maybe Text)`,
  `awaitingCorrelationKey :: !(Maybe Text)`, `awaitingDeadline :: !(Maybe UTCTime)`,
  `resumeInput :: !(Maybe Text)`. Extend `sessionRowDecoder` with four more `D.column`
  decoders in the same order, and append the four columns to *every* `SELECT` column list (the
  by-id, by-namespace, by-scope, by-focus, by-started-range, and recursive chain statements all
  list columns explicitly and must stay in lockstep with the decoder).
- Extend `upsertSessionStmt` and `sessionRowEncoder` to include the four new columns. For the
  `SessionStarted`/`InteractiveSessionRecorded` upserts, set all four to `Nothing` in
  `startedRow`/`interactiveRow`.
- Add two new arms to `applySessionEvent`:

```haskell
    SessionAwaiting d ->
      Tx.statement
        (idText d.sessionId, d.reason, d.correlationKey, d.deadline)
        updateSessionAwaitingStmt
    SessionResumed d ->
      Tx.statement
        (idText d.sessionId, d.input)
        updateSessionResumedStmt
```

  with the statements:

```haskell
updateSessionAwaitingStmt :: Statement (Text, Text, Maybe Text, Maybe UTCTime) ()
updateSessionAwaitingStmt =
  preparable
    "UPDATE kioku_sessions SET status = 'awaiting', awaiting_reason = $2, \
    \awaiting_correlation_key = $3, awaiting_deadline = $4, updated_at = NOW() \
    \WHERE session_id = $1"
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nullable E.timestamptz))
    )
    D.noResult

updateSessionResumedStmt :: Statement (Text, Text) ()
updateSessionResumedStmt =
  preparable
    "UPDATE kioku_sessions SET status = 'running', resume_input = $2, \
    \awaiting_reason = NULL, awaiting_correlation_key = NULL, awaiting_deadline = NULL, \
    \updated_at = NOW() WHERE session_id = $1"
    (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)))
    D.noResult
```

  Resuming clears the `awaiting_*` columns (the park is over) but keeps `resume_input` as the
  record of the last delivered input. (`contrazip2` comes from `Contravariant.Extras`; it is
  already imported alongside `contrazip3`/`contrazip4` — extend the import list if needed.)

- Because the domain allows `Awaiting → Completed` and `Awaiting → Failed`, update the existing
  `updateSessionCompletedStmt` and `updateSessionFailedStmt` so they clear the active park
  columns while preserving `resume_input`:

```haskell
updateSessionCompletedStmt :: Statement (Text, UTCTime, Maybe Text, Maybe Text) ()
updateSessionCompletedStmt =
  preparable
    "UPDATE kioku_sessions SET status = 'completed', completed_at = $2, model_used = $3, \
    \summary = $4, awaiting_reason = NULL, awaiting_correlation_key = NULL, \
    \awaiting_deadline = NULL, updated_at = NOW() WHERE session_id = $1"
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nullable E.text))
        (E.param (E.nullable E.text))
    )
    D.noResult

updateSessionFailedStmt :: Statement (Text, UTCTime, Text) ()
updateSessionFailedStmt =
  preparable
    "UPDATE kioku_sessions SET status = 'failed', completed_at = $2, error_message = $3, \
    \awaiting_reason = NULL, awaiting_correlation_key = NULL, awaiting_deadline = NULL, \
    \updated_at = NOW() WHERE session_id = $1"
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nonNullable E.text))
    )
    D.noResult
```

- Add the awaiting-by-correlation-key query: a `newtype
  AwaitingSessionsByCorrelationKeyQuery = AwaitingSessionsByCorrelationKeyQuery Text Text`
  (namespace, correlation key), an
  `awaitingSessionsByCorrelationKeyReadModel :: ReadModel AwaitingSessionsByCorrelationKeyQuery [SessionRow]`
  built like the other read models (table `kioku_sessions`, subscription `kioku-session-inline`,
  `version = 3`, `shapeHash = "kioku-session-v3"`), and the statement:

```haskell
selectAwaitingByCorrelationKeyStmt :: Statement AwaitingSessionsByCorrelationKeyQuery [SessionRow]
selectAwaitingByCorrelationKeyStmt =
  preparable
    """
    SELECT <full column list incl. the four new columns>
    FROM kioku_sessions
    WHERE namespace = $1
      AND status = 'awaiting'
      AND awaiting_correlation_key = $2
    ORDER BY started_at DESC
    """
    ( ((\(AwaitingSessionsByCorrelationKeyQuery ns _) -> ns) >$< E.param (E.nonNullable E.text))
        <> ((\(AwaitingSessionsByCorrelationKeyQuery _ k) -> k) >$< E.param (E.nonNullable E.text))
    )
    (D.rowList sessionRowDecoder)
```

  Bump all session read models in this module from `version = 2` /
  `shapeHash = "kioku-session-v2"` to `version = 3` / `shapeHash = "kioku-session-v3"` in the
  same edit. This includes the by-id, by-namespace, by-scope, by-focus, by-started-range,
  chain, delegation-children, and new awaiting-by-correlation-key read models. Do not bump
  `turnsBySessionReadModel`; it still reads `kioku_turns` and uses `kioku-turn-v1`.

Export the new query type, read model, and (if added) statement from the module header.
Acceptance: `cabal build kioku-core` succeeds; `just migrate` applies the new migration with no
error (see Concrete Steps).


### Milestone 4 — Command API: awaitInput, resume, getAwaitingByCorrelationKey

Scope: `kioku-core/src/Kioku/Session.hs`. At the end, callers have ergonomic, guarded,
idempotent park/resume operations, and `complete`/`failSession` can terminate either a running
or awaiting session.

Add to the module export list: `awaitInput`, `resume`, `getAwaitingByCorrelationKey`. Add the
implementations, following the current command pattern (read current row, guard, run command):

```haskell
awaitInput ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  AwaitInputData ->
  Eff es (Either SessionWriteError SessionId)
awaitInput cmdData = do
  existing <- getById cmdData.sessionId
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right Nothing -> pure (Left SessionNotFound)
    Right (Just row)
      | row.status == "awaiting" -> pure (Right cmdData.sessionId) -- already parked: idempotent
      | row.status /= "running" -> pure (Left SessionNotRunning)
      | otherwise -> runSessionCommand cmdData.sessionId (AwaitInput cmdData)

resume ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  ResumeSessionData ->
  Eff es (Either SessionWriteError SessionId)
resume cmdData = do
  existing <- getById cmdData.sessionId
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right Nothing -> pure (Left SessionNotFound)
    Right (Just row)
      | row.status == "running" -> pure (Right cmdData.sessionId) -- already resumed: idempotent no-op
      | row.status /= "awaiting" -> pure (Left SessionNotAwaiting)
      | not (correlationMatches row cmdData) -> pure (Left SessionCorrelationMismatch)
      | otherwise -> runSessionCommand cmdData.sessionId (ResumeSession cmdData)
  where
    correlationMatches row d =
      case d.correlationKey of
        Nothing -> True -- caller did not target a specific key
        Just k -> row.awaitingCorrelationKey == Just k

getAwaitingByCorrelationKey ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  Text ->
  Eff es (Either ReadModelError [SessionRow])
getAwaitingByCorrelationKey ns correlationKey =
  runQueryWith Nothing Eventual awaitingSessionsByCorrelationKeyReadModel
    (AwaitingSessionsByCorrelationKeyQuery (namespaceText ns) correlationKey)
```

Add the two new error constructors `SessionNotAwaiting` and `SessionCorrelationMismatch` to
`SessionWriteError`. Import the new read model and query from `Kioku.Session.ReadModel`.

Also update `complete` and `failSession` so they dispatch from both active states:

```haskell
complete cmdData = do
  existing <- getById cmdData.sessionId
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right Nothing -> pure (Left SessionNotFound)
    Right (Just row)
      | row.status == "running" || row.status == "awaiting" ->
          runSessionCommand cmdData.sessionId (CompleteSession cmdData)
      | otherwise -> pure (Right cmdData.sessionId)

failSession cmdData = do
  existing <- getById cmdData.sessionId
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right Nothing -> pure (Left SessionNotFound)
    Right (Just row)
      | row.status == "running" || row.status == "awaiting" ->
          runSessionCommand cmdData.sessionId (FailSession cmdData)
      | otherwise -> pure (Right cmdData.sessionId)
```

The terminal-state no-op keeps existing idempotent `complete`/`failSession` behavior for
already completed, failed, or interactive sessions, while making the new legal awaiting
transitions reachable. The idempotency guards live here in the command API; the transducer
remains the durable backstop because
`runCommandWithProjections` rehydrates from the log and would reject an illegal transition even
if a guard were bypassed. Acceptance: `cabal build kioku-core` succeeds.


### Milestone 5 — Tests: park, query, resume, crash reconstruction, idempotence

Scope: a new `kioku-core/test/Kioku/AwaitingSpec.hs`, wired into `kioku-core/test/Main.hs` and
the `other-modules` of the `kioku-test` stanza in `kioku-core/kioku-core.cabal`. At the end,
`cabal test` exercises the full lifecycle against a real ephemeral Postgres and proves the
behavior end to end.

Model the test setup on `kioku-core/test/Kioku/DistillSpec.hs`: wrap the body in
`withKiokuMigratedDatabase \connStr -> withStore (defaultConnectionSettings connStr) \st -> …`
and run the session operations inside `runAppIO`. The test cases (see Validation and
Acceptance for the exact assertions):

1. `testParkAndResume` — start, awaitInput, assert `status == "awaiting"` and awaiting columns,
   assert the tail event is `SessionAwaiting`, resume, assert `status == "running"` and
   `resumeInput == Just …`, assert a `SessionResumed` event was appended.
2. `testFindAwaitingByCorrelationKey` — park two sessions with different correlation keys and
   confirm `getAwaitingByCorrelationKey` returns only the matching one.
3. `testReconstructAfterCrash` — park a session; read its event stream forward with
   `Kiroku.Store.Read.readStreamForward (Stream.streamName (sessionStream sid)) (StreamVersion
   0) 100`, decode each `RecordedEvent.payload` with `parseSessionEvent`, and confirm the
   replayed events end in `SessionAwaiting`; then call `resume` (which rehydrates the aggregate
   purely from the log) and confirm it succeeds — proving the park survives without trusting the
   read-model row. Import `Keiro.Stream qualified as Stream` and `Kiroku.Store.Types
   (RecordedEvent (..), StreamVersion (..))` for this test shape.
4. `testIdempotentResume` — park, resume once (status running), resume again with the same data
   and assert the second call returns `Right` and that exactly one `SessionResumed` event exists
   in the stream.
5. `testCorrelationMismatchRejected` — park with key `"k1"`, resume with key `Just "k2"`, assert
   `Left SessionCorrelationMismatch`.
6. `testCompleteAwaitingSession` — park a session, call `Session.complete`, assert the row is
   `status == "completed"` and all `awaiting_*` fields are `Nothing`, and assert the stream has
   `SessionStarted`, `SessionAwaiting`, `SessionCompleted` in order.
7. `testFailAwaitingSession` — park a session, call `Session.failSession`, assert the row is
   `status == "failed"` and all `awaiting_*` fields are `Nothing`, and assert the stream has
   `SessionStarted`, `SessionAwaiting`, `SessionFailed` in order.

Acceptance: `cabal test kioku-test` passes, including the seven new cases.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kioku` inside the nix
dev shell (which sets the `PG*` environment variables and provides `cabal`, `just`, `psql`, and
`codd`). If you are not already in the shell, enter it with `nix develop` (or rely on `direnv`,
which this repo configures via `.envrc`).

Build the core library after each of Milestones 1, 2, 3, and 4:

```bash
cabal build kioku-core
```

Expected (abbreviated) on success:

```text
[ 1 of 1] Compiling Kioku.Session.Domain ...
Linking ...
```

Scaffold and apply the migration (Milestone 3). First create the dev database if it does not
exist, then run migrations:

```bash
just new-migration kioku-awaiting-session-state
# edit the generated sql-migrations/<timestamp>-kioku-awaiting-session-state.sql per the plan
just create-database   # idempotent: creates the DB if missing, then runs `just migrate`
just migrate           # re-running is safe; ALTER TABLE ... IF NOT EXISTS is idempotent
```

Expected tail of `just migrate` (codd reports the applied migrations); the key signal is a
clean exit with no SQL error:

```text
Applying <timestamp>-kioku-awaiting-session-state.sql
... All migrations applied successfully
```

Verify the columns landed (optional spot check):

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "\d+ kiroku.kioku_sessions" | grep awaiting
```

Expected:

```text
 awaiting_reason          | text
 awaiting_correlation_key | text
 awaiting_deadline        | timestamptz
```

Run the test suite (Milestone 5):

```bash
cabal test kioku-test
```

Expected tail:

```text
kioku
  Awaiting park-and-resume
    park then resume:                          OK
    find awaiting by correlation key:          OK
    reconstruct aggregate after crash:         OK
    idempotent resume on re-delivery:          OK
    correlation mismatch is rejected:          OK
    complete an awaiting session:              OK
    fail an awaiting session:                  OK

All N tests passed
```


## Validation and Acceptance

Acceptance is behavioral, demonstrated by the Milestone-5 tests against a real Postgres. The
load-bearing observations:

- **Park is visible in the read model.** After `Session.start` then `Session.awaitInput` with
  `AwaitInputData { reason = "approval", correlationKey = Just "approval_req_1", deadline =
  Nothing, ... }`, `Session.getById sid` returns a row with `status == "awaiting"`,
  `awaitingReason == Just "approval"`, and `awaitingCorrelationKey == Just "approval_req_1"`.

- **Park is durable in the log.** Reading the entity stream with
  `Kiroku.Store.Read.readStreamForward (Stream.streamName (sessionStream sid)) (StreamVersion
  0) 100` and decoding each `RecordedEvent.payload` with `parseSessionEvent` yields, in order,
  `SessionStarted` then `SessionAwaiting` carrying the same reason and correlation key. This is
  the source of truth, independent of the table.

- **A resumer can find the park.** `Session.getAwaitingByCorrelationKey (Namespace "test")
  "approval_req_1"` returns exactly the parked session; the same call for `"approval_req_2"`
  returns `[]`.

- **Resume advances the run and records the input.** After `Session.resume (ResumeSessionData {
  sessionId = sid, correlationKey = Just "approval_req_1", input = "approved", resumedAt = now
  })`, `getById` shows `status == "running"`, `resumeInput == Just "approved"`, and the awaiting
  columns are back to `Nothing`. The stream's tail event is `SessionResumed` carrying `input ==
  "approved"`.

- **Crash survival.** Re-issue `resume` for a session whose only knowledge is the event log:
  the call rehydrates the aggregate by replaying `SessionStarted, SessionAwaiting` (it does not
  read the table to decide the transition), lands in `Awaiting`, and accepts the resume. This
  proves the parked state lives in the durable log, not in volatile process memory.

- **Idempotent re-delivery.** Calling `resume` a second time with the same data returns `Right
  sid` and leaves exactly one `SessionResumed` event in the stream (count them by reading the
  stream forward).

- **Targeted resume.** `resume` with `correlationKey = Just "wrong-key"` against a park keyed
  `"approval_req_1"` returns `Left SessionCorrelationMismatch` and emits no event.

- **Awaiting sessions can terminate without resume.** After parking a session, `Session.complete`
  appends `SessionCompleted`, sets `status == "completed"`, and clears the `awaiting_*` fields.
  The analogous `Session.failSession` path appends `SessionFailed`, sets `status == "failed"`,
  preserves the failure message, and clears the `awaiting_*` fields.

These tests fail to compile (and then fail to pass) before the implementation and pass after,
which is the proof beyond compilation.


## Idempotence and Recovery

Every step in this plan is safe to repeat.

- **Migration.** The new migration uses `ALTER TABLE … ADD COLUMN IF NOT EXISTS` and `CREATE
  INDEX IF NOT EXISTS`, so `just migrate` can be run any number of times with no drift. codd
  also tracks applied migrations and will not re-run a completed one.

- **Build/test.** `cabal build` and `cabal test` are naturally idempotent. The test suite uses
  an ephemeral, cached Postgres (`EphemeralPg`/`withKiokuMigratedDatabase`), so it never
  mutates a developer database.

- **`awaitInput`.** Calling it on a session already `awaiting` returns success without emitting
  a second `SessionAwaiting` (the command-API guard); calling it on a `completed`/`failed`
  session returns `Left SessionNotRunning`. No double-park.

- **`resume`.** Calling it on a session already `running` (the common re-delivery case from an
  at-least-once queue) returns success without emitting a second `SessionResumed`. Calling it
  with a mismatched correlation key returns `Left SessionCorrelationMismatch` and changes
  nothing. The transducer is the backstop: even if a guard were bypassed, replaying the log
  would reject a resume from a non-`Awaiting` vertex, so the durable state can never be
  corrupted.

- **`complete`/`failSession` from `awaiting`.** These calls are safe to retry. The first call
  appends the terminal event and clears the active park columns; later calls see a terminal row
  and return success without emitting another event, matching the pre-existing idempotent
  terminal behavior.

- **Recovery from a half-applied change.** Because all edits are additive and each milestone
  builds on its own, you can stop after any milestone with a green build. If the migration is
  edited and re-run, the `IF NOT EXISTS` clauses make partial application harmless. There is no
  destructive operation anywhere in this plan; rollback is simply reverting the source edits
  (the added columns are nullable and ignored by older code).


## Interfaces and Dependencies

This plan stays within kioku and its existing dependency set; no new libraries are introduced.
It uses `keiro` (event-sourcing command/projection runtime: `Keiro.Projection.runCommandWithProjections`,
`Keiro.Command.defaultRunCommandOptions`, `Keiro.ReadModel.runQueryWith`), `kiroku` (the event
store: `Kiroku.Store.Connection.withStore`, `Kiroku.Store.Read.readStreamForward`), `keiki` (the
transducer builder DSL `Keiki.Builder` and `deriveAggregate`), and `hasql`/`hasql-transaction`
for the read-model SQL.

The following must exist at the end of the named milestones (full module paths):

End of Milestone 1 — `kioku-core/src/Kioku/Session/Domain.hs`:

```haskell
data SessionVertex = NotCreated | Running | Completed | Failed | Interactive | Awaiting

data Continuation = Continuation
  { reason :: !Text, correlationKey :: !(Maybe Text), deadline :: !(Maybe UTCTime) }

data AwaitInputData = AwaitInputData
  { sessionId :: !SessionId, reason :: !Text, correlationKey :: !(Maybe Text)
  , deadline :: !(Maybe UTCTime), awaitedAt :: !UTCTime }

data ResumeSessionData = ResumeSessionData
  { sessionId :: !SessionId, correlationKey :: !(Maybe Text), input :: !Text, resumedAt :: !UTCTime }

-- SessionCommand gains:   AwaitInput !AwaitInputData | ResumeSession !ResumeSessionData
-- SessionEvent   gains:   SessionAwaiting !SessionAwaitingData | SessionResumed !SessionResumedData

data SessionAwaitingData = SessionAwaitingData
  { sessionId :: !SessionId, reason :: !Text, correlationKey :: !(Maybe Text)
  , deadline :: !(Maybe UTCTime), awaitedAt :: !UTCTime }

data SessionResumedData = SessionResumedData
  { sessionId :: !SessionId, correlationKey :: !(Maybe Text), input :: !Text, resumedAt :: !UTCTime }

-- sessionTransducer gains: Running --AwaitInput--> Awaiting; Awaiting --ResumeSession--> Running;
--                          Awaiting --CompleteSession--> Completed; Awaiting --FailSession--> Failed
```

These new types and constructors must be added to the module's export list, and to
`commandSessionId` and `eventSessionId`.

End of Milestone 2 — `kioku-core/src/Kioku/Session/EventStream.hs`: `sessionCodec` lists and
dispatches `"SessionAwaiting"` and `"SessionResumed"`.

End of Milestone 3 — `kioku-core/src/Kioku/Session/ReadModel.hs`:

```haskell
-- SessionRow gains: awaitingReason, awaitingCorrelationKey :: Maybe Text
--                   awaitingDeadline :: Maybe UTCTime; resumeInput :: Maybe Text

data AwaitingSessionsByCorrelationKeyQuery = AwaitingSessionsByCorrelationKeyQuery Text Text -- namespace, key
awaitingSessionsByCorrelationKeyReadModel :: ReadModel AwaitingSessionsByCorrelationKeyQuery [SessionRow]

-- applySessionEvent gains arms for SessionAwaiting (updateSessionAwaitingStmt)
--                                  and SessionResumed (updateSessionResumedStmt)
-- updateSessionCompletedStmt/updateSessionFailedStmt clear awaiting_* columns.
```

plus the migration file `kioku-migrations/sql-migrations/<timestamp>-kioku-awaiting-session-state.sql`
adding the four columns and the partial index. Every session read model in this module uses
`version = 3` and `shapeHash = "kioku-session-v3"` after this milestone; the turns read model
remains `kioku-turn-v1`.

End of Milestone 4 — `kioku-core/src/Kioku/Session.hs`:

```haskell
awaitInput :: (IOE :> es, Store :> es, Error StoreError :> es)
           => AwaitInputData -> Eff es (Either SessionWriteError SessionId)

resume :: (IOE :> es, Store :> es, Error StoreError :> es)
       => ResumeSessionData -> Eff es (Either SessionWriteError SessionId)

getAwaitingByCorrelationKey :: (IOE :> es, Store :> es)
                            => Namespace -> Text -> Eff es (Either ReadModelError [SessionRow])

-- SessionWriteError gains: SessionNotAwaiting | SessionCorrelationMismatch
```

End of Milestone 5 — `kioku-core/test/Kioku/AwaitingSpec.hs` exporting `tests :: TestTree`,
referenced from `kioku-core/test/Main.hs` and listed in `other-modules` of the `kioku-test`
suite in `kioku-core/kioku-core.cabal`.

**Consumers (downstream, not built here).** The three `shinzui/shikigami` ExecPlans below depend
on this API and are the reason its shape is what it is; this plan must land first:

- "Agent runs as durable keiro workflows" — `awaitApproval` calls `awaitInput` with reason
  `"approval"` and correlation key = approval request id; the approval signal's consumer calls
  `getAwaitingByCorrelationKey` then `resume`.
- "Conversational agent loop bound to danwa" — parks between human turns with reason
  `"next_turn"` and correlation key = `danwa` thread id; the next inbound message resumes.
- "Multi-agent delegation primitive" — a parent parks with reason `"child_result"` and
  correlation key = child session id; the child's completion resumes the parent.


## Revision Notes

2026-06-27: Validation update. Corrected stale read-model version guidance from v1/v2 to the
current v2 → v3 migration path, made the public `complete`/`failSession` API reachable from
`awaiting` sessions to match the planned domain transitions, required completion/failure
projections to clear active park columns, and tightened event-log test instructions to decode
`RecordedEvent.payload` from `readStreamForward (Stream.streamName (sessionStream sid))`.
