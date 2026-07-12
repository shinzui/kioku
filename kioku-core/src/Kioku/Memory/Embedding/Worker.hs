module Kioku.Memory.Embedding.Worker
  ( EmbeddingWorkerEnv (..),
    EmbedOutcome (..),
    backfillMissingEmbeddings,
    embeddingHandler,
    embeddingWorkerProcessor,
    mkEmbeddingWorkerEnv,
    runEmbeddingWorkerHost,
    shouldSkipEmbedding,
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
import Kioku.Memory.Embedding (EmbedError, embedWithRetry, sha256Hex)
import Kioku.Memory.EventStream (memoryCodec)
import Kioku.Prelude
import Kioku.Recall.Capability (VectorCapability (..))
import Kioku.Worker.Failure (embeddingRetryDelay, isTransientStoreError)
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
    guardKirokuHandler,
    kirokuAdapter,
  )
import Shibuya.App (ProcessorId (..), QueueProcessor (..), defaultAppConfig, runApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..))
import Shibuya.Core.Ingested (Ingested (..), Message (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (Tracing)
import System.IO qualified as IO

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

-- | Everything the embedding path needs from the outside world.
--
-- The provider call is a field rather than a direct 'embedWithRetry' call so
-- tests can drive every branch of the ack taxonomy — a failing provider, a
-- succeeding one, one that returns the wrong number of dimensions — without an
-- embedding API key or a network.
data EmbeddingWorkerEnv = EmbeddingWorkerEnv
  { model :: !EmbeddingModel,
    dimensions :: !Int,
    embed :: !(Text -> IO (Either EmbedError (Vector Double)))
  }
  deriving stock (Generic)

-- | The production environment: the real provider, retried three times
-- in-process (~0.6s of jitter-free backoff) before the failure is reported to
-- the caller, which then decides whether the /event/ should be redelivered.
mkEmbeddingWorkerEnv :: EmbeddingModel -> Int -> EmbeddingWorkerEnv
mkEmbeddingWorkerEnv model dims =
  EmbeddingWorkerEnv {model, dimensions = dims, embed = embedWithRetry model 3}

-- | What one embedding attempt did.
--
-- 'EmbedSkipped' covers both "already embedded with this exact content" and
-- "the memory is not there to embed"; neither is a failure. The distinction
-- that matters to the handler is 'EmbedFailed', which used to be indistinguishable
-- from success.
data EmbedOutcome
  = EmbedSkipped
  | EmbedStored
  | EmbedFailed !EmbedError
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
  started <- runApp defaultAppConfig [processor]
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
          -- The kiroku bridge is ack-coupled: a synchronous exception escaping
          -- the handler leaves the ack unfinalized and blocks the subscription
          -- worker forever. The guard turns that into a one-second retry.
          handler = guardKirokuHandler (embeddingMessageHandler capability (mkEmbeddingWorkerEnv model dims)),
          ordering = StrictInOrder,
          concurrency = Serial
        }
    )

-- | Decide what happens to one delivered @MemoryRecorded@ event.
--
-- Every branch is a deliberate choice about durability:
--
-- * a provider failure is /transient/ — retry with backoff, and let kiroku's
--   retry policy dead-letter it if the outage outlasts the window;
-- * an undecodable payload can never succeed — dead-letter it visibly rather
--   than acking it into the void;
-- * a transient store error must not kill the pipeline — retry;
-- * a permanent store error (a dimension mismatch, a broken schema) would fail
--   identically for every subsequent event — halting is the honest response,
--   because dead-lettering would quietly drain the whole stream.
embeddingHandler ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  VectorCapability ->
  EmbeddingWorkerEnv ->
  Ingested es RecordedEvent ->
  Eff es AckDecision
embeddingHandler capability env ingested =
  handleEmbeddingEnvelope capability env ingested.envelope

embeddingMessageHandler ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  VectorCapability ->
  EmbeddingWorkerEnv ->
  Message es RecordedEvent ->
  Eff es AckDecision
embeddingMessageHandler capability env message =
  handleEmbeddingEnvelope capability env message.envelope

