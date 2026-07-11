---
id: 10
slug: propagate-memory-forget-operations-to-scenes-personas-and-workspace-mirrors
title: "Propagate memory forget operations to scenes, personas, and workspace mirrors"
kind: exec-plan
created_at: 2026-07-07T14:58:23Z
intention: "intention_01kwyhabypepdt1mwemmf0dvqa"
master_plan: "docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md"
---

# Propagate memory forget operations to scenes, personas, and workspace mirrors

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

kioku is an event-sourced memory library for coding agents. Individual facts ("memory
atoms") are distilled by an LLM into per-scope summaries called scenes (stored in the
`kioku_scenes` Postgres table), scenes are distilled into a persona (the `kioku_personas`
table), and both are mirrored as plaintext Markdown files into the agent's workspace under
`.kioku/scenes/*.md` and `.kioku/persona/*.md`.

Today, forgetting a memory does not remove it from any of those derived artifacts. Archiving,
superseding, or merging a memory updates only the `kioku_memories` row; no scene or persona
regeneration is triggered, so the forgotten content stays in the database rows and in the
plaintext mirror files indefinitely — until some unrelated new memory happens to be recorded
in the same scope. Worse, if every memory in a scope is forgotten, the scene and persona for
that scope can never be cleaned up at all, because regeneration returns early on an empty
scope without touching the existing rows or files. This is a privacy-shaped defect: a user
who asks the agent to forget something can still find it verbatim in `.kioku/scenes/*.md`.

After this change, archiving, superseding, or merging a memory schedules the same durable
scene-regeneration timer that recording one does. When the timer fires, the scene is rebuilt
from the remaining active memories (so the forgotten content disappears from the scene row
and its mirror file), and the persona is rebuilt in turn. When the last active memory in a
scope is forgotten, the scene row and its mirror file are deleted outright — without calling
the LLM — and the persona row and its mirror follow by the same rule. You can see it working
by running the new "Forget propagation" tests in `kioku-core/test/Kioku/DistillSpec.hs`,
which drive the real timer worker against a real ephemeral Postgres and assert on the actual
mirror files on disk.

Deliberately out of scope: the immutable event log keeps the original `MemoryRecorded`
events. In an event-sourced system "forgetting" means removal from all derived, queryable,
and plaintext artifacts, not rewriting history. Also out of scope: debouncing/collapsing of
regeneration timers (owned by docs/plans/9-make-l1-distillation-idempotent-and-debounce-distillation-timers.md)
and escaping of scope identity strings (owned by
docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md).


## Progress

- [x] Milestone 1: forget events (`MemoryArchived`, `MemorySuperseded`, `MemoryMerged`)
      schedule L2 scene timers from `l2SceneTimerScheduleProjection`, with a test that
      counts due timers before and after each forget operation. — 2026-07-11. Failed
      before the fix with exactly the predicted `expected: 6, but got: 5`; passes after.
      Full suite 44 passed (was 43).
- [ ] Milestone 2: `regenerateScene` deletes the scene row and mirror file when the scope
      has no active memories (and schedules the L3 persona timer in the same transaction);
      `regeneratePersona` deletes the persona row and mirror file when the scope has no
      scenes. Neither empty path calls the LLM. Tests call the regeneration functions
      directly and assert on rows, mirror files, and LLM invocation counts.
- [ ] Milestone 3: end-to-end tests that drive the real timer worker
      (`runKiokuTimerWorkerOnce`) through record → distill → archive/supersede/merge →
      observe scene, persona, and mirror content change, including the archive-everything
      case.
- [ ] Final: full test suite green, plan's living sections updated, Outcomes &
      Retrospective written.


## Surprises & Discoveries

Findings from the pre-implementation research (2026-07-07), verified against the working
tree at commit `b18da36` and the pinned keiro commit `f1d67a01b7457387a4861e7268d1c521ef82287d`:

- The forget events carry no scope. `MemoryArchivedData`, `MemorySupersededData`, and
  `MemoryMergedData` (kioku-core/src/Kioku/Memory/Domain.hs:125-162) contain only the
  memory id and a timestamp, while the scene timer needs a `MemoryScope`. This forces the
  scheduling projection to look the scope up from the `kioku_memories` read-model row inside
  the same transaction (see Decision Log).
