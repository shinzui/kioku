# Library API

This page is for **host developers** embedding kioku in a Haskell application. It covers the
write API (`Kioku.Memory`, `Kioku.Session`), the read/recall API (`Kioku.Recall`), the shared
types (`Kioku.Api.*`), and how to run them.

> kioku is a five-package project: `kioku-api` (pure types), `kioku-core` (the aggregates, recall,
> and distillation), `kioku-cli`, `kioku-migrations` (the embedded schema), and `kioku-migrate` (the
> migration executable). Hosts depend on `kioku-api` and `kioku-core`.

> **Command records live in the `*.Domain` modules.** `Kioku.Memory` and `Kioku.Session` export the
> *functions* and the error types, not the input records. A host calling `record` or `start` must
> also import `Kioku.Memory.Domain (RecordMemoryData (..), …)` and
> `Kioku.Session.Domain (StartSessionData (..), …)`. Likewise `MemoryRow` comes from
> `Kioku.Memory.ReadModel` and `TurnRow` from `Kioku.Session.ReadModel`.

## The effect context

kioku's write/read functions run in the `Eff` monad (from `effectful`) and require a `Store`
effect (the kiroku event store), `IOE`, and — for writes — an `Error StoreError`. A typical
shape:

```haskell
record ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  RecordMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
```

The CLI sets this up via `Kioku.App` (`AppEnv`, `runAppIO`) over a kiroku store opened with
`withStore`. Hosts typically already have a store and an interpreter; thread kioku's calls into
it the same way.

## Shared types (`kioku-api`)

From `Kioku.Api.Scope`:

```haskell
newtype Namespace = Namespace Text
newtype ScopeKind = ScopeKind Text

data MemoryScope
  = ScopeGlobal Namespace                 -- global bucket; recall treats it namespace-wide
  | ScopeEntity Namespace ScopeKind Text  -- anchored to a specific entity
```

From `Kioku.Api.Types`:

```haskell
data MemoryType
  = MemoryFact | MemoryPattern | MemoryPreference | MemoryConstraint | MemoryInstruction

data Confidence = HighConfidence | MediumConfidence | LowConfidence

data MemoryStatus = MemoryActive | MemorySuperseded | MemoryMergedStatus | MemoryArchived

data MemoryRecord = MemoryRecord
  { memoryId   :: Text
  , agentId    :: Text
  , sessionId  :: Maybe Text
  , scope      :: MemoryScope
  , memoryType :: Text
  , content    :: Text
  , priority   :: Int
  , confidence :: Text
  , tags       :: Set Text
  , status     :: Text
  , createdAt  :: UTCTime
  }
```

`MemoryRecord` is the read-side view returned by recall. The `*ToText`/`*FromText` helpers
convert the enums to/from their wire strings (`"fact"`, `"high"`, `"active"`, …).

## Writing memories (`Kioku.Memory`)

All writers are idempotent for *matching* duplicates and return a conflict for
non-matching ones; the rules are enforced by the aggregate, not by a read-model precheck, so
they hold under concurrent writers. They return `Either MemoryWriteError MemoryId`.

`record` on an existing id succeeds only if the request carries the same **agent id, session id**,
content, scope, type, priority, confidence, tags, and `supersedes`; otherwise it returns
`MemoryConflict`. `supersede` and `merge` on an already-retired memory succeed only if the winner is
the same one; `archive` succeeds only if the memory was archived (not superseded or merged).
Call-time timestamps do not participate in the comparison — the id is the identity, and a retry that
re-reads its clock is still a retry.

```haskell
data MemoryWriteError
  = MemoryCommandRejected CommandError
  | MemoryReadFailed ReadModelError
  | MemoryNotFound
  | MemoryNotActive
  | MemoryConflict Text          -- names the field that differs

record          :: RecordMemoryData            -> Eff es (Either MemoryWriteError MemoryId)
supersede       :: SupersedeMemoryData         -> Eff es (Either MemoryWriteError MemoryId)
archive         :: ArchiveMemoryData           -> Eff es (Either MemoryWriteError MemoryId)
updateTags      :: UpdateMemoryTagsData        -> Eff es (Either MemoryWriteError MemoryId)
updateConfidence:: UpdateMemoryConfidenceData  -> Eff es (Either MemoryWriteError MemoryId)
merge           :: MemoryId -> MemoryId         -> Eff es (Either MemoryWriteError MemoryId)
```

