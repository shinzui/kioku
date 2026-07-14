module Kioku.Memory
  ( MemoryWriteError (..),
    record,
    supersede,
    archive,
    updateTags,
    updateConfidence,
    merge,
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
  deriving stock (Generic, Show)

record ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  RecordMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
record cmdData = do
  existing <- lookupMemory cmdData.memoryId
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right (Just row) -> pure (idempotentOr "record" recordMismatch row cmdData.memoryId)
    Right Nothing ->
      runMemoryCommand cmdData.memoryId (RecordMemory cmdData)
        >>= acceptRejectedIfMatches cmdData.memoryId (isNothing . recordMismatch)
  where
    recordMismatch = mismatchOf memoryRecordFields cmdData

supersede ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  SupersedeMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
supersede cmdData = do
  existing <- lookupMemory cmdData.memoryId
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right Nothing -> pure (Left MemoryNotFound)
    Right (Just row)
      -- Already retired: only a supersession by the *same* winner is this request's own
      -- echo. Superseding by a different winner is a conflict, not a duplicate.
      | row.status /= "active" -> pure (idempotentOr "supersede" supersedeMismatch row cmdData.memoryId)
      | otherwise ->
          runMemoryCommand cmdData.memoryId (SupersedeMemory cmdData)
            >>= acceptRejectedIfMatches cmdData.memoryId (isNothing . supersedeMismatch)
  where
    supersedeMismatch = mismatchOf memorySupersedeFields cmdData

archive ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  ArchiveMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
archive cmdData = do
  existing <- lookupMemory cmdData.memoryId
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right Nothing -> pure (Left MemoryNotFound)
    Right (Just row)
      | row.status /= "active" -> pure (idempotentOr "archive" archiveMismatch row cmdData.memoryId)
      | otherwise ->
          runMemoryCommand cmdData.memoryId (ArchiveMemory cmdData)
            >>= acceptRejectedIfMatches cmdData.memoryId (isNothing . archiveMismatch)
  where
    archiveMismatch = mismatchOf memoryArchiveFields cmdData

updateTags ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  UpdateMemoryTagsData ->
  Eff es (Either MemoryWriteError MemoryId)
updateTags cmdData = do
  existing <- lookupMemory cmdData.memoryId
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right Nothing -> pure (Left MemoryNotFound)
    Right (Just row)
      | row.status /= "active" -> pure (Left MemoryNotActive)
      | row.tags == cmdData.tags -> pure (Right cmdData.memoryId)
      | otherwise -> runMemoryCommand cmdData.memoryId (UpdateMemoryTags cmdData)

updateConfidence ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  UpdateMemoryConfidenceData ->
  Eff es (Either MemoryWriteError MemoryId)
updateConfidence cmdData = do
  existing <- lookupMemory cmdData.memoryId
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right Nothing -> pure (Left MemoryNotFound)
    Right (Just row)
      | row.status /= "active" -> pure (Left MemoryNotActive)
      | row.confidence == confidenceToText cmdData.confidence -> pure (Right cmdData.memoryId)
      | otherwise -> runMemoryCommand cmdData.memoryId (UpdateMemoryConfidence cmdData)

-- | Merge @loser@ into @winner@.
--
-- Unlike the other writes, @mergedAt@ is generated here rather than supplied by the caller,
-- so a retry cannot re-deliver an identical timestamp. Idempotency therefore matches on the
-- merge target alone: merging into the same winner twice is a duplicate, merging into a
-- different one is a conflict.
merge ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryId ->
  MemoryId ->
  Eff es (Either MemoryWriteError MemoryId)
merge loser winner = do
  existing <- lookupMemory loser
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right Nothing -> pure (Left MemoryNotFound)
    Right (Just row)
      | row.status /= "active" -> pure (idempotentOr "merge" mergeMismatch row loser)
      | otherwise -> do
          now <- liftIO getCurrentTime
          runMemoryCommand loser (MergeMemory (MergeMemoryData loser winner now))
            >>= acceptRejectedIfMatches loser (isNothing . mergeMismatch)
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
  MemoryId ->
  (MemoryRow -> Bool) ->
  Either MemoryWriteError MemoryId ->
  Eff es (Either MemoryWriteError MemoryId)
acceptRejectedIfMatches mid matches = \case
  Left err@(MemoryCommandRejected CommandRejected) -> do
    reread <- lookupMemory mid
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

lookupMemory ::
  (IOE :> es, Store :> es) =>
  MemoryId ->
  Eff es (Either ReadModelError (Maybe MemoryRow))
lookupMemory mid =
  runQueryWith Nothing Eventual memoryByIdReadModel (MemoryByIdQuery (idText mid))

getMemoryRowById ::
  (IOE :> es, Store :> es) =>
  MemoryId ->
  Eff es (Either ReadModelError (Maybe MemoryRow))
getMemoryRowById =
  lookupMemory

getActiveRowsInNamespace ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  Eff es (Either ReadModelError [MemoryRow])
getActiveRowsInNamespace (Namespace ns) =
  runQueryWith Nothing Eventual memoriesByNamespaceRowsReadModel (MemoriesByNamespaceQuery ns)

getActiveRowsByScope ::
  (IOE :> es, Store :> es) =>
  MemoryScope ->
  Eff es (Either ReadModelError [MemoryRow])
getActiveRowsByScope scope =
  runQueryWith
    Nothing
    Eventual
    memoriesByScopeRowsReadModel
    (MemoriesByScopeQuery (scopeNamespaceText scope) (scopeKindText scope) (scopeRefText scope))

getRowsBySession ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  Eff es (Either ReadModelError [MemoryRow])
getRowsBySession sid =
  runQueryWith Nothing Eventual memoriesBySessionRowsReadModel (MemoriesBySessionQuery (idText sid))

getActiveRowsByType ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  MemoryType ->
  Eff es (Either ReadModelError [MemoryRow])
getActiveRowsByType (Namespace ns) memoryType =
  runQueryWith Nothing Eventual memoriesByTypeRowsReadModel (MemoriesByTypeQuery ns (memoryTypeToText memoryType))

getSupersessionChain ::
  (IOE :> es, Store :> es) =>
  MemoryId ->
  Eff es (Either ReadModelError [MemoryRow])
getSupersessionChain mid =
  runQueryWith Nothing Eventual memorySupersessionChainReadModel (MemorySupersessionChainQuery (idText mid))

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