- keiro's `scheduleTimerTx` upserts on timer id but re-arms a conflicting row **only while
  it is still `scheduled`** (`ON CONFLICT (timer_id) DO UPDATE ... WHERE
  keiro_timers.status = 'scheduled'` in keiro's `Keiro.Timer.Schema` at the pinned commit).
  Reusing the record-time timer id (derived from scope + memory id) for the archive of the
  same memory would therefore be a silent no-op once the record-time timer has fired — which
  it almost always has. Forget events must use distinct deterministic ids (see Decision Log).
- The L3 empty-scope hole is confirmed: `regeneratePersona` (kioku-core/src/Kioku/Distill/L3.hs:122-125)
  returns `Right Nothing` when `getPersonaScenesByScope` yields `[]`, leaving the
  `kioku_personas` row and `.kioku/persona/*.md` mirror untouched, exactly like the scene
  hole at kioku-core/src/Kioku/Distill/L2.hs:144-145.
- Adjacent staleness gap, deliberately not fixed here: `MemoryConfidenceUpdated` changes a
  value that is part of the scene source hash (`atomSource` includes `confidence`,
  L2.hs:283-285) and of the rendered atom text (`renderAtom`, L2.hs:291-300), yet it also
  falls through to `[]` in `timerRequestsForEvent`, so a confidence change never refreshes
  the scene. This is a staleness bug of the same shape but not a forget operation; it is
  recorded here for the MasterPlan to pick up (see Decision Log entry 7).
- At the pinned keiro commit the timers table is addressed as unqualified `keiro_timers`
  (schema placement is being reworked by
  docs/plans/14-align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations.md).
  Tests in this plan therefore never query the timers table with raw SQL; they observe
  timers through the keiro library API (`Keiro.Timer.countDueTimers`) and through worker
  behavior, which stays correct regardless of where the table lives.

(Implementation-time discoveries go here as work proceeds.)


## Decision Log

- Decision 1: Trigger scene regeneration for forget events from the existing inline
  projection `l2SceneTimerScheduleProjection`, resolving the scope by querying the
  `kioku_memories` row inside the projection's transaction.
  Rationale: the projection already runs inside every memory command's append transaction
  (kioku-core/src/Kioku/Memory.hs:204), so the timer insert commits atomically with the
  forget event — a crash cannot forget the memory without also scheduling the propagation.
  The alternatives are worse: adding scope to the three event payloads changes the persisted
  wire format (old events would need `Maybe` fields and migration of decoders), and
  scheduling the timer imperatively in `Kioku.Memory.archive/supersede/merge` after the
  command returns is non-atomic and bypasses the process-manager pattern. The scope lookup
  is safe because the aggregate only allows forget commands from the `Active` state, which
  is only reachable after `MemoryRecorded` — whose inline projection upserted the row with
  its scope columns in a previously committed transaction.
  Date: 2026-07-07.

- Decision 2: Forget-event timers use `l2SceneTimerId scope sourceId` with
  `sourceId = idText memoryId <> ":archived" | ":superseded" | ":merged"`; the record path
  keeps its existing bare `idText memoryId` source id.
  Rationale: keiro re-arms a conflicting timer id only while it is still `scheduled`, so
  reusing the record-time id would be dropped once that timer has fired. The suffixed ids
  are still deterministic UUIDv5 values over stable inputs (each forget event occurs at most
  once per memory because the aggregate's `Superseded`/`Merged`/`Archived` vertices are
  terminal — kioku-core/src/Kioku/Memory/Domain.hs:267-272), matching the existing pattern
  and keeping scheduling idempotent if the same command were ever re-applied. Keeping the
  record path's id unchanged means zero behavioral change for timers already in flight when
  this lands. Process-manager names are not renamed.
  Date: 2026-07-07.

- Decision 3: When a scope empties, **delete** the scene/persona row and **remove** the
  mirror file, rather than blanking or tombstoning them.
  Rationale: presence of a `kioku_scenes` row is what feeds `selectScenesForPersonaStmt`
  (kioku-core/src/Kioku/Distill/L3.hs:327-343) and the `scenes`/`persona` CLI commands; a
  blanked row would still flow an empty scene into persona regeneration inputs and keep
  stale `atom_ids` metadata pointing at forgotten memories. Deletion is also the honest
  "forgotten" observable for the plaintext mirrors — an empty leftover file invites
  confusion. Recreation is trivial and conflict-free because row ids are deterministic
  (`sceneRowId`/`personaRowId`) and writes are upserts. No audit trail is lost: the event
  log retains the full history.
  Date: 2026-07-07.

- Decision 4: L3 personas need no new event-level trigger; they stay chained off scene
  changes. The scene-delete transaction schedules the L3 persona timer exactly like the
  scene-upsert transaction already does (`scheduleL3PersonaTimerTx`, L2.hs:185). When the
  persona timer fires on a scope whose scenes are all gone, `regeneratePersona` deletes the
  persona row and mirror.
  Rationale: verified that today the only L3 scheduling site is inside `regenerateScene`'s
  upsert transaction; extending the same chaining to the delete path keeps a single L3
  trigger topology. The hash short-circuit (`row.sourceHash == sourceHash`) correctly skips
  the L3 schedule when the scene did not actually change.
  Date: 2026-07-07.

- Decision 5: Empty-scope handling is pure — no `DistillRuntime` LLM call is made to
  produce or "summarize" an empty artifact. The `Right [] ->` branches never touch
  `runSceneDistillation`/`runPersonaDistillation`.
  Rationale: an LLM call on empty input costs money and latency and can only hallucinate.
  Tests assert the LLM runner is not invoked on the empty path via call counters.
  Date: 2026-07-07.

- Decision 6: No SQL migration. The fix only INSERTs, UPDATEs, and DELETEs rows in existing
  tables (`kioku_scenes`, `kioku_personas`, keiro's timers table); no DDL changes.
  Rationale: the MasterPlan tentatively listed EP-2 among migration-adding plans; research
  shows none is needed, which also removes any migration-timestamp coordination with
  sibling plans.
  Date: 2026-07-07.

- Decision 7: Defer the `MemoryConfidenceUpdated` staleness gap (see Surprises &
  Discoveries). It is the same mechanism (one more case arm in the scheduling projection)
  but it is not a forget operation, its timer id needs the update timestamp mixed in
  (confidence can change repeatedly, unlike the terminal forget events), and folding it in
  would grow this plan's test matrix. Flagged for the MasterPlan as a candidate follow-up.
  Date: 2026-07-07.

- Decision 8: Rows and mirror paths touched by the delete paths are always computed by
  calling the existing functions — the fetched row's primary key (which was itself written
  from `sceneRowId`/`personaRowId`) and `sceneMirrorPath`/`personaMirrorPath` on the
  fetched row — never by re-concatenating the id or slug format inline.
  Rationale: docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md
  owns changing the scope-identity string format (`renderScope`, slug derivation); this
  plan must compose with it landing in either order. Deleting by the looked-up row's own
  key and deriving the mirror path from the looked-up row is format-agnostic.
  Date: 2026-07-07.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root, `/Users/shinzui/Keikaku/bokuno/kioku`. The
repo is a Haskell cabal project with packages `kioku-api` (ids, scope, shared types),
`kioku-core` (domain, distillation, recall), `kioku-cli`, and `kioku-migrations` (SQL
migrations embedded via Template Haskell and applied with codd). Postgres access goes
through hasql; event sourcing comes from the keiki/kiroku/keiro frameworks (pinned by git
tag in `cabal.project`; keiro is pinned at `f1d67a01b7457387a4861e7268d1c521ef82287d` and a
local checkout lives at `/Users/shinzui/Keikaku/bokuno/keiro` — read pinned sources with
`git show <tag>:path` there, and never search `/nix/store`). LLM calls go through the
shikumi library, wrapped in a `DistillRuntime` record of swappable `IO` functions
(kioku-core/src/Kioku/Distill/Runtime.hs) so tests can replace them with canned responses.

Terms used below, in plain language:

- *Memory atom*: one stored fact. Written through the memory aggregate in
  kioku-core/src/Kioku/Memory/Domain.hs, a state machine with vertices
  `NotCreated → Active → {Superseded | Merged | Archived}`; the last three are terminal, so
  each forget event happens at most once per memory. Commands are run by
  kioku-core/src/Kioku/Memory.hs (`record`, `archive`, `supersede`, `merge`, ...), which
  emit events `MemoryRecorded`, `MemoryArchived`, `MemorySuperseded`, `MemoryMerged`.
- *Scope*: where a memory applies — `MemoryScope` (kioku-api/src/Kioku/Api/Scope.hs) is a
  namespace plus optional entity kind/ref, stored as three columns
  (`namespace`, `scope_kind`, `scope_ref`) and reconstructed with `scopeFromColumns`.
- *Inline projection*: a read-model update that runs inside the same Postgres transaction
  as the command's event append (`InlineProjection` in keiro's `Keiro.Projection`; its
  `apply :: event -> RecordedEvent -> Tx.Transaction ()`). `Kioku.Memory.runMemoryCommand`
  (kioku-core/src/Kioku/Memory.hs:192-208) runs two of them in order for every memory
  command: `memoryInlineProjection` (maintains the `kioku_memories` table,
  kioku-core/src/Kioku/Memory/ReadModel.hs) and `l2SceneTimerScheduleProjection`
  (schedules scene-regeneration timers, kioku-core/src/Kioku/Distill/L2.hs:95-100).
