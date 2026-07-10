{-# LANGUAGE DataKinds #-}

module Kioku.DistillSpec
  ( tests,
  )
where

import Baikai (Response, _Response, _TextContent)
import Baikai.Content (AssistantContent (..))
import Baikai.Embedding (EmbeddingModel)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (addUTCTime, diffUTCTime)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Prim (runPrim)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Stream qualified as Stream
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..), scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Api.Types (Confidence (..), MemoryType (..))
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Distill.Consolidate (ConsolidateInput (..), ExistingMemory (..), consolidateProgram)
import Kioku.Distill.Extract (extractProgram)
import Kioku.Distill.L1 (L1Error (..), L1Outcome (..), L1RunMode (..), L1Summary (..), distillSessionL1, recallCandidates, scopedScanCandidates)
import Kioku.Distill.L2 (SceneRow (..), getScenesByScope, regenerateScene)
import Kioku.Distill.L3 (PersonaRow (..), getPersonaByScope, regeneratePersona)
import Kioku.Distill.Persona (personaProgram)
import Kioku.Distill.Runtime (DistillRuntime (..), newDistillRuntime)
import Kioku.Distill.Scene (sceneProgram)
import Kioku.Distill.Timer (idleFlushSeconds, l1ExtractProcessManagerName)
import Kioku.Id (MemoryId, SessionId, genMemoryId, genSessionId, idText, parseIdAnyPrefix)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Memory.Embedding (EmbeddingConfig (..), toEmbeddingModel)
import Kioku.Memory.EventStream (memoryStream)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Prelude
import Kioku.Recall.Capability (VectorCapability (..), detectVectorCapability)
import Kioku.Session qualified as Session
import Kioku.Session.Domain (CompleteSessionData (..), RecordTurnData (..), StartSessionData (..))
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventType (..), RecordedEvent (..), StreamVersion (..))
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..))
import Shikumi.Program (Program, runProgram)
import Shikumi.Schema.Types (unField)
import Shikumi.Trace (runTrace, tracedLLM)
import Shikumi.Trace.Replay (runLLMReplay)
import Shikumi.Trace.Store (replayIndex)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Distillation pyramid"
    [ testCase "replay distills duplicate turns into merged atom scene and persona" testReplayDistillation,
      testCase "re-running distillSessionL1 creates no new memories or audit rows" testRerunIdempotent,
      testCase "consolidation failure stores nothing and fails the pass" testConsolidationFailure,
      testCase "merge with a missing target drops it and stays convergent" testMergeMissingTarget,
      testCase "watermark skips re-extraction until a new turn arrives" testWatermarkSkip,
      testCase "a session accumulates one idle timer however many turns" testIdleTimerCollapse,
      testCase "recall candidates find a duplicate outside the scan window" testRecallCandidateWindow
    ]

data MemoryStatus = MemoryStatus
  { memoryId :: !Text,
    content :: !Text,
    status :: !Text
  }
  deriving stock (Generic, Eq, Show)

