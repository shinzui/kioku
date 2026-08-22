-- | Pins the on-the-wire shape of every event Kioku persists.
--
-- Keiro 0.4 tightened validated event-stream assembly, so the risk worth holding
-- still is that a payload written by an earlier Kioku stops decoding. Each
-- fixture below is the literal output of the live codec's @encode@ for one
-- constructor, captured from the pre-upgrade tree; the assertions decode them
-- through the same @parseMemoryEvent@ / @parseSessionEvent@ the event store uses
-- and check the round-tripped value field by field.
module Kioku.CodecCompatSpec
  ( tests,
  )
where

import Control.Monad ((<=<))
import Data.Aeson (Value, eitherDecode, encode)
import Data.Bifunctor (first)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Kioku.Api.Access
  ( MemorySpaceId,
    PrincipalRef,
    RecordedPrincipal (..),
    legacyMemorySpaceId,
    legacyPrincipalRef,
    mkPrincipalRef,
    recordedPrincipalText,
  )
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (Confidence (..), MemoryType (..))
import Kioku.Id (MemoryId, SessionId, idText, parseId)
import Kioku.Memory.Domain
  ( MemoryArchivedData (..),
    MemoryConfidenceUpdatedData (..),
    MemoryEvent (..),
    MemoryMergedData (..),
    MemoryRecordedData (..),
    MemorySupersededData (..),
    MemoryTagsUpdatedData (..),
  )
import Kioku.Memory.Domain qualified as MemoryDomain
import Kioku.Memory.EventStream (parseMemoryEvent)
import Kioku.Prelude (toJSON)
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
import Kioku.Session.Domain qualified as SessionDomain
import Kioku.Session.EventStream (parseSessionEvent)
import Kioku.SpaceFixtures (testActorPrincipal, testSpace)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "pre-upgrade event payloads still decode"
    [ testGroup "memory events" memoryTests,
      testGroup "session events" sessionTests,
      testGroup "foreign payloads are rejected" foreignPayloadTests,
      testGroup "pre-partition payloads land in the legacy space" partitionTests,
      testGroup "partitioned payloads round-trip" roundTripTests
    ]

-- * The memory-space partition

--
-- Every fixture above was captured before memory spaces existed, which makes them the exact
-- input the compatibility rules were written for. These assert what those rules produce.
--
-- Two things are being pinned. First, that a payload with no partition decodes into one
-- explicit space rather than into "no space" — absence of a partition must never read as
-- unrestricted access. Second, that a historical @agentId@ stays marked as the free-text label
-- it is: promoting @agent-1@ to a directory principal would put an identity nobody issued into
-- an audit trail, and every later authorization decision about it would be a decision about a
-- string somebody typed.

partitionTests :: [TestTree]
partitionTests =
  [ testCase "a pre-partition memory_recorded lands in the legacy space" do
      decodeMemory memoryRecordedJson >>= \case
        MemoryRecorded d -> do
          d.memorySpaceId @?= legacyMemorySpaceId
          d.actorPrincipal @?= LegacyPrincipal (legacyPrincipalRef "agent-1")
          d.ownerPrincipal @?= Nothing
        other -> unexpected "MemoryRecorded" other,
    testCase "a legacy agent label is not a directory principal" do
      -- The rendering carries the marker, so nothing downstream can mistake it for one.
      decodeMemory memoryRecordedJson >>= \case
        MemoryRecorded d -> recordedPrincipalText d.actorPrincipal @?= "kioku:legacy:agent-1"
        other -> unexpected "MemoryRecorded" other,
    testCase "a pre-partition memory_archived records no actor at all" do
      -- Archiving never carried an agent, so there is nothing to attribute it to. Inventing
      -- one would be worse than saying so.
      decodeMemory memoryArchivedJson >>= \case
        MemoryArchived d -> do
          d.memorySpaceId @?= legacyMemorySpaceId
          d.actorPrincipal @?= UnattributedPrincipal
        other -> unexpected "MemoryArchived" other,
    testCase "every other pre-partition memory event lands in the legacy space" do
      spaces <- traverse (fmap memoryEventSpace . decodeMemory) allMemoryFixtures
      spaces @?= replicate (length allMemoryFixtures) legacyMemorySpaceId,
    testCase "a pre-partition session_started lands in the legacy space" do
      decodeSession sessionStartedJson >>= \case
        SessionStarted d -> do
          d.memorySpaceId @?= legacyMemorySpaceId
          d.actorPrincipal @?= LegacyPrincipal (legacyPrincipalRef "agent-1")
          d.ownerPrincipal @?= Nothing
        other -> unexpected "SessionStarted" other,
    testCase "a pre-partition turn_recorded records no actor at all" do
      decodeSession turnRecordedJson >>= \case
        TurnRecorded d -> do
          d.memorySpaceId @?= legacyMemorySpaceId
          d.actorPrincipal @?= UnattributedPrincipal
        other -> unexpected "TurnRecorded" other,
    testCase "every other pre-partition session event lands in the legacy space" do
      spaces <- traverse (fmap sessionEventSpace . decodeSession) allSessionFixtures
      spaces @?= replicate (length allSessionFixtures) legacyMemorySpaceId
  ]