- *Durable timer*: a row in keiro's timers table created by `scheduleTimerTx` inside the
  caller's transaction. A worker loop claims due timers one at a time and calls a fire
  function; kioku's dispatcher is `fireKiokuTimer`
  (kioku-core/src/Kioku/Distill/Timer/Worker.hs:51-65), which routes by
  `processManagerName` to L1 (session extraction), L2 (`kioku-l2-scene` →
  `fireL2SceneTimer`), or L3 (`kioku-l3-persona` → `fireL3PersonaTimer`). Timer firing is
  at-least-once; fire handlers must be idempotent. A fire returning `Nothing` leaves the
  timer claimed until a stale-requeue makes it retryable.
- *Distillation pyramid*: L1 extracts atoms from session transcripts; L2
  (`regenerateScene`, kioku-core/src/Kioku/Distill/L2.hs:136-187) summarizes a scope's
  active atoms into one scene row (`kioku_scenes`, primary key `sceneRowId scope`, scene
  key `"default"`); L3 (`regeneratePersona`, kioku-core/src/Kioku/Distill/L3.hs:117-162)
  summarizes a scope's scenes into one persona row (`kioku_personas`, primary key
  `personaRowId scope`). Both use a source-content hash over their inputs to short-circuit
  when nothing changed, making regeneration idempotent and cheap to re-fire. Both tables
  were created by kioku-migrations/sql-migrations/2026-06-24-02-00-00-kioku-distillation.sql.
