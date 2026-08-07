{-# LANGUAGE DataKinds #-}

module Kioku.EmbeddingWorkerSpec
  ( tests,
  )
where

import Baikai.Embedding (EmbeddingModel)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.HashMap.Strict qualified as HashMap
import Data.Set qualified as Set
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Stream qualified as Stream
import Kioku.Api.Access
  ( MemoryAccessContext,
    MemoryAccessDenial (..),
    MemoryContextProvider (..),
    MemoryPermission (..),
    MemorySpaceId,
    memoryContextRecordedActor,
    memoryContextSpace,
  )
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (Confidence (..), MemoryType (..))
import Kioku.App (AppEffects, AppEnv, runAppIO, withNoopAppEnv)
import Kioku.Id (MemoryId, genMemoryId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Memory.Embedding (EmbedError (..), EmbeddingConfig (..), toEmbeddingModel)
import Kioku.Memory.Embedding.Worker
  ( EmbeddingBackfillScope (..),
    EmbeddingWorkerEnv (..),
    backfillMissingEmbeddings,
    embeddingHandler,
    shouldSkipEmbedding,
  )
import Kioku.Memory.EventStream (memoryStream)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Prelude
import Kioku.Recall.Capability (VectorCapability (..), detectVectorCapability)
import Kioku.SpaceFixtures (otherContext, otherSpace, testContext, testContextProvider, testSpace)
import Kioku.Worker.Failure (embeddingRetryDelay, isTransientStoreError)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (ExpectedVersion (..), RecordedEvent (..), StreamName (..), StreamVersion (..))
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..), MessageId (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Embedding worker"
    [ testCase "skips only when the embedding exists and the content hash matches" do
        shouldSkipEmbedding True (Just "hash-a") "hash-a" @?= True
        shouldSkipEmbedding False (Just "hash-a") "hash-a" @?= False
        shouldSkipEmbedding True Nothing "hash-a" @?= False
        shouldSkipEmbedding True (Just "hash-b") "hash-a" @?= False,
      testCase "classifies only connection-shaped store errors as transient" testTransientClassification,
      testCase "backs off on the documented retry schedule" testRetrySchedule,
      testCase "provider failure acks retry" testProviderFailureRetries,
      testCase "undecodable payload acks dead-letter" testUndecodablePayloadDeadLetters,
      testCase "successful embedding acks ok and stores the vector" testSuccessStoresEmbedding,
      testCase "dimension mismatch halts the processor" testDimensionMismatchHalts,
      testCase "a refused memory space acks dead-letter" testRefusedSpaceDeadLetters,
      testCase "an envelope naming another space acks dead-letter and writes nothing" testForgedSpaceDeadLetters,
      testCase "a one-space backfill leaves every other space alone" testBackfillHonorsSpace
    ]

-- | Every constructor kiroku documents as retryable is transient; every
-- constructor describing a stable disagreement with the database is not. A new
-- kiroku constructor breaks this test's exhaustiveness at the source, not here.
testTransientClassification :: Assertion
testTransientClassification = do
  isTransientStoreError PoolAcquisitionTimeout @?= True
  isTransientStoreError (ConnectionLost "reset by peer") @?= True
  isTransientStoreError (ConnectionError "pool closed") @?= True
  isTransientStoreError (UnexpectedServerError "22000" "expected 1536 dimensions, not 8") @?= False
  isTransientStoreError (StreamNotFound (StreamName "kioku_memory-x")) @?= False
  isTransientStoreError (DuplicateEvent Nothing) @?= False
  isTransientStoreError (WrongExpectedVersion (StreamName "s") AnyVersion (StreamVersion 0)) @?= False
  isTransientStoreError (EmptyAppendBatch (StreamName "s")) @?= False
  isTransientStoreError (ReservedStreamName (StreamName "$all")) @?= False
  isTransientStoreError (StreamNameTooLong (StreamName "s") 9000) @?= False
  isTransientStoreError (StreamAlreadyExists (StreamName "s")) @?= False
  isTransientStoreError (EventAlreadyLinked (StreamName "s") Nothing) @?= False
  isTransientStoreError (LinkSourceEventMissing (StreamName "s")) @?= False

testRetrySchedule :: Assertion
testRetrySchedule = do
  embeddingRetryDelay (Just (Attempt 0)) @?= RetryDelay 5
  embeddingRetryDelay (Just (Attempt 1)) @?= RetryDelay 20
  embeddingRetryDelay (Just (Attempt 2)) @?= RetryDelay 60
  embeddingRetryDelay (Just (Attempt 3)) @?= RetryDelay 180
  -- An adapter that does not track redeliveries gets the longest delay.
  embeddingRetryDelay Nothing @?= RetryDelay 180

-- | A provider outage must not be acked as success: the event is redelivered
-- with the attempt-indexed backoff, and kiroku's retry policy bounds it.
testProviderFailureRetries :: Assertion
testProviderFailureRetries =
  withVectorEnv "provider failure" \env capability -> do
    decision <-
      runHandler env capability (failingEmbed (EmbedTransport "provider is down")) (Just 0)
    decision @?= AckRetry (embeddingRetryDelay (Just (Attempt 0)))

-- | A payload that cannot be decoded can never succeed. It goes to the
-- dead-letter table with a reason instead of vanishing behind an 'AckOk'.
-- Not gated on pgvector: the handler decides before it touches the memory row.
testUndecodablePayloadDeadLetters :: Assertion
testUndecodablePayloadDeadLetters =
  withEmbeddingEnv \appEnv -> do
    capability <- runOrFail appEnv (detectVectorCapability embeddingDims)
    decision <- runOrFail appEnv do
      (_, recorded) <- recordFixtureMemory testContext "corrupt payload memory"
      let env = mkTestEnv (failingEmbed EmbedEmpty)
      embeddingHandler testContextProvider capability env (mkIngested (corruptPayload recorded) (Just 0))
    case decision of
      AckDeadLetter (InvalidPayload _) -> pure ()
      other -> assertFailure ("expected a dead-letter for an undecodable payload, got: " <> show other)

-- | The happy path still works, and it actually writes: 'AckOk' is only honest
-- if the vector landed in the row.
testSuccessStoresEmbedding :: Assertion
testSuccessStoresEmbedding =
  withVectorEnv "successful embedding" \env capability -> do
    (decision, stored) <-
      runOrFail env do
        (memoryId, recorded) <- recordFixtureMemory testContext "a memory worth embedding"
        let workerEnv = mkTestEnv (\_ -> pure (Right (Vector.replicate embeddingDims 0.1)))
        decision <- embeddingHandler testContextProvider capability workerEnv (mkIngested recorded (Just 0))
        stored <- loadEmbeddingState (idText memoryId)
        pure (decision, stored)
    decision @?= AckOk
    assertBool "the memory row has an embedding and a content hash" stored

-- | The one case where halting is right. A dimension mismatch is a permanent,
-- systemic store error: every subsequent event would fail identically, so
-- dead-lettering would quietly drain the whole stream.
testDimensionMismatchHalts :: Assertion
testDimensionMismatchHalts =
  withVectorEnv "dimension mismatch" \env capability -> do
    decision <-
      runHandler env capability (\_ -> pure (Right (Vector.replicate 8 0.1))) (Just 0)
    case decision of
      AckHalt (HaltFatal _) -> pure ()
      other -> assertFailure ("expected a fatal halt on a dimension mismatch, got: " <> show other)

-- | A provider that refuses every space, as a host with a real authorization engine would when
-- the worker is not allowed to touch this tenant.
refusingContextProvider :: (Applicative m) => MemoryContextProvider m
refusingContextProvider =
  MemoryContextProvider \space -> pure (Left (MemoryPermissionDenied space MemoryDistill))

-- | A worker that may not act in a space must not quietly retry forever. The refusal is a
-- configuration fact: it goes to the dead-letter table where an operator can see it, and the
-- memory row is never read, let alone written.
testRefusedSpaceDeadLetters :: Assertion
testRefusedSpaceDeadLetters =
  withEmbeddingEnv \appEnv -> do
    capability <- runOrFail appEnv (detectVectorCapability embeddingDims)
    decision <- runOrFail appEnv do
      (_, recorded) <- recordFixtureMemory testContext "a memory in a refused space"
      embeddingHandler
        refusingContextProvider
        capability
        (mkTestEnv (\_ -> pure (Right (Vector.replicate embeddingDims 0.1))))
        (mkIngested recorded (Just 0))
    case decision of
      AckDeadLetter (InvalidPayload _) -> pure ()
      other -> assertFailure ("expected a dead-letter for a refused memory space, got: " <> show other)

-- | The case a partition predicate alone cannot catch.
--
-- The event names 'otherSpace'; the memory it names is in 'testSpace'. Had the state read been
-- scoped by the envelope's space, this would have come back as "no such memory" and acked as a
-- success — a forged envelope silently swallowed. Instead the row's own space is read and
-- compared, so the disagreement is visible and nothing is written.
testForgedSpaceDeadLetters :: Assertion
testForgedSpaceDeadLetters =
  withVectorEnv "forged memory space" \appEnv capability -> do
    (decision, embedded) <- runOrFail appEnv do
      (memoryId, recorded) <- recordFixtureMemory testContext "a memory in its real space"
      verdict <-
        embeddingHandler
          testContextProvider
          capability
          (mkTestEnv (\_ -> pure (Right (Vector.replicate embeddingDims 0.1))))
          (mkIngested (retargetSpace otherSpace recorded) (Just 0))
      stored <- loadEmbeddingState (idText memoryId)
      pure (verdict, stored)
    case decision of
      AckDeadLetter (InvalidPayload _) -> pure ()
      other -> assertFailure ("expected a dead-letter for a forged memory space, got: " <> show other)
    assertBool "the forged envelope must not have embedded the row" (not embedded)

-- | A backfill bounded to one space embeds that space and nothing else.
--
-- Both memories are unembedded when the pass starts, so a scan that ignored the predicate would
-- return two rows and the count alone would give it away; the per-row assertions are what prove
-- the /other/ space's row was not merely counted but genuinely left alone.
testBackfillHonorsSpace :: Assertion
testBackfillHonorsSpace =
  withVectorEnv "one-space backfill" \appEnv capability -> do
    (count, mineEmbedded, theirsEmbedded) <- runOrFail appEnv do
      (mine, _) <- recordFixtureMemory testContext "a memory in the backfilled space"
      (theirs, _) <- recordFixtureMemory otherContext "a memory in the untouched space"
      embedded <-
        backfillMissingEmbeddings
          capability
          (mkTestEnv (\_ -> pure (Right (Vector.replicate embeddingDims 0.1))))
          (BackfillOneSpace testSpace)
      (embedded,,) <$> loadEmbeddingState (idText mine) <*> loadEmbeddingState (idText theirs)
    assertBool ("the backfill embedded nothing (count " <> show count <> ")") (count >= 1)
    assertBool "the backfilled space's memory has no embedding" mineEmbedded
    assertBool "the untouched space's memory was embedded anyway" (not theirsEmbedded)

-- | Record a memory, then hand back its id and the @MemoryRecorded@ event at
-- the head of its stream — a real recorded event, not a hand-built one.
recordFixtureMemory ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  Text ->
  Eff es (MemoryId, RecordedEvent)
recordFixtureMemory context content = do
  memoryId <- liftIO genMemoryId
  now <- liftIO getCurrentTime
  recorded <-
    Memory.recordWithContext
      context
      RecordMemoryData
        { memorySpaceId = memoryContextSpace context,
          actorPrincipal = memoryContextRecordedActor context,
          ownerPrincipal = Nothing,
          memoryId,
          agentId = "test-agent",
          sessionId = Nothing,
          scope = fixtureScope,
          memoryType = MemoryPreference,
          content,
          priority = 5,
          confidence = HighConfidence,
          tags = Set.fromList ["embedding-worker-spec"],
          supersedes = Nothing,
          recordedAt = now
        }
  void (liftIO (expectRight "Memory.recordWithContext" recorded))
  events <- readStreamForward (Stream.streamName (memoryStream memoryId)) (StreamVersion 0) 10
  case Vector.toList events of
    event : _ -> pure (memoryId, event)
    [] -> liftIO (assertFailure "the recorded memory has no events")

-- | Replace the event payload with something the memory codec cannot decode.
-- Spelled out field by field rather than as a record update because @payload@
-- is also an 'Envelope' field, and GHC will not guess which one is meant.
corruptPayload :: RecordedEvent -> RecordedEvent
corruptPayload e = withPayload e (Aeson.String "garbage")

-- | Rewrite a recorded event's @memorySpaceId@, leaving everything else — including the memory
-- id — exactly as it was written. This is what a stale or forged envelope looks like.
--
-- The event encoding is a tagged object (@Kioku.Prelude.eventAesonOptions@), so the field lives
-- under @data@ rather than at the top level. An unexpected shape is fatal rather than a no-op:
-- silently returning the event unchanged would make this test pass by testing nothing.
retargetSpace :: MemorySpaceId -> RecordedEvent -> RecordedEvent
retargetSpace space e =
  withPayload e $
    case e.payload of
      Aeson.Object o
        | Just (Aeson.Object d) <- KeyMap.lookup "data" o ->
            Aeson.Object
              (KeyMap.insert "data" (Aeson.Object (KeyMap.insert "memorySpaceId" (Aeson.toJSON space) d)) o)
      other -> error ("retargetSpace: unexpected event payload shape: " <> show other)

withPayload :: RecordedEvent -> Aeson.Value -> RecordedEvent
withPayload e payload =
  RecordedEvent
    { eventId = e.eventId,
      eventType = e.eventType,
      streamVersion = e.streamVersion,
      globalPosition = e.globalPosition,
      originalStreamId = e.originalStreamId,
      originalVersion = e.originalVersion,
      payload,
      metadata = e.metadata,
      causationId = e.causationId,
      correlationId = e.correlationId,
      createdAt = e.createdAt
    }

runHandler ::
  AppEnv ->
  VectorCapability ->
  (Text -> IO (Either EmbedError (Vector.Vector Double))) ->
  Maybe Word ->
  IO AckDecision
runHandler appEnv capability embed attemptN =
  runOrFail appEnv do
    (_, recorded) <- recordFixtureMemory testContext "a memory to embed"
    embeddingHandler testContextProvider capability (mkTestEnv embed) (mkIngested recorded attemptN)

mkTestEnv :: (Text -> IO (Either EmbedError (Vector.Vector Double))) -> EmbeddingWorkerEnv
mkTestEnv embed =
  EmbeddingWorkerEnv {model = testModel, dimensions = embeddingDims, embed}

failingEmbed :: EmbedError -> (Text -> IO (Either EmbedError (Vector.Vector Double)))
failingEmbed err _ = pure (Left err)

-- | The adapter's envelope, built by hand: only 'attempt' and 'payload' matter
-- to the handler, and the ack handle is never finalized because the handler
-- returns its decision rather than committing it.
mkIngested :: RecordedEvent -> Maybe Word -> Ingested es RecordedEvent
mkIngested recorded attemptN =
  Ingested
    { envelope =
        Envelope
          { messageId = MessageId "embedding-worker-spec",
            cursor = Nothing,
            partition = Nothing,
            enqueuedAt = Nothing,
            traceContext = Nothing,
            headers = Nothing,
            attempt = Attempt <$> attemptN,
            attributes = HashMap.empty,
            payload = recorded
          },
      ack = AckHandle {finalize = \_ -> pure ()},
      lease = Nothing
    }

-- | Run a database-backed case, skipping it when the ephemeral PostgreSQL has
-- no pgvector: without the extension the embedding column does not exist, so
-- the store-error branches under test cannot be reached at all.
withVectorEnv :: String -> (AppEnv -> VectorCapability -> IO ()) -> Assertion
withVectorEnv label action =
  withEmbeddingEnv \appEnv -> do
    capability <- runOrFail appEnv (detectVectorCapability embeddingDims)
    case capability of
      VectorAvailable -> action appEnv capability
      _ ->
        putStrLn
          ( "  [skipped: "
              <> label
              <> "] pgvector is unavailable in the ephemeral database ("
              <> show capability
              <> ")"
          )

withEmbeddingEnv :: (AppEnv -> IO a) -> IO a
withEmbeddingEnv action =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) action

loadEmbeddingState :: (Store :> es) => Text -> Eff es Bool
loadEmbeddingState memoryId =
  runTransaction (Tx.statement memoryId selectEmbeddedStmt)

selectEmbeddedStmt :: Statement Text Bool
selectEmbeddedStmt =
  preparable
    """
    SELECT embedding IS NOT NULL AND content_hash IS NOT NULL
    FROM kiroku.kioku_memories
    WHERE memory_id = $1
    """
    (E.param (E.nonNullable E.text))
    (D.singleRow (D.column (D.nonNullable D.bool)))

fixtureScope :: MemoryScope
fixtureScope =
  ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_embedding_worker_spec"

testModel :: EmbeddingModel
testModel =
  toEmbeddingModel
    EmbeddingConfig
      { baseUrl = "http://embedding.invalid",
        model = "text-embedding-3-small",
        dimensions = embeddingDims,
        apiKey = "not-used-the-provider-is-faked"
      }

-- | Matches the @vector(1536)@ column the embedding migration creates.
embeddingDims :: Int
embeddingDims = 1536

runOrFail :: AppEnv -> Eff AppEffects a -> IO a
runOrFail appEnv action = runAppIO appEnv action >>= expectRight "runAppIO"

expectRight :: (Show e) => String -> Either e a -> IO a
expectRight label = \case
  Left err -> assertFailure (label <> " failed: " <> show err)
  Right value -> pure value
