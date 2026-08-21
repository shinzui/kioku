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
effect (the kiroku event store) and `IOE`. Writes additionally require `Error StoreError` and
Kiroku 0.3's `KirokuStoreResource`, which preserves configured event-enrichment hooks across
Keiro's transactional append-and-project path. A typical shape:

```haskell
record ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  RecordMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
```

The CLI sets this up via `Kioku.App`: `AppEnv` holds Kiroku `ConnectionSettings`, and `runAppIO`
acquires `KirokuStoreResource` and interprets `Store` with `runStoreResource`. `withNoopAppEnv`
constructs the common no-telemetry environment and registers all Kioku read models once before
serving queries, as required by Keiro 0.3. Hosts with their own effect stack should install the
resource with `withKirokuStore`, interpret `Store` with `runStoreResource`, and run
`Kioku.ReadModel.registerKiokuReadModels` once at application startup before calling Kioku APIs.

## Shared types (`kioku-api`)

From `Kioku.Api.Scope`:

```haskell
newtype Namespace = Namespace Text
newtype ScopeKind = ScopeKind Text

data MemoryScope
  = ScopeGlobal Namespace                 -- the global bucket: no entity scope
  | ScopeEntity Namespace ScopeKind Text  -- anchored to a specific entity
```

A `MemoryScope` says where a memory *is*. It no longer says how widely to search: that is a
[`RecallTarget`](#recall-kiokurecall), and `ScopeGlobal ns` reaches recall only as
`ExactScope (ScopeGlobal ns)` — the bucket itself — or as `NamespaceWide ns`, which is a different
value.

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

## The memory access context

Every write takes a `MemoryAccessContext` as its first argument. That record says *somebody has
already decided this caller may do this here*: it names one `MemorySpaceId` — the isolation
boundary — the principal the write is attributed to, and the actions it was minted for. Kioku's
core never derives one.

An embedded host with no authentication boundary of its own builds one directly:

```haskell
import Kioku.Api.Access

context :: MemoryAccessContext
context =
  assumeAuthorizedMemoryContext
    (either error id (mkMemorySpaceId "acme-tenant-3"))
    (MemoryActor (either error id (mkPrincipalRef "agent_01h9xk3v7hf8b9c0d1e2f3g4h5")))
```

`assumeAuthorizedMemoryContext` is named the way it is so it cannot be used by accident: it grants
every action on the named space without asking anyone. A host serving untrusted callers uses
`authorizeMemoryAccess` instead, which runs a coarse credential check, a directory lookup, and a
per-space permission check in that order. See [Scopes & Integrations](integrations.md).

Two rules follow from this, and both are checked on every write:

- **The payload must name the same space and principal as the context.** A payload that disagrees
  is refused (`MemorySpaceMismatch`, `MemoryActorMismatch`) rather than quietly rewritten, so a
  stored event and the decision that allowed it stay the same fact.
- **A context authorizes specific actions.** One minted for reading cannot be spent on a write
  (`MemoryNotPermitted`).

A memory or session belongs to the space it was created in, permanently. The aggregate itself
refuses any later command naming a different one, so the check survives a concurrent-writer
retry rather than depending on a read-model precheck.

Namespaces and scopes are unaffected: they organize memory *inside* a space and decide nothing
about who may read it. Two different spaces can use the same namespace and scope for entirely
unrelated data.

> **Reads take the space, not the context.** Every query function below takes a `MemorySpaceId`
> as its first argument and returns nothing outside it; pass `memoryContextSpace` of the context
> that authorized the read. They take the space rather than the whole context because they return
> `Either ReadModelError` and the permission decision has already been made — `authorizeMemoryAccess`
> mints a context only for the permissions it checked, so request `MemoryRead` when you mint one.

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
  | MemoryConflict Text                            -- names the field that differs
  | MemoryNotPermitted MemoryPermission            -- the context did not authorize this action
  | MemorySpaceMismatch MemorySpaceId MemorySpaceId  -- requested, authorized
  | MemoryActorMismatch RecordedPrincipal RecordedPrincipal  -- claimed, authorized

recordWithContext           :: MemoryAccessContext -> RecordMemoryData           -> Eff es (Either MemoryWriteError MemoryId)
supersedeWithContext        :: MemoryAccessContext -> SupersedeMemoryData        -> Eff es (Either MemoryWriteError MemoryId)
archiveWithContext          :: MemoryAccessContext -> ArchiveMemoryData          -> Eff es (Either MemoryWriteError MemoryId)
updateTagsWithContext       :: MemoryAccessContext -> UpdateMemoryTagsData       -> Eff es (Either MemoryWriteError MemoryId)
updateConfidenceWithContext :: MemoryAccessContext -> UpdateMemoryConfidenceData -> Eff es (Either MemoryWriteError MemoryId)
mergeWithContext            :: MemoryAccessContext -> MemoryId -> MemoryId       -> Eff es (Either MemoryWriteError MemoryId)
```

Each asks the context for one permission: `MemoryRecord` for `recordWithContext`,
`updateTagsWithContext`, and `updateConfidenceWithContext`, which create or amend a memory;
`MemoryForget` for `supersedeWithContext`, `archiveWithContext`, and `mergeWithContext`, which
retire one.

- `recordWithContext` — idempotent success if the id already exists with the same payload; `MemoryConflict` if
  any semantic field differs; otherwise appends `MemoryRecorded`.
- `supersede` / `archive` / `merge` — `MemoryNotFound` if the memory doesn't exist; idempotent
  success if it is already retired **the same way** (the same winner for supersede/merge,
  `archived` for archive); `MemoryConflict` otherwise.
- `updateTags` / `updateConfidence` — `MemoryNotActive` on an inactive memory; no-op if the value is
  unchanged.
- `mergeWithContext ctx loser winner` — folds `loser` into `winner`. Unlike the other writes it
  generates its own `mergedAt`, so idempotency matches on the merge target alone.

The unsuffixed `record`, `supersede`, `archive`, `updateTags`, `updateConfidence`, and `merge`
still exist for one release as **deprecated** wrappers. They take no context and refuse any
payload naming a space other than `legacyMemorySpaceId`, so they cannot reach anybody else's
data. See [Upgrading to memory spaces](upgrading-to-memory-spaces.md).

`RecordMemoryData` (the main input):

```haskell
data RecordMemoryData = RecordMemoryData
  { memoryId       :: MemoryId
  , memorySpaceId  :: MemorySpaceId          -- must equal the context's space
  , actorPrincipal :: RecordedPrincipal      -- must equal the context's principal
  , ownerPrincipal :: Maybe PrincipalRef     -- who the memory belongs to, if not the actor
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
      , memorySpaceId = memoryContextSpace context
      , actorPrincipal = memoryContextRecordedActor context
      , ownerPrincipal = Nothing
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
result <- Memory.recordWithContext context payload
```

`memoryContextSpace` and `memoryContextRecordedActor` are the only supported way to fill those two
fields. `RecordedPrincipal` has three cases: `KnownPrincipal` for a principal a directory issued,
`LegacyPrincipal` for the free-text `agentId` events carried before memory spaces existed, and
`UnattributedPrincipal` for older events that recorded no actor at all. Kioku never turns a legacy
label into a directory principal.

## Sessions (`Kioku.Session`)

Session writes take a context on the same terms, and all of them ask for `MemoryRecord`: a
session, its turns, and its lifecycle are memory being recorded.

```haskell
startWithContext             :: MemoryAccessContext -> StartSessionData              -> Eff es (Either SessionWriteError SessionId)
awaitInputWithContext        :: MemoryAccessContext -> AwaitInputData                -> Eff es (Either SessionWriteError SessionId)
resumeWithContext            :: MemoryAccessContext -> ResumeSessionData             -> Eff es (Either SessionWriteError SessionId)
forceResumeWithContext       :: MemoryAccessContext -> SessionId -> Text -> UTCTime  -> Eff es (Either SessionWriteError SessionId)
completeWithContext          :: MemoryAccessContext -> CompleteSessionData           -> Eff es (Either SessionWriteError SessionId)
failSessionWithContext       :: MemoryAccessContext -> FailSessionData               -> Eff es (Either SessionWriteError SessionId)
recordInteractiveWithContext :: MemoryAccessContext -> RecordInteractiveSessionData  -> Eff es (Either SessionWriteError SessionId)
recordTurnWithContext        :: MemoryAccessContext -> RecordTurnData                -> Eff es (Either SessionWriteError SessionId)
```

`SessionWriteError` gains `SessionNotPermitted`, `SessionSpaceMismatch`, and
`SessionActorMismatch`, which mean exactly what their memory counterparts do. The unsuffixed
names remain as deprecated legacy-space wrappers.

`forceResumeWithContext` waives the correlation-key check and nothing else: the session must still
belong to the space the context authorizes. An operator override for a lost key is not an
override for the isolation boundary.

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
  , memorySpaceId     :: MemorySpaceId
  , actorPrincipal    :: RecordedPrincipal
  , ownerPrincipal    :: Maybe PrincipalRef
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
  EmbeddingModel ->
  VectorCapability ->
  MemoryAccessContext ->
  RecallQuery ->
  Eff es (Either RecallError [RecallHit])

data RecallQuery = RecallQuery
  { target     :: RecallTarget
  , query      :: Text
  , strategy   :: RecallStrategy   -- Keyword | Embedding | Hybrid
  , maxResults :: RecallLimit      -- 1..100, via mkRecallLimit
  }

data RecallTarget
  = ExactScope MemoryScope   -- exactly this scope; ScopeGlobal ns is the global bucket
  | NamespaceWide Namespace  -- every scope in the namespace

data RecallHit = RecallHit
  { memory  :: MemoryRecord
  , score   :: Double
  , ftsRank :: Maybe Int
  , vecRank :: Maybe Int
  }

data RecallError
  = RecallSpaceMismatch MemorySpaceId MemorySpaceId  -- requested, authorized (legacyRecall only)

mkRecallQuery :: RecallTarget -> Text -> RecallStrategy -> Int -> Either Text RecallQuery
mkRecallLimit :: Int -> Either Text RecallLimit
```

The **target** says what to search and comes from you; the **memory space** says whose memories
those are and comes from `memoryContextSpace` of the context. Nothing in the request can change
the space, so widening a target never widens the tenancy.

`recall` does not re-check a permission: a `MemoryAccessContext` exists only for permissions
`authorizeMemoryAccess` already checked against that space, which is the same reason the reads
below take a bare `MemorySpaceId`.

All three targets execute. `RecallError` therefore has one constructor left, and only
`legacyRecall` can produce it — a `RecallQuery` carries no memory space of its own to disagree
with the context. `recall` keeps returning `Either` so that adding a refusal later is not a
breaking change at every call site.

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

### The pre-target API, deprecated

`RecallRequest` and `legacyRecall` keep an unmigrated caller working for one release:

```haskell
legacyRecall ::
  (IOE :> es, Store :> es) =>
  EmbeddingModel ->
  VectorCapability ->
  MemoryAccessContext ->
  RecallRequest ->                 -- carries its own memorySpaceId, which must match the context
  Eff es (Either RecallError [RecallHit])

legacyRecallTarget :: MemoryScope -> RecallTarget
```

> **The scope asymmetry this replaces.** A `ScopeGlobal` `RecallRequest` is *namespace-wide*: the
> scope filter vanishes and entity-scoped rows are returned too. That is the opposite of
> `getActiveByScope` below, which treats the same value as "the global bucket only".
> `legacyRecallTarget` maps `ScopeGlobal ns` to `NamespaceWide ns`, so a mechanical migration keeps
> today's rows; the exact global bucket is `ExactScope (ScopeGlobal ns)` and you have to ask for it.
> See [Migrating from `RecallRequest`](recall.md#migrating-from-recallrequest) for the table and the
> removal window.

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
  (Store :> es) => ResolvedRecall -> Vector Double -> Eff es (VectorChannelOutcome, [MemoryRecord])

-- a ResolvedRecall is a query bound to one authorized space, built only by:
resolveRecall :: MemorySpaceId -> RecallQuery -> Either RecallError ResolvedRecall
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
                                               -- receives the pass's MemoryAccessContext

distillSessionL1 ::
  MemoryAccessContext -> L1RunMode -> DistillRuntime -> FindMergeCandidates es -> SessionId ->
  Eff es (Either L1Error L1Outcome)

-- Kioku.Distill.L2 / L3
regenerateScene   :: DistillRuntime -> MemorySpaceId -> MemoryScope -> Eff es (Either L2Error (Maybe SceneRow))
regeneratePersona :: DistillRuntime -> MemorySpaceId -> MemoryScope -> Eff es (Either L3Error (Maybe PersonaRow))
```

An L1 pass records new atoms and can supersede or merge old ones, so it needs a context for the
space the session belongs to and preflights `[MemoryDistill, MemoryRecord, MemoryForget]` in that
stable order. The first missing permission returns `L1NotPermitted` before a session read or LLM
call. A service-backed host must request all three when minting the context; an embedded host using
`assumeAuthorizedMemoryContext` already grants them.

`regenerateScene` and `regeneratePersona` are low-level trusted-host seams: the caller supplies the
space explicitly. The timer handlers are the authorization boundary for background regeneration;
they require `MemoryDistill` before calling either seam.

`L1SkippedUpToDate` is the watermark: under `RespectWatermark` a session with no turns newer than
the last successful pass is skipped before any LLM call. `regenerateScene`/`regeneratePersona`
return `Nothing` when the scope has emptied — they delete the row and its mirror file rather than
summarizing nothing.

- `Kioku.Distill.L2` also exports `getScenesByScope` and the mirroring helpers
  (`mirrorSceneToWorkspace`, `sceneMirrorPath`); `Kioku.Distill.L3` the persona equivalents. Both
  paths are derived from the row's own `memorySpaceId`, so the signatures are unchanged.
- `Kioku.Workspace` — the artifact layout itself: `spaceArtifactRoot`, `sceneArtifactDir`,
  `personaArtifactDir`, and the pre-partition `legacySceneArtifactDir` /
  `legacyPersonaArtifactDir`. A memory space id is validated for a database column rather than for
  a path (`..` is legal), so the directory component is a sanitised prefix plus a digest, never
  the id itself. `planArtifactMigration` / `applyArtifactMigration` are what
  `kioku migrate-artifacts` runs; the plan is a pure report and the apply publishes a complete
  copy atomically without replacing an existing path. If the destination appears after planning,
  byte-identical content is accepted as already migrated and differing content raises an
  `IOException` that names the refused destination.
- `Kioku.Distill.Timer` — the timer ids, the schedule projection (`l1TimerScheduleProjection`,
  `l1IdleTimerId`, `idleFlushSeconds`), and `L1TimerPayload`, which carries the memory space the
  scheduled pass belongs to.
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
  `scopeSlugFromColumns`) that determines scene/persona mirror filenames, plus the shared
  `slugWithDigest` primitive used by both scope filenames and workspace space directories.

Most hosts let the **worker** drive these on timers rather than calling them directly; see
[Distillation](distillation.md).

### Background workers and the context provider

A worker discovers its own work, so it cannot arrive holding a context. It reads the memory space
out of the claimed timer's payload and asks a `MemoryContextProvider` for a decision about *that*
space:

```haskell
-- Kioku.Api.Access
newtype MemoryContextProvider m = MemoryContextProvider
  { contextForSpace :: MemorySpaceId -> m (Either MemoryAccessDenial MemoryAccessContext) }

assumeAuthorizedContextProvider :: Applicative m => MemoryActor -> MemoryContextProvider m

-- Kioku.Distill.Timer.Worker
runKiokuTimerWorkerOnce ::
  Maybe KeiroMetrics -> MemoryContextProvider (Eff es) -> DistillRuntime -> FindMergeCandidates es ->
  UTCTime -> Eff es (Maybe TimerRow)

drainKiokuTimers ::
  Maybe KeiroMetrics -> MemoryContextProvider (Eff es) -> DistillRuntime -> FindMergeCandidates es ->
  Eff es Int
```

An embedded host wires `assumeAuthorizedContextProvider`; a host behind a service boundary wires
its own authorizer. Returning `Right context` is not enough by itself: L2 and L3 require that the
context names the requested space and grants `MemoryDistill`. Provider refusal, a missing
permission, or a wrong-space context dead-letters the timer before database, model, or workspace
work, because each is a configuration fact an operator has to see.

The CLI resolves both values from the environment: `KIOKU_MEMORY_SPACE` (default `kioku_legacy`)
and `KIOKU_ACTOR` (default `kioku_cli`). A malformed value is a startup error, not a silent
fallback.

## Embeddings and worker plumbing

- `Kioku.Memory.Embedding` — `resolveEmbeddingConfig`, `toEmbeddingModel`.
- `Kioku.Memory.Embedding.Worker` — the embedding worker a host must run, or hybrid recall degrades
  to keyword: `mkEmbeddingWorkerEnv`, `runEmbeddingWorkerHost`, `embeddingHandler`,
  `backfillMissingEmbeddings`, `shouldSkipEmbedding`. It discovers its own work, so it takes a
  `MemoryContextProvider` rather than a context, and reads the space from the delivered event; an
  envelope whose space disagrees with the memory row it names dead-letters without writing.
  `backfillMissingEmbeddings` takes an `EmbeddingBackfillScope` (`BackfillEverySpace` or
  `BackfillOneSpace`) and an `EmbeddingWorkerEnv`, so a host can bound a pass to one tenant and a
  test can drive it with a fake provider.
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

The supported dependency baseline is Keiki 0.2, Keiro 0.3, Kiroku Store 0.3, and pg-migrate 1.1.
These are ordinary Hackage dependencies; downstream projects do not need Git
`source-repository-package` stanzas for the framework or migration packages.

kioku ships a native pg-migrate component whose ordered SQL manifest is embedded and checksummed at
compile time. `kiokuMigrations` is the component named `kioku` (depending on `keiro`), while
`kiokuMigrationPlan` composes kiroku, keiro, and kioku in validated dependency order. A downstream
host composes `kiokuMigrations` with its own components; this repo's `kioku-migrate` mounts the
standard `plan`, `list`, `check`, `status`, `verify`, `up`, `repair`, and `new` commands, plus the
kioku-specific Codd history `import` command.

### Where kioku's tables live

kioku owns the `kioku` PostgreSQL schema and everything in it: `memories`, `sessions`, `turns`,
`l1_watermarks`, `consolidation_decisions`, `scenes`, and `personas`. It does **not** own an event
store — it appends to the host's kiroku streams, using the host's connection settings, and creates
no second store. Every statement kioku issues names its own relations explicitly rather than
resolving them through `search_path`, so adding entries to the store's `extraSearchPath` cannot
change which relations kioku reads or writes.

The database role your application connects with needs `USAGE ON SCHEMA kioku` in addition to its
privileges on the tables. Nothing else about the connection contract changes.

Hosts upgrading from a release where these tables were `kiroku.kioku_*` should read
[Upgrading to the kioku schema](upgrading-to-the-kioku-schema.md): it is a migration-first upgrade
with a short planned outage and no compatibility views.

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
withNoopAppEnv (defaultConnectionSettings connStr) \env -> do
  result <- runAppIO env reconcileReadModelRegistry
  either throwIO (const (pure ())) result
```

It is idempotent — a second run writes nothing — and it derives every name, version, and
shape hash from the same `ReadModel` values the queries use, so it cannot drift from the
code. Run it at migration time, not at app startup: every host process would otherwise race
to write the registry on boot.

This is not a hypothetical for the current release. `0012-relocate-projections-to-kioku-schema`
advances memory to v3, session to v5, and turn to v3 precisely so that a binary on the wrong side
of the move fails closed instead of querying relations that are no longer there — which means
every kioku read stays down until reconciliation runs.

### Adding a migration

Use `just new-migration <slug>`. It delegates to pg-migrate-cli, creates the next
`NNNN-<slug>.sql` file exclusively, and appends it to `kioku-migrations/migrations/manifest`
atomically. The manifest and every listed SQL file are compilation dependencies. A stray `.sql`
file or missing manifest entry makes the build fail with `UnlistedSqlFiles` instead of silently
shipping an incomplete component.
