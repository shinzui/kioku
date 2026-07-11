module Kioku.ReiCompatSpec
  ( tests,
  )
where

import Data.Aeson (eitherDecode)
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (Confidence (..), MemoryType (..))
import Kioku.Id (idText)
import Kioku.Memory.Domain (MemoryEvent (..), MemoryRecordedData (..))
import Kioku.Memory.EventStream (parseMemoryEvent)
import Kioku.Session.Domain
  ( InteractiveSessionRecordedData (..),
    SessionCompletedData (..),
    SessionEvent (..),
    SessionFailedData (..),
    SessionResumedData (..),
    SessionStartedData (..),
  )
import Kioku.Session.EventStream (parseSessionEvent)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Rei legacy codec compatibility"
    [ testCase "decodes agent_memory_recorded" do
        value <- either fail pure (eitherDecode reiMemoryRecordedJson)
        event <- either (fail . show) pure (parseMemoryEvent value)
        case event of
          MemoryRecorded d -> assertMemoryRecorded d
          other -> fail ("Expected MemoryRecorded, got " <> show other),
      testCase "decodes agent_session_started" do
        value <- either fail pure (eitherDecode reiSessionStartedJson)
        event <- either (fail . show) pure (parseSessionEvent value)
        case event of
          SessionStarted d -> assertSessionStarted d
          other -> fail ("Expected SessionStarted, got " <> show other),
      testCase "decodes agent_session_completed" do
        event <- decodeSession reiSessionCompletedJson
        case event of
          SessionCompleted d -> do
            idText d.sessionId @?= "kioku_session_01kvxa7d2cezhs874g3n8dfgme"
            d.completedAt @?= at "2026-06-24T21:30:00Z"
            d.modelUsed @?= Just "claude-opus-4-8"
            d.summary @?= Just "planned the day"
          other -> fail ("Expected SessionCompleted, got " <> show other),
      testCase "decodes agent_session_failed" do
        event <- decodeSession reiSessionFailedJson
        case event of
          SessionFailed d -> do
            idText d.sessionId @?= "kioku_session_01kvxa7d2cezhs874g3n8dfgme"
            d.failedAt @?= at "2026-06-24T21:30:00Z"
            d.errorMessage @?= "model timed out"
          other -> fail ("Expected SessionFailed, got " <> show other),
      testCase "decodes interactive_session_recorded" do
        event <- decodeSession reiInteractiveSessionRecordedJson
        case event of
          InteractiveSessionRecorded d -> do
            idText d.sessionId @?= "kioku_session_01kvxa7d2cezhs874g3n8dfgme"
            d.agentId @?= "demo-agent"
            d.focus @?= "general_coaching"
            d.scope @?= ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_demo"
            d.startedAt @?= at "2026-06-24T20:10:00Z"
          other -> fail ("Expected InteractiveSessionRecorded, got " <> show other),
      -- The two cases below pin the upcast rule for native SessionResumed events written
      -- before the `force` field existed. Under the old code an omitted correlation key
      -- bypassed matching entirely, so a keyless legacy resume must replay through the
      -- force arm of the new guard and a keyed one through the matching arm. Get this
      -- backwards and historical streams stop hydrating.
      testCase "a pre-force keyless resume decodes as a force resume" do
        event <- decodeSession (resumedWithoutForceJson "null")
        case event of
          SessionResumed d -> do
            d.correlationKey @?= Nothing
            d.force @?= True
          other -> fail ("Expected SessionResumed, got " <> show other),
      testCase "a pre-force keyed resume decodes as a plain resume" do
        event <- decodeSession (resumedWithoutForceJson "\"k1\"")
        case event of
          SessionResumed d -> do
            d.correlationKey @?= Just "k1"
            d.force @?= False
          other -> fail ("Expected SessionResumed, got " <> show other)
    ]

decodeSession :: LBS.ByteString -> IO SessionEvent
decodeSession raw = do
  value <- either fail pure (eitherDecode raw)
  either (fail . show) pure (parseSessionEvent value)

at :: String -> UTCTime
at = fromMaybe (error "bad fixture timestamp") . iso8601ParseM

