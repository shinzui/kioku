-- | Writing and reading memories.
--
-- Every write takes a 'MemoryAccessContext' first. That record is the statement "somebody has
-- already decided this caller may do this here" — obtained from
-- 'Kioku.Api.Access.authorizeMemoryAccess' behind a service boundary, or from
-- 'Kioku.Api.Access.assumeAuthorizedMemoryContext' in a trusted in-process host. Kioku's core
-- never derives one.
--
-- Each write asks the context for one permission:
--
-- * 'MemoryRecord' — 'recordWithContext', 'updateTagsWithContext',
--   'updateConfidenceWithContext'. These create or amend a memory.
-- * 'MemoryForget' — 'supersedeWithContext', 'archiveWithContext', 'mergeWithContext'. These
--   retire one.
--
-- The context is checked against the command, not merged into it: the payload names its own
-- memory space and actor, and a payload that disagrees with the context that authorized it is
-- rejected rather than quietly rewritten. That keeps the stored event and the decision that
-- allowed it the same fact.
--
-- The unsuffixed functions ('record', 'archive', …) remain for one release as deprecated
-- compatibility wrappers. They take no context and refuse any payload naming a space other than
-- 'legacyMemorySpaceId', so they cannot reach data belonging to anybody else.
--
-- Every read takes a 'MemorySpaceId' first and returns nothing outside it. Pass
-- 'Kioku.Api.Access.memoryContextSpace' of the context that authorized the read: the context is
-- what decides which space may be named, and the space is what the schema enforces. A read
-- takes the space rather than the whole context because these functions return
-- @Either ReadModelError@, and a permission denial has already been decided — a context exists
-- only for permissions 'Kioku.Api.Access.authorizeMemoryAccess' actually checked.
module Kioku.Memory
  ( MemoryWriteError (..),

    -- * Writing memory
    recordWithContext,
    supersedeWithContext,
    archiveWithContext,
    updateTagsWithContext,
    updateConfidenceWithContext,
    mergeWithContext,

    -- * Deprecated compatibility wrappers, confined to the legacy memory space
    record,
    supersede,
    archive,
    updateTags,
    updateConfidence,
    merge,

    -- * Reading memory
    getMemoryRowById,
    getActiveRowsInNamespace,
    getActiveRowsByScope,
    getRowsBySession,
    getActiveRowsByType,
    getSupersessionChain,
  )
where

import Data.List (find)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Command (CommandError (..), defaultRunCommandOptions)
import Keiro.Projection (runCommandWithProjections)
import Keiro.ReadModel (ConsistencyMode (..), ReadModelError, runQueryWith)
import Kioku.Api.Access
  ( MemoryAccessContext,
    MemoryPermission (..),
    MemorySpaceId,
    RecordedPrincipal (..),
    inLegacyMemorySpaceOnly,
    legacyMemorySpaceId,
    memoryContextRecordedActor,
    memoryContextSpace,
    underMemoryContext,
  )
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Api.Types (MemoryType, confidenceToText, memoryTypeToText)
import Kioku.Distill.L2 (l2SceneTimerScheduleProjection)
import Kioku.Id (MemoryId, SessionId, idText)
import Kioku.Memory.Domain
import Kioku.Memory.EventStream (memoryEventStream, memoryStream)
import Kioku.Memory.ReadModel
  ( MemoriesByNamespaceQuery (..),
    MemoriesByScopeQuery (..),
    MemoriesBySessionQuery (..),
    MemoriesByTypeQuery (..),
    MemoryByIdQuery (..),
    MemoryRow (..),
    MemorySupersessionChainQuery (..),
    memoriesByNamespaceRowsReadModel,
    memoriesByScopeRowsReadModel,
    memoriesBySessionRowsReadModel,
    memoriesByTypeRowsReadModel,
    memoryByIdReadModel,
    memoryInlineProjection,
    memorySupersessionChainReadModel,
  )
import Kioku.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)

