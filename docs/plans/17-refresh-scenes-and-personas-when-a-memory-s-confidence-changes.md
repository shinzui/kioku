---
id: 17
slug: refresh-scenes-and-personas-when-a-memory-s-confidence-changes
title: "Refresh scenes and personas when a memory's confidence changes"
kind: exec-plan
created_at: 2026-07-11T19:57:52Z
intention: "intention_01kwyhabypepdt1mwemmf0dvqa"
master_plan: "docs/masterplans/3-kioku-follow-up-scene-freshness-and-filtered-ann-recall-quality.md"
---

# Refresh scenes and personas when a memory's confidence changes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

kioku stores an agent's long-term memories in Postgres and periodically asks an LLM to write a
prose summary of each *scope* — a "scene" — which is saved to a database table and mirrored to a
plaintext Markdown file the agent can read. Whenever the memories a scene is built from change,
kioku schedules a background job (a "timer") to rewrite that scene.

One kind of change is missing from that rule. A memory carries a **confidence** (`high`,
`medium`, or `low`), and a host can lower it — the ordinary way an agent says "I am no longer
sure about this". That confidence is baked into the scene: it is hashed into the scene's source
fingerprint and it is written into the LLM's prompt, so the scene literally says things like
"(preference, high): prefers concise answers". But `MemoryConfidenceUpdated` schedules nothing.
The scene keeps asserting the old confidence forever — until some *unrelated* memory happens to
be recorded in the same scope and incidentally drags the scene back into sync.

So today an agent can downgrade a belief to `low` confidence and then read a scene file that
still presents it as `high`. That is the bug this plan fixes. After it, changing a memory's
confidence refreshes that scope's scene, and — because scene regeneration already cascades into
persona regeneration — the persona and both mirror files follow.

You can see it working end to end by running the test suite, which after this plan contains a
case that lowers a memory's confidence and then asserts that the scene row, the persona row,
and the `.kioku/scenes/*.md` mirror file on disk all reflect the new value:

```bash
nix develop --command cabal test kioku-core:test:kioku-test
```

The case is named "a confidence change refreshes the scene, the persona, and the mirrors". It
fails before this plan (the scene keeps the stale confidence) and passes after.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add a `MemoryConfidenceUpdated` arm to `scheduleSceneTimersForEvent` in `kioku-core/src/Kioku/Distill/L2.hs`, deriving the timer's source id from the recorded event's id so repeated confidence changes each get their own timer.
- [ ] M1: Thread the `RecordedEvent` (currently ignored as `_recorded`) into `scheduleSceneTimersForEvent`.
- [ ] M1: Unit test — a confidence change schedules exactly one scene timer, and two successive confidence changes on the same memory schedule two distinct timers (the regression the naive fix would introduce).
- [ ] M2: End-to-end test — lowering a memory's confidence refreshes the scene row, the persona row, and both mirror files.
- [ ] M2: Confirm `MemoryTagsUpdated` still schedules nothing, with a test that pins the reason.
- [ ] M2: Full suite green; update this plan's Outcomes and the MasterPlan's Progress/Registry.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (Pre-implementation research, 2026-07-11.) **The fix is one case arm, but the naive version of
  that arm introduces a worse bug than it fixes.** keiro's `scheduleTimerTx` re-arms a
  conflicting timer id only while that timer is still in the `scheduled` state; once the timer
  has fired, re-scheduling the same id is **silently dropped**. This is recorded in the code
  itself, at `kioku-core/src/Kioku/Distill/L2.hs:133-136`, which is why the forget events suffix
  their timer's source id with the event kind rather than reusing the record-time id. Confidence
  — unlike archiving, superseding, and merging — can change *repeatedly* on the same memory. So a
  source id of `<memoryId>:confidence` would refresh the scene on the first confidence change
  and then silently never again, which would look fixed and pass a naive test. The source id
  must vary per event. **This is exactly why the previous initiative's EP-2 deferred this work**
  (docs/plans/10-…, Decision 7) rather than folding it in with the forget arms.

- (Pre-implementation research, 2026-07-11.) **The event id is available and is a better
  discriminator than the update timestamp.** The MasterPlan and EP-2's deferral note both assumed
  the fix would need "the update timestamp mixed in". It does not have to. keiro's
  `InlineProjection` is
  `data InlineProjection co = InlineProjection { name :: Text, apply :: co -> RecordedEvent -> Tx.Transaction () }`
  (verified in the pinned source at
  `dist-newstyle/src/keiro-*/keiro/src/Keiro/Projection.hs:61-64`), and kioku's scene-timer
  projection currently *ignores* that second argument — `apply = \event _recorded -> …`
  (`kioku-core/src/Kioku/Distill/L2.hs:107`). `RecordedEvent` carries
  `eventId :: EventId` ("the event's stable id (UUIDv7 by default)",
  `dist-newstyle/src/kiroku-*/kiroku-store/src/Kiroku/Store/Types.hs:209-211`). An event id is
  unique per event, stable across replay and re-projection, and — unlike the caller-supplied
  `updatedAt` timestamp — not something a host controls. The previous initiative's EP-4 learned
  the hard way that caller-supplied timestamps are a poor identity ingredient. Decision 2 below
  records the choice.

- (Pre-implementation research, 2026-07-11.) **`MemoryTagsUpdated` scheduling nothing is
  correct, and must be left alone.** `scheduleSceneTimersForEvent` has two fall-through arms, so
  the obvious assumption is that this plan should fix both. It should not. A scene is built from
  `atomSource` (`kioku-core/src/Kioku/Distill/L2.hs:341-343`), which is
  `(memoryId, content, priority, confidence, createdAt)`, and the LLM sees `renderAtom`
  (`L2.hs:349-358`), which renders the memory id, type, confidence, and content. **Tags appear in
  neither.** Scheduling a regeneration on a tag change would spend an LLM call to produce a
  byte-identical scene. M2 adds a test that pins this reasoning so a future reader does not
  "fix" it.

