{-# LANGUAGE DataKinds #-}

module Kioku.DistillSpec
  ( tests,
  )
where

import Baikai (Response, _Response, _TextContent)
import Baikai.Content (AssistantContent (..))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
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
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Distill.Consolidate (ConsolidateInput (..), ExistingMemory (..), consolidateProgram)
import Kioku.Distill.Extract (extractProgram)
import Kioku.Distill.L1 (L1Summary (..), distillSessionL1, scopedScanCandidates)
import Kioku.Distill.L2 (SceneRow (..), getScenesByScope, regenerateScene)
import Kioku.Distill.L3 (PersonaRow (..), getPersonaByScope, regeneratePersona)
import Kioku.Distill.Persona (personaProgram)
import Kioku.Distill.Runtime (DistillRuntime (..), newDistillRuntime)
import Kioku.Distill.Scene (sceneProgram)
import Kioku.Id (MemoryId, SessionId, genSessionId, idText, parseIdAnyPrefix)
import Kioku.Memory.EventStream (memoryStream)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Prelude
import Kioku.Session qualified as Session
import Kioku.Session.Domain (CompleteSessionData (..), RecordTurnData (..), StartSessionData (..))
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventType (..), RecordedEvent (..), StreamVersion (..))
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM (..))
import Shikumi.Program (Program, runProgram)
import Shikumi.Schema.Types (unField)
import Shikumi.Trace (runTrace, tracedLLM)
import Shikumi.Trace.Replay (runLLMReplay)
import Shikumi.Trace.Store (replayIndex)
import System.Directory (withCurrentDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Distillation pyramid"
    [ testCase "replay distills duplicate turns into merged atom scene and persona" testReplayDistillation
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
testReplayDistillation =
  withSystemTempDirectory "kioku-distill" \tmp ->
    withCurrentDirectory tmp $
      withKiokuMigratedDatabase \connStr ->
        withStore (defaultConnectionSettings connStr) \st -> do
          tracer <- noopTracer
          runtime <- replayRuntime
          sid <- genSessionId
          now <- getCurrentTime
          let scope = ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_distill_test"
              env = AppEnv {store = st, tracer, metrics = Nothing}
          result <-
            runAppIO env do
              writeFixtureSession sid scope now
              distillResult <- distillSessionL1 runtime (scopedScanCandidates 5) sid
              summary <- liftIO (expectRight "distillSessionL1" distillResult)
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

writeFixtureSession ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  MemoryScope ->
  UTCTime ->
  Eff es ()
writeFixtureSession sid scope now = do
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
  traverse_
    ( \(turnIndex, content) -> do
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
                recordedAt = now
              }
        void (liftIO (expectRight "Session.recordTurn" turnResult))
    )
    [ (1, "I like short answers."),
      (2, "Please keep replies brief."),
      (3, "The deploy script is in ops/deploy.sh.")
    ]
  completeResult <-
    Session.complete
      CompleteSessionData
        { sessionId = sid,
          completedAt = now,
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

consolidateResponse :: ConsolidateInput -> Text
consolidateResponse input =
  case input.existing of
    [] ->
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

encodeJsonText :: (ToJSON a) => a -> Text
encodeJsonText =
  TE.decodeUtf8 . BL.toStrict . Aeson.encode