- *Workspace mirrors*: after every successful regeneration the scene/persona Markdown is
  written (best-effort, IO exceptions swallowed) to
  `<cwd>/.kioku/scenes/<slug>.md` and `<cwd>/.kioku/persona/<slug>.md`
  (`mirrorSceneToCurrentWorkspace` L2.hs:231-250, `mirrorPersonaToCurrentWorkspace`
  L3.hs:203-222). The slug is derived from the scope columns.

The defects this plan fixes, verified in the current tree:

1. `timerRequestsForEvent` (L2.hs:102-110) emits a scene timer only for `MemoryRecorded`;
   `MemoryArchived`, `MemorySuperseded`, and `MemoryMerged` fall through to `[]`. Forgetting
   never triggers regeneration.
2. `regenerateScene` returns `Right Nothing` when the scope has no active memories
   (L2.hs:144-145) without deleting the existing `kioku_scenes` row or its mirror file;
   `regeneratePersona` has the identical hole for `kioku_personas` (L3.hs:124-125).
3. No test covers scenes/personas/mirrors after a forget operation
   (kioku-core/test/Kioku/DistillSpec.hs has a single distillation test and never archives).

Two facts that constrain the design (details in Surprises & Discoveries): the forget events
carry no scope, so the scheduling projection must look the scope up from the
`kioku_memories` row inside its transaction; and keiro's `scheduleTimerTx` will not re-arm a
timer id that has already fired, so forget events need their own deterministic timer ids.

Test infrastructure: `Kioku.Migrations.TestSupport.withKiokuMigratedDatabase`
(kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs) boots a cached ephemeral
Postgres and applies all kiroku + keiro + kioku migrations; `DistillSpec.replayRuntime`
builds a `DistillRuntime` whose LLM runners return canned shikumi responses through the
trace/replay harness, so no network is used. Tests run from the nix dev shell.


## Plan of Work

The work happens almost entirely in two files — kioku-core/src/Kioku/Distill/L2.hs and
kioku-core/src/Kioku/Distill/L3.hs — plus tests in kioku-core/test/Kioku/DistillSpec.hs.
No new modules, no cabal changes, no SQL migrations, no renames of process-manager names or
exported functions. Three milestones, each independently verifiable.


### Milestone 1 — Forget events schedule scene-regeneration timers

Scope: extend the inline projection in kioku-core/src/Kioku/Distill/L2.hs so that
`MemoryArchived`, `MemorySuperseded`, and `MemoryMerged` schedule an L2 scene timer for the
affected memory's scope. At the end of this milestone, every forget command atomically
leaves behind a `scheduled` timer row for process manager `kioku-l2-scene`, proven by a test
that counts due timers around each operation. The timer *firing* behavior on an emptied
scope is Milestone 2's job.

In L2.hs, replace the pure `timerRequestsForEvent :: MemoryEvent -> [TimerRequest]`
(it is module-internal; nothing else references it) with a transaction-level function, and
point the projection at it:

```haskell
l2SceneTimerScheduleProjection :: InlineProjection MemoryEvent
l2SceneTimerScheduleProjection =
  InlineProjection
    { name = "kioku-l2-scene-timer-schedule",
      apply = \event _recorded -> scheduleSceneTimersForEvent event
    }

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
  MemoryConfidenceUpdated _ -> pure ()
```

Keep the `MemoryRecorded` arm byte-for-byte equivalent to today's behavior (same timer id
inputs, same debounce) — Decision 2 explains why its source id stays a bare memory id.

`scheduleForgetTimerTx` looks up the memory's scope columns from `kioku_memories` (the row
is guaranteed to exist: the aggregate only permits forget commands from `Active`, which
implies a committed `MemoryRecorded` whose inline projection upserted the row) and schedules
a timer whose source id is the memory id suffixed with the event kind:

```haskell
scheduleForgetTimerTx :: MemoryId -> Text -> UTCTime -> Tx.Transaction ()
scheduleForgetTimerTx memoryId kind occurredAt = do
  scopeCols <- Tx.statement (idText memoryId) selectMemoryScopeColumnsStmt
  for_ scopeCols \(ns, sk, sr) ->
    scheduleTimerTx $
      l2SceneTimerRequest
        (scopeFromColumns ns sk sr)
        (idText memoryId <> ":" <> kind)
        (addUTCTime sceneDebounceSeconds occurredAt)

selectMemoryScopeColumnsStmt :: Statement Text (Maybe (Text, Maybe Text, Maybe Text))
selectMemoryScopeColumnsStmt =
  preparable
    "SELECT namespace, scope_kind, scope_ref FROM kioku_memories WHERE memory_id = $1"
    (E.param (E.nonNullable E.text))
    (D.rowMaybe ((,,) <$> D.column (D.nonNullable D.text)
                      <*> D.column (D.nullable D.text)
                      <*> D.column (D.nullable D.text)))
```