-- | Encoding emits only the new form, so a value written today has to survive the same
-- decoder the fixtures above go through — with its space and actor intact rather than
-- defaulted.
roundTripTests :: [TestTree]
roundTripTests =
  [ testCase "a partitioned memory event survives encode and decode" do
      let event = MemoryRecorded partitionedRecord
      decoded <- either (assertFailure . Text.unpack) pure (parseMemoryEvent (toJSON event))
      decoded @?= event,
    testCase "the encoded form actually contains the partition" do
      -- Without this, the round-trip above would still pass if both sides defaulted.
      let encoded = toJSON (MemoryRecorded partitionedRecord)
      assertBool "names the space" (encodedContains "space_test" encoded)
      assertBool "names the actor" (encodedContains "agent_01h9xk3v7hf8b9c0d1e2f3g4h5" encoded),
    testCase "a partitioned session event survives encode and decode" do
      let event = SessionStarted partitionedStart
      decoded <- either (assertFailure . Text.unpack) pure (parseSessionEvent (toJSON event))
      decoded @?= event,
    testCase "a legacy-marked actor survives encode and decode" do
      -- A stream rebuilt and re-encoded must not launder its legacy actor into a real one.
      let event = MemoryRecorded partitionedRecord {actorPrincipal = LegacyPrincipal (legacyPrincipalRef "demo-agent")}
      decoded <- either (assertFailure . Text.unpack) pure (parseMemoryEvent (toJSON event))
      decoded @?= event
  ]

partitionedRecord :: MemoryRecordedData
partitionedRecord =
  MemoryRecordedData
    { memoryId = fixtureMemoryId,
      memorySpaceId = testSpace,
      actorPrincipal = testActorPrincipal,
      ownerPrincipal = Just ownerRef,
      agentId = "agent-1",
      sessionId = Just fixtureSessionId,
      scope = fixtureScope,
      memoryType = MemoryFact,
      content = "the build is green",
      priority = 3,
      confidence = HighConfidence,
      tags = Set.fromList ["build", "ci"],
      supersedes = Nothing,
      recordedAt = at "2026-06-24T21:30:00Z"
    }

partitionedStart :: SessionStartedData
partitionedStart =
  SessionStartedData
    { sessionId = fixtureSessionId,
      memorySpaceId = testSpace,
      actorPrincipal = testActorPrincipal,
      ownerPrincipal = Just ownerRef,
      agentId = "agent-1",
      focus = "ship the release",
      scope = fixtureScope,
      subjectRef = Just "kioku",
      previousSessionId = Nothing,
      parentSessionId = Nothing,
      delegationDepth = 0,
      startedAt = at "2026-06-24T21:30:00Z"
    }

ownerRef :: PrincipalRef
ownerRef = either (error . Text.unpack) id (mkPrincipalRef "person_01h9xk3v7hf8b9c0d1e2f3g4h9")

memoryEventSpace :: MemoryEvent -> MemorySpaceId
memoryEventSpace = MemoryDomain.eventMemorySpaceId

sessionEventSpace :: SessionEvent -> MemorySpaceId
sessionEventSpace = SessionDomain.eventMemorySpaceId