assertMemoryRecorded :: MemoryRecordedData -> Assertion
assertMemoryRecorded d = do
  idText d.memoryId @?= "kioku_memory_01kvx9my35e5y825cpy4nycjgz"
  (idText <$> d.sessionId) @?= Just "kioku_session_01kvxa7d2cezhs874g3n8dfgme"
  d.agentId @?= "demo-agent"
  d.scope @?= ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_demo"
  d.memoryType @?= MemoryPreference
  d.content @?= "prefers concise answers"
  d.priority @?= 100
  d.confidence @?= HighConfidence
  d.tags @?= Set.fromList ["style"]
  (idText <$> d.supersedes) @?= Just "kioku_memory_01kvx9pkrxevzafwat8k704yzh"

assertSessionStarted :: SessionStartedData -> Assertion
assertSessionStarted d = do
  idText d.sessionId @?= "kioku_session_01kvxa7d2cezhs874g3n8dfgme"
  d.agentId @?= "demo-agent"
  d.focus @?= "today"
  d.scope @?= ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_demo"
  d.subjectRef @?= Just "daily planning"
  (idText <$> d.previousSessionId) @?= Just "kioku_session_01kvxa2gw6er7r2yzpvtq9axch"

reiMemoryRecordedJson :: LBS.ByteString
reiMemoryRecordedJson =
  """
  {
    "type": "agent_memory_recorded",
    "data": {
      "memoryId": "agent_memory_01kvx9my35e5y825cpy4nycjgz",
      "agentId": "demo-agent",
      "sessionId": "agent_session_01kvxa7d2cezhs874g3n8dfgme",
      "memoryType": "preference",
      "content": "prefers concise answers",
      "anchor": {
        "type": "intention",
        "id": "intention_demo"
      },
      "confidence": "high",
      "tags": ["style"],
      "supersedes": "agent_memory_01kvx9pkrxevzafwat8k704yzh",
      "recordedAt": "2026-06-24T20:10:00Z"
    }
  }
  """

reiSessionStartedJson :: LBS.ByteString
reiSessionStartedJson =
  """
  {
    "type": "agent_session_started",
    "data": {
      "sessionId": "agent_session_01kvxa7d2cezhs874g3n8dfgme",
      "agentId": "demo-agent",
      "focusType": "FocusToday",
      "intentionId": "intention_demo",
      "previousSessionId": "agent_session_01kvxa2gw6er7r2yzpvtq9axch",
      "focusTarget": "daily planning",
      "startedAt": "2026-06-24T20:10:00Z"
    }
  }
  """

reiSessionCompletedJson :: LBS.ByteString
reiSessionCompletedJson =
  """
  {
    "type": "agent_session_completed",
    "data": {
      "sessionId": "agent_session_01kvxa7d2cezhs874g3n8dfgme",
      "completedAt": "2026-06-24T21:30:00Z",
      "modelUsed": "claude-opus-4-8",
      "summary": "planned the day"
    }
  }
  """

reiSessionFailedJson :: LBS.ByteString
reiSessionFailedJson =
  """
  {
    "type": "agent_session_failed",
    "data": {
      "sessionId": "agent_session_01kvxa7d2cezhs874g3n8dfgme",
      "failedAt": "2026-06-24T21:30:00Z",
      "errorMessage": "model timed out"
    }
  }
  """

reiInteractiveSessionRecordedJson :: LBS.ByteString
reiInteractiveSessionRecordedJson =
  """
  {
    "type": "interactive_session_recorded",
    "data": {
      "sessionId": "agent_session_01kvxa7d2cezhs874g3n8dfgme",
      "agentId": "demo-agent",
      "focusType": "FocusGeneralCoaching",
      "intentionId": "intention_demo",
      "startedAt": "2026-06-24T20:10:00Z"
    }
  }
  """

-- | A native @SessionResumed@ payload as written before the @force@ field existed.
resumedWithoutForceJson :: LBS.ByteString -> LBS.ByteString
resumedWithoutForceJson correlationKey =
  "{\"type\": \"session_resumed\", \"data\": {"
    <> "\"sessionId\": \"kioku_session_01kvxa7d2cezhs874g3n8dfgme\", "
    <> "\"correlationKey\": "
    <> correlationKey
    <> ", "
    <> "\"input\": \"approved\", "
    <> "\"resumedAt\": \"2026-06-24T21:30:00Z\"}}"