handleEmbeddingEnvelope ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  VectorCapability ->
  EmbeddingWorkerEnv ->
  Envelope RecordedEvent ->
  Eff es AckDecision
handleEmbeddingEnvelope capability env envelope =
  EffError.catchError @StoreError run \_callStack storeErr ->
    if isTransientStoreError storeErr
      then do
        logWorker ("transient store error, retrying: " <> Text.pack (show storeErr))
        pure (AckRetry retryDelay)
      else do
        logWorker ("fatal store error, halting: " <> Text.pack (show storeErr))
        pure (AckHalt (HaltFatal ("kioku embedding worker store error: " <> Text.pack (show storeErr))))
  where
    retryDelay = embeddingRetryDelay envelope.attempt

    run =
      case decodeRecorded memoryCodec envelope.payload of
        Left codecErr -> do
          logWorker ("undecodable event, dead-lettering: " <> Text.pack (show codecErr))
          pure (AckDeadLetter (InvalidPayload (Text.pack (show codecErr))))
        Right (MemoryRecorded d) -> do
          outcome <- embedMemoryContent capability env (idText (d.memoryId :: MemoryId)) d.content
          case outcome of
            EmbedFailed err -> do
              logWorker ("embedding failed, retrying: " <> Text.pack (show err))
              pure (AckRetry retryDelay)
            EmbedStored -> pure AckOk
            EmbedSkipped -> pure AckOk
        -- The subscription is filtered to MemoryRecorded, so this is unreachable
        -- today; acking is the harmless answer if the filter ever widens.
        Right _ -> pure AckOk

logWorker :: (IOE :> es) => Text -> Eff es ()
logWorker msg =
  liftIO (IO.hPutStrLn IO.stderr (Text.unpack (embeddingWorkerName <> ": " <> msg)))

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
    env = mkEmbeddingWorkerEnv model dims

    embedCandidate count candidate
      | shouldSkipEmbedding candidate.hasEmbedding candidate.contentHash contentHash =
          pure count
      | otherwise = do
          outcome <- embedAndStore env candidate.memoryId candidate.content contentHash
          case outcome of
            EmbedStored -> pure (count + 1)
            EmbedSkipped -> pure count
            -- One unembeddable memory must not abort the pass: a backfill exists
            -- precisely to recover from failures, and the next run retries this row.
            EmbedFailed err -> do
              logWorker ("backfill skipped " <> candidate.memoryId <> ": " <> Text.pack (show err))
              pure count
      where
        contentHash = sha256Hex candidate.content
backfillMissingEmbeddings _ _ _ = pure 0

embedMemoryContent ::
  (IOE :> es, Store :> es) =>
  VectorCapability ->
  EmbeddingWorkerEnv ->
  Text ->
  Text ->
  Eff es EmbedOutcome
embedMemoryContent VectorAvailable env memoryId content = do
  existing <- runTransaction (Tx.statement memoryId selectEmbeddingStateStmt)
  case existing of
    Nothing -> pure EmbedSkipped
    Just state
      | shouldSkipEmbedding state.hasEmbedding state.contentHash contentHash ->
          pure EmbedSkipped
      | otherwise ->
          embedAndStore env memoryId content contentHash
  where
    contentHash = sha256Hex content
embedMemoryContent _ _ _ _ = pure EmbedSkipped

shouldSkipEmbedding :: Bool -> Maybe Text -> Text -> Bool
shouldSkipEmbedding hasEmbedding storedContentHash contentHash =
  hasEmbedding && storedContentHash == Just contentHash

embedAndStore ::
  (IOE :> es, Store :> es) =>
  EmbeddingWorkerEnv ->
  Text ->
  Text ->
  Text ->
  Eff es EmbedOutcome
embedAndStore env memoryId content contentHash = do
  result <- liftIO (env.embed content)
  case result of
    Left err -> pure (EmbedFailed err)
    Right embedding -> do
      runTransaction $
        Tx.statement
          EmbeddingUpdate
            { memoryId,
              embedding,
              embeddingModel = env.model.modelId,
              dimensions = env.dimensions,
              contentHash
            }
          upsertEmbeddingStmt
      pure EmbedStored

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