fixtureMemoryId :: MemoryId
fixtureMemoryId = either (error . Text.unpack) id (parseId memoryIdText)

fixtureSessionId :: SessionId
fixtureSessionId = either (error . Text.unpack) id (parseId sessionIdText)

encodedContains :: Text -> Value -> Bool
encodedContains needle = Text.isInfixOf needle . Text.pack . LBS8.unpack . encode

allMemoryFixtures :: [ByteString]
allMemoryFixtures =
  [ memorySupersededJson,
    memoryArchivedJson,
    memoryTagsUpdatedJson,
    memoryConfidenceUpdatedJson,
    memoryMergedJson
  ]

allSessionFixtures :: [ByteString]
allSessionFixtures =
  [ sessionCompletedJson,
    sessionFailedJson,
    sessionAwaitingJson,
    sessionResumedJson,
    interactiveSessionRecordedJson,
    turnRecordedJson
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
    -- These two cases pin the native upcast for SessionResumed events written before the
    -- @force@ field existed. An omitted correlation key used to bypass matching entirely,
    -- so a keyless resume must replay through the force arm and a keyed resume through the
    -- matching arm.
    testCase "a pre-force keyless resume decodes as a force resume" do
      decodeSession (resumedWithoutForceJson "null") >>= \case
        SessionResumed d -> do
          d.correlationKey @?= Nothing
          d.force @?= True
        other -> unexpected "SessionResumed" other,
    testCase "a pre-force keyed resume decodes as a plain resume" do
      decodeSession (resumedWithoutForceJson "\"k1\"") >>= \case
        SessionResumed d -> do
          d.correlationKey @?= Just "k1"
          d.force @?= False
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

-- * Foreign payload rejection

--
-- The public parser accepts Kioku's native event language only. Construct the former foreign
-- tag from fragments so source scans cannot mistake this negative case for a supported fixture.

foreignPayloadTests :: [TestTree]
foreignPayloadTests =
  [ testCase "a former consumer-specific memory payload fails native decoding" do
      case parseMemoryEvent =<< decodeValue foreignMemoryRecordedJson of
        Right event -> assertFailure ("expected a decode failure, got " <> show event)
        Left _ -> pure ()
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

-- | A native @SessionResumed@ payload as written before the @force@ field existed.
resumedWithoutForceJson :: ByteString -> ByteString
resumedWithoutForceJson correlationKey =
  "{\"type\": \"session_resumed\", \"data\": {"
    <> "\"sessionId\": \"kioku_session_01kvxa7d2cezhs874g3n8dfgme\", "
    <> "\"correlationKey\": "
    <> correlationKey
    <> ", "
    <> "\"input\": \"approved\", "
    <> "\"resumedAt\": \"2026-06-24T21:30:00Z\"}}"

interactiveSessionRecordedJson :: ByteString
interactiveSessionRecordedJson =
  "{\"data\":{\"agentId\":\"agent-1\",\"focus\":\"pairing\",\"scope\":{\"contents\":[\"shikigami\",\"repo\",\"kioku\"],\"tag\":\"ScopeEntity\"},\"sessionId\":\"kioku_session_01kvxa7d2cezhs874g3n8dfgme\",\"startedAt\":\"2026-06-24T21:44:00Z\",\"subjectRef\":null},\"type\":\"interactive_session_recorded\"}"

turnRecordedJson :: ByteString
turnRecordedJson =
  "{\"data\":{\"content\":\"hello\",\"outputTokens\":34,\"promptTokens\":12,\"recordedAt\":\"2026-06-24T21:45:00Z\",\"role\":\"user\",\"sessionId\":\"kioku_session_01kvxa7d2cezhs874g3n8dfgme\",\"toolSummary\":\"no tools\",\"turnId\":\"turn-1\",\"turnIndex\":0},\"type\":\"turn_recorded\"}"

foreignMemoryRecordedJson :: ByteString
foreignMemoryRecordedJson =
  "{\"type\":\"agent"
    <> "_memory_recorded\",\"data\":{\"memoryId\":\"agent"
    <> "_memory_01kvxa7d2cezhs874g3n8dfgme\"}}"

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