data ScopeParams = ScopeParams
  { namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

data AuditRowView = AuditRowView
  { decision :: !Text,
    targetIds :: !Text,
    resultMemoryId :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

data TimerKindRow = TimerKindRow
  { kind :: !Text,
    timerCount :: !Int64,
    maxFireAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data TimerQuery = TimerQuery
  { processManagerName :: !Text,
    correlationId :: !Text
  }
  deriving stock (Generic, Eq, Show)

data DistillResult = DistillResult
  { summary :: !L1Summary,
    memories :: ![MemoryStatus],
    scenes :: ![SceneRow],
    persona :: !(Maybe PersonaRow),
    mergeAuditCount :: !Int64,
    loserEvents :: ![RecordedEvent]
  }
  deriving stock (Generic, Show)

testReplayDistillation :: Assertion
testReplayDistillation = withDistillEnv \env -> do
  runtime <- replayRuntime
  sid <- genSessionId
  now <- getCurrentTime
  let scope = fixtureScope
  result <-
    runAppIO env do
      writeFixtureSession sid scope now
      distillResult <- distillSessionL1 RespectWatermark runtime (scopedScanCandidates 5) sid
      summary <- liftIO (expectDistilled "distillSessionL1" distillResult)
      sceneResult <- regenerateScene runtime scope
      _scene <- liftIO (expectRight "regenerateScene" sceneResult)
      personaResult <- regeneratePersona runtime scope
      _persona <- liftIO (expectRight "regeneratePersona" personaResult)
      memories <- loadMemoryStatuses scope
      mergeAuditCount <- loadMergeAuditCount scope
      scenes <- getScenesByScope scope
      persona <- getPersonaByScope scope
      loserEvents <- loadLoserEvents memories
      pure DistillResult {summary, memories, scenes, persona, mergeAuditCount, loserEvents}
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right distill -> assertDistillResult distill

-- | Run an action against a freshly migrated ephemeral database. Deliberately
-- does not change the working directory: tasty runs test cases concurrently and
-- the process-wide cwd would race. ephemeral-pg keeps its cluster under the XDG
-- cache directory, so no chdir is needed.
withDistillEnv :: (AppEnv -> IO a) -> IO a
withDistillEnv action =
  withKiokuMigratedDatabase \connStr ->
    withStore (defaultConnectionSettings connStr) \st -> do
      tracer <- noopTracer
      action AppEnv {store = st, tracer, metrics = Nothing}

fixtureScope :: MemoryScope
fixtureScope =
  ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_distill_test"

-- | A second pass over an unchanged session must converge: the deterministic
-- atom ids mean every write is a no-op and the deterministic audit key means
-- @ON CONFLICT DO NOTHING@ suppresses duplicate audit rows.
testRerunIdempotent :: Assertion
testRerunIdempotent = withDistillEnv \env -> do
  runtime <- replayRuntime
  sid <- genSessionId
  now <- getCurrentTime
  result <-
    runAppIO env do
      writeFixtureSession sid fixtureScope now
      first <- distillSessionL1 RespectWatermark runtime (scopedScanCandidates 5) sid
      summary1 <- liftIO (expectDistilled "first pass" first)
      memories1 <- loadMemoryStatuses fixtureScope
      audits1 <- loadAuditCount fixtureScope
      second <- distillSessionL1 IgnoreWatermark runtime (scopedScanCandidates 5) sid
      summary2 <- liftIO (expectDistilled "second pass" second)
      memories2 <- loadMemoryStatuses fixtureScope
      audits2 <- loadAuditCount fixtureScope
      pure (summary1, memories1, audits1, summary2, memories2, audits2)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (summary1, memories1, audits1, summary2, memories2, audits2) -> do
      summary1.stored @?= 1
      summary1.merged @?= 1
      length memories1 @?= 2
      audits1 @?= 2
      summary2.extracted @?= 2
      summary2.stored @?= 0
      summary2.merged @?= 0
      summary2.skipped @?= 2
      memories2 @?= memories1
      audits2 @?= audits1
      length [() | row <- memories2, row.status == "active"] @?= 1

-- | A consolidation LLM failure is a failed pass, not a silent store.
testConsolidationFailure :: Assertion
testConsolidationFailure = withDistillEnv \env -> do
  base <- replayRuntime
  let runtime = base {runConsolidate = \_ -> pure (Left (ValidationFailure "boom"))}
  sid <- genSessionId
  now <- getCurrentTime
  result <-
    runAppIO env do
      writeFixtureSession sid fixtureScope now
      distilled <- distillSessionL1 RespectWatermark runtime (scopedScanCandidates 5) sid
      memories <- loadMemoryStatuses fixtureScope
      audits <- loadAuditCount fixtureScope
      pure (distilled, memories, audits)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (distilled, memories, audits) -> do
      case distilled of
        Left (L1ConsolidationFailed _) -> pure ()
        other -> assertFailure ("expected L1ConsolidationFailed, got " <> show other)
      memories @?= []
      audits @?= 0

-- | A hallucinated-but-parseable merge target is dropped before the winner is
-- recorded, the audit records only the surviving target, and a re-run converges.
testMergeMissingTarget :: Assertion
testMergeMissingTarget = withDistillEnv \env -> do
  base <- replayRuntime
  existingId <- genMemoryId
  ghostId <- genMemoryId
  let mergeResponse = mergeTargetsResponse [idText existingId, idText ghostId]
      runtime =
        base
          { runExtract = replayProgram singleAtomExtractResponse extractProgram,
            runConsolidate = replayProgram mergeResponse consolidateProgram
          }
  sid <- genSessionId
  now <- getCurrentTime
  result <-
    runAppIO env do
      writeFixtureSession sid fixtureScope now
      seedMemory existingId sid fixtureScope "The user likes concise answers." now
      first <- distillSessionL1 RespectWatermark runtime (scopedScanCandidates 5) sid
      summary1 <- liftIO (expectDistilled "first pass" first)
      memories1 <- loadMemoryStatuses fixtureScope
      audits1 <- loadAuditRows fixtureScope
      second <- distillSessionL1 IgnoreWatermark runtime (scopedScanCandidates 5) sid
      void (liftIO (expectDistilled "second pass" second))
      memories2 <- loadMemoryStatuses fixtureScope
      audits2 <- loadAuditRows fixtureScope
      pure (summary1, memories1, audits1, memories2, audits2)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (summary1, memories1, audits1, memories2, audits2) -> do
      summary1.extracted @?= 1
      summary1.merged @?= 1
      assertBool "seeded memory is merged away" $
        any (\row -> row.memoryId == idText existingId && row.status == "merged") memories1
      length [() | row <- memories1, row.status == "active"] @?= 1
      case audits1 of
        [audit] -> do
          audit.decision @?= "merge"
          audit.targetIds @?= encodeJsonText [idText existingId]
        other -> assertFailure ("expected exactly one audit row, got " <> show (length other))
      memories2 @?= memories1
      audits2 @?= audits1

-- | The watermark makes a re-fire with no new turns a pure database read. The
-- proof is an extractor that fails if it is ever called: the pass succeeds
-- anyway, so the LLM was not reached. Recording one more turn re-enables it.
testWatermarkSkip :: Assertion
testWatermarkSkip = withDistillEnv \env -> do
  working <- replayRuntime
  let exploding =
        working {runExtract = \_ -> pure (Left (ValidationFailure "extractor must not run"))}
  sid <- genSessionId
  now <- getCurrentTime
  result <-
    runAppIO env do
      writeRunningFixtureSession sid fixtureScope now
      first <- distillSessionL1 RespectWatermark working (scopedScanCandidates 5) sid
      void (liftIO (expectDistilled "first pass" first))
      skipped <- distillSessionL1 RespectWatermark exploding (scopedScanCandidates 5) sid
      recordFixtureTurn sid now 4 "Never deploy on a Friday."
      afterNewTurn <- distillSessionL1 RespectWatermark exploding (scopedScanCandidates 5) sid
      pure (skipped, afterNewTurn)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (skipped, afterNewTurn) -> do
      case skipped of
        Right L1SkippedUpToDate -> pure ()
        other -> assertFailure ("expected L1SkippedUpToDate, got " <> show other)
      case afterNewTurn of
        Left (L1ExtractionFailed _) -> pure ()
        other -> assertFailure ("expected L1ExtractionFailed after a new turn, got " <> show other)

-- | However many turns a session records, it holds exactly one idle timer,
-- re-armed forward to the latest turn. Ramp timers fire only on ramp turns
-- (1, 2, 4, 8, 16, ...), and completion adds one final timer.
testIdleTimerCollapse :: Assertion
testIdleTimerCollapse = withDistillEnv \env -> do
  sid <- genSessionId
  now <- getCurrentTime
  result <-
    runAppIO env do
      writeFixtureSession sid fixtureScope now
      loadTimerKinds sid
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right kinds -> do
      let lookupKind k = [row | row <- kinds, row.kind == k]
      case lookupKind "idle" of
        [idle] -> do
          idle.timerCount @?= 1
          let lastTurnAt = turnRecordedAt now (length fixtureTurns)
              expected = addUTCTime idleFlushSeconds lastTurnAt
          assertBool
            ( "idle timer should be re-armed to the last turn's recordedAt + 30min; expected "
                <> show expected
                <> " but found "
                <> show idle.maxFireAt
            )
            (abs (diffUTCTime idle.maxFireAt expected) < 0.001)
        other -> assertFailure ("expected exactly one idle timer row, got " <> show other)
      case lookupKind "ramp" of
        [ramp] -> ramp.timerCount @?= 2
        other -> assertFailure ("expected one ramp kind grouping, got " <> show other)
      case lookupKind "final" of
        [final] -> final.timerCount @?= 1
        other -> assertFailure ("expected one final timer row, got " <> show other)

-- | The scan finder returns the first @limit@ rows of a @priority ASC@ scan, so
-- a duplicate that sits behind enough low-priority filler is invisible to the
-- consolidator and gets stored again. Relevance-ranked recall finds it.
--
-- Both halves run in one database against separate scopes, so the contrast is
-- the only difference between them.
testRecallCandidateWindow :: Assertion
testRecallCandidateWindow = withDistillEnv \env -> do
  base <- replayRuntime
  recallSid <- genSessionId
  scanSid <- genSessionId
  recallDuplicateId <- genMemoryId
  scanDuplicateId <- genMemoryId
  now <- getCurrentTime
  let recallScope = ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_recall_window"
      scanScope = ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_scan_window"
      -- Merge only when the consolidator was actually shown the duplicate.
      runtimeFor duplicateId =
        base
          { runExtract = replayProgram singleAtomExtractResponse extractProgram,
            runConsolidate = \input ->
              if any (\existing -> unField existing.memoryId == idText duplicateId) input.existing
                then replayProgram (mergeTargetsResponse [idText duplicateId]) consolidateProgram input
                else replayProgram storeAtomResponse consolidateProgram input
          }
  result <-
    runAppIO env do
      capability <- detectVectorCapability
      writeRunningFixtureSession recallSid recallScope now
      seedCandidateWindow recallSid recallScope now recallDuplicateId
      recallOutcome <-
        distillSessionL1
          RespectWatermark
          (runtimeFor recallDuplicateId)
          (recallCandidates dummyEmbeddingModel capability 8)
          recallSid
      recallSummary <- liftIO (expectDistilled "recall pass" recallOutcome)
      recallMemories <- loadMemoryStatuses recallScope

      writeRunningFixtureSession scanSid scanScope now
      seedCandidateWindow scanSid scanScope now scanDuplicateId
      scanOutcome <-
        distillSessionL1
          RespectWatermark
          (runtimeFor scanDuplicateId)
          (scopedScanCandidates 5)
          scanSid
      scanSummary <- liftIO (expectDistilled "scan pass" scanOutcome)
      scanMemories <- loadMemoryStatuses scanScope
      pure (capability, recallSummary, recallMemories, scanSummary, scanMemories)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (capability, recallSummary, recallMemories, scanSummary, scanMemories) -> do
      -- ephemeral-pg ships no pgvector, so recall runs FTS-only and never calls
      -- the embedding endpoint. That is what makes dummyEmbeddingModel safe.
      capability @?= VectorExtensionUnavailable

      recallSummary.merged @?= 1
      recallSummary.stored @?= 0
      assertBool "recall found the duplicate behind the scan window and merged it" $
        any
          (\row -> row.memoryId == idText recallDuplicateId && row.status == "merged")
          recallMemories

      -- The defect being fixed, pinned in place: the scan never sees the duplicate.
      scanSummary.stored @?= 1
      scanSummary.merged @?= 0
      assertBool "the scan window hid the duplicate, so it stayed active" $
        any
          (\row -> row.memoryId == idText scanDuplicateId && row.status == "active")
          scanMemories

-- | Six low-priority fillers ahead of the duplicate in a @priority ASC@ scan,
-- with content that shares no stem with the extracted atom so full-text search
-- passes over them.
seedCandidateWindow ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  MemoryScope ->
  UTCTime ->
  MemoryId ->
  Eff es ()
seedCandidateWindow sid scope now duplicateId = do
  traverse_
    ( \(n :: Int) -> do
        fillerId <- genMemoryId
        seedMemoryWith
          fillerId
          sid
          scope
          ("Filler note " <> Text.pack (show n) <> ": the deployment pipeline runs on Nix flakes.")
          10
          now
    )
    [1 .. 6]
  seedMemoryWith duplicateId sid scope "The user prefers concise answers." 90 now

dummyEmbeddingModel :: EmbeddingModel
dummyEmbeddingModel =
  toEmbeddingModel
    EmbeddingConfig
      { baseUrl = "http://embedding.invalid",
        model = "test-embedding",
        dimensions = 8,
        apiKey = ""
      }

seedMemory ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  MemoryId ->
  SessionId ->
  MemoryScope ->
  Text ->
  UTCTime ->
  Eff es ()
seedMemory memoryId sid scope content =
  seedMemoryWith memoryId sid scope content 50

seedMemoryWith ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  MemoryId ->
  SessionId ->
  MemoryScope ->
  Text ->
  Int ->
  UTCTime ->
  Eff es ()
seedMemoryWith memoryId sid scope content priority now = do
  recorded <-
    Memory.record
      RecordMemoryData
        { memoryId,
          agentId = "test-agent",
          sessionId = Just sid,
          scope,
          memoryType = MemoryPreference,
          content,
          priority,
          confidence = HighConfidence,
          tags = Set.fromList ["seed"],
          supersedes = Nothing,
          recordedAt = now
        }
  void (liftIO (expectRight "Memory.record" recorded))

-- | Turn @n@ is recorded one minute after turn @n-1@, so the single debounced
-- idle timer's @fire_at@ is observably re-armed forward by each turn.
turnRecordedAt :: UTCTime -> Int -> UTCTime
turnRecordedAt now turnIndex =
  addUTCTime (60 * fromIntegral (turnIndex - 1)) now

fixtureTurns :: [(Int, Text)]
fixtureTurns =
  [ (1, "I like short answers."),
    (2, "Please keep replies brief."),
    (3, "The deploy script is in ops/deploy.sh.")
  ]

-- | Start a session and record 'fixtureTurns', leaving it @Running@ so further
-- turns can be recorded. The aggregate only accepts @RecordTurn@ from @Running@.
writeRunningFixtureSession ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  MemoryScope ->
  UTCTime ->
  Eff es ()
writeRunningFixtureSession sid scope now = do
  startResult <-
    Session.start
      StartSessionData
        { sessionId = sid,
          agentId = "test-agent",
          focus = "style preference capture",
          scope,
          subjectRef = Just "intention_distill_test",
          previousSessionId = Nothing,
          parentSessionId = Nothing,
          delegationDepth = 0,
          startedAt = now
        }
  void (liftIO (expectRight "Session.start" startResult))
  traverse_ (uncurry (recordFixtureTurn sid now)) fixtureTurns

recordFixtureTurn ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  UTCTime ->
  Int ->
  Text ->
  Eff es ()
recordFixtureTurn sid now turnIndex content = do
  turnResult <-
    Session.recordTurn
      RecordTurnData
        { sessionId = sid,
          turnId = idText sid <> "-turn-" <> Text.pack (show turnIndex),
          turnIndex,
          role = "user",
          content,
          toolSummary = Nothing,
          promptTokens = Nothing,
          outputTokens = Nothing,
          recordedAt = turnRecordedAt now turnIndex
        }
  void (liftIO (expectRight "Session.recordTurn" turnResult))

writeFixtureSession ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  MemoryScope ->
  UTCTime ->
  Eff es ()
writeFixtureSession sid scope now = do
  writeRunningFixtureSession sid scope now
  completeResult <-
    Session.complete
      CompleteSessionData
        { sessionId = sid,
          completedAt = turnRecordedAt now (length fixtureTurns),
          modelUsed = Just "test-model",
          summary = Just "Captured style preferences."
        }
  void (liftIO (expectRight "Session.complete" completeResult))

replayRuntime :: IO DistillRuntime
replayRuntime = do
  rt <- newDistillRuntime
  pure
    rt
      { runExtract = replayProgram extractResponse extractProgram,
        runConsolidate = \input -> replayProgram (consolidateResponse input) consolidateProgram input,
        runScene = replayProgram sceneResponse sceneProgram,
        runPersona = replayProgram personaResponse personaProgram
      }

replayProgram :: Text -> Program i o -> i -> IO (Either ShikumiError o)
replayProgram response prog input = do
  (live, tree) <-
    runEff
      . runPrim
      . runTime
      . runTrace
      . runFixedLLM (mkResponse response)
      . tracedLLM
      . runErrorNoCallStack @ShikumiError
      $ runProgram prog input
  case live of
    Left err -> pure (Left err)
    Right _ -> case replayIndex tree of
      Left err -> assertFailure (Text.unpack err)
      Right idx ->
        runEff
          . runLLMReplay idx
          . runErrorNoCallStack @ShikumiError
          $ runProgram prog input

runFixedLLM :: Response -> Eff (LLM : es) a -> Eff es a
runFixedLLM resp = interpret \_ -> \case
  Complete {} -> pure resp
  Stream {} -> pure []

mkResponse :: Text -> Response
mkResponse responseText =
  _Response
    & #message
    . #content
    .~ Vector.singleton (AssistantText (_TextContent & #text .~ responseText))

extractResponse :: Text
extractResponse =
  """
  [[ ## atoms ## ]]
  [
    {"atomType":"preference","content":"The user prefers concise answers.","priority":50,"confidence":"high"},
    {"atomType":"preference","content":"The user wants replies kept brief.","priority":50,"confidence":"high"}
  ]
  [[ ## completed ## ]]
  """

storeAtomResponse :: Text
storeAtomResponse =
  """
  [[ ## action ## ]]
  StoreAtom
  [[ ## targetMemoryIds ## ]]
  []
  [[ ## resultContent ## ]]
  The user prefers concise answers.
  [[ ## rationale ## ]]
  The preference is durable and not yet represented.
  [[ ## completed ## ]]
  """

consolidateResponse :: ConsolidateInput -> Text
consolidateResponse input =
  case input.existing of
    [] -> storeAtomResponse
    ExistingMemory {memoryId = targetId} : _ ->
      Text.unlines
        [ "[[ ## action ## ]]",
          "MergeAtom",
          "[[ ## targetMemoryIds ## ]]",
          encodeJsonText ([unField targetId] :: [Text]),
          "[[ ## resultContent ## ]]",
          "The user prefers concise answers.",
          "[[ ## rationale ## ]]",
          "The candidate restates the existing concise-answer preference.",
          "[[ ## completed ## ]]"
        ]

singleAtomExtractResponse :: Text
singleAtomExtractResponse =
  """
  [[ ## atoms ## ]]
  [
    {"atomType":"preference","content":"The user prefers concise answers.","priority":50,"confidence":"high"}
  ]
  [[ ## completed ## ]]
  """

mergeTargetsResponse :: [Text] -> Text
mergeTargetsResponse targets =
  Text.unlines
    [ "[[ ## action ## ]]",
      "MergeAtom",
      "[[ ## targetMemoryIds ## ]]",
      encodeJsonText targets,
      "[[ ## resultContent ## ]]",
      "The user prefers concise answers.",
      "[[ ## rationale ## ]]",
      "The candidate restates the existing concise-answer preference.",
      "[[ ## completed ## ]]"
    ]

sceneResponse :: Text
sceneResponse =
  """
  [[ ## title ## ]]
  Response style
  [[ ## bodyMd ## ]]
  - The user prefers concise answers.
  [[ ## completed ## ]]
  """

personaResponse :: Text
personaResponse =
  """
  [[ ## bodyMd ## ]]
  # Persona

  The user values concise answers in this scope.
  [[ ## completed ## ]]
  """

loadMemoryStatuses ::
  (Store :> es) =>
  MemoryScope ->
  Eff es [MemoryStatus]
loadMemoryStatuses scope =
  runTransaction $
    Tx.statement (scopeParams scope) selectMemoryStatusesStmt

loadMergeAuditCount ::
  (Store :> es) =>
  MemoryScope ->
  Eff es Int64
loadMergeAuditCount scope =
  runTransaction $
    Tx.statement (scopeParams scope) selectMergeAuditCountStmt

loadAuditCount ::
  (Store :> es) =>
  MemoryScope ->
  Eff es Int64
loadAuditCount scope =
  runTransaction $
    Tx.statement (scopeParams scope) selectAuditCountStmt

loadAuditRows ::
  (Store :> es) =>
  MemoryScope ->
  Eff es [AuditRowView]
loadAuditRows scope =
  runTransaction $
    Tx.statement (scopeParams scope) selectAuditRowsStmt

-- | keiro's timer table is unqualified at the pinned version: it lives in the
-- @kiroku@ schema, which the connection's search_path already resolves.
loadTimerKinds ::
  (Store :> es) =>
  SessionId ->
  Eff es [TimerKindRow]
loadTimerKinds sid =
  runTransaction $
    Tx.statement
      TimerQuery
        { processManagerName = l1ExtractProcessManagerName,
          correlationId = idText sid
        }
      selectTimerKindsStmt

selectTimerKindsStmt :: Statement TimerQuery [TimerKindRow]
selectTimerKindsStmt =
  preparable
    """
    SELECT payload->>'kind', count(*), max(fire_at)
    FROM keiro_timers
    WHERE process_manager_name = $1
      AND correlation_id = $2
    GROUP BY payload->>'kind'
    ORDER BY payload->>'kind'
    """
    timerQueryEncoder
    (D.rowList timerKindRowDecoder)

timerQueryEncoder :: E.Params TimerQuery
timerQueryEncoder =
  ((\q -> q.processManagerName) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.correlationId) >$< E.param (E.nonNullable E.text))

timerKindRowDecoder :: D.Row TimerKindRow
timerKindRowDecoder =
  TimerKindRow
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.int8)
    <*> D.column (D.nonNullable D.timestamptz)

loadLoserEvents ::
  (Store :> es) =>
  [MemoryStatus] ->
  Eff es [RecordedEvent]
loadLoserEvents memories =
  case [mid | MemoryStatus {memoryId = mid, status = "merged"} <- memories] of
    loser : _ ->
      case (parseIdAnyPrefix loser :: Either Text MemoryId) of
        Left _ -> pure []
        Right loserId ->
          Vector.toList <$> readStreamForward (Stream.streamName (memoryStream loserId)) (StreamVersion 0) 100
    [] -> pure []

scopeParams :: MemoryScope -> ScopeParams
scopeParams scope =
  ScopeParams
    { namespace = scopeNamespaceText scope,
      scopeKind = scopeKindText scope,
      scopeRef = scopeRefText scope
    }

selectMemoryStatusesStmt :: Statement ScopeParams [MemoryStatus]
selectMemoryStatusesStmt =
  preparable
    """
    SELECT memory_id, content, status
    FROM kioku_memories
    WHERE namespace = $1
      AND ((scope_kind = $2 AND scope_ref = $3)
           OR ($2 IS NULL AND scope_kind IS NULL AND $3 IS NULL AND scope_ref IS NULL))
    ORDER BY created_at ASC
    """
    scopeParamsEncoder
    (D.rowList memoryStatusDecoder)

selectAuditCountStmt :: Statement ScopeParams Int64
selectAuditCountStmt =
  preparable
    """
    SELECT count(*)
    FROM kioku_consolidation_decisions
    WHERE namespace = $1
      AND ((scope_kind = $2 AND scope_ref = $3)
           OR ($2 IS NULL AND scope_kind IS NULL AND $3 IS NULL AND scope_ref IS NULL))
    """
    scopeParamsEncoder
    (D.singleRow (D.column (D.nonNullable D.int8)))

selectAuditRowsStmt :: Statement ScopeParams [AuditRowView]
selectAuditRowsStmt =
  preparable
    """
    SELECT decision, target_ids::text, result_memory_id
    FROM kioku_consolidation_decisions
    WHERE namespace = $1
      AND ((scope_kind = $2 AND scope_ref = $3)
           OR ($2 IS NULL AND scope_kind IS NULL AND $3 IS NULL AND scope_ref IS NULL))
    ORDER BY decided_at ASC
    """
    scopeParamsEncoder
    (D.rowList auditRowViewDecoder)

auditRowViewDecoder :: D.Row AuditRowView
auditRowViewDecoder =
  AuditRowView
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)

selectMergeAuditCountStmt :: Statement ScopeParams Int64
selectMergeAuditCountStmt =
  preparable
    """
    SELECT count(*)
    FROM kioku_consolidation_decisions
    WHERE namespace = $1
      AND ((scope_kind = $2 AND scope_ref = $3)
           OR ($2 IS NULL AND scope_kind IS NULL AND $3 IS NULL AND scope_ref IS NULL))
      AND decision = 'merge'
    """
    scopeParamsEncoder
    (D.singleRow (D.column (D.nonNullable D.int8)))

scopeParamsEncoder :: E.Params ScopeParams
scopeParamsEncoder =
  ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\q -> q.scopeRef) >$< E.param (E.nullable E.text))

