module Kioku.Memory
  ( MemoryWriteError (..),
    record,
    supersede,
    archive,
    updateTags,
    updateConfidence,
    merge,
  )
where

import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Command (CommandError, defaultRunCommandOptions)
import Keiro.Projection (runCommandWithProjections)
import Keiro.ReadModel (ConsistencyMode (..), ReadModelError, runQueryWith)
import Kioku.Api.Types (confidenceToText)
import Kioku.Distill.L2 (l2SceneTimerScheduleProjection)
import Kioku.Id (MemoryId, idText)
import Kioku.Memory.Domain
import Kioku.Memory.EventStream (memoryEventStream, memoryStream)
import Kioku.Memory.ReadModel (MemoryByIdQuery (..), MemoryRow (..), memoryByIdReadModel, memoryInlineProjection)
import Kioku.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)

data MemoryWriteError
  = MemoryCommandRejected !CommandError
  | MemoryReadFailed !ReadModelError
  | MemoryNotFound
  | MemoryNotActive
  deriving stock (Generic, Show)

record ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  RecordMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
record cmdData = do
  existing <- lookupMemory cmdData.memoryId
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right (Just _) -> pure (Right cmdData.memoryId)
    Right Nothing ->
      runMemoryCommand cmdData.memoryId (RecordMemory cmdData)

supersede ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SupersedeMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
supersede cmdData = do
  existing <- lookupMemory cmdData.memoryId
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right Nothing -> pure (Left MemoryNotFound)
    Right (Just row)
      | row.status /= "active" -> pure (Right cmdData.memoryId)
      | otherwise -> runMemoryCommand cmdData.memoryId (SupersedeMemory cmdData)

archive ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  ArchiveMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)
archive cmdData = do
  existing <- lookupMemory cmdData.memoryId
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right Nothing -> pure (Left MemoryNotFound)
    Right (Just row)
      | row.status /= "active" -> pure (Right cmdData.memoryId)
      | otherwise -> runMemoryCommand cmdData.memoryId (ArchiveMemory cmdData)

updateTags ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
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
  (IOE :> es, Store :> es, Error StoreError :> es) =>
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

merge ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  MemoryId ->
  MemoryId ->
  Eff es (Either MemoryWriteError MemoryId)
merge loser winner = do
  existing <- lookupMemory loser
  case existing of
    Left err -> pure (Left (MemoryReadFailed err))
    Right Nothing -> pure (Left MemoryNotFound)
    Right (Just row)
      | row.status /= "active" -> pure (Right loser)
      | otherwise -> do
          now <- liftIO getCurrentTime
          runMemoryCommand loser (MergeMemory (MergeMemoryData loser winner now))

lookupMemory ::
  (IOE :> es, Store :> es) =>
  MemoryId ->
  Eff es (Either ReadModelError (Maybe MemoryRow))
lookupMemory mid =
  runQueryWith Nothing Eventual memoryByIdReadModel (MemoryByIdQuery (idText mid))

runMemoryCommand ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
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