- (Pre-implementation research, 2026-07-11.) **The keiro upsert that causes the silent drop,
  quoted exactly.** From the pinned source, `scheduleTimerStmt` in
  `dist-newstyle/src/keiro-*/keiro/src/Keiro/Timer/Schema.hs`:

  ```sql
  INSERT INTO keiro_timers
    (timer_id, process_manager_name, correlation_id, fire_at, payload, status)
  VALUES ($1, $2, $3, $4, $5, $6)
  ON CONFLICT (timer_id) DO UPDATE
    SET process_manager_name = EXCLUDED.process_manager_name,
        correlation_id = EXCLUDED.correlation_id,
        fire_at = EXCLUDED.fire_at,
        payload = EXCLUDED.payload,
        status = EXCLUDED.status,
        updated_at = now()
    WHERE keiro_timers.status = 'scheduled'
  ```

  The trailing `WHERE keiro_timers.status = 'scheduled'` is the whole hazard: a re-scheduled
  duplicate id whose timer has already fired matches the `ON CONFLICT` and then updates **zero
  rows**. No error, no insert. This is also the mechanism behind the *desirable* debounce
  (`Kioku/Distill/Timer.hs:48-56` explains it for L1: fifty recorded turns push one idle timer
  forward rather than inserting fifty).

- (Pre-implementation research, 2026-07-11.) **There is an in-repo precedent for varying a
  UUIDv5 timer id, and an invariant this plan must be careful not to break.** `l3PersonaTimerId`
  (`kioku-core/src/Kioku/Distill/L3.hs:105-117`) already folds a `UTCTime` into its UUIDv5 name
  via `Text.pack (show fireAt)`. But `kioku-core/src/Kioku/Distill/Timer.hs:48-49` states the
  rule that governs the *projection* side: "Every timer id is a UUIDv5 over **stable event data
  only**, never over `fireAt`, so re-projecting a session's events can never double-schedule."
  L3 is allowed its `fireAt` because it is scheduled from `regenerateScene` (a worker-side call
  with a live clock), not from an inline projection that replay re-runs. **This plan schedules
  from a projection, so it must use stable event data.** The event id qualifies — it is assigned
  at append time and persisted, so a replay of the same event yields the same id. The payload's
  `updatedAt` would also qualify. A wall-clock `now` would not, and would double-schedule on
  every re-projection. Decision 2 chooses the event id; this note records why either of the two
  legal choices is legal and the illegal one is illegal.

- (Pre-implementation research, 2026-07-11.) **`updateConfidence` already refuses to emit a
  no-op event, so this fix cannot produce spurious timers.** `Kioku.Memory.updateConfidence`
  (`kioku-core/src/Kioku/Memory.hs:123-135`) short-circuits when the stored confidence already
  equals the requested one: `| row.confidence == confidenceToText cmdData.confidence -> pure
  (Right cmdData.memoryId)`. No event, therefore no projection run, therefore no timer. Setting
  `high` on a memory that is already `high` costs nothing. (It also means a test cannot schedule
  a second timer by re-applying the *same* confidence — the two-changes test must genuinely walk
  `high → medium → low`.)

- (Pre-implementation research, 2026-07-11.) **`Memory.updateConfidence` has no other call sites
  in the repository and no existing test.** It is a library-only API — there is no CLI command
  for it. So this plan is writing the first test of that command as well as fixing the scheduling
  gap, and there is no caller whose behavior could change underneath it.

- (Pre-implementation research, 2026-07-11.) **The existing source-hash guard is what keeps this
  fix from amplifying LLM cost, and it means a redundant timer is nearly free.**
  `regenerateScene` computes `sceneSourceHash` over the scope's atoms and skips the LLM call
  entirely when it is unchanged (`kioku-core/src/Kioku/Distill/L2.hs:337-339` and the
  short-circuit in `regenerateScene`). This is why the current design can afford to schedule one
  scene timer per *recorded memory* without N memories costing N LLM calls: the first timer to
  fire regenerates, and the rest observe an unchanged hash and skip. This plan inherits that
  protection. A confidence change *does* alter the hash, because confidence is in `atomSource` —
  so it regenerates exactly once, and any extra timers cost a hash comparison rather than an LLM
  call.


## Decision Log

Record every decision made while working on the plan.

- Decision 1: Add exactly one arm — `MemoryConfidenceUpdated` — to `scheduleSceneTimersForEvent`.
  Leave `MemoryTagsUpdated -> pure ()` untouched.
  Rationale: Confidence is in both the scene's source hash (`atomSource`) and the LLM prompt
  (`renderAtom`); tags are in neither, so a tag change cannot alter the scene and a regeneration
  for it would burn an LLM call to rewrite an identical row. See Surprises for the exact lines.
  Date: 2026-07-11