memoryStatusDecoder :: D.Row MemoryStatus
memoryStatusDecoder =
  MemoryStatus
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)

assertDistillResult :: DistillResult -> Assertion
assertDistillResult result = do
  result.summary.extracted @?= 2
  result.summary.stored @?= 1
  result.summary.merged @?= 1
  length [() | row <- result.memories, row.status == "active"] @?= 1
  length [() | row <- result.memories, row.status == "merged"] @?= 1
  assertBool "active memory keeps the concise-answer preference" $
    any (\row -> row.status == "active" && "concise answers" `Text.isInfixOf` row.content) result.memories
  result.mergeAuditCount @?= 1
  assertBool "loser stream contains MemoryMerged" $
    any (\event -> event.eventType == EventType "MemoryMerged") result.loserEvents
  length result.scenes @?= 1
  assertBool "scene body is non-empty" $
    any (not . Text.null . (.bodyMd)) result.scenes
  case result.persona of
    Nothing -> assertFailure "expected persona row"
    Just persona -> assertBool "persona body is non-empty" (not (Text.null persona.bodyMd))

expectRight :: (Show e) => String -> Either e a -> IO a
expectRight label = \case
  Left err -> assertFailure (label <> " failed: " <> show err)
  Right value -> pure value

-- | Unwrap a pass that was expected to actually run, not skip on the watermark.
expectDistilled :: String -> Either L1Error L1Outcome -> IO L1Summary
expectDistilled label outcome = do
  distilled <- expectRight label outcome
  case distilled of
    L1Distilled summary -> pure summary
    L1SkippedUpToDate -> assertFailure (label <> " unexpectedly skipped on the watermark")

encodeJsonText :: (ToJSON a) => a -> Text
encodeJsonText =
  TE.decodeUtf8 . BL.toStrict . Aeson.encode
