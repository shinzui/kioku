-- | The embedding worker: it computes a vector for each memory's content and writes it back onto
-- the same row.
--
-- Like the distillation timers, this worker discovers its own work, so it cannot arrive holding
-- an authorization context. It takes the memory space out of the delivered @MemoryRecorded@
-- event and asks a 'MemoryContextProvider' for a decision about /that/ space; a refusal
-- dead-letters, because a worker that is not allowed to embed a space is a configuration fact
-- and retrying it every second would hide it.
--
-- Three things then carry the partition, and each closes a different hole:
--
-- * the state read returns the row's /own/ space, and a disagreement with the envelope is
--   'EmbedSpaceMismatch' — dead-lettered, never mutated. Scoping that read by the envelope's
--   space instead would turn the disagreement into "no such memory", which acks as a success;
-- * the update names the space as well as the id, so a redelivery cannot enrich a row outside
--   the space its event named however stale the envelope has become;
-- * the backfill scan takes an 'EmbeddingBackfillScope', so an operator can run the pass for one
--   space rather than for every space in the database.
--
-- None of this is an authorization boundary in the sense recall is: a memory's embedding is a
-- property of the memory, no content reaches a caller, and a process holding the database
-- credentials may already act in any space in that database — which is what
-- 'Kioku.Api.Access.assumeAuthorizedContextProvider' says out loud. It is a /durable work
-- identity/ boundary: at-least-once delivery means the same envelope is handled repeatedly, and
-- every one of those attempts must land in the space the event named.
module Kioku.Memory.Embedding.Worker
  ( EmbeddingWorkerEnv (..),
    EmbedOutcome (..),
    EmbeddingBackfillScope (..),
    backfillMissingEmbeddings,
    selectEmbeddingCandidateIds,
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
import Kioku.Api.Access
  ( MemoryContextProvider (..),
    MemoryPermission (..),
    MemorySpaceId,
    memoryContextAllows,
    memoryContextSpace,
    memorySpaceIdText,
  )
import Kioku.Database.Schema (memoriesTable)
import Kioku.Id (MemoryId, idText)
import Kioku.Memory.Domain (MemoryEvent (..), MemoryRecordedData (..))
import Kioku.Memory.Embedding (EmbedError, embedWithRetry, sha256Hex)
import Kioku.Memory.EventStream (memoryCodec)
import Kioku.Partition (memorySpaceColumn, memorySpaceParam)
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
  { memorySpaceId :: !MemorySpaceId,
    memoryId :: !Text,
    content :: !Text,
    contentHash :: !(Maybe Text),
    hasEmbedding :: !Bool
  }
  deriving stock (Generic, Eq, Show)

data EmbeddingUpdate = EmbeddingUpdate
  { memorySpaceId :: !MemorySpaceId,
    memoryId :: !Text,
    embedding :: !(Vector Double),
    embeddingModel :: !Text,
    dimensions :: !Int,
    contentHash :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | What the row itself says, including which space it is in.
--
-- The space is read back rather than asserted because that is the only way the handler can tell
-- a stale envelope from a missing memory. See 'EmbedSpaceMismatch'.
data EmbeddingState = EmbeddingState
  { memorySpaceId :: !MemorySpaceId,
    contentHash :: !(Maybe Text),
    hasEmbedding :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | Which memory spaces one backfill pass covers.
--
-- 'BackfillEverySpace' is what the continuous worker runs at startup: it serves every space the
-- database holds, so recovering embeddings for only one of them would leave the rest silently
-- unsearchable. 'BackfillOneSpace' is for an operator repairing a single tenant, and for the
-- case where a pass over every space would be too large to finish.
data EmbeddingBackfillScope
  = BackfillEverySpace
  | BackfillOneSpace !MemorySpaceId
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
--
-- 'EmbedSpaceMismatch' is the one outcome that must never be quiet. It means a delivered event
-- named one memory space and the row it names is in another, which is a forged or corrupt
-- envelope rather than an ordinary failure — no retry can fix it and nothing was written. It
-- carries the envelope's space first and the row's second.
data EmbedOutcome
  = EmbedSkipped
  | EmbedStored
  | EmbedFailed !EmbedError
  | EmbedSpaceMismatch !MemorySpaceId !MemorySpaceId
  deriving stock (Generic, Eq, Show)

runEmbeddingWorkerHost ::
  (IOE :> es, Store :> es, Error StoreError :> es, Tracing :> es) =>
  KirokuStore ->
  MemoryContextProvider (Eff es) ->
  VectorCapability ->
  EmbeddingModel ->
  Int ->
  Eff es ()
runEmbeddingWorkerHost store contexts capability model dims = do
  processor <- embeddingWorkerProcessor contexts capability model dims store
  started <- runApp defaultAppConfig [processor]
  case started of
    Left appErr ->
      liftIO (ioError (userError ("kioku embedding worker failed to start: " <> show appErr)))
    Right appHandle -> do
      liftIO (putStrLn "kioku embedding worker started. Press Ctrl+C to stop.")
      waitApp appHandle

embeddingWorkerProcessor ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  MemoryContextProvider (Eff es) ->
  VectorCapability ->
  EmbeddingModel ->
  Int ->
  KirokuStore ->
  Eff es (ProcessorId, QueueProcessor es)
embeddingWorkerProcessor contexts capability model dims store = do
  adapter <- kirokuAdapter store embeddingAdapterConfig
  pure
    ( ProcessorId embeddingWorkerName,
      QueueProcessor
        { adapter,
          -- The kiroku bridge is ack-coupled: a synchronous exception escaping
          -- the handler leaves the ack unfinalized and blocks the subscription
          -- worker forever. The guard turns that into a one-second retry.
          handler = guardKirokuHandler (embeddingMessageHandler contexts capability (mkEmbeddingWorkerEnv model dims)),
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
--
-- Two branches are about the partition rather than about durability. A provider that refuses
-- this event's memory space dead-letters, matching 'Kioku.Distill.Timer.Worker.fireL1Timer': a
-- worker that may not embed a space is a configuration fact, and an operator requeues the
-- dead-letter row once it is fixed. An envelope whose space disagrees with the row's own space
-- dead-letters too, and writes nothing.
embeddingHandler ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  MemoryContextProvider (Eff es) ->
  VectorCapability ->
  EmbeddingWorkerEnv ->
  Ingested es RecordedEvent ->
  Eff es AckDecision
embeddingHandler contexts capability env ingested =
  handleEmbeddingEnvelope contexts capability env ingested.envelope

embeddingMessageHandler ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  MemoryContextProvider (Eff es) ->
  VectorCapability ->
  EmbeddingWorkerEnv ->
  Message es RecordedEvent ->
  Eff es AckDecision
embeddingMessageHandler contexts capability env message =
  handleEmbeddingEnvelope contexts capability env message.envelope

handleEmbeddingEnvelope ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  MemoryContextProvider (Eff es) ->
  VectorCapability ->
  EmbeddingWorkerEnv ->
  Envelope RecordedEvent ->
  Eff es AckDecision
handleEmbeddingEnvelope contexts capability env envelope =
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
          decision <- contexts.contextForSpace d.memorySpaceId
          case decision of
            Left denial -> do
              let reason =
                    "not authorized to embed memory space "
                      <> memorySpaceIdText d.memorySpaceId
                      <> ": "
                      <> Text.pack (show denial)
              logWorker ("dead-lettering: " <> reason)
              pure (AckDeadLetter (InvalidPayload reason))
            Right context
              | not (memoryContextAllows MemoryDistill context) -> do
                  let reason =
                        "context for memory space "
                          <> memorySpaceIdText d.memorySpaceId
                          <> " does not grant distill"
                  logWorker ("dead-lettering: " <> reason)
                  pure (AckDeadLetter (InvalidPayload reason))
              | otherwise -> do
                  outcome <-
                    embedMemoryContent
                      capability
                      env
                      (memoryContextSpace context)
                      (idText (d.memoryId :: MemoryId))
                      d.content
                  case outcome of
                    EmbedFailed err -> do
                      logWorker ("embedding failed, retrying: " <> Text.pack (show err))
                      pure (AckRetry retryDelay)
                    EmbedSpaceMismatch expected actual -> do
                      let reason =
                            "event claims memory space "
                              <> memorySpaceIdText expected
                              <> " but memory "
                              <> idText (d.memoryId :: MemoryId)
                              <> " is in "
                              <> memorySpaceIdText actual
                      logWorker ("dead-lettering: " <> reason)
                      pure (AckDeadLetter (InvalidPayload reason))
                    EmbedStored -> pure AckOk
                    EmbedSkipped -> pure AckOk
        -- The subscription is filtered to MemoryRecorded, so this is unreachable
        -- today; acking is the harmless answer if the filter ever widens.
        Right _ -> pure AckOk

logWorker :: (IOE :> es) => Text -> Eff es ()
logWorker msg =
  liftIO (IO.hPutStrLn IO.stderr (Text.unpack (embeddingWorkerName <> ": " <> msg)))

-- | Embed every active memory that is missing a current vector, in one space or in all of them.
--
-- A candidate carries the space it was read from, so the update writes back into that same
-- space. There is no mismatch branch here and there cannot be one: unlike the subscription
-- handler, this pass has no envelope to disagree with the row.
-- It takes a whole 'EmbeddingWorkerEnv' rather than a model and a dimension count, for the
-- reason that record exists: a test can drive the pass with a fake provider, which is the only
-- way to assert /which rows/ a scope selected without an embedding API key and a network.
backfillMissingEmbeddings ::
  (IOE :> es, Store :> es) =>
  VectorCapability ->
  EmbeddingWorkerEnv ->
  EmbeddingBackfillScope ->
  Eff es Int
backfillMissingEmbeddings VectorAvailable env scope = do
  candidates <- selectEmbeddingCandidates scope
  foldM embedCandidate 0 candidates
  where
    embedCandidate count candidate
      | shouldSkipEmbedding candidate.hasEmbedding candidate.contentHash contentHash =
          pure count
      | otherwise = do
          outcome <-
            embedAndStore env candidate.memorySpaceId candidate.memoryId candidate.content contentHash
          case outcome of
            EmbedStored -> pure (count + 1)
            EmbedSkipped -> pure count
            -- One unembeddable memory must not abort the pass: a backfill exists
            -- precisely to recover from failures, and the next run retries this row.
            EmbedFailed err -> do
              logWorker ("backfill skipped " <> candidate.memoryId <> ": " <> Text.pack (show err))
              pure count
            -- Unreachable: the candidate's space came from the row being updated.
            EmbedSpaceMismatch expected actual -> do
              logWorker
                ( "backfill skipped "
                    <> candidate.memoryId
                    <> ": read in "
                    <> memorySpaceIdText expected
                    <> " but now in "
                    <> memorySpaceIdText actual
                )
              pure count
      where
        contentHash = sha256Hex candidate.content
backfillMissingEmbeddings _ _ _ = pure 0

-- | Return only the identities that the production backfill statements actually transferred.
--
-- This deliberately projects from decoded 'EmbeddingCandidate' values after running the same
-- statements as 'backfillMissingEmbeddings'. It is a regression seam for the database/Haskell
-- transfer boundary, not a second spelling of candidate eligibility.
selectEmbeddingCandidateIds ::
  (Store :> es) =>
  EmbeddingBackfillScope ->
  Eff es [(MemorySpaceId, Text)]
selectEmbeddingCandidateIds scope =
  fmap (\candidate -> (candidate.memorySpaceId, candidate.memoryId))
    <$> selectEmbeddingCandidates scope

selectEmbeddingCandidates ::
  (Store :> es) =>
  EmbeddingBackfillScope ->
  Eff es [EmbeddingCandidate]
selectEmbeddingCandidates scope =
  runTransaction $
    case scope of
      BackfillEverySpace -> Tx.statement () selectEmbeddingCandidatesStmt
      BackfillOneSpace space -> Tx.statement space selectEmbeddingCandidatesInSpaceStmt

-- | Embed one memory, refusing to touch it if it is not in the space the caller named.
--
-- The state read is keyed by the memory id alone, which is globally unique, and returns the
-- row's own space. That is deliberate and is the opposite of a leak: reading the space in order
-- to compare it is what makes a disagreement loud. Scoping the read by @space AND id@ would
-- report a memory in another space as absent, and absent is an ack.
embedMemoryContent ::
  (IOE :> es, Store :> es) =>
  VectorCapability ->
  EmbeddingWorkerEnv ->
  MemorySpaceId ->
  Text ->
  Text ->
  Eff es EmbedOutcome
embedMemoryContent VectorAvailable env memorySpaceId memoryId content = do
  existing <- runTransaction (Tx.statement memoryId selectEmbeddingStateStmt)
  case existing of
    Nothing -> pure EmbedSkipped
    Just state
      | state.memorySpaceId /= memorySpaceId ->
          pure (EmbedSpaceMismatch memorySpaceId state.memorySpaceId)
      | shouldSkipEmbedding state.hasEmbedding state.contentHash contentHash ->
          pure EmbedSkipped
      | otherwise ->
          embedAndStore env memorySpaceId memoryId content contentHash
  where
    contentHash = sha256Hex content
embedMemoryContent _ _ _ _ _ = pure EmbedSkipped

shouldSkipEmbedding :: Bool -> Maybe Text -> Text -> Bool
shouldSkipEmbedding hasEmbedding storedContentHash contentHash =
  hasEmbedding && storedContentHash == Just contentHash

embedAndStore ::
  (IOE :> es, Store :> es) =>
  EmbeddingWorkerEnv ->
  MemorySpaceId ->
  Text ->
  Text ->
  Text ->
  Eff es EmbedOutcome
embedAndStore env memorySpaceId memoryId content contentHash = do
  result <- liftIO (env.embed content)
  case result of
    Left err -> pure (EmbedFailed err)
    Right embedding -> do
      runTransaction $
        Tx.statement
          EmbeddingUpdate
            { memorySpaceId,
              memoryId,
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
    ( """
      SELECT memory_space_id, memory_id, content, content_hash, embedding IS NOT NULL AS has_embedding
      FROM
      """
        <> " "
        <> memoriesTable
        <> " "
        <> "WHERE status = 'active' AND "
        <> embeddingCandidatePredicate
        <> " ORDER BY created_at ASC"
    )
    E.noParams
    (D.rowList embeddingCandidateDecoder)

-- | The same scan bounded to one space, so an operator can repair one tenant.
--
-- @memory_space_id@ leads @kioku_memories_space_namespace_idx@, but this predicate carries no
-- namespace and orders by @created_at@, so the planner is free to prefer a scan. That is
-- correct: a backfill visits every unembedded row in the space by definition, and the point of
-- the predicate here is which rows are eligible, not how they are reached.
selectEmbeddingCandidatesInSpaceStmt :: Statement MemorySpaceId [EmbeddingCandidate]
selectEmbeddingCandidatesInSpaceStmt =
  preparable
    ( """
      SELECT memory_space_id, memory_id, content, content_hash, embedding IS NOT NULL AS has_embedding
      FROM
      """
        <> " "
        <> memoriesTable
        <> " "
        <> "WHERE status = 'active' AND memory_space_id = $1 AND "
        <> embeddingCandidatePredicate
        <> " ORDER BY created_at ASC"
    )
    memorySpaceParam
    (D.rowList embeddingCandidateDecoder)

-- | Candidate eligibility belongs at the transfer boundary. PostgreSQL calculates the same
-- lowercase hexadecimal SHA-256 that 'sha256Hex' calculates in Haskell, so settled content is
-- rejected before its full text crosses the Hasql connection. 'shouldSkipEmbedding' remains the
-- later race check after a row has already been selected.
embeddingCandidatePredicate :: Text
embeddingCandidatePredicate =
  """
  (embedding IS NULL
   OR content_hash IS DISTINCT FROM encode(sha256(convert_to(content, 'UTF8')), 'hex'))
  """

selectEmbeddingStateStmt :: Statement Text (Maybe EmbeddingState)
selectEmbeddingStateStmt =
  preparable
    ( """
      SELECT memory_space_id, content_hash, embedding IS NOT NULL AS has_embedding
      FROM
      """
        <> " "
        <> memoriesTable
        <> " "
        <> """
           WHERE memory_id = $1 AND status = 'active'
           """
    )
    (E.param (E.nonNullable E.text))
    (D.rowMaybe embeddingStateDecoder)

embeddingCandidateDecoder :: D.Row EmbeddingCandidate
embeddingCandidateDecoder =
  EmbeddingCandidate
    <$> memorySpaceColumn
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.bool)

embeddingStateDecoder :: D.Row EmbeddingState
embeddingStateDecoder =
  EmbeddingState
    <$> memorySpaceColumn
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.bool)

-- | The write names the space as well as the id.
--
-- 'embedMemoryContent' has already compared the two, so this predicate can never be the thing
-- that rejects a row — but the comparison and the write are two statements, and between them a
-- memory could in principle be rewritten into another space. The predicate is what makes the
-- write itself, rather than a check that preceded it, the thing that is partition-safe.
upsertEmbeddingStmt :: Statement EmbeddingUpdate ()
upsertEmbeddingStmt =
  preparable
    ( "UPDATE "
        <> memoriesTable
        <> "\n"
        <> """
           SET embedding = $3::vector,
               embedding_model = $4,
               dimensions = $5,
               content_hash = $6
           WHERE memory_space_id = $1 AND memory_id = $2
           """
    )
    embeddingUpdateEncoder
    D.noResult

embeddingUpdateEncoder :: E.Params EmbeddingUpdate
embeddingUpdateEncoder =
  ((\update -> update.memorySpaceId) >$< memorySpaceParam)
    <> ((\update -> update.memoryId) >$< E.param (E.nonNullable E.text))
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