- Decision 2: The scene timer's source id for a confidence change is
  `<memoryId>:confidence:<eventId>`, using the id of the `RecordedEvent` that the inline
  projection is applying — **not** a fixed `<memoryId>:confidence`, and **not** the payload's
  `updatedAt` timestamp.
  Rationale: It must vary per event, or keiro silently drops every confidence change after the
  first (see Surprises — this is the crux of the whole plan). Between the two candidates that
  vary, the event id is strictly better than the timestamp. It is unique by construction, whereas
  two confidence updates bearing the same caller-supplied `updatedAt` would collide and the
  second would be silently dropped — a subtle, load-dependent version of the very bug being
  fixed. It is stable across replay and re-projection, so a re-projected event derives the same
  timer id and cannot double-schedule. And it is not host-controlled: the previous initiative's
  EP-4 established, with evidence, that caller-supplied timestamps are unsafe as an identity
  ingredient (it had to remove them from the idempotency contract after they broke L1's re-fire
  path). The event id costs nothing to obtain — the projection already receives the
  `RecordedEvent` and currently throws it away.
  Date: 2026-07-11

- Decision 3: Reuse `scheduleForgetTimerTx`'s scope lookup rather than adding the scope to the
  `MemoryConfidenceUpdated` payload.
  Rationale: `MemoryConfidenceUpdatedData` carries only `{ memoryId, confidence, updatedAt }`
  (`kioku-core/src/Kioku/Memory/Domain.hs:148-152`) — no scope, exactly like the forget events.
  The forget path already solves this by reading the scope columns back from the `kioku_memories`
  read-model row inside the same transaction, and that row is guaranteed to exist for the same
  reason (the aggregate only accepts a confidence-update command for an `Active` memory, which
  implies a committed `MemoryRecorded` whose inline projection upserted the row). Changing the
  event payload would be an event-schema change requiring a decoder migration for zero benefit.
  Date: 2026-07-11

- Decision 4: Reuse the existing 5-second debounce (`sceneDebounceSeconds`) and fire at
  `updatedAt + 5s`, matching every other arm.
  Rationale: Consistency, and the debounce exists so that a burst of writes to one scope
  coalesces into roughly one regeneration rather than one per write. A confidence change is no
  different in kind. No new tunable is introduced.
  Date: 2026-07-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

kioku is an event-sourced agent-memory library in Haskell (GHC 9.12, built with `cabal`, entered
through a Nix development shell). "Event-sourced" means every write is an immutable event
appended to a Postgres-backed log; the tables you query are *read models* rebuilt from that log.
There is no `UPDATE` in the domain sense and no delete — a memory is changed by appending a new
event.

All commands in this plan run from the repository root,
`/Users/shinzui/Keikaku/bokuno/kioku`. Enter the toolchain with `nix develop` (or prefix each
command with `nix develop --command`). Format any Haskell file you edit with
`fourmolu -i <file>` (config: `fourmolu.yaml`). The repository is a Cabal multi-package project;
the only package this plan touches is `kioku-core`.

### The vocabulary you need

A **memory** is one atom of knowledge: a row in `kiroku.kioku_memories` with a `content`, a
`memory_type` (`preference`, `fact`, …), a `priority` (0–100), a **confidence** (`high`,
`medium`, `low`), and a **scope**.

A **scope** is where a memory lives — `ScopeGlobal namespace` or `ScopeEntity namespace kind ref`
(`kioku-api/src/Kioku/Api/Scope.hs`), written on the command line as `NAMESPACE` or
`NAMESPACE:KIND:REF`.

**Distillation** is kioku's LLM-driven summarisation pipeline, in three layers. **L1** turns a
conversation session into memory atoms. **L2** turns the memories of one scope into a *scene* — a
short prose summary — stored in `kiroku.kioku_scenes` and mirrored to a Markdown file under
`.kioku/scenes/`. **L3** turns a scope's scenes into a *persona*, stored in
`kiroku.kioku_personas` and mirrored under `.kioku/persona/`. This plan is entirely about L2's
*scheduling*, and touches L3 only by observing that it follows.

A **timer** is a scheduled background job, provided by the `keiro` framework and stored in a
`keiro_timers` table. A `TimerRequest` carries a `timerId`, a `processManagerName` (which
handler should run it — here `kioku-l2-scene`), a `correlationId`, a `fireAt` time, and a JSON
`payload`. The `kioku worker` process claims due timers and dispatches them. Timer ids are
deterministic: `l2SceneTimerId` derives a UUIDv5 from the process-manager name, the scope's
identity string, and a caller-supplied **source id**, so the same inputs always produce the same
timer id and re-projecting an event cannot double-schedule.

An **inline projection** is a function keiro runs *inside the same database transaction that
appends the event*. kioku uses one to schedule scene timers, so scheduling is atomic with the
write: if the event commits, the timer exists.

### The exact code, as it stands today

The scheduling projection lives in `kioku-core/src/Kioku/Distill/L2.hs`. Lines 103-126:

```haskell
l2SceneTimerScheduleProjection :: InlineProjection MemoryEvent
l2SceneTimerScheduleProjection =
  InlineProjection
    { name = "kioku-l2-scene-timer-schedule",
      apply = \event _recorded -> scheduleSceneTimersForEvent event
    }

-- | Every event that changes which memories a scope's scene is built from must
-- schedule a regeneration. Forgetting is such a change: without this, archived,
-- superseded, and merged content survives in the scene row and its plaintext
-- mirror until some unrelated memory happens to be recorded in the same scope.
scheduleSceneTimersForEvent :: MemoryEvent -> Tx.Transaction ()
scheduleSceneTimersForEvent = \case
  MemoryRecorded d ->
    scheduleTimerTx $
      l2SceneTimerRequest
        d.scope
        (idText (d.memoryId :: MemoryId))
        (addUTCTime sceneDebounceSeconds d.recordedAt)
  MemoryArchived d -> scheduleForgetTimerTx d.memoryId "archived" d.archivedAt
  MemorySuperseded d -> scheduleForgetTimerTx d.memoryId "superseded" d.supersededAt
  MemoryMerged d -> scheduleForgetTimerTx d.memoryId "merged" d.mergedAt
  MemoryTagsUpdated _ -> pure ()
  MemoryConfidenceUpdated _ -> pure ()          -- <-- the bug
```

