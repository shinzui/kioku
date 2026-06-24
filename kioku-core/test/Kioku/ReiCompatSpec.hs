module Kioku.ReiCompatSpec
  ( tests,
  )
where

import Data.Aeson (eitherDecode)
import Data.ByteString.Lazy qualified as LBS
import Data.Set qualified as Set
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (Confidence (..), MemoryType (..))
import Kioku.Id (idText)
import Kioku.Memory.Domain (MemoryEvent (..), MemoryRecordedData (..))
import Kioku.Memory.EventStream (parseMemoryEvent)
import Kioku.Session.Domain (SessionEvent (..), SessionStartedData (..))
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
          other -> fail ("Expected SessionStarted, got " <> show other)
    ]

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
  d.focus @?= "FocusToday"
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