- `record` — idempotent success if the id already exists with the same payload; `MemoryConflict` if
  any semantic field differs; otherwise appends `MemoryRecorded`.
- `supersede` / `archive` / `merge` — `MemoryNotFound` if the memory doesn't exist; idempotent
  success if it is already retired **the same way** (the same winner for supersede/merge,
  `archived` for archive); `MemoryConflict` otherwise.
- `updateTags` / `updateConfidence` — `MemoryNotActive` on an inactive memory; no-op if the value is
  unchanged.
- `merge loser winner` — folds `loser` into `winner`. Unlike the other writes it generates its own
  `mergedAt`, so idempotency matches on the merge target alone.

`RecordMemoryData` (the main input):

```haskell
data RecordMemoryData = RecordMemoryData
  { memoryId    :: MemoryId
  , agentId     :: Text
  , sessionId   :: Maybe SessionId
  , scope       :: MemoryScope
  , memoryType  :: MemoryType
  , content     :: Text
  , priority    :: Int
  , confidence  :: Confidence
  , tags        :: Set Text
  , supersedes  :: Maybe MemoryId
  , recordedAt  :: UTCTime
  }
```

Generate ids with `Kioku.Id` (`genMemoryId`, `genSessionId`). They produce typed ids with the
`kioku_memory_...` and `kioku_session_...` prefixes respectively. Example (mirrors `kioku demo`):

```haskell
mid <- genMemoryId
now <- getCurrentTime
let payload = RecordMemoryData
      { memoryId = mid
      , agentId = "demo-agent"
      , sessionId = Nothing
      , scope = ScopeEntity (Namespace "kioku_demo") (ScopeKind "demo") "demo"
      , memoryType = MemoryPreference
      , content = "prefers concise answers"
      , priority = 100
      , confidence = HighConfidence
      , tags = Set.fromList ["style"]
      , supersedes = Nothing
      , recordedAt = now
      }
result <- Memory.record payload
```

## Sessions (`Kioku.Session`)

```haskell
start           :: StartSessionData              -> Eff es (Either SessionWriteError SessionId)
awaitInput      :: AwaitInputData                -> Eff es (Either SessionWriteError SessionId)
resume          :: ResumeSessionData             -> Eff es (Either SessionWriteError SessionId)
forceResume     :: SessionId -> Text -> UTCTime  -> Eff es (Either SessionWriteError SessionId)
complete        :: CompleteSessionData           -> Eff es (Either SessionWriteError SessionId)
failSession     :: FailSessionData               -> Eff es (Either SessionWriteError SessionId)
recordInteractive :: RecordInteractiveSessionData -> Eff es (Either SessionWriteError SessionId)
recordTurn      :: RecordTurnData                -> Eff es (Either SessionWriteError SessionId)
```

Reads:

```haskell
getById             :: SessionId          -> Eff es (Either ReadModelError (Maybe SessionRow))
getRecentInNamespace:: Namespace -> Int   -> Eff es (Either ReadModelError [SessionRow])
getByScope          :: MemoryScope        -> Eff es (Either ReadModelError [SessionRow])
getByFocus          :: Namespace -> Text  -> Eff es (Either ReadModelError [SessionRow])
getByStartedRange   :: Namespace -> UTCTime -> UTCTime -> Eff es (Either ReadModelError [SessionRow])
getChain            :: SessionId          -> Eff es (Either ReadModelError [SessionRow])
getDelegationChildren:: SessionId         -> Eff es (Either ReadModelError [SessionRow])
getAwaitingByCorrelationKey:: Namespace -> Text -> Eff es (Either ReadModelError [SessionRow])
getTurns            :: SessionId          -> Eff es (Either ReadModelError [TurnRow])
```

`StartSessionData` includes both continuation and delegation links:

```haskell
data StartSessionData = StartSessionData
  { sessionId         :: SessionId
  , agentId           :: Text
  , focus             :: Text
  , scope             :: MemoryScope
  , subjectRef        :: Maybe Text
  , previousSessionId :: Maybe SessionId
  , parentSessionId   :: Maybe SessionId
  , delegationDepth   :: Int
  , startedAt         :: UTCTime
  }
```