Import `scopeFromColumns` from `Kioku.Api.Scope` and `for_` from `Data.Foldable` (the
module already imports `traverse_` from there; adjust the import list). If the row is
somehow absent, the `for_` makes the projection a no-op rather than aborting the forget
command — the memory is still forgotten, only propagation is skipped, and the invariant
above says this cannot happen in practice. Everything reuses `l2SceneTimerRequest` and
therefore `l2SceneTimerId` (UUIDv5 over `"kioku-l2-scene:" <> renderScope scope <> ":" <>
sourceId`) and the existing `SceneTimerPayload` — deterministic ids, no format
re-implementation, no process-manager rename.

Test (add to kioku-core/test/Kioku/DistillSpec.hs, inside a new
`testGroup "Forget propagation"` that Milestones 2 and 3 also extend): using
`withKiokuMigratedDatabase`/`withStore`/`runAppIO` exactly as `testReplayDistillation` does,
record two memories in one scope directly via `Kioku.Memory.record` (build
`RecordMemoryData` with `genMemoryId`, `sessionId = Nothing`, some content, `recordedAt =
now`), then archive one via `Kioku.Memory.archive`, supersede the other via
`Kioku.Memory.supersede` (superseder id can be a third recorded memory), and merge a fourth
into a fifth via `Kioku.Memory.merge`. After each step, observe the timer backlog with
`Keiro.Timer.countDueTimers (addUTCTime 3600 now)` (library API — schema-agnostic, see
Surprises & Discoveries) and assert it grows by exactly one per operation beyond the
record-time timers. No session events are involved, so every counted timer is an L2 scene
timer. Before the code change, the forget steps leave the count flat — the test fails with
an assertion like `expected: 5, but got: 4`; after, it passes.


### Milestone 2 — Emptied scopes delete their scene/persona rows and mirror files, without the LLM

Scope: fix the `Right [] ->` early returns in `regenerateScene` (L2.hs) and the `[] ->`
early return in `regeneratePersona` (L3.hs) so that forgotten content cannot survive in a
scope that has emptied. At the end of this milestone, calling `regenerateScene` on a scope
with no active memories deletes the existing scene row and its mirror file and chains the
persona timer; calling `regeneratePersona` on a scope with no scenes deletes the persona row
and its mirror file; neither path invokes the LLM.

In kioku-core/src/Kioku/Distill/L2.hs, `regenerateScene` currently reads
(L2.hs:141-145):

```haskell
  memoryResult <- Recall.getActiveByScope scope
  case memoryResult of
    Left err -> pure (Left (L2MemoryReadFailed err))
    Right [] -> pure (Right Nothing)
```

Replace the `Right []` arm with a lookup-then-delete:

```haskell
    Right [] -> do
      existing <- lookupScene scope defaultSceneKey
      case existing of
        Left err -> pure (Left err)
        Right Nothing -> pure (Right Nothing)
        Right (Just row) -> do
          now <- liftIO getCurrentTime
          runTransaction do
            Tx.statement row.sceneId deleteSceneStmt
            scheduleL3PersonaTimerTx scope now
          liftIO (bestEffortRemoveSceneMirror row)
          pure (Right Nothing)
```

with, alongside the other statements at the bottom of the module:

```haskell
deleteSceneStmt :: Statement Text ()
deleteSceneStmt =
  preparable
    "DELETE FROM kioku_scenes WHERE scene_id = $1"
    (E.param (E.nonNullable E.text))
    D.noResult

bestEffortRemoveSceneMirror :: SceneRow -> IO ()
bestEffortRemoveSceneMirror row = do
  result <- try do
    workspace <- getCurrentDirectory
    let path = sceneMirrorPath workspace row
    exists <- doesFileExist path
    when exists (removeFile path)
  case result :: Either IOException () of
    _ -> pure ()
```

Import `doesFileExist` and `removeFile` from `System.Directory`. Deleting by `row.sceneId`
(the primary key of the row just looked up by scope columns, which was originally written
from `sceneRowId scope`) and computing the path with `sceneMirrorPath` on that row honors
Decision 8: no id or slug format is re-implemented, so this composes with the sibling
scope-identity plan in either landing order. Scheduling `scheduleL3PersonaTimerTx` in the
same transaction as the delete mirrors what the upsert path already does at L2.hs:183-185,
so the persona re-derives after the scene disappears (Decision 4). Note the whole branch
runs before any `runSceneDistillation` call — the LLM is untouched (Decision 5).

In kioku-core/src/Kioku/Distill/L3.hs, `regeneratePersona`'s empty arm (L3.hs:124-125)
gets the symmetric treatment:

```haskell
    [] -> do
      existing <- getPersonaByScope scope
      case existing of
        Nothing -> pure (Right Nothing)
        Just row -> do
          runTransaction (Tx.statement row.personaId deletePersonaStmt)
          liftIO (bestEffortRemovePersonaMirror row)
          pure (Right Nothing)
```

with `deletePersonaStmt` (`DELETE FROM kioku_personas WHERE persona_id = $1`) and
`bestEffortRemovePersonaMirror` (same shape as the scene one, using `personaMirrorPath`).
No further chaining is needed from the persona delete — the persona is the top of the
pyramid.

