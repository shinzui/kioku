-- | Pins the on-the-wire shape of every event Kioku persists.
--
-- Keiro 0.4 tightened validated event-stream assembly, so the risk worth holding
-- still is that a payload written by an earlier Kioku stops decoding. Each
-- fixture below is the literal output of the live codec's @encode@ for one
-- constructor, captured from the pre-upgrade tree; the assertions decode them
-- through the same @parseMemoryEvent@ / @parseSessionEvent@ the event store uses
-- and check the round-tripped value field by field.
--
-- 'Kioku.ReiCompatSpec' covers the /legacy/ arm of those parsers -- payloads in
-- the older Rei wire format. This module covers the /native/ arm, and the last
-- test here pins the fallback that joins them, so a future upgrade cannot delete
-- the legacy path without a test going red.
module Kioku.CodecCompatSpec
  ( tests,
  )
where

import Control.Monad ((<=<))
import Data.Aeson (Value, eitherDecode)
import Data.Bifunctor (first)
import Data.ByteString.Lazy (ByteString)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (Confidence (..), MemoryType (..))
import Kioku.Id (idText)
import Kioku.Memory.Domain
  ( MemoryArchivedData (..),
    MemoryConfidenceUpdatedData (..),
    MemoryEvent (..),
    MemoryMergedData (..),
    MemoryRecordedData (..),
    MemorySupersededData (..),
    MemoryTagsUpdatedData (..),
  )
import Kioku.Memory.EventStream (parseMemoryEvent)
import Kioku.Session.Domain
  ( InteractiveSessionRecordedData (..),
    SessionAwaitingData (..),
    SessionCompletedData (..),
    SessionEvent (..),
    SessionFailedData (..),
    SessionResumedData (..),
    SessionStartedData (..),
    TurnRecordedData (..),
  )
import Kioku.Session.EventStream (parseSessionEvent)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "pre-upgrade event payloads still decode"
    [ testGroup "memory events" memoryTests,
      testGroup "session events" sessionTests,
      testGroup "the legacy fallback still exists" fallbackTests
    ]

-- * Memory events

memoryTests :: [TestTree]
memoryTests =
  [ testCase "memory_recorded" do
      decodeMemory memoryRecordedJson >>= \case
        MemoryRecorded d -> do
          idText d.memoryId @?= memoryIdText
          d.agentId @?= "agent-1"
          fmap idText d.sessionId @?= Just sessionIdText
          d.scope @?= fixtureScope
          d.memoryType @?= MemoryFact
          d.content @?= "the build is green"
          d.priority @?= 3
          d.confidence @?= HighConfidence
          d.tags @?= Set.fromList ["build", "ci"]
          d.supersedes @?= Nothing
          d.recordedAt @?= at "2026-06-24T21:30:00Z"
        other -> unexpected "MemoryRecorded" other,
    testCase "memory_superseded" do
      decodeMemory memorySupersededJson >>= \case
        MemorySuperseded d -> do
          idText d.memoryId @?= memoryIdText
          idText d.supersededBy @?= otherMemoryIdText
          d.supersededAt @?= at "2026-06-24T21:31:00Z"
        other -> unexpected "MemorySuperseded" other,
    testCase "memory_archived" do
      decodeMemory memoryArchivedJson >>= \case
        MemoryArchived d -> do
          idText d.memoryId @?= memoryIdText
          d.archivedAt @?= at "2026-06-24T21:32:00Z"
        other -> unexpected "MemoryArchived" other,
    testCase "memory_tags_updated" do
      decodeMemory memoryTagsUpdatedJson >>= \case
        MemoryTagsUpdated d -> do
          idText d.memoryId @?= memoryIdText
          d.tags @?= Set.fromList ["ci", "stable"]
          d.updatedAt @?= at "2026-06-24T21:33:00Z"
        other -> unexpected "MemoryTagsUpdated" other,
    testCase "memory_confidence_updated" do
      decodeMemory memoryConfidenceUpdatedJson >>= \case
        MemoryConfidenceUpdated d -> do
          idText d.memoryId @?= memoryIdText
          d.confidence @?= MediumConfidence
          d.updatedAt @?= at "2026-06-24T21:34:00Z"
        other -> unexpected "MemoryConfidenceUpdated" other,
    testCase "memory_merged" do
      decodeMemory memoryMergedJson >>= \case
        MemoryMerged d -> do
          idText d.memoryId @?= memoryIdText
          idText d.mergedInto @?= otherMemoryIdText
          d.mergedAt @?= at "2026-06-24T21:35:00Z"
        other -> unexpected "MemoryMerged" other
  ]