`previousSessionId` is for a chronological continuation chain; `getChain` follows it.
`parentSessionId` and `delegationDepth` are for spawned child work; use
`getDelegationChildren` to list direct children of a parent session.

Park-and-resume data:

```haskell
data AwaitInputData = AwaitInputData
  { sessionId      :: SessionId
  , reason         :: Text
  , correlationKey :: Maybe Text
  , deadline       :: Maybe UTCTime
  , awaitedAt      :: UTCTime
  }

data ResumeSessionData = ResumeSessionData
  { sessionId      :: SessionId
  , correlationKey :: Maybe Text
  , force          :: Bool        -- waive the correlation check (see forceResume)
  , input          :: Text
  , resumedAt      :: UTCTime
  }
```

`deadline` is **advisory**: kioku stores it for the host and does not enforce it. No timer fires
and nothing expires when it passes.

Lifecycle: `start` → `running`; then `complete` or `failSession`, or `awaitInput` → `awaiting`
→ `resume` → `running`. `complete` and `failSession` may close either a `running` or
`awaiting` session. `recordTurn` only succeeds while a session is `running`
(`SessionNotRunning` otherwise). `recordInteractive` creates a terminal `interactive` session from
metadata (agent, focus, scope, subject, and start time); it does not store a transcript, summary, or
completion timestamp. Use `recordTurn` on a normal running session when the conversation itself
must become **L0 evidence**. See [Distillation](distillation.md).

Session rows include the fields used by the read APIs:

```haskell
data SessionRow = SessionRow
  { sessionId               :: Text
  , agentId                 :: Text
  , focus                   :: Text
  , namespace               :: Text
  , scopeKind               :: Maybe Text
  , scopeRef                :: Maybe Text
  , subjectRef              :: Maybe Text
  , previousSessionId       :: Maybe Text
  , parentSessionId         :: Maybe Text
  , delegationDepth         :: Int
  , status                  :: Text
  , startedAt               :: UTCTime
  , completedAt             :: Maybe UTCTime
  , modelUsed               :: Maybe Text
  , summary                 :: Maybe Text
  , errorMessage            :: Maybe Text
  , awaitingReason          :: Maybe Text
  , awaitingCorrelationKey  :: Maybe Text
  , awaitingDeadline        :: Maybe UTCTime
  , resumeInput             :: Maybe Text
  }
```

The session write errors are `SessionCommandRejected`, `SessionReadFailed`, `SessionNotFound`,
`SessionNotRunning`, `SessionNotAwaiting`, `SessionCorrelationMismatch`, `SessionInvalidLineage`,
and `SessionConflict`. Four of them carry payloads worth surfacing:
`SessionCommandRejected CommandError`, `SessionReadFailed ReadModelError`,
`SessionInvalidLineage Text`, and `SessionConflict Text`.

**Resume correlation.** A `resume` must supply exactly the key the session parked on — including
the keyless case, where it must supply no key. The awaited key lives in the session's replayed
aggregate state, so the check holds under concurrent writers: a caller holding a stale key cannot
answer a wait that was already resumed and re-parked. A duplicate `resume` after the session is
already running is idempotent success **only when it re-delivers the same input**; a different
input returns `SessionConflict`. `forceResume` waives the key check explicitly; it is an operator
override for a session whose awaited key is lost or wrong, and is inherently last-writer-wins.

**Conflicts.** Duplicate writes that match what already happened succeed; conflicting ones return
`SessionConflict`. Completing a failed session, or failing a completed one, is a conflict — not a
silent success. `start` on an existing id succeeds only if the request matches the recorded
session.

**Lineage.** `start` rejects self-referential and inconsistent lineage with
`SessionInvalidLineage`: a session may not be its own `previousSessionId` or `parentSessionId`,
`delegationDepth` must be non-negative and within the cap, and it must agree with
`parentSessionId` (delegated ⇒ depth ≥ 1, root ⇒ depth 0). Existence of the referenced sessions is
not checked.