data MemoryWriteError
  = MemoryCommandRejected !CommandError
  | MemoryReadFailed !ReadModelError
  | MemoryNotFound
  | MemoryNotActive
  | MemoryConflict !Text
  | -- | the context authorized other actions, but not this one
    MemoryNotPermitted !MemoryPermission
  | -- | the command names a memory space the context was not minted for:
    -- @MemorySpaceMismatch requested authorized@
    MemorySpaceMismatch !MemorySpaceId !MemorySpaceId
  | -- | the command attributes the write to somebody other than the context's own principal
    MemoryActorMismatch !RecordedPrincipal !RecordedPrincipal
  deriving stock (Generic, Show)

-- | Gate a write on the decision that authorized it.
--
-- Three things have to agree and none of them is redundant. The permission check is what stops a
-- context minted for reading from being spent on a write. The space check is the isolation
-- boundary itself. The actor check is what stops a caller authorized as one principal from
-- writing an event that says another principal acted — which would be a forged audit trail, and
-- is the reason the actor is checked rather than merely defaulted.
underContext ::
  (Applicative f) =>
  MemoryAccessContext ->
  MemoryPermission ->
  MemorySpaceId ->
  RecordedPrincipal ->
  f (Either MemoryWriteError a) ->
  f (Either MemoryWriteError a)
underContext =
  underMemoryContext
    MemoryNotPermitted
    MemorySpaceMismatch
    MemoryActorMismatch

-- | Gate a deprecated wrapper on the one space it is allowed to touch.
--
-- A wrapper that silently retargeted a payload into the legacy space would reintroduce exactly
-- the defaulting this whole change exists to remove, so it refuses instead.
inLegacySpaceOnly ::
  (Applicative f) =>
  MemorySpaceId ->
  f (Either MemoryWriteError a) ->
  f (Either MemoryWriteError a)
inLegacySpaceOnly = inLegacyMemorySpaceOnly MemorySpaceMismatch

-- | Record a new memory in the space the context authorizes.
recordWithContext ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  RecordMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
recordWithContext context cmdData =
  underContext context MemoryRecord cmdData.memorySpaceId cmdData.actorPrincipal (recordIn cmdData)