-- * Session events

sessionTests :: [TestTree]
sessionTests =
  [ testCase "session_started" do
      decodeSession sessionStartedJson >>= \case
        SessionStarted d -> do
          idText d.sessionId @?= sessionIdText
          d.agentId @?= "agent-1"
          d.focus @?= "ship the release"
          d.scope @?= fixtureScope
          d.subjectRef @?= Just "kioku"
          d.previousSessionId @?= Nothing
          d.parentSessionId @?= Nothing
          d.delegationDepth @?= 0
          d.startedAt @?= at "2026-06-24T21:30:00Z"
        other -> unexpected "SessionStarted" other,
    testCase "session_completed" do
      decodeSession sessionCompletedJson >>= \case
        SessionCompleted d -> do
          idText d.sessionId @?= sessionIdText
          d.completedAt @?= at "2026-06-24T21:40:00Z"
          d.modelUsed @?= Just "claude-opus-4-8"
          d.summary @?= Just "planned the day"
        other -> unexpected "SessionCompleted" other,
    testCase "session_failed" do
      decodeSession sessionFailedJson >>= \case
        SessionFailed d -> do
          idText d.sessionId @?= sessionIdText
          d.failedAt @?= at "2026-06-24T21:41:00Z"
          d.errorMessage @?= "model timed out"
        other -> unexpected "SessionFailed" other,
    testCase "session_awaiting" do
      decodeSession sessionAwaitingJson >>= \case
        SessionAwaiting d -> do
          idText d.sessionId @?= sessionIdText
          d.reason @?= "needs human input"
          d.correlationKey @?= Just "approval-1"
          d.deadline @?= Just (at "2026-06-25T21:41:00Z")
          d.awaitedAt @?= at "2026-06-24T21:42:00Z"
        other -> unexpected "SessionAwaiting" other,
    testCase "session_resumed" do
      decodeSession sessionResumedJson >>= \case
        SessionResumed d -> do
          idText d.sessionId @?= sessionIdText
          d.correlationKey @?= Just "approval-1"
          d.force @?= False
          d.input @?= "approved"
          d.resumedAt @?= at "2026-06-24T21:43:00Z"
        other -> unexpected "SessionResumed" other,
    testCase "interactive_session_recorded" do
      decodeSession interactiveSessionRecordedJson >>= \case
        InteractiveSessionRecorded d -> do
          idText d.sessionId @?= sessionIdText
          d.agentId @?= "agent-1"
          d.focus @?= "pairing"
          d.scope @?= fixtureScope
          d.subjectRef @?= Nothing
          d.startedAt @?= at "2026-06-24T21:44:00Z"
        other -> unexpected "InteractiveSessionRecorded" other,
    testCase "turn_recorded" do
      decodeSession turnRecordedJson >>= \case
        TurnRecorded d -> do
          idText d.sessionId @?= sessionIdText
          d.turnId @?= "turn-1"
          d.turnIndex @?= 0
          d.role @?= "user"
          d.content @?= "hello"
          d.toolSummary @?= Just "no tools"
          d.promptTokens @?= Just 12
          d.outputTokens @?= Just 34
          d.recordedAt @?= at "2026-06-24T21:45:00Z"
        other -> unexpected "TurnRecorded" other
  ]

-- * The two-arm fallback

--
-- @parseMemoryEvent@ tries the native parser, then the legacy Rei one, and on a
-- double failure reports both errors. These pin all three behaviours so the
-- fallback cannot be dropped silently.

fallbackTests :: [TestTree]
fallbackTests =
  [ testCase "a legacy Rei payload decodes through the second arm" do
      decodeMemory legacyReiMemoryRecordedJson >>= \case
        MemoryRecorded d -> do
          idText d.memoryId @?= memoryIdText
          d.content @?= "recorded by rei"
        other -> unexpected "MemoryRecorded" other,
    testCase "an undecodable payload reports both arms' errors" do
      case parseMemoryEvent =<< decodeValue "{\"type\":\"not_a_real_event\",\"data\":{}}" of
        Right event -> assertFailure ("expected a decode failure, got " <> show event)
        Left err -> do
          assertContains "legacy decode failed" err
          assertContains "not_a_real_event" err
  ]