Note `apply = \event _recorded -> …`: the `RecordedEvent` is received and discarded. That is the
argument this plan needs.

The scope-lookup helper the forget events use, lines 128-145 — read its comment, because it is
the single most important paragraph in this plan:

```haskell
-- | The forget events carry no scope, so it is read back from the read-model row
-- inside this same transaction. The row is guaranteed present: the aggregate only
-- accepts a forget command from @Active@, which implies a committed
-- @MemoryRecorded@ whose inline projection upserted the row.
--
-- The source id is suffixed with the event kind rather than reusing the record
-- path's bare memory id, because keiro's 'scheduleTimerTx' re-arms a conflicting
-- timer only while it is still @scheduled@ — reusing the record-time id would be
-- silently dropped once that timer has fired, which by then it almost always has.
scheduleForgetTimerTx :: MemoryId -> Text -> UTCTime -> Tx.Transaction ()
scheduleForgetTimerTx memoryId kind occurredAt = do
  scopeCols <- Tx.statement (idText memoryId) selectMemoryScopeColumnsStmt
  for_ scopeCols \(ns, sk, sr) ->
    scheduleTimerTx $
      l2SceneTimerRequest
        (scopeFromColumns ns sk sr)
        (idText memoryId <> ":" <> kind)
        (addUTCTime sceneDebounceSeconds occurredAt)
```

The timer-id derivation, lines 147-169:

```haskell
l2SceneTimerRequest :: MemoryScope -> Text -> UTCTime -> TimerRequest
l2SceneTimerRequest scope sourceId fireAt =
  TimerRequest
    { timerId = l2SceneTimerId scope sourceId,
      processManagerName = l2SceneProcessManagerName,
      correlationId = scopeIdentity scope,
      fireAt,
      payload = Aeson.toJSON (SceneTimerPayload scope)
    }

l2SceneTimerId :: MemoryScope -> Text -> TimerId
l2SceneTimerId scope sourceId =
  TimerId $
    UUIDv5.generateNamed
      l2SceneTimerNamespace
      (BS.unpack (TE.encodeUtf8 raw))
  where
    raw =
      l2SceneProcessManagerName <> ":" <> scopeIdentity scope <> ":" <> sourceId
```

What a scene is *made of*, lines 337-358 — this is why confidence matters and tags do not:

```haskell
sceneSourceHash :: [MemoryRecord] -> Text
sceneSourceHash atoms =
  "v1:" <> Text.pack (show (Hash.hash (BL.toStrict (Aeson.encode (atomSource <$> atoms))) :: Digest SHA256))

atomSource :: MemoryRecord -> (Text, Text, Int, Text, UTCTime)
atomSource atom =
  (atom.memoryId, atom.content, atom.priority, atom.confidence, atom.createdAt)

renderAtom :: MemoryRecord -> Text
renderAtom atom =
  "- " <> atom.memoryId <> " (" <> atom.memoryType <> ", " <> atom.confidence <> "): " <> atom.content
```

And the cascade into L3, inside `regenerateScene` (line 236): after upserting the scene row it
calls `scheduleL3PersonaTimerTx scope now`. **You do not need to touch `Kioku/Distill/L3.hs`.**
Personas follow from scenes automatically; your job is to test that they do.

The event payload you will match on, `kioku-core/src/Kioku/Memory/Domain.hs:148-152`:

```haskell
data MemoryConfidenceUpdatedData = MemoryConfidenceUpdatedData
  { memoryId :: !MemoryId,
    confidence :: !Confidence,
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
```

It carries no scope — hence Decision 3.

The `RecordedEvent` you will start using, from the pinned kiroku source
(`dist-newstyle/src/kiroku-*/kiroku-store/src/Kiroku/Store/Types.hs:209-211`):

```haskell
data RecordedEvent = RecordedEvent
    { eventId :: !EventId
    -- ^ The event's stable id (UUIDv7 by default).
    , eventType :: !EventType
    , streamVersion :: !StreamVersion
    , globalPosition :: !GlobalPosition
    -- … more fields
    }
```

`EventId` is a newtype over a `UUID` (`Kiroku.Store.Types`); `kioku-core` already imports it in
`kioku-core/src/Kioku/Distill/Timer/Outcome.hs`, which unwraps it as `EventId uuid`.

**Important: read the pinned framework sources under `dist-newstyle/src/<pkg>-<hash>/`, not the
sibling working checkouts** such as `/Users/shinzui/Keikaku/bokuno/keiro`. Those checkouts are at
HEAD and their APIs differ from the pinned versions kioku actually links. The previous initiative
lost time to exactly this.

### The command that emits the event

`Kioku.Memory.updateConfidence` (in `kioku-core/src/Kioku/Memory.hs`) is the public entry point;
it appends a `MemoryConfidenceUpdated` event. Find it by grepping:

```bash
grep -rn "updateConfidence\|MemoryConfidenceUpdated" kioku-core/src/Kioku/Memory.hs
```

Read its signature before writing tests — the test will call it.


## Plan of Work

Two milestones. M1 makes the scheduling correct and proves it at the projection level, which is
where the subtle bug (silently-dropped duplicate timer ids) actually lives. M2 proves the whole
chain end to end — event, timer, worker, scene row, persona row, mirror files — because a
scheduling fix that does not actually change what the agent reads on disk has not fixed
anything a user cares about.