{-# DEPRECATED record "Use recordWithContext. This wrapper accepts only legacyMemorySpaceId and will be removed." #-}

-- | Deprecated: record into the legacy memory space, with no authorization context.
record ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  RecordMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
record cmdData = inLegacySpaceOnly cmdData.memorySpaceId (recordIn cmdData)

recordIn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  RecordMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
recordIn cmdData = do
  existing <- lookupMemory cmdData.memorySpaceId cmdData.memoryId
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right (Just row) -> pure (idempotentOr "record" recordMismatch row cmdData.memoryId)
    Right Nothing -> do
      targetResult <- requireOptionalLineageTarget cmdData.memorySpaceId cmdData.supersedes
      case targetResult of
        Left err -> pure (Left err)
        Right () ->
          runMemoryCommand cmdData.memoryId (RecordMemory cmdData)
            >>= acceptRejectedIfMatches cmdData.memorySpaceId cmdData.memoryId (isNothing . recordMismatch)
  where
    recordMismatch = mismatchOf memoryRecordFields cmdData

-- | Retire a memory in favour of a newer one, in the space the context authorizes.
supersedeWithContext ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  SupersedeMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
supersedeWithContext context cmdData =
  underContext context MemoryForget cmdData.memorySpaceId cmdData.actorPrincipal (supersedeIn cmdData)

{-# DEPRECATED supersede "Use supersedeWithContext. This wrapper accepts only legacyMemorySpaceId and will be removed." #-}

-- | Deprecated: supersede within the legacy memory space, with no authorization context.
supersede ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  SupersedeMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
supersede cmdData = inLegacySpaceOnly cmdData.memorySpaceId (supersedeIn cmdData)

supersedeIn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  SupersedeMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
supersedeIn cmdData = do
  existing <- lookupMemory cmdData.memorySpaceId cmdData.memoryId
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right Nothing -> pure (Left MemoryNotFound)
    Right (Just row)
      -- Already retired: only a supersession by the *same* winner is this request's own
      -- echo. Superseding by a different winner is a conflict, not a duplicate.
      | row.status /= "active" -> pure (idempotentOr "supersede" supersedeMismatch row cmdData.memoryId)
      | otherwise -> do
          targetResult <- requireLineageTarget cmdData.memorySpaceId cmdData.supersededBy
          case targetResult of
            Left err -> pure (Left err)
            Right () ->
              runMemoryCommand cmdData.memoryId (SupersedeMemory cmdData)
                >>= acceptRejectedIfMatches cmdData.memorySpaceId cmdData.memoryId (isNothing . supersedeMismatch)
  where
    supersedeMismatch = mismatchOf memorySupersedeFields cmdData

-- | Archive a memory, in the space the context authorizes.
archiveWithContext ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  ArchiveMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
archiveWithContext context cmdData =
  underContext context MemoryForget cmdData.memorySpaceId cmdData.actorPrincipal (archiveIn cmdData)

{-# DEPRECATED archive "Use archiveWithContext. This wrapper accepts only legacyMemorySpaceId and will be removed." #-}

-- | Deprecated: archive within the legacy memory space, with no authorization context.
archive ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  ArchiveMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
archive cmdData = inLegacySpaceOnly cmdData.memorySpaceId (archiveIn cmdData)

archiveIn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  ArchiveMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
archiveIn cmdData = do
  existing <- lookupMemory cmdData.memorySpaceId cmdData.memoryId
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right Nothing -> pure (Left MemoryNotFound)
    Right (Just row)
      | row.status /= "active" -> pure (idempotentOr "archive" archiveMismatch row cmdData.memoryId)
      | otherwise ->
          runMemoryCommand cmdData.memoryId (ArchiveMemory cmdData)
            >>= acceptRejectedIfMatches cmdData.memorySpaceId cmdData.memoryId (isNothing . archiveMismatch)
  where
    archiveMismatch = mismatchOf memoryArchiveFields cmdData

-- | Replace a memory's tags, in the space the context authorizes.
updateTagsWithContext ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  UpdateMemoryTagsData ->
  Eff es (Either MemoryWriteError MemoryId)
updateTagsWithContext context cmdData =
  underContext context MemoryRecord cmdData.memorySpaceId cmdData.actorPrincipal (updateTagsIn cmdData)

{-# DEPRECATED updateTags "Use updateTagsWithContext. This wrapper accepts only legacyMemorySpaceId and will be removed." #-}

-- | Deprecated: retag within the legacy memory space, with no authorization context.
updateTags ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  UpdateMemoryTagsData ->
  Eff es (Either MemoryWriteError MemoryId)
updateTags cmdData = inLegacySpaceOnly cmdData.memorySpaceId (updateTagsIn cmdData)

updateTagsIn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  UpdateMemoryTagsData ->
  Eff es (Either MemoryWriteError MemoryId)
updateTagsIn cmdData = do
  existing <- lookupMemory cmdData.memorySpaceId cmdData.memoryId
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right Nothing -> pure (Left MemoryNotFound)
    Right (Just row)
      | row.status /= "active" -> pure (Left MemoryNotActive)
      | row.tags == cmdData.tags -> pure (Right cmdData.memoryId)
      | otherwise -> runMemoryCommand cmdData.memoryId (UpdateMemoryTags cmdData)

-- | Re-score a memory's confidence, in the space the context authorizes.
updateConfidenceWithContext ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  UpdateMemoryConfidenceData ->
  Eff es (Either MemoryWriteError MemoryId)
updateConfidenceWithContext context cmdData =
  underContext context MemoryRecord cmdData.memorySpaceId cmdData.actorPrincipal (updateConfidenceIn cmdData)

{-# DEPRECATED updateConfidence "Use updateConfidenceWithContext. This wrapper accepts only legacyMemorySpaceId and will be removed." #-}

-- | Deprecated: re-score within the legacy memory space, with no authorization context.
updateConfidence ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  UpdateMemoryConfidenceData ->
  Eff es (Either MemoryWriteError MemoryId)
updateConfidence cmdData = inLegacySpaceOnly cmdData.memorySpaceId (updateConfidenceIn cmdData)

updateConfidenceIn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  UpdateMemoryConfidenceData ->
  Eff es (Either MemoryWriteError MemoryId)
updateConfidenceIn cmdData = do
  existing <- lookupMemory cmdData.memorySpaceId cmdData.memoryId
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right Nothing -> pure (Left MemoryNotFound)
    Right (Just row)
      | row.status /= "active" -> pure (Left MemoryNotActive)
      | row.confidence == confidenceToText cmdData.confidence -> pure (Right cmdData.memoryId)
      | otherwise -> runMemoryCommand cmdData.memoryId (UpdateMemoryConfidence cmdData)

-- | Merge @loser@ into @winner@, in the space the context authorizes.
--
-- Unlike the other writes, @mergedAt@ is generated here rather than supplied by the caller,
-- so a retry cannot re-deliver an identical timestamp. Idempotency therefore matches on the
-- merge target alone: merging into the same winner twice is a duplicate, merging into a
-- different one is a conflict.
--
-- Both memories must live in the authorized space. The loser is checked by the aggregate guard
-- on the command below; the referenced winner is resolved through the same space-scoped read
-- model before the first transition. 'Kioku.Distill.L1' keeps its earlier planning check so a
-- bad model response can degrade without partially applying its batch.
mergeWithContext ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  MemoryId ->
  MemoryId ->
  Eff es (Either MemoryWriteError MemoryId)
mergeWithContext context loser winner =
  underContext context MemoryForget space actor (mergeIn space actor loser winner)
  where
    space = memoryContextSpace context
    actor = memoryContextRecordedActor context

{-# DEPRECATED merge "Use mergeWithContext. This wrapper writes only into legacyMemorySpaceId and will be removed." #-}

-- | Deprecated: merge within the legacy memory space, with no authorization context.
--
-- The recorded actor is 'UnattributedPrincipal' rather than an invented one: this path has no
-- context, so nothing here knows who is merging.
merge ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryId ->
  MemoryId ->
  Eff es (Either MemoryWriteError MemoryId)
merge = mergeIn legacyMemorySpaceId UnattributedPrincipal

mergeIn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemorySpaceId ->
  RecordedPrincipal ->
  MemoryId ->
  MemoryId ->
  Eff es (Either MemoryWriteError MemoryId)
mergeIn memorySpaceId actorPrincipal loser winner = do
  existing <- lookupMemory memorySpaceId loser
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right Nothing -> pure (Left MemoryNotFound)
    Right (Just row)
      | row.status /= "active" -> pure (idempotentOr "merge" mergeMismatch row loser)
      | otherwise -> do
          targetResult <- requireLineageTarget memorySpaceId winner
          case targetResult of
            Left err -> pure (Left err)
            Right () -> do
              now <- liftIO getCurrentTime
              runMemoryCommand
                loser
                ( MergeMemory
                    MergeMemoryData
                      { memoryId = loser,
                        memorySpaceId,
                        actorPrincipal,
                        mergedInto = winner,
                        mergedAt = now
                      }
                )
                >>= acceptRejectedIfMatches memorySpaceId loser (isNothing . mergeMismatch)
  where
    mergeMismatch = mismatchOf memoryMergeFields winner

-- * Idempotent accepts

-- | A named comparison between one request field and the memory row that already exists.
type FieldCheck cmd = (Text, cmd -> MemoryRow -> Bool)

-- | The first request field that disagrees with the recorded row, if any.
--
-- Call-time timestamps (@recordedAt@, @supersededAt@, @archivedAt@) are deliberately /not/
-- compared. The id is the identity: a second write against the same id with the same
-- semantic payload is a retry, and retries re-read the clock. Distillation is the proof —
-- 'Kioku.Distill.L1.recordAtom' derives a deterministic memory id but passes
-- @recordedAt = now@, so comparing the timestamp would turn every idle-timer re-fire (the
-- exact regime L1's deterministic identity exists to survive) into a hard conflict.
--
-- Everything that carries meaning — content, scope, type, priority, confidence, tags,
-- lineage, and the merge/supersession target — is compared, which is what the review
-- actually asked for: a reused id with different /content/ must not report success.
--
-- The memory space is absent from these comparisons because it can no longer differ. Every
-- lookup that produces the row is now scoped to the command's own space, so a row from another
-- space is simply not found and the write proceeds to the aggregate, which refuses it. That
-- closes the residual this comment used to describe: presenting the id of a memory in another
-- space no longer reveals, through an idempotent answer, that the id exists or that it is
-- active.
mismatchOf :: [FieldCheck cmd] -> cmd -> MemoryRow -> Maybe Text
mismatchOf checks cmd row =
  fst <$> find (\(_, matches) -> not (matches cmd row)) checks

-- | A duplicate request that matches what already happened succeeds; one that conflicts with
-- it gets a conflict error naming the field that differs.
idempotentOr ::
  Text ->
  (MemoryRow -> Maybe Text) ->
  MemoryRow ->
  MemoryId ->
  Either MemoryWriteError MemoryId
idempotentOr operation mismatch row mid =
  case mismatch row of
    Nothing -> Right mid
    Just field ->
      Left (MemoryConflict (operation <> ": " <> field <> " differs from the recorded memory"))

-- | Translate a losing concurrent-duplicate race into the success the winner got. See
-- 'Kioku.Session.acceptRejectedIfMatches' — same contract, memory side.
acceptRejectedIfMatches ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  MemoryId ->
  (MemoryRow -> Bool) ->
  Either MemoryWriteError MemoryId ->
  Eff es (Either MemoryWriteError MemoryId)
acceptRejectedIfMatches space mid matches = \case
  Left err@(MemoryCommandRejected CommandRejected) -> do
    reread <- lookupMemory space mid
    pure case reread of
      Right (Just row) | matches row -> Right mid
      _ -> Left err
  other -> pure other

memoryRecordFields :: [FieldCheck RecordMemoryData]
memoryRecordFields =
  [ ("agentId", \d row -> row.agentId == d.agentId),
    ("sessionId", \d row -> row.sessionId == (idText <$> d.sessionId)),
    ("namespace", \d row -> row.namespace == scopeNamespaceText d.scope),
    ("scopeKind", \d row -> row.scopeKind == scopeKindText d.scope),
    ("scopeRef", \d row -> row.scopeRef == scopeRefText d.scope),
    ("memoryType", \d row -> row.memoryType == memoryTypeToText d.memoryType),
    ("content", \d row -> row.content == d.content),
    ("priority", \d row -> row.priority == d.priority),
    ("confidence", \d row -> row.confidence == confidenceToText d.confidence),
    ("tags", \d row -> row.tags == d.tags),
    ("supersedes", \d row -> row.supersedes == (idText <$> d.supersedes))
  ]

memorySupersedeFields :: [FieldCheck SupersedeMemoryData]
memorySupersedeFields =
  [ ("status", \_ row -> row.status == "superseded"),
    ("supersededBy", \d row -> row.supersededBy == Just (idText d.supersededBy))
  ]

memoryArchiveFields :: [FieldCheck ArchiveMemoryData]
memoryArchiveFields =
  [("status", \_ row -> row.status == "archived")]

-- | The projection records the merge target in @superseded_by@. Keyed on the winner id
-- alone, not a command payload, because 'merge' generates its own timestamp.
memoryMergeFields :: [FieldCheck MemoryId]
memoryMergeFields =
  [ ("status", \_ row -> row.status == "merged"),
    ("mergedInto", \winner row -> row.supersededBy == Just (idText winner))
  ]

-- | Require a lineage id to resolve inside the source memory's space. The scoped query makes a
-- target in another space indistinguishable from one that does not exist, preserving the same
-- no-oracle behavior as source-memory lookups.
requireLineageTarget ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  MemoryId ->
  Eff es (Either MemoryWriteError ())
requireLineageTarget space target =
  lookupMemory space target <&> \case
    Left err -> Left (MemoryReadFailed err)
    Right Nothing -> Left MemoryNotFound
    Right (Just _) -> Right ()

requireOptionalLineageTarget ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  Maybe MemoryId ->
  Eff es (Either MemoryWriteError ())
requireOptionalLineageTarget _ Nothing = pure (Right ())
requireOptionalLineageTarget space (Just target) = requireLineageTarget space target

-- | Look a memory up inside one space. A memory that lives elsewhere is 'Nothing' here, which
-- is what makes the write paths' idempotency prechecks unable to answer questions about it.
lookupMemory ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  MemoryId ->
  Eff es (Either ReadModelError (Maybe MemoryRow))
lookupMemory space mid =
  runQueryWith
    Nothing
    Eventual
    memoryByIdReadModel
    MemoryByIdQuery {memorySpaceId = space, memoryId = idText mid}

getMemoryRowById ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  MemoryId ->
  Eff es (Either ReadModelError (Maybe MemoryRow))
getMemoryRowById =
  lookupMemory

getActiveRowsInNamespace ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  Namespace ->
  Eff es (Either ReadModelError [MemoryRow])
getActiveRowsInNamespace space (Namespace ns) =
  runQueryWith
    Nothing
    Eventual
    memoriesByNamespaceRowsReadModel
    MemoriesByNamespaceQuery {memorySpaceId = space, namespace = ns}

getActiveRowsByScope ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  MemoryScope ->
  Eff es (Either ReadModelError [MemoryRow])
getActiveRowsByScope space scope =
  runQueryWith
    Nothing
    Eventual
    memoriesByScopeRowsReadModel
    MemoriesByScopeQuery
      { memorySpaceId = space,
        namespace = scopeNamespaceText scope,
        scopeKind = scopeKindText scope,
        scopeRef = scopeRefText scope
      }

getRowsBySession ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  SessionId ->
  Eff es (Either ReadModelError [MemoryRow])
getRowsBySession space sid =
  runQueryWith
    Nothing
    Eventual
    memoriesBySessionRowsReadModel
    MemoriesBySessionQuery {memorySpaceId = space, sessionId = idText sid}

getActiveRowsByType ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  Namespace ->
  MemoryType ->
  Eff es (Either ReadModelError [MemoryRow])
getActiveRowsByType space (Namespace ns) memoryType =
  runQueryWith
    Nothing
    Eventual
    memoriesByTypeRowsReadModel
    MemoriesByTypeQuery
      { memorySpaceId = space,
        namespace = ns,
        memoryType = memoryTypeToText memoryType
      }

getSupersessionChain ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  MemoryId ->
  Eff es (Either ReadModelError [MemoryRow])
getSupersessionChain space mid =
  runQueryWith
    Nothing
    Eventual
    memorySupersessionChainReadModel
    MemorySupersessionChainQuery {memorySpaceId = space, memoryId = idText mid}

runMemoryCommand ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryId ->
  MemoryCommand ->
  Eff es (Either MemoryWriteError MemoryId)
runMemoryCommand mid cmd = do
  result <-
    runCommandWithProjections
      defaultRunCommandOptions
      memoryEventStream
      (memoryStream mid)
      cmd
      [memoryInlineProjection, l2SceneTimerScheduleProjection]
  pure $
    case result of
      Left err -> Left (MemoryCommandRejected err)
      Right _ -> Right mid