**Turn identity.** A turn is identified by `(sessionId, turnIndex)`; `turnId` is an idempotency
token. Indexes must strictly increase (enforced by the aggregate). Re-recording an identical turn
is a no-op; the same index with different content, or a `turnId` reused at a different index,
returns `SessionConflict`. Reusing a `turnId` across two different sessions is a caller bug that
surfaces as a raw store failure.

## Recall (`Kioku.Recall`)

Ranked hybrid recall:

```haskell
recall ::
  (IOE :> es, Store :> es) =>
  EmbeddingModel -> VectorCapability -> RecallRequest -> Eff es [RecallHit]

data RecallRequest = RecallRequest
  { scope      :: MemoryScope
  , query      :: Text
  , strategy   :: RecallStrategy   -- Keyword | Embedding | Hybrid
  , maxResults :: Int
  }

data RecallHit = RecallHit
  { memory  :: MemoryRecord
  , score   :: Double
  , ftsRank :: Maybe Int
  , vecRank :: Maybe Int
  }
```

Build the `EmbeddingModel` from config with `Kioku.Memory.Embedding` (`resolveEmbeddingConfig`,
`toEmbeddingModel`), and detect the vector capability with `Kioku.Recall.Capability`. Note that
detection takes the **configured embedding dimensions** and fails closed to keyword-only on a
mismatch, so pass the dimensions you resolved from config:

```haskell
data VectorCapability
  = VectorAvailable
  | VectorExtensionUnavailable
  | VectorColumnsUnavailable [Text]
  | VectorDimensionMismatch Int Int   -- configured, actual

detectVectorCapability :: (Store :> es) => Int -> Eff es VectorCapability
```