**Milestone 1 — a confidence change schedules a scene regeneration, and a second one schedules
another.** Change `l2SceneTimerScheduleProjection` to pass the `RecordedEvent` through to
`scheduleSceneTimersForEvent`, and add the `MemoryConfidenceUpdated` arm. The arm reuses the
forget path's scope lookup (the event carries no scope) but supplies a source id of
`<memoryId>:confidence:<eventId>` so that each confidence change derives a distinct timer id.
Generalise `scheduleForgetTimerTx` into a scope-lookup helper both paths share rather than
copying it — the two differ only in the source id and the timestamp.

The test that matters here is not "a confidence change schedules a timer" (the naive fix passes
that). It is: **two successive confidence changes on the same memory schedule two distinct
timers.** A fixed `<memoryId>:confidence` source id passes the first and fails the second, and
that is the trap this milestone exists to close. Count timers with keiro's library API
(`Keiro.Timer.countDueTimers`) rather than raw SQL against the timers table — the previous
initiative established that the table's *schema* is in motion (it is addressed as
`kiroku.keiro_timers` at the current pin and keiro HEAD relocates it), so a test that queries it
directly will break on the next pin bump for no good reason.

At the end of M1: `nix develop --command cabal build all` is clean and the new projection tests
pass.

**Milestone 2 — the agent actually reads the new confidence.** Add the end-to-end case. Seed a
scope with a memory at `high` confidence, run a scene regeneration so a scene and a persona
exist with `high` baked into them, then lower the memory to `low` confidence, drain the timers
with the same worker entry point production uses, and assert on three things: the
`kioku_scenes` row's `source_hash` changed and its body reflects the new confidence, the
`kioku_personas` row was regenerated (proving the cascade), and the mirror file on disk contains
the new value. Assert against the mirror file's **real bytes**, not against an in-memory value —
the previous initiative's EP-2 made exactly this mistake-proofing choice and it is what caught a
real bug.

Two mechanical facts you need. First, the L2/L3 regeneration calls an LLM, so the test must
inject a canned response — `kioku-core/test/Kioku/DistillSpec.hs` already does this for its
forget-propagation cases; copy that pattern. Second, mirror files are written relative to
`DistillRuntime`'s `workspaceRoot :: Maybe FilePath` field; a test **must** set it to a temporary
directory. Do not use `withCurrentDirectory` — tasty runs cases concurrently and a process-wide
`chdir` races. (The previous initiative discovered this the expensive way and added
`workspaceRoot` precisely so tests could stop doing it. A `.kioku/` directory appearing in the
repository working tree is a symptom that someone got this wrong.)

Also in M2: add the small test that pins why `MemoryTagsUpdated` schedules nothing, so the next
reader does not "complete" this fix by adding an arm that costs an LLM call per tag edit.

