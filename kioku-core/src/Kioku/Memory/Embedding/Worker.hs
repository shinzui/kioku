module Kioku.Memory.Embedding.Worker
  ( backfillMissingEmbeddings,
    embeddingWorkerProcessor,
    runEmbeddingWorkerHost,
  )
where

import Baikai.Embedding (EmbeddingModel (..))
import Control.Monad (foldM)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int32)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Effectful.Error.Static qualified as EffError
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Codec (decodeRecorded)
import Kioku.Id (MemoryId, idText)
import Kioku.Memory.Domain (MemoryEvent (..), MemoryRecordedData (..))
import Kioku.Memory.Embedding (embedWithRetry, sha256Hex)
import Kioku.Memory.EventStream (memoryCodec)
import Kioku.Prelude
import Kioku.Recall.Capability (VectorCapability (..))
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (CategoryName (..), EventType (..), RecordedEvent)
import Shibuya.Adapter.Kiroku
  ( EventTypeFilter (..),
    KirokuAdapterConfig (..),
    SubscriptionName (..),
    SubscriptionTarget (..),
    defaultKirokuAdapterConfig,
    kirokuAdapter,
  )
import Shibuya.App (ProcessorId (..), QueueProcessor (..), SupervisionStrategy (..), runApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Policy (Concurrency (..), Ordering (..))
import Shibuya.Telemetry.Effect (Tracing)

data EmbeddingCandidate = EmbeddingCandidate
  { memoryId :: !Text,
    content :: !Text,
    contentHash :: !(Maybe Text),
    hasEmbedding :: !Bool
  }
  deriving stock (Generic, Eq, Show)

data EmbeddingUpdate = EmbeddingUpdate
  { memoryId :: !Text,
    embedding :: !(Vector Double),
    embeddingModel :: !Text,
    dimensions :: !Int,
    contentHash :: !Text
  }
  deriving stock (Generic, Eq, Show)

data EmbeddingState = EmbeddingState
  { contentHash :: !(Maybe Text),
    hasEmbedding :: !Bool
  }
  deriving stock (Generic, Eq, Show)

runEmbeddingWorkerHost ::
  (IOE :> es, Store :> es, Error StoreError :> es, Tracing :> es) =>
  KirokuStore ->
  VectorCapability ->
  EmbeddingModel ->
  Int ->
  Eff es ()
runEmbeddingWorkerHost store capability model dims = do
  processor <- embeddingWorkerProcessor capability model dims store
  started <- runApp IgnoreFailures 100 [processor]
  case started of
    Left appErr ->
      liftIO (ioError (userError ("kioku embedding worker failed to start: " <> show appErr)))
    Right appHandle -> do
      liftIO (putStrLn "kioku embedding worker started. Press Ctrl+C to stop.")
      waitApp appHandle

embeddingWorkerProcessor ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  VectorCapability ->
  EmbeddingModel ->
  Int ->
  KirokuStore ->
  Eff es (ProcessorId, QueueProcessor es)
embeddingWorkerProcessor capability model dims store = do
  adapter <- kirokuAdapter store embeddingAdapterConfig
  pure
    ( ProcessorId embeddingWorkerName,
      QueueProcessor
        { adapter,
          handler = embeddingHandler capability model dims,
          ordering = StrictInOrder,
          concurrency = Serial
        }
    )

embeddingHandler ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  VectorCapability ->
  EmbeddingModel ->
  Int ->
  Ingested es RecordedEvent ->
  Eff es AckDecision
embeddingHandler capability model dims ingested =
  EffError.catchError @StoreError
    ( do
        processRecordedEvent capability model dims ingested.envelope.payload
        pure AckOk
    )
    \_callStack storeErr ->
      pure (AckHalt (HaltFatal ("kioku embedding worker store error: " <> Text.pack (show storeErr))))

processRecordedEvent ::
  (IOE :> es, Store :> es) =>
  VectorCapability ->
  EmbeddingModel ->
  Int ->
  RecordedEvent ->
  Eff es ()
processRecordedEvent capability model dims recorded =
  case decodeRecorded memoryCodec recorded of
    Right (MemoryRecorded d) ->
      void (embedMemoryContent capability model dims (idText (d.memoryId :: MemoryId)) d.content)
    Right _ ->
      pure ()
    Left _ ->
      pure ()

backfillMissingEmbeddings ::
  (IOE :> es, Store :> es) =>
  VectorCapability ->
  EmbeddingModel ->
  Int ->
  Eff es Int
backfillMissingEmbeddings VectorAvailable model dims = do
  candidates <- runTransaction (Tx.statement () selectEmbeddingCandidatesStmt)
  foldM embedCandidate 0 candidates
  where
    embedCandidate count candidate
      | candidate.hasEmbedding && candidate.contentHash == Just contentHash =
          pure count
      | otherwise = do
          embedded <- embedAndStore candidate.memoryId model dims candidate.content contentHash
          pure (if embedded then count + 1 else count)
      where
        contentHash = sha256Hex candidate.content
backfillMissingEmbeddings _ _ _ = pure 0

embedMemoryContent ::
  (IOE :> es, Store :> es) =>
  VectorCapability ->
  EmbeddingModel ->
  Int ->
  Text ->
  Text ->
  Eff es Bool
embedMemoryContent VectorAvailable model dims memoryId content = do
  existing <- runTransaction (Tx.statement memoryId selectEmbeddingStateStmt)
  case existing of
    Nothing -> pure False
    Just state
      | state.hasEmbedding && state.contentHash == Just contentHash ->
          pure False
      | otherwise ->
          embedAndStore memoryId model dims content contentHash
  where
    contentHash = sha256Hex content
embedMemoryContent _ _ _ _ _ = pure False

embedAndStore ::
  (IOE :> es, Store :> es) =>
  Text ->
  EmbeddingModel ->
  Int ->
  Text ->
  Text ->
  Eff es Bool
embedAndStore memoryId model dims content contentHash = do
  result <- liftIO (embedWithRetry model 3 content)
  case result of
    Left _err -> pure False
    Right embedding -> do
      runTransaction $
        Tx.statement
          EmbeddingUpdate
            { memoryId,
              embedding,
              embeddingModel = model.modelId,
              dimensions = dims,
              contentHash
            }
          upsertEmbeddingStmt
      pure True

selectEmbeddingCandidatesStmt :: Statement () [EmbeddingCandidate]
selectEmbeddingCandidatesStmt =
  preparable
    """
    SELECT memory_id, content, content_hash, embedding IS NOT NULL AS has_embedding
    FROM kiroku.kioku_memories
    WHERE status = 'active'
    ORDER BY created_at ASC
    """
    E.noParams
    (D.rowList embeddingCandidateDecoder)

selectEmbeddingStateStmt :: Statement Text (Maybe EmbeddingState)
selectEmbeddingStateStmt =
  preparable
    """
    SELECT content_hash, embedding IS NOT NULL AS has_embedding
    FROM kiroku.kioku_memories
    WHERE memory_id = $1 AND status = 'active'
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe embeddingStateDecoder)

embeddingCandidateDecoder :: D.Row EmbeddingCandidate
embeddingCandidateDecoder =
  EmbeddingCandidate
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.bool)

embeddingStateDecoder :: D.Row EmbeddingState
embeddingStateDecoder =
  EmbeddingState
    <$> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.bool)

upsertEmbeddingStmt :: Statement EmbeddingUpdate ()
upsertEmbeddingStmt =
  preparable
    """
    UPDATE kiroku.kioku_memories
    SET embedding = $2::vector,
        embedding_model = $3,
        dimensions = $4,
        content_hash = $5
    WHERE memory_id = $1
    """
    embeddingUpdateEncoder
    D.noResult

embeddingUpdateEncoder :: E.Params EmbeddingUpdate
embeddingUpdateEncoder =
  ((\update -> update.memoryId) >$< E.param (E.nonNullable E.text))
    <> ((\update -> vectorLiteral update.embedding) >$< E.param (E.nonNullable E.text))
    <> ((\update -> update.embeddingModel) >$< E.param (E.nonNullable E.text))
    <> ((\update -> fromIntegral @Int @Int32 update.dimensions) >$< E.param (E.nonNullable E.int4))
    <> ((\update -> update.contentHash) >$< E.param (E.nonNullable E.text))

vectorLiteral :: Vector Double -> Text
vectorLiteral values =
  "[" <> Text.intercalate "," (Text.pack . show <$> Vector.toList values) <> "]"

embeddingAdapterConfig :: KirokuAdapterConfig
embeddingAdapterConfig =
  (defaultKirokuAdapterConfig (SubscriptionName embeddingWorkerName) (Category (CategoryName "kioku_memory")))
    { eventTypeFilter = OnlyEventTypes (Set.fromList [EventType "MemoryRecorded"])
    }

embeddingWorkerName :: Text
embeddingWorkerName = "kioku-memory-embedding"