-- * Fixtures

--
-- Captured verbatim from @memoryCodec.encode@ / @sessionCodec.encode@ on the
-- pre-upgrade tree (kioku 0.1.0.0, Keiro 0.3). Do not regenerate these from the
-- current code -- that would make the test tautological. Edit only alongside a
-- deliberate, documented wire-format change.

memoryRecordedJson :: ByteString
memoryRecordedJson =
  "{\"data\":{\"agentId\":\"agent-1\",\"confidence\":\"high\",\"content\":\"the build is green\",\"memoryId\":\"kioku_memory_01kvxa7d2cezhs874g3n8dfgme\",\"memoryType\":\"fact\",\"priority\":3,\"recordedAt\":\"2026-06-24T21:30:00Z\",\"scope\":{\"contents\":[\"shikigami\",\"repo\",\"kioku\"],\"tag\":\"ScopeEntity\"},\"sessionId\":\"kioku_session_01kvxa7d2cezhs874g3n8dfgme\",\"supersedes\":null,\"tags\":[\"build\",\"ci\"]},\"type\":\"memory_recorded\"}"

memorySupersededJson :: ByteString
memorySupersededJson =
  "{\"data\":{\"memoryId\":\"kioku_memory_01kvxa7d2cezhs874g3n8dfgme\",\"supersededAt\":\"2026-06-24T21:31:00Z\",\"supersededBy\":\"kioku_memory_01kvxa7d2cezhs874g3n8dfgmf\"},\"type\":\"memory_superseded\"}"

memoryArchivedJson :: ByteString
memoryArchivedJson =
  "{\"data\":{\"archivedAt\":\"2026-06-24T21:32:00Z\",\"memoryId\":\"kioku_memory_01kvxa7d2cezhs874g3n8dfgme\"},\"type\":\"memory_archived\"}"

memoryTagsUpdatedJson :: ByteString
memoryTagsUpdatedJson =
  "{\"data\":{\"memoryId\":\"kioku_memory_01kvxa7d2cezhs874g3n8dfgme\",\"tags\":[\"ci\",\"stable\"],\"updatedAt\":\"2026-06-24T21:33:00Z\"},\"type\":\"memory_tags_updated\"}"

memoryConfidenceUpdatedJson :: ByteString
memoryConfidenceUpdatedJson =
  "{\"data\":{\"confidence\":\"medium\",\"memoryId\":\"kioku_memory_01kvxa7d2cezhs874g3n8dfgme\",\"updatedAt\":\"2026-06-24T21:34:00Z\"},\"type\":\"memory_confidence_updated\"}"

memoryMergedJson :: ByteString
memoryMergedJson =
  "{\"data\":{\"memoryId\":\"kioku_memory_01kvxa7d2cezhs874g3n8dfgme\",\"mergedAt\":\"2026-06-24T21:35:00Z\",\"mergedInto\":\"kioku_memory_01kvxa7d2cezhs874g3n8dfgmf\"},\"type\":\"memory_merged\"}"

sessionStartedJson :: ByteString
sessionStartedJson =
  "{\"data\":{\"agentId\":\"agent-1\",\"delegationDepth\":0,\"focus\":\"ship the release\",\"parentSessionId\":null,\"previousSessionId\":null,\"scope\":{\"contents\":[\"shikigami\",\"repo\",\"kioku\"],\"tag\":\"ScopeEntity\"},\"sessionId\":\"kioku_session_01kvxa7d2cezhs874g3n8dfgme\",\"startedAt\":\"2026-06-24T21:30:00Z\",\"subjectRef\":\"kioku\"},\"type\":\"session_started\"}"

sessionCompletedJson :: ByteString
sessionCompletedJson =
  "{\"data\":{\"completedAt\":\"2026-06-24T21:40:00Z\",\"modelUsed\":\"claude-opus-4-8\",\"sessionId\":\"kioku_session_01kvxa7d2cezhs874g3n8dfgme\",\"summary\":\"planned the day\"},\"type\":\"session_completed\"}"