At the end of M2: `nix develop --command cabal test all` is green, and the new end-to-end case
fails if you revert the M1 arm.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/kioku`.

### M1 — schedule a scene timer on a confidence change

1. Read the three regions of `kioku-core/src/Kioku/Distill/L2.hs` quoted in Context and
   Orientation (lines ~100-170, ~330-360) so the shapes are in front of you.

2. Change the projection to pass the recorded event through. In
   `kioku-core/src/Kioku/Distill/L2.hs`:

   ```haskell
   l2SceneTimerScheduleProjection :: InlineProjection MemoryEvent
   l2SceneTimerScheduleProjection =
     InlineProjection
       { name = "kioku-l2-scene-timer-schedule",
         apply = scheduleSceneTimersForEvent
       }
   ```

   and give `scheduleSceneTimersForEvent` the second argument:

   ```haskell
   scheduleSceneTimersForEvent :: MemoryEvent -> RecordedEvent -> Tx.Transaction ()
   scheduleSceneTimersForEvent event recorded = case event of
     MemoryRecorded d ->
       scheduleTimerTx $
         l2SceneTimerRequest
           d.scope
           (idText (d.memoryId :: MemoryId))
           (addUTCTime sceneDebounceSeconds d.recordedAt)
     MemoryArchived d -> scheduleScopedSceneTimerTx d.memoryId (kindSourceId d.memoryId "archived") d.archivedAt
     MemorySuperseded d -> scheduleScopedSceneTimerTx d.memoryId (kindSourceId d.memoryId "superseded") d.supersededAt
     MemoryMerged d -> scheduleScopedSceneTimerTx d.memoryId (kindSourceId d.memoryId "merged") d.mergedAt
     -- Confidence is in the scene's source hash ('atomSource') and in the LLM prompt
     -- ('renderAtom'), so a change to it makes the scene stale exactly as a forget does.
     --
     -- The source id must carry the event id. keiro re-arms a conflicting timer only while it
     -- is still 'scheduled'; a fixed "<memoryId>:confidence" would be silently dropped on every
     -- change after the first, which would look fixed and be worse than the bug.
     MemoryConfidenceUpdated d ->
       scheduleScopedSceneTimerTx
         d.memoryId
         (idText d.memoryId <> ":confidence:" <> eventIdText recorded.eventId)
         d.updatedAt
     -- Tags are in neither 'atomSource' nor 'renderAtom', so a tag change cannot alter the
     -- scene. Scheduling here would spend an LLM call to rewrite a byte-identical row.
     MemoryTagsUpdated _ -> pure ()
   ```

   Add the two small helpers next to it (naming is yours to adjust; keep the comment):

   ```haskell
   kindSourceId :: MemoryId -> Text -> Text
   kindSourceId memoryId kind = idText memoryId <> ":" <> kind

   eventIdText :: EventId -> Text
   eventIdText (EventId uuid) = UUID.toText uuid
   ```

   and rename `scheduleForgetTimerTx` to `scheduleScopedSceneTimerTx`, taking the source id
   rather than the kind (its body is otherwise unchanged — it still reads the scope columns back
   from `kioku_memories` inside the same transaction, which is what makes it work for an event
   that carries no scope):

   ```haskell
   -- | Schedule a scene regeneration for a memory whose event does not carry its scope.
   --
   -- The scope is read back from the read-model row inside this same transaction. The row is
   -- guaranteed present: the aggregate only accepts these commands for an @Active@ memory, which
   -- implies a committed @MemoryRecorded@ whose inline projection upserted the row.
   scheduleScopedSceneTimerTx :: MemoryId -> Text -> UTCTime -> Tx.Transaction ()
   scheduleScopedSceneTimerTx memoryId sourceId occurredAt = do
     scopeCols <- Tx.statement (idText memoryId) selectMemoryScopeColumnsStmt
     for_ scopeCols \(ns, sk, sr) ->
       scheduleTimerTx $
         l2SceneTimerRequest
           (scopeFromColumns ns sk sr)
           sourceId
           (addUTCTime sceneDebounceSeconds occurredAt)
   ```

   You will need imports for `RecordedEvent (..)` and `EventId (..)` from `Kiroku.Store.Types`
   and `Data.UUID qualified as UUID`. Check whether `uuid` is already a dependency of
   `kioku-core`:

   ```bash
   grep -n "uuid\|kiroku-store" kioku-core/kioku-core.cabal
   ```

   If `uuid` is not listed, either add it to `build-depends` or render the id via `show`
   (`Text.pack (show uuid)`) to avoid a new dependency — either is acceptable; record which you
   chose in the Decision Log.

3. Build:

   ```bash
   nix develop --command cabal build all
   ```

   The compiler will point at every call site of the renamed helper if you missed one.

4. Add the projection-level tests to `kioku-core/test/Kioku/DistillSpec.hs`. The existing
   "Forget propagation" group is your template; the helpers you need already exist and are listed
   at the end of this plan under "Test helpers that already exist". The closest model is
   `testForgetSchedulesSceneTimers` (`DistillSpec.hs:210-256`), which needs **no runtime and no
   LLM at all**: it records memories, then counts due timers with `Keiro.Timer.countDueTimers`
   over a one-hour horizon (`addUTCTime 3600 now`, which clears the 5-second debounce) and
   asserts the count goes 5 → 6 → 7 → 8 as it archives, supersedes, and merges. Delta-counting
   is exactly what this plan needs.

   Add the new cases to that same group (or a sibling group named "Confidence propagation"):

   - *"a confidence change schedules a scene timer"*: record one memory in a fresh scope, count
     due timers, call `Kioku.Memory.updateConfidence` to lower it from `HighConfidence` to
     `MediumConfidence`, and assert the count went up by exactly one.

   - *"two confidence changes schedule two distinct timers"* — **this is the case that matters,
     and the delta-count is what proves it.** Continue from the previous state and lower the
     memory again (`MediumConfidence` → `LowConfidence`), then assert the count went up by one
     *again*. With a fixed `<memoryId>:confidence` source id the second update derives the *same*
     UUIDv5 timer id, so the `ON CONFLICT … WHERE status = 'scheduled'` upsert re-arms the
     still-scheduled first timer instead of inserting a second — the count stays flat and the
     test fails. That is the trap, and this assertion is the only thing standing between it and
     production, so comment the case with the reason.

     Note two things that make this test honest. First, you must genuinely walk `high → medium →
     low`: `updateConfidence` refuses to emit an event when the confidence is unchanged
     (`kioku-core/src/Kioku/Memory.hs:134`), so re-applying the same value schedules nothing and
     would make the test pass for the wrong reason. Second, you do **not** need to fire the first
     timer in between — the count assertion distinguishes "two rows" from "one re-armed row"
     directly, which is stronger and much simpler than arranging a fired state.

   Count timers through keiro's API (`Keiro.Timer.countDueTimers`, already imported at
   `DistillSpec.hs:32`), never with raw SQL against `keiro_timers` — the table's schema placement
   is in flux across keiro versions (it is `kiroku.keiro_timers` at the current pin, and keiro
   HEAD relocates it), so a raw-SQL test would break on the next pin bump for no good reason.

   Give the new cases their own scope string (the existing cases use distinct ones —
   `intention_forget_timers`, `intention_forget_worker`, …) so that concurrently-running cases
   never count each other's timers. `intention_confidence_timers` and
   `intention_confidence_worker` are the obvious names.

5. Run and commit:

   ```bash
   nix develop --command cabal test kioku-core:test:kioku-test
   ```

   Commit: `fix(distill): regenerate scenes when a memory's confidence changes`

### M2 — prove the agent reads the new value