The return types of `regenerateScene` and `regeneratePersona` do not change; `Right
Nothing` now means "this scope has no artifact (and any stale one was just removed)", which
is exactly how `fireL2SceneTimer`/`fireL3PersonaTimer` already treat it — they mark the
timer fired (L2.hs:189-206, L3.hs:164-181), so an emptied-scope timer completes cleanly
instead of looping.

Tests (extend the "Forget propagation" group): wrap the replay runtime's `runScene` and
`runPersona` in counters so invocations are observable —

```haskell
countingRuntime :: IORef Int -> IORef Int -> IORef [Text] -> DistillRuntime -> DistillRuntime
-- increments the counters and records unField input.atoms before delegating
```

(an `IORef Int` per runner plus an `IORef [Text]` capturing each `SceneInput`'s rendered
atoms; ~15 lines using `modifyIORef'`). Then, in one test case: record two memories with
distinctive contents ("alpha secret", "beta fact") in a scope; call `regenerateScene` and
`regeneratePersona` (canned responses, as in `replayRuntime`) and keep the returned
`SceneRow`/`PersonaRow`; assert the mirror files exist at `sceneMirrorPath tmp row` /
`personaMirrorPath tmp row` (the test already runs under `withCurrentDirectory tmp`).
Archive the "alpha secret" memory; call `regenerateScene` again and assert (a) the captured
`SceneInput` atoms text does not contain "alpha secret", and (b) the returned row's
`atomIds` no longer includes the archived id. Archive the remaining memory; call
`regenerateScene` again and assert the scene runner counter did **not** increase,
`getScenesByScope scope` returns `[]`, and `doesFileExist` on the scene mirror path returns
`False`. Call `regeneratePersona` and assert the persona runner counter did not increase,
`getPersonaByScope scope` returns `Nothing`, and the persona mirror file is gone. Before
this milestone's code changes, the row/file assertions fail (row and file survive); after,
they pass.


### Milestone 3 — End-to-end: the timer worker propagates forgetting to every artifact

Scope: prove the whole pipeline — command → inline projection → durable timer → worker →
regeneration → rows and mirror files — with no hand-called regeneration. At the end of this
milestone there are tests that drive `runKiokuTimerWorkerOnce` exactly as the production
`kioku worker` CLI does (kioku-cli/src/Kioku/Cli/Commands/Worker.hs:87) and observe the
scene/persona/mirror artifacts change after archive, supersede, and merge.

Add a drain helper to DistillSpec that fires timers until none are due:

```haskell
drainTimers :: DistillRuntime -> UTCTime -> Eff es ()
drainTimers rt now = do
  claimed <- runKiokuTimerWorkerOnce Nothing rt (scopedScanCandidates 5) now
  case claimed of
    Nothing -> pure ()
    Just _ -> drainTimers rt now
```

Timers are debounced 5 seconds past their event time and the chained L3 timer is armed 5
seconds past the wall clock, so each drain call takes `now` as
`addUTCTime 3600 realNow` with a fresh `realNow <- liftIO getCurrentTime` — every
scheduled timer is then due. (If a fire ever returned `Nothing`, the timer would stay
claimed and the loop still terminates; the canned runtime cannot fail, so in practice every
timer marks fired.)

