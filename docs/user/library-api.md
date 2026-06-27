# Library API

This page is for **host developers** embedding kioku in a Haskell application. It covers the
write API (`Kioku.Memory`, `Kioku.Session`), the read/recall API (`Kioku.Recall`), the shared
types (`Kioku.Api.*`), and how to run them.

> kioku is one of the kikan 4-package projects: `kioku-api` (pure types), `kioku-core` (the
> aggregates, recall, and distillation), `kioku-cli`, and `kioku-migrations`. Hosts depend on
> `kioku-api` and `kioku-core`.

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
  = ScopeGlobal Namespace                 -- namespace-wide
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

All writers are idempotent and guarded by the current read-model state. They return
`Either MemoryWriteError MemoryId`.

```haskell
record          :: RecordMemoryData            -> Eff es (Either MemoryWriteError MemoryId)
supersede       :: SupersedeMemoryData         -> Eff es (Either MemoryWriteError MemoryId)
archive         :: ArchiveMemoryData           -> Eff es (Either MemoryWriteError MemoryId)
updateTags      :: UpdateMemoryTagsData        -> Eff es (Either MemoryWriteError MemoryId)
updateConfidence:: UpdateMemoryConfidenceData  -> Eff es (Either MemoryWriteError MemoryId)
merge           :: MemoryId -> MemoryId         -> Eff es (Either MemoryWriteError MemoryId)
```

- `record` — no-op if the id already exists; otherwise appends `MemoryRecorded`.
- `supersede` / `archive` — no-op if the memory is already inactive; error `MemoryNotFound` if it
  doesn't exist.
- `updateTags` / `updateConfidence` — error `MemoryNotActive` on an inactive memory; no-op if the
  value is unchanged.
- `merge loser winner` — folds `loser` into `winner`.

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

Generate ids with `Kioku.Id` (`genMemoryId`, `genSessionId`). Example (mirrors `kioku demo`):

```haskell
mid <- genMemoryId
now <- getCurrentTime
let payload = RecordMemoryData
      { memoryId = mid
      , agentId = "demo-agent"
      , sessionId = Nothing
      , scope = ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_demo"
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
  , input          :: Text
  , resumedAt      :: UTCTime
  }
```

Lifecycle: `start` → `running`; then `complete` or `failSession`, or `awaitInput` → `awaiting`
→ `resume` → `running`. `complete` and `failSession` may close either a `running` or
`awaiting` session. `recordTurn` only succeeds while a session is `running`
(`SessionNotRunning` otherwise). `recordInteractive` captures a finished interactive
conversation in one event. Turns recorded here are the **L0 evidence** the distillation pyramid
consumes — see [Distillation](distillation.md).

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

The session write errors now include `SessionNotAwaiting` and `SessionCorrelationMismatch` in
addition to command/read failures, `SessionNotFound`, and `SessionNotRunning`. A duplicate
`resume` after the session is already running is treated as idempotent success; a resume with a
supplied non-matching correlation key is rejected.

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

Build the `EmbeddingModel` from config with `Kioku.Memory.Embedding`
(`resolveEmbeddingConfig`, `toEmbeddingModel`), and detect the vector capability with
`Kioku.Recall.Capability.detectVectorCapability`. The scoring/fusion model is in
[Recall](recall.md).

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
`updatedAt`:

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

Hosts that want to drive distillation directly:

- `Kioku.Distill.L1` — `distillSessionL1`, plus candidate finders `scopedScanCandidates` and
  `recallCandidates`.
- `Kioku.Distill.L2` — `regenerateScene`, `getScenesByScope`, workspace mirroring
  (`mirrorSceneToWorkspace`, `sceneMirrorPath`).
- `Kioku.Distill.L3` — `regeneratePersona`, `getPersonaByScope`, persona mirroring.
- `Kioku.Distill.Timer` / `Kioku.Distill.Timer.Worker` — the idle-flush timer projection and the
  worker loop (`runKiokuTimerWorkerOnce`, `runKiokuTimerWorkerLoop`).

Most hosts let the **worker** drive these on timers rather than calling them directly; see
[Distillation](distillation.md).

## Migrations (`kioku-migrations`)

kioku ships its schema as embedded migrations applied via codd. A host composes kioku's
migrations with its own. In this repo, `just migrate` runs `kioku-migrate` against the
dev-shell database. See the [Getting Started](getting-started.md) setup steps.