1. Add the end-to-end case to `kioku-core/test/Kioku/DistillSpec.hs`, modelled on
   `testWorkerPropagatesArchive` (`DistillSpec.hs:258-333`), whose own comment describes the
   shape you want: "The whole pipeline, with nothing called by hand: a forget command schedules a
   timer through the inline projection, the worker claims and fires it exactly as `kioku worker`
   does, and the scene, persona, and both plaintext mirrors follow."

   Name the new case *"a confidence change refreshes the scene, the persona, and the mirrors"*.
   Shape:

   - `withDistillWorkspaceEnv \env workspace -> …` gives you an `AppEnv` plus a private temp
     directory for the mirrors.
   - `calls <- newDistillCalls; runtime <- echoingRuntime calls <$> replayRuntimeIn workspace`.
     `echoingRuntime` makes the canned scene body **echo the atom text it was prompted with**,
     which is what lets you assert on the mirror file's real bytes rather than on a fixed canned
     string. `replayRuntimeIn workspace` sets `workspaceRoot = Just workspace`.
   - Record one memory in a fresh scope with `HighConfidence` (adapt `recordForgetFixture`,
     `DistillSpec.hs:426-453`, or inline `Memory.record`).
   - `drainTimers runtime` — this fires the scene timer and, through the cascade, the persona
     timer. Now a scene row and a persona row exist. Capture the scene row's `sourceHash` via
     `getScenesByScope` / `expectOneScene`.
   - `Memory.updateConfidence` on that memory with `LowConfidence`.
   - `drainTimers runtime` again.
   - Assert four things:
     1. The scene row's `sourceHash` **differs** from the captured one. This is the crisp,
        LLM-independent proof that regeneration actually happened, because the hash is computed
        from `atomSource`, which contains confidence.
     2. The scene *prompt* saw the new value: `latestSceneAtoms calls` returns the rendered atom
        text handed to the most recent scene distillation, and `renderAtom` formats each memory
        as `- <id> (<type>, <confidence>): <content>`. So assert the latest atoms contain `"low"`
        and no longer contain `"high"`. This is a direct, readable assertion on the thing that
        was broken.
     3. The scene **mirror file's bytes on disk** contain the new confidence. Read it with
        `Data.Text.IO.readFile` at `sceneMirrorPath workspace sceneRow`. Do not assert on an
        in-memory row and call it a mirror test — the previous initiative made a point of this,
        and it caught a real bug.
     4. The persona was regenerated (the cascade fired) — assert `personaCalls` incremented, or
        that the persona row's `updatedAt` advanced. Persona bodies do not contain confidence
        directly (`PersonaInput.scenes` is built from scene titles and bodies), so it inherits
        the change transitively through the scene body; assert on the *fact of regeneration*,
        not on persona text containing `"low"`.

   **One caveat the forget tests do not have.** They finish with a convergence check —
   `refired <- drainTimers runtime; refired @?= 0` — which works because the forget events are
   terminal and schedule exactly one timer each. Think before copying that assertion here: how
   many timers a *repeatable* event leaves behind is precisely the observable this plan is
   manipulating. A second `drainTimers` immediately after the first should still fire nothing
   new (no further events have been appended), so the check is still valid — but if it fails,
   read it as a signal about your timer-id derivation rather than as a flaky test.

2. Add the tags case: *"a tag change schedules nothing, because tags are not in the scene"*.
   Record a memory, drain, then call the tags-update command and assert **no new** scene timer
   is due. Comment it with the reason (`atomSource` and `renderAtom` contain no tags), because
   without the comment this case reads like an oversight rather than a decision.

3. Full suite:

   ```bash
   nix develop --command cabal test all
   ```

   Expect the whole suite green. **If you get `TimeoutError (ConnectionTimeout {durationSeconds
   = 60})`, rerun before investigating** — the suite's ephemeral-Postgres clusters lose a
   startup race under concurrency often enough to matter (a failing run takes ~65s, a healthy one
   ~15s). This is known, pre-existing, and not caused by your change.

4. Prove the test is real by reverting the fix and watching it fail:

   ```bash
   git stash push kioku-core/src/Kioku/Distill/L2.hs
   nix develop --command cabal test kioku-core:test:kioku-test   # the new cases must FAIL
   git stash pop
   ```

   Paste the failure into this plan's Surprises or Outcomes section as evidence.

5. Commit: `test(distill): prove a confidence change reaches the scene, persona, and mirrors`

6. Update this plan's Progress, Surprises, and Outcomes sections, and update the Progress
   section and the Exec-Plan Registry row for EP-1 in
   docs/masterplans/3-kioku-follow-up-scene-freshness-and-filtered-ann-recall-quality.md.


## Validation and Acceptance

Everything below is observable behavior.

The primary acceptance is the end-to-end test case, which must fail before the fix and pass
after:

```bash
nix develop --command cabal test kioku-core:test:kioku-test
```

Expect a line in the output like:

```text
    Forget propagation
      …
      a confidence change refreshes the scene, the persona, and the mirrors:  OK
      two confidence changes schedule two distinct timers:                    OK
      a tag change schedules nothing, because tags are not in the scene:      OK
```

The proof that the test is *load-bearing* rather than vacuous is the `git stash` step in M2 step
4: with `L2.hs` reverted, "a confidence change refreshes the scene…" must fail on the source-hash
assertion (the scene keeps the stale hash), and "two confidence changes schedule two distinct
timers" must fail if you weaken the source id to a fixed `<memoryId>:confidence`.

A full-suite regression run must also be green:

```bash
nix develop --command cabal test all
```

Manual acceptance, if you have a dev database and an LLM key configured: record a memory,
run the worker to let the scene materialise, read `.kioku/scenes/*.md` and observe the memory
rendered at `high` confidence; lower its confidence through the library; run the worker again;
re-read the file and observe `low`. Before this plan, the file never changes.


## Idempotence and Recovery

Every step is an ordinary source edit plus a build or test run, and all of it is safe to repeat.
No SQL migration is added, no data is transformed, and no existing event or row is rewritten.
The change is purely additive at the domain level: it schedules a timer that was not scheduled
before.

The behavior is idempotent by construction, which is the point of Decision 2. Timer ids are
deterministic UUIDv5 values derived from the scope and the source id, and the source id now
carries the event id — so re-projecting the same event (a replay, a re-run) derives the *same*
timer id and cannot double-schedule, while two genuinely different confidence changes derive
*different* ids and both get scheduled. Regeneration itself is already idempotent: the scene's
source hash short-circuits the LLM call when nothing that feeds the scene has changed, so a
redundant timer costs a hash comparison.