> **`recall` has a scope asymmetry you must know about.** A `ScopeGlobal` `RecallRequest` is
> *namespace-wide*: the scope filter vanishes and entity-scoped rows are returned too. That is the
> opposite of `getActiveByScope` below, which treats the same value as "the global bucket only". See
> [Recall](recall.md#global-scope-namespace-wide-recall-vs-exact-scope-reads).

Other exported recall API:

```haskell
data RecallExecutionPlan = RecallExecutionPlan
  { runFts :: Bool, runVector :: Bool, needsQueryEmbedding :: Bool }

planRecallExecution   :: VectorCapability -> RecallStrategy -> RecallExecutionPlan
fuseRecallCandidates  :: UTCTime -> [MemoryRecord] -> [MemoryRecord] -> [RecallHit]
applyCharacterBudgets :: Int -> Int -> [RecallHit] -> [RecallHit]
```

`applyCharacterBudgets` is what a host uses to fit hits into its own context budget.

### Observing a degraded semantic channel

`recall` discards the vector channel's diagnostics. To observe them — the HNSW index is
post-filtered, so a selective scope can starve the approximate pass — call the diagnosed variant:

```haskell
data VectorChannelOutcome = VectorChannelOutcome
  { annRows :: Int, exactFallbackFired :: Bool, rowsReturned :: Int }

vectorChannelStarved :: VectorChannelOutcome -> Bool

selectVectorCandidatesDiagnosed ::
  (Store :> es) => RecallRequest -> Vector Double -> Eff es (VectorChannelOutcome, [MemoryRecord])
```

kioku emits no metric itself (`Kioku.Recall` has no access to the host's tracer), so a host that
wants a health signal for its semantic channel should count `vectorChannelStarved`. The CLI does not
expose it. See [Recall](recall.md#the-vector-channels-two-passes).

Unranked scope scans (return all active memories, no embedding needed):

```haskell
getActiveByScope    :: MemoryScope          -> Eff es (Either ReadModelError [MemoryRecord])
getActiveInNamespace:: Namespace            -> Eff es (Either ReadModelError [MemoryRecord])
getGlobal           :: Namespace            -> Eff es (Either ReadModelError [MemoryRecord])
getById             :: MemoryId             -> Eff es (Either ReadModelError (Maybe MemoryRecord))
getBySession        :: SessionId            -> Eff es (Either ReadModelError [MemoryRecord])
getByType           :: Namespace -> MemoryType -> Eff es (Either ReadModelError [MemoryRecord])
```

Full-detail memory row reads (`Kioku.Memory`) expose projection fields that are intentionally
not part of the smaller `MemoryRecord` API, including `supersededBy`, `supersedes`, and
`updatedAt`. The row *type* comes from `Kioku.Memory.ReadModel` — `Kioku.Memory` exports the
queries, not the type:

```haskell
data MemoryRow = MemoryRow
  { memoryId     :: Text
  , agentId      :: Text
  , sessionId    :: Maybe Text
  , namespace    :: Text
  , scopeKind    :: Maybe Text
  , scopeRef     :: Maybe Text
  , memoryType   :: Text
  , content      :: Text
  , priority     :: Int
  , confidence   :: Text
  , tags         :: Set Text
  , status       :: Text
  , supersededBy :: Maybe Text
  , supersedes   :: Maybe Text
  , createdAt    :: UTCTime
  , updatedAt    :: UTCTime
  }

getMemoryRowById        :: MemoryId -> Eff es (Either ReadModelError (Maybe MemoryRow))
getActiveRowsInNamespace:: Namespace -> Eff es (Either ReadModelError [MemoryRow])
getActiveRowsByScope    :: MemoryScope -> Eff es (Either ReadModelError [MemoryRow])
getRowsBySession        :: SessionId -> Eff es (Either ReadModelError [MemoryRow])
getActiveRowsByType     :: Namespace -> MemoryType -> Eff es (Either ReadModelError [MemoryRow])
getSupersessionChain    :: MemoryId -> Eff es (Either ReadModelError [MemoryRow])
```

Use the row API when a host needs audit/detail views or supersession inspection. Use
`MemoryRecord`/recall when the caller only needs active memory content for context injection.

## Distillation (`Kioku.Distill.*`)

Hosts that want to drive generation directly pass a `DistillRuntime`, which carries the LLM config
and the four programs. Read-only queries, timer helpers, and mirror-path helpers do not need it:

```haskell
-- Kioku.Distill.Runtime
newDistillRuntime :: IO DistillRuntime         -- registers the Claude provider; needs ANTHROPIC_API_KEY

-- Kioku.Distill.L1
data L1RunMode = RespectWatermark | IgnoreWatermark
data L1Outcome = L1Distilled L1Summary | L1SkippedUpToDate
newtype FindMergeCandidates es                 -- produced by scopedScanCandidates / recallCandidates

distillSessionL1 ::
  L1RunMode -> DistillRuntime -> FindMergeCandidates es -> SessionId ->
  Eff es (Either L1Error L1Outcome)

-- Kioku.Distill.L2 / L3
regenerateScene   :: DistillRuntime -> MemoryScope -> Eff es (Either L2Error (Maybe SceneRow))
regeneratePersona :: DistillRuntime -> MemoryScope -> Eff es (Either L3Error (Maybe PersonaRow))
```

`L1SkippedUpToDate` is the watermark: under `RespectWatermark` a session with no turns newer than
the last successful pass is skipped before any LLM call. `regenerateScene`/`regeneratePersona`
return `Nothing` when the scope has emptied — they delete the row and its mirror file rather than
summarizing nothing.

- `Kioku.Distill.L2` also exports `getScenesByScope` and the mirroring helpers
  (`mirrorSceneToWorkspace`, `sceneMirrorPath`); `Kioku.Distill.L3` the persona equivalents.
- `Kioku.Distill.Timer` — the timer ids and schedule projection (`l1TimerScheduleProjection`,
  `l1IdleTimerId`, `idleFlushSeconds`).
- `Kioku.Distill.Timer.Outcome` — the taxonomy a timer handler returns. This **replaced a
  `Maybe EventId`** whose `Nothing` meant three incompatible things:

  ```haskell
  data FireOutcome
    = FireCompleted EventId
    | FireRetryLater NominalDiffTime Text
    | FireFailedPermanently Text
    | FireNotMine
  ```

- `Kioku.Distill.Timer.Worker` — one worker step (`runKiokuTimerWorkerOnce`), a drain
  (`drainKiokuTimers`), the handler (`fireKiokuTimer`), and the outcome applier
  (`applyFireOutcome`). **kioku ships no loop function**: the supervised loop is the host's, and the
  CLI builds one with `race` over `drainKiokuTimers`.
- `Kioku.Distill.ScopeIdentity` — the collision-free scope identity (`scopeIdentity`,
  `scopeSlugFromColumns`) that determines scene/persona mirror filenames.

Most hosts let the **worker** drive these on timers rather than calling them directly; see
[Distillation](distillation.md).

## Embeddings and worker plumbing

- `Kioku.Memory.Embedding` — `resolveEmbeddingConfig`, `toEmbeddingModel`.
- `Kioku.Memory.Embedding.Worker` — the embedding worker a host must run, or hybrid recall degrades
  to keyword: `mkEmbeddingWorkerEnv`, `runEmbeddingWorkerHost`, `embeddingHandler`,
  `backfillMissingEmbeddings`, `shouldSkipEmbedding`.
- `Kioku.Worker.Failure` — the retry/dead-letter/halt classification a host's own worker loop needs:
  `isTransientStoreError`, `embeddingRetryDelay`.

## Scope construction and ids

`Kioku.Api.Scope` exports validating constructors alongside the raw ones. Namespaces and kinds may
not be empty or contain `%`, `/`, or `:` — the characters the scope-identity encoding gives meaning
to:

```haskell
mkNamespace      :: Text -> Either Text Namespace
mkScopeKind      :: Text -> Either Text ScopeKind
scopeFromColumns :: Text -> Maybe Text -> Maybe Text -> MemoryScope
```

`Kioku.Id` exports `genMemoryId`/`genSessionId` and two parsers: use strict **`parseId`** for
operator or host input; **`parseIdLenient`** exists for legacy streams only and will happily take a
`kioku_memory` id, discard its prefix, and rebrand the UUID.

## Migrations (`kioku-migrations`)

kioku ships a native pg-migrate component whose ordered SQL manifest is embedded and checksummed at
compile time. `kiokuMigrations` is the component named `kioku` (depending on `keiro`), while
`kiokuMigrationPlan` composes kiroku, keiro, and kioku in validated dependency order. A downstream
host composes `kiokuMigrations` with its own components; this repo's `kioku-migrate` mounts the
standard `plan`, `list`, `check`, `status`, `verify`, `up`, `repair`, and `new` commands, plus the
kioku-specific Codd history `import` command.

### Applying migrations as a library: reconcile the read-model registry

Applying the migrations is only half the job. keiro records each read model's schema
identity — its version and shape hash — in a `keiro_read_models` registry row, and refuses
to serve any query whose registry row disagrees with the code's declared identity, failing
with `ReadModelStaleSchema`. That guard is deliberate, but nothing repairs the rows on its
own: `registerReadModel` only ever *inserts*, so an existing row stays pinned at its old
version forever. A kioku upgrade that bumps a read model's version therefore takes every
query for that model down until the registry catches up.

`kioku-migrate up` does this for you after pg-migrate succeeds; read-only commands never write the
registry. **A host that runs a composed plan directly must call
`Kioku.ReadModel.reconcileReadModelRegistry` afterwards**, on a `Store`, or it will hit that outage
on the next kioku upgrade:

```haskell
import Database.PostgreSQL.Migrate (defaultRunOptions, runMigrationPlan)
import Kioku.Migrations (kiokuMigrationPlan)
import Kioku.ReadModel (reconcileReadModelRegistry)

plan <- either (fail . show) pure kiokuMigrationPlan
_ <- runMigrationPlan defaultRunOptions migrationSettings plan >>= either (fail . show) pure
withStore (defaultConnectionSettings connStr) \store -> do
  tracer <- noopTracer
  result <-
    runAppIO
      AppEnv {store = store, tracer = tracer, metrics = Nothing}
      reconcileReadModelRegistry
  either throwIO (const (pure ())) result
```

It is idempotent — a second run writes nothing — and it derives every name, version, and
shape hash from the same `ReadModel` values the queries use, so it cannot drift from the
code. Run it at migration time, not at app startup: every host process would otherwise race
to write the registry on boot.

### Adding a migration

Use `just new-migration <slug>`. It delegates to pg-migrate-cli, creates the next
`NNNN-<slug>.sql` file exclusively, and appends it to `kioku-migrations/migrations/manifest`
atomically. The manifest and every listed SQL file are compilation dependencies. A stray `.sql`
file or missing manifest entry makes the build fail with `UnlistedSqlFiles` instead of silently
shipping an incomplete component.