Test "archive empties the scope end-to-end": record two memories ("alpha secret", "beta
fact") in a fresh scope via `Kioku.Memory.record`; drain; assert the scene row exists, its
mirror file exists, the persona row exists (the scene fire chains the persona timer, which
the same drain also fires), and its mirror exists. Archive the "alpha secret" memory via
`Kioku.Memory.archive`; drain; assert the newest captured `SceneInput` atoms text lacks
"alpha secret", the scene row's `atomIds` is exactly the surviving id, and the scene mirror
file's on-disk content equals the (new) canned scene body — i.e. the mirror was rewritten.
Archive "beta fact"; drain; assert `getScenesByScope` is `[]`, `getPersonaByScope` is
`Nothing`, and both mirror files are gone from disk. To make the mirror rewrite observable
with canned LLM output, let the counting runtime derive the scene body from the input (for
example return a body that embeds the captured atoms text, by generating the canned
response text per call) or simply assert on `atomIds` plus mirror deletion — the plan
requires at minimum: input-capture assertion, `atomIds` assertion, and file
existence/removal assertions.

Test "supersede and merge propagate like archive": in a second scope, record memory A,
drain, then record B and `Kioku.Memory.supersede` A with `supersededBy = B`; drain; assert
the captured `SceneInput` contains B's content and not A's. In a third scope, record C and
D, drain, `Kioku.Memory.merge` C into D; drain; assert the scene input lacks C's content
and the scene row's `atomIds` is exactly D's id. These two paths share all helpers with the
archive test; what they prove is that all three terminal events schedule and fire, not just
archive.

Also verify at-least-once safety cheaply: after the final drain in the archive test, drain
once more and assert nothing changes (idempotent re-fire: hash short-circuit on the
non-empty path, no-op lookups on the empty path).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kioku`, inside the
nix dev shell (which provides ghc 9.12.4, cabal, and Postgres binaries for the ephemeral
database).

1. Build everything once before editing, to confirm a clean baseline:

   ```bash
   cabal build all
   ```

2. Write the Milestone 1 test first (timer counting) in
   kioku-core/test/Kioku/DistillSpec.hs, register the new group in `tests`, and watch it
   fail:

   ```bash
   cabal test kioku-core:test:kioku-test --test-show-details=direct \
     --test-options='-p "Forget propagation"'
   ```

   Expected before the fix (plain output):

   ```text
   Forget propagation
     forget operations schedule scene timers: FAIL
       expected: 5
        but got: 4
   ```

3. Implement Milestone 1 in kioku-core/src/Kioku/Distill/L2.hs (projection +
   `scheduleForgetTimerTx` + `selectMemoryScopeColumnsStmt`), re-run the same command, and
   confirm `OK`.

4. Write the Milestone 2 test (direct regeneration calls, counting runtime, mirror file
   assertions), watch the row/file assertions fail, then implement the empty-scope delete
   paths in L2.hs and L3.hs and confirm the group passes:

   ```bash
   cabal test kioku-core:test:kioku-test --test-show-details=direct \
     --test-options='-p "Forget propagation"'
   ```

5. Write and pass the Milestone 3 end-to-end tests (worker-driven), same command.

6. Run the full suite (all specs share the cached ephemeral Postgres) and the other
   packages' builds to catch import fallout:

   ```bash
   cabal build all
   cabal test kioku-core:test:kioku-test --test-show-details=direct
   ```

   Expected tail of the output:

   ```text
   All N tests passed
   ```

7. Update this plan's Progress, Surprises & Discoveries, and Decision Log at every stopping
   point; write Outcomes & Retrospective at the end. Commit per milestone with conventional
   messages, for example:

   ```text
   feat(distill): schedule scene regeneration timers for memory forget events
   feat(distill): delete scene and persona artifacts when a scope empties
   test(distill): cover forget propagation end-to-end through the timer worker
   ```

No migration steps: this plan adds no SQL files, so
kioku-migrations/src/Kioku/Migrations.hs is not touched and `just migrate` is unnecessary
beyond what tests do themselves.


## Validation and Acceptance

Acceptance is behavioral. After implementation, from the repository root:

```bash
cabal test kioku-core:test:kioku-test --test-show-details=direct \
  --test-options='-p "Forget propagation"'
```

passes, and the following narrated scenario — which is literally what the Milestone 3 test
performs against a real Postgres and a real temp-directory workspace — holds:

1. Record two memories, "alpha secret" and "beta fact", in scope
   `rei/intention/forget_test`; run the timer worker until idle. Observe: a
   `kioku_scenes` row for the scope whose `atom_ids` lists both memory ids, a
   `kioku_personas` row, and files `.kioku/scenes/rei-intention-forget_test.md` and
   `.kioku/persona/rei-intention-forget_test.md` in the working directory.
2. Archive the "alpha secret" memory; run the worker until idle. Observe: the scene was
   regenerated from only the surviving atom — the text handed to the scene LLM program no
   longer contains "alpha secret", `atom_ids` lists only the surviving id, and the scene
   mirror file was rewritten. The persona was regenerated in turn.
3. Archive "beta fact"; run the worker until idle. Observe: the `kioku_scenes` row is gone,
   the `kioku_personas` row is gone, both mirror files are gone from disk, and the LLM
   runners were not invoked for these empty regenerations (call counters flat).
4. Superseding and merging behave like archiving: the losing memory's content disappears
   from the next scene regeneration in its scope.
5. Running the worker again after step 3 changes nothing (idempotent re-fire).

Each milestone also has a fail-before/pass-after demonstration described in its section:
Milestone 1's timer count stays flat before the fix; Milestone 2's scene row and mirror
file survive an emptied scope before the fix. Beyond the new tests, the pre-existing test
`replay distills duplicate turns into merged atom scene and persona` must still pass
unchanged — it exercises the record-path timer scheduling and regeneration this plan must
not disturb.


## Idempotence and Recovery

Every step is safe to repeat. The scheduling projection is deterministic: re-running a
forget command against a terminal aggregate is rejected by the state machine before any
event is emitted, and even a hypothetical duplicate event produces the same UUIDv5 timer id,
which `scheduleTimerTx` upserts. Timer firing is at-least-once by keiro's contract, and both
regeneration paths tolerate re-fires: the non-empty path short-circuits on the source hash;
the empty path finds no row on the second pass (`DELETE` of an absent row and `removeFile`
guarded by `doesFileExist` are no-ops). Mirror-file removal is best-effort inside a `try`,
exactly like mirror writing already is — a failure to remove the file never fails the timer
(the database row, the durable artifact, is already gone; the next regeneration in that
workspace rewrites or removes the file).

There are no destructive or migratory steps against shared state: the only deletions are of
derived rows that regenerate deterministically from the event log — re-recording any memory
in the scope rebuilds the scene and persona from scratch. If implementation goes wrong
mid-milestone, `git checkout -- kioku-core` restores the tree; the test database is
ephemeral and rebuilt per run.


## Interfaces and Dependencies

Libraries and modules relied on (all already dependencies; nothing new is added to any
cabal file):

- keiro (pinned in `cabal.project` at `f1d67a01b7457387a4861e7268d1c521ef82287d`; sources at
  `/Users/shinzui/Keikaku/bokuno/keiro`): `Keiro.Timer` for `TimerRequest (..)`,
  `TimerId (..)`, `scheduleTimerTx` (transactional upsert; re-arms only `scheduled` rows —
  the fact that forces distinct forget timer ids), `countDueTimers` (used by tests instead
  of raw SQL against the timers table), and `runTimerWorker` semantics (at-least-once,
  idempotent handlers required). `Keiro.Projection.InlineProjection` with
  `apply :: event -> RecordedEvent -> Tx.Transaction ()`, applied in list order inside the
  command's append transaction by `runCommandWithProjections` — `memoryInlineProjection`
  runs before `l2SceneTimerScheduleProjection` per kioku-core/src/Kioku/Memory.hs:204.
- hasql / hasql-transaction for the two new `DELETE` statements and the scope-columns
  `SELECT`; `System.Directory` (`doesFileExist`, `removeFile`) for mirror removal.
- shikumi only indirectly: the empty-scope paths must not call
  `runSceneDistillation`/`runPersonaDistillation`; tests swap `DistillRuntime.runScene` /
  `runPersona` with counting/capturing wrappers over canned trace/replay responses.
- kioku-migrations test support: `withKiokuMigratedDatabase` for ephemeral Postgres.

Signatures that must hold at the end of each milestone (full module paths; unchanged unless
marked new):

- `Kioku.Distill.L2.l2SceneTimerScheduleProjection :: InlineProjection MemoryEvent` —
  same name and type; new behavior for the three forget events (Milestone 1).
- new, module-internal: `Kioku.Distill.L2.scheduleSceneTimersForEvent :: MemoryEvent ->
  Tx.Transaction ()`, `Kioku.Distill.L2.scheduleForgetTimerTx :: MemoryId -> Text ->
  UTCTime -> Tx.Transaction ()`, `Kioku.Distill.L2.selectMemoryScopeColumnsStmt ::
  Statement Text (Maybe (Text, Maybe Text, Maybe Text))` (Milestone 1).
- `Kioku.Distill.L2.regenerateScene :: (IOE :> es, Store :> es) => DistillRuntime ->
  MemoryScope -> Eff es (Either L2Error (Maybe SceneRow))` — unchanged type; `Right
  Nothing` now implies any stale artifact was deleted (Milestone 2).
- `Kioku.Distill.L3.regeneratePersona :: (IOE :> es, Store :> es) => DistillRuntime ->
  MemoryScope -> Eff es (Either L3Error (Maybe PersonaRow))` — unchanged type, same
  semantics extension (Milestone 2).
- new, module-internal: `Kioku.Distill.L2.deleteSceneStmt :: Statement Text ()`,
  `Kioku.Distill.L2.bestEffortRemoveSceneMirror :: SceneRow -> IO ()`,
  `Kioku.Distill.L3.deletePersonaStmt :: Statement Text ()`,
  `Kioku.Distill.L3.bestEffortRemovePersonaMirror :: PersonaRow -> IO ()` (Milestone 2).
- Unchanged and relied upon: `l2SceneProcessManagerName = "kioku-l2-scene"`,
  `l3PersonaProcessManagerName = "kioku-l3-persona"`, `l2SceneTimerId`,
  `l3PersonaTimerId`, `scheduleL3PersonaTimerTx`, `sceneMirrorPath`, `personaMirrorPath`,
  `fireL2SceneTimer`, `fireL3PersonaTimer`, `fireKiokuTimer`, `runKiokuTimerWorkerOnce`.

Cross-plan integration constraints (reference sibling plans by path only; both are
currently unwritten skeletons, so these constraints are stated so the plans compose in any
landing order):

- docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md
  owns the `renderScope`/slug escaping fix in L2.hs/L3.hs. This plan never re-implements
  those string formats: rows are deleted by the primary key of the row looked up via scope
  columns, and mirror paths come from `sceneMirrorPath`/`personaMirrorPath` on that row
  (Decision 8).
- docs/plans/9-make-l1-distillation-idempotent-and-debounce-distillation-timers.md rewrites
  L1 session-timer scheduling in kioku-core/src/Kioku/Distill/Timer.hs. This plan touches
  only L2/L3 scheduling, keeps timer ids deterministic UUIDv5 over stable inputs, renames
  no process managers, and preserves the record-path timer id exactly. Soft dependency:
  prefer landing after that plan to reduce churn in shared concepts, but do not block on
  it — nothing here edits Timer.hs.
- docs/plans/14-align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations.md
  moves keiro framework tables between schemas; this plan's tests deliberately observe
  timers only through the keiro API, never raw SQL, so they survive the relocation.
- No SQL migration is added by this plan, so there is no migration-timestamp coordination
  and kioku-migrations/src/Kioku/Migrations.hs is untouched (Decision 6).