If M1 is half-applied the build fails and names the site (the helper rename is compile-checked),
so it cannot silently persist — finish it or `git checkout -- kioku-core/src/Kioku/Distill/L2.hs`.
Each milestone is a single commit, so `git revert <sha>` cleanly undoes either.

The one thing to be careful about: **do not weaken the source id to make a test simpler.** If a
future contributor finds the `:<eventId>` suffix inconvenient and replaces it with a constant,
every confidence change after the first will silently stop refreshing the scene, and only the
"two confidence changes" test stands between that mistake and production. That is why the test
carries a comment explaining itself.


## Interfaces and Dependencies

No new libraries are required, with one possible exception: rendering the event id as text may
want `Data.UUID` from the `uuid` package. Check `kioku-core/kioku-core.cabal` first; if `uuid`
is not already a dependency, `Text.pack (show uuid)` is an acceptable substitute and adds
nothing. Record the choice in the Decision Log.

Signatures that must exist at the end of this plan, in `kioku-core/src/Kioku/Distill/L2.hs`:

- `scheduleSceneTimersForEvent :: MemoryEvent -> RecordedEvent -> Tx.Transaction ()` — takes the
  recorded event (it previously ignored it), and has a `MemoryConfidenceUpdated` arm.
- `scheduleScopedSceneTimerTx :: MemoryId -> Text -> UTCTime -> Tx.Transaction ()` — the
  generalised scope-lookup scheduler, taking a source id (this replaces `scheduleForgetTimerTx`,
  which took an event-kind `Text`).
- `l2SceneTimerRequest`, `l2SceneTimerId`, `l2SceneProcessManagerName`, `sceneDebounceSeconds`,
  `regenerateScene`, `sceneRowId`, `sceneSourceHash`, `atomSource`, `renderAtom` — all
  **unchanged**. If you find yourself editing any of them, stop: this plan does not need to.

### Test helpers that already exist — do not rebuild these

All of these are in `kioku-core/test/Kioku/DistillSpec.hs` and were built by the previous
initiative's EP-2 for exactly this kind of test. Read them before writing anything.

- `withDistillEnv :: (AppEnv -> IO a) -> IO a` (`:604-609`) — migrated ephemeral database plus a
  store and an `AppEnv`. Database only, no workspace.
- `withDistillWorkspaceEnv :: (AppEnv -> FilePath -> IO a) -> IO a` (`:1026-1030`) — the same,
  plus a private temp directory for mirror files. **Any test that regenerates a scene must use
  this**, because regeneration writes a mirror file as a side effect and a test that does not
  redirect it will write into the repository working tree.
- `replayRuntime :: IO DistillRuntime` (`:1006-1013`) — a `DistillRuntime` whose four LLM entry
  points (`runExtract`, `runConsolidate`, `runScene`, `runPersona`) return canned responses
  instead of calling an endpoint.
- `replayRuntimeIn :: FilePath -> IO DistillRuntime` (`:1015-1024`) — `replayRuntime` with
  `workspaceRoot = Just workspace`. Its comment spells out why: "tasty runs cases concurrently,
  so a process-wide `chdir` would race."
- `DistillCalls` / `newDistillCalls` / `countingRuntime` / `echoingRuntime` / `latestSceneAtoms`
  (`:1032-1088`) — LLM call counters, plus a runtime whose scene body **echoes the atoms it was
  prompted with**, so the mirror file's bytes become a direct function of which memories (and
  which confidences) fed it. `latestSceneAtoms` hands you the rendered atom text of the most
  recent scene distillation.
- `drainTimers :: DistillRuntime -> Eff es Int` (`:393-415`) — fires due timers through the real
  worker entry point (`runKiokuTimerWorkerOnce`) until none are claimable, looking an hour ahead
  so both the 5-second scene debounce and the chained persona timer are due. Bounded at 50 fires
  so a self-rescheduling timer fails the test instead of hanging it.
- `recordForgetFixture` (`:426-453`), `expectOneScene` / `expectJust` / `expectRight`
  (`:417-424`), and `forgetScope :: Text -> MemoryScope` (`:426-428`).
- `Keiro.Timer.countDueTimers` is already imported at `DistillSpec.hs:32`.

You will need to add `UpdateMemoryConfidenceData (..)` to the `Kioku.Memory.Domain` import list
at `DistillSpec.hs:48`. `Kioku.Memory` is already imported qualified as `Memory` (`:47`), and
`Confidence (..)` — hence `HighConfidence`, `MediumConfidence`, `LowConfidence` — is already
imported (`:34`).

Cross-plan constraints. This plan is EP-1 of
docs/masterplans/3-kioku-follow-up-scene-freshness-and-filtered-ann-recall-quality.md. It has no
dependencies and nothing depends on it; the MasterPlan's other two children (EP-2 and EP-3) are
about vector recall and touch `kioku-core/src/Kioku/Recall.hs` and the test suite's recall
modules — disjoint from this plan's files. The only shared file is
`kioku-core/test/Kioku/DistillSpec.hs`, which EP-2 and EP-3 do not touch at all.

**The process-manager names `kioku-l2-scene` and `kioku-l3-persona` must not be renamed.** The
timer worker's dispatcher and the read-model reconciler both key on them, and the previous
initiative's EP-3 and EP-6 each depend on them being stable. This plan has no reason to touch
them; the constraint is recorded so that it stays that way.