sessionFailedJson :: ByteString
sessionFailedJson =
  "{\"data\":{\"errorMessage\":\"model timed out\",\"failedAt\":\"2026-06-24T21:41:00Z\",\"sessionId\":\"kioku_session_01kvxa7d2cezhs874g3n8dfgme\"},\"type\":\"session_failed\"}"

sessionAwaitingJson :: ByteString
sessionAwaitingJson =
  "{\"data\":{\"awaitedAt\":\"2026-06-24T21:42:00Z\",\"correlationKey\":\"approval-1\",\"deadline\":\"2026-06-25T21:41:00Z\",\"reason\":\"needs human input\",\"sessionId\":\"kioku_session_01kvxa7d2cezhs874g3n8dfgme\"},\"type\":\"session_awaiting\"}"

sessionResumedJson :: ByteString
sessionResumedJson =
  "{\"data\":{\"correlationKey\":\"approval-1\",\"force\":false,\"input\":\"approved\",\"resumedAt\":\"2026-06-24T21:43:00Z\",\"sessionId\":\"kioku_session_01kvxa7d2cezhs874g3n8dfgme\"},\"type\":\"session_resumed\"}"

interactiveSessionRecordedJson :: ByteString
interactiveSessionRecordedJson =
  "{\"data\":{\"agentId\":\"agent-1\",\"focus\":\"pairing\",\"scope\":{\"contents\":[\"shikigami\",\"repo\",\"kioku\"],\"tag\":\"ScopeEntity\"},\"sessionId\":\"kioku_session_01kvxa7d2cezhs874g3n8dfgme\",\"startedAt\":\"2026-06-24T21:44:00Z\",\"subjectRef\":null},\"type\":\"interactive_session_recorded\"}"

turnRecordedJson :: ByteString
turnRecordedJson =
  "{\"data\":{\"content\":\"hello\",\"outputTokens\":34,\"promptTokens\":12,\"recordedAt\":\"2026-06-24T21:45:00Z\",\"role\":\"user\",\"sessionId\":\"kioku_session_01kvxa7d2cezhs874g3n8dfgme\",\"toolSummary\":\"no tools\",\"turnId\":\"turn-1\",\"turnIndex\":0},\"type\":\"turn_recorded\"}"

-- | A Rei-format payload, which only the legacy arm of 'parseMemoryEvent' understands.
legacyReiMemoryRecordedJson :: ByteString
legacyReiMemoryRecordedJson =
  "{\"type\":\"agent_memory_recorded\",\"data\":{\"memoryId\":\"agent_memory_01kvxa7d2cezhs874g3n8dfgme\",\"agentId\":\"agent-1\",\"anchor\":{\"type\":\"intention\",\"id\":\"intention_demo\"},\"memoryType\":\"fact\",\"content\":\"recorded by rei\",\"confidence\":\"high\",\"tags\":[\"build\"],\"recordedAt\":\"2026-06-24T21:30:00Z\"}}"

-- * Helpers

fixtureScope :: MemoryScope
fixtureScope = ScopeEntity (Namespace "shikigami") (ScopeKind "repo") "kioku"

memoryIdText :: Text
memoryIdText = "kioku_memory_01kvxa7d2cezhs874g3n8dfgme"

otherMemoryIdText :: Text
otherMemoryIdText = "kioku_memory_01kvxa7d2cezhs874g3n8dfgmf"

sessionIdText :: Text
sessionIdText = "kioku_session_01kvxa7d2cezhs874g3n8dfgme"

at :: String -> UTCTime
at = maybe (error "CodecCompatSpec: malformed fixture timestamp") id . iso8601ParseM

decodeValue :: ByteString -> Either Text Value
decodeValue = first Text.pack . eitherDecode

decodeMemory :: ByteString -> IO MemoryEvent
decodeMemory = either (assertFailure . Text.unpack) pure . (parseMemoryEvent <=< decodeValue)

decodeSession :: ByteString -> IO SessionEvent
decodeSession = either (assertFailure . Text.unpack) pure . (parseSessionEvent <=< decodeValue)

unexpected :: (Show event) => String -> event -> IO ()
unexpected expected got = assertFailure ("Expected " <> expected <> ", got " <> show got)

assertContains :: Text -> Text -> IO ()
assertContains needle haystack =
  if needle `Text.isInfixOf` haystack
    then pure ()
    else assertFailure ("expected " <> show needle <> " in " <> show haystack)
