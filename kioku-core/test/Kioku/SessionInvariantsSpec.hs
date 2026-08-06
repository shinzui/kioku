-- | Invariants the session aggregate enforces itself, independent of any read-model
-- precheck. Every test here that matters drives 'runCommandWithProjections' directly, so a
-- passing assertion proves the state machine rejected (or accepted) the command — not that
-- a precheck happened to run first.
module Kioku.SessionInvariantsSpec (tests) where

import Control.Monad (void)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import Keiro.Command (CommandError (..), defaultRunCommandOptions)
import Keiro.Projection (runCommandWithProjections)
import Keiro.Stream qualified as Stream
import Kioku.Api.Access
  ( MemorySpaceId,
    RecordedPrincipal (..),
    legacyMemorySpaceId,
    legacyPrincipalRef,
  )
import Kioku.Api.Scope (MemoryScope (..), Namespace (..))
import Kioku.App (AppEffects, runAppIO, withNoopAppEnv)
import Kioku.Distill.Timer (l1TimerScheduleProjection)
import Kioku.Id (SessionId, genSessionId, idText)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Session qualified as Session
import Kioku.Session.Domain
  ( AwaitInputData (..),
    RecordTurnData (..),
    ResumeSessionData (..),
    SessionAwaitingData (..),
    SessionCommand (..),
    SessionEvent (..),
    SessionResumedData (..),
    SessionStartedData (..),
    StartSessionData (..),
  )
import Kioku.Session.EventStream (parseSessionEvent, sessionEventStream, sessionStream)
import Kioku.Session.ReadModel (SessionRow (..), sessionInlineProjection)
import Kioku.SpaceFixtures (testActorPrincipal, testContext, testSpace)
import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Types
  ( EventData (..),
    EventType (..),
    ExpectedVersion (..),
    RecordedEvent (..),
    StreamVersion (..),
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Session invariants"
    [ testCase "aggregate rejects a mismatched resume key" testAggregateRejectsMismatchedKey,
      testCase "a stale resume after re-park is rejected" testStaleResumeAfterRepark,
      testCase "forceResume waives the key explicitly" testForceResume,
      testCase "a keyless wait resumes with no key" testKeylessWaitResumes,
      testCase "a keyed resume of a keyless wait is rejected" testKeyedResumeOfKeylessWait,
      testCase "re-park clears the previous resume input" testReparkClearsResumeInput,
      testCase "pre-force keyless resume events still hydrate" testHydratesLegacyKeylessResume,
      testCase "pre-force keyed resume events still hydrate" testHydratesLegacyKeyedResume,
      testGroup
        "turn identity"
        [ testCase "an identical re-record is a duplicate" testTurnReRecordIsDuplicate,
          testCase "the same index with different content is a conflict" testTurnSameIndexConflict,
          testCase "the same turn id at a different index is a conflict" testTurnIdReuseConflict,
          testCase "the aggregate rejects a non-increasing index" testAggregateRejectsNonIncreasingTurn
        ]
    ]

-- | The core proof: with the session parked on @k1@, a @ResumeSession@ carrying @k2@ is
-- rejected by the transducer itself. No read-model precheck runs on this path, so the
-- rejection can only have come from the aggregate's guard.
testAggregateRejectsMismatchedKey :: Assertion
testAggregateRejectsMismatchedKey =
  withApp do
    sid <- startFixture
    parkFixture sid (Just "k1")
    now <- liftIO getCurrentTime
    result <-
      runSessionCommandDirect
        sid
        ( ResumeSession
            ResumeSessionData
              { sessionId = sid,
                memorySpaceId = testSpace,
                actorPrincipal = testActorPrincipal,
                correlationKey = Just "k2",
                force = False,
                input = "approved",
                resumedAt = now
              }
        )
    liftIO $ assertRejected "mismatched resume key" result
    events <- readSessionEvents sid
    liftIO $
      assertEqual
        "no SessionResumed event was appended"
        ["SessionStarted", "SessionAwaiting"]
        (eventName <$> events)

-- | The race the plan closes: park k1, resume k1, re-park on k2. A caller still holding
-- k1 must not be able to answer the k2 wait.
testStaleResumeAfterRepark :: Assertion
testStaleResumeAfterRepark =
  withApp do
    sid <- startFixture
    parkFixture sid (Just "k1")
    resumeFixture sid (Just "k1") "first answer"
    parkFixture sid (Just "k2")
    now <- liftIO getCurrentTime
    let staleResume =
          ResumeSessionData
            { sessionId = sid,
              memorySpaceId = testSpace,
              actorPrincipal = testActorPrincipal,
              correlationKey = Just "k1",
              force = False,
              input = "stale answer",
              resumedAt = now
            }
    -- Through the public API the precheck catches it early ...
    apiResult <- Session.resumeWithContext testContext staleResume
    case apiResult of
      Left Session.SessionCorrelationMismatch -> pure ()
      other -> liftIO (assertFailure ("expected SessionCorrelationMismatch, got " <> show other))
    -- ... and with the precheck bypassed, the aggregate catches it too.
    directResult <- runSessionCommandDirect sid (ResumeSession staleResume)
    liftIO $ assertRejected "stale resume key" directResult
    -- The live wait still resumes.
    resumeFixture sid (Just "k2") "second answer"
    row <- getExisting sid
    liftIO do
      assertEqual "resumed with the live key" "running" row.status
      assertEqual "the live answer won" (Just "second answer") row.resumeInput

testForceResume :: Assertion
testForceResume =
  withApp do
    sid <- startFixture
    parkFixture sid (Just "k1")
    now <- liftIO getCurrentTime
    result <- Session.forceResumeWithContext testContext sid "forced answer" now
    void (liftEither "Session.forceResumeWithContext" result)
    row <- getExisting sid
    liftIO do
      assertEqual "force resume ran" "running" row.status
      assertEqual "force resume input" (Just "forced answer") row.resumeInput
    events <- readSessionEvents sid
    liftIO $
      assertBool "the appended SessionResumed event carries force = True" $
        case [d | SessionResumed d <- events] of
          [d] -> d.force && isNothing' d.correlationKey
          _ -> False
  where
    isNothing' = \case
      Nothing -> True
      Just (_ :: Text) -> False

testKeylessWaitResumes :: Assertion
testKeylessWaitResumes =
  withApp do
    sid <- startFixture
    parkFixture sid Nothing
    resumeFixture sid Nothing "approved"
    row <- getExisting sid
    liftIO do
      assertEqual "keyless resume ran" "running" row.status
      assertEqual "keyless resume input" (Just "approved") row.resumeInput

-- | Exact 'Maybe' equality: naming a key when the wait has none is a mismatch, not a
-- harmless extra.
testKeyedResumeOfKeylessWait :: Assertion
testKeyedResumeOfKeylessWait =
  withApp do
    sid <- startFixture
    parkFixture sid Nothing
    now <- liftIO getCurrentTime
    result <-
      runSessionCommandDirect
        sid
        ( ResumeSession
            ResumeSessionData
              { sessionId = sid,
                memorySpaceId = testSpace,
                actorPrincipal = testActorPrincipal,
                correlationKey = Just "unexpected",
                force = False,
                input = "approved",
                resumedAt = now
              }
        )
    liftIO $ assertRejected "keyed resume of a keyless wait" result

testReparkClearsResumeInput :: Assertion
testReparkClearsResumeInput =
  withApp do
    sid <- startFixture
    parkFixture sid (Just "k1")
    resumeFixture sid (Just "k1") "first answer"
    parkFixture sid (Just "k2")
    row <- getExisting sid
    liftIO do
      assertEqual "re-parked" "awaiting" row.status
      assertEqual "the new wait's key is visible" (Just "k2") row.awaitingCorrelationKey
      assertEqual "the previous wait's answer is gone" Nothing row.resumeInput

-- | A stream written before the @force@ field existed, whose resume omitted the
-- correlation key. Under the old code that omission /was/ a bypass, so it must replay
-- through the force arm of the new guard.
testHydratesLegacyKeylessResume :: Assertion
testHydratesLegacyKeylessResume = hydrateLegacyStream Nothing

-- | The same, but the historical resume named the key it parked on: it must replay through
-- the matching arm.
testHydratesLegacyKeyedResume :: Assertion
testHydratesLegacyKeyedResume = hydrateLegacyStream (Just "k1")

-- | Hand-append a pre-@force@ event stream (no @force@ key in the @SessionResumed@ JSON),
-- then drive a real command against it. Success proves keiro rehydrated all three events
-- through the new guard: a rejected historical event would surface as
-- 'HydrationReplayFailed' instead.
--
-- The command runs through 'runCommandWithProjections' rather than 'Session.awaitInputWithContext'
-- because a hand-appended stream has no read-model row, and the public API's precheck
-- would fail with 'SessionNotFound' before hydration was ever attempted.
hydrateLegacyStream :: Maybe Text -> Assertion
hydrateLegacyStream resumedKey =
  withApp do
    sid <- liftIO genSessionId
    now <- liftIO getCurrentTime
    let started =
          SessionStarted
            SessionStartedData
              { memorySpaceId = legacyMemorySpaceId,
                actorPrincipal = LegacyPrincipal (legacyPrincipalRef "test-agent"),
                ownerPrincipal = Nothing,
                sessionId = sid,
                agentId = "test-agent",
                focus = "legacy replay",
                scope = testScope,
                subjectRef = Nothing,
                previousSessionId = Nothing,
                parentSessionId = Nothing,
                delegationDepth = 0,
                startedAt = now
              }
        awaiting =
          SessionAwaiting
            SessionAwaitingData
              { memorySpaceId = legacyMemorySpaceId,
                actorPrincipal = UnattributedPrincipal,
                sessionId = sid,
                reason = "approval",
                correlationKey = Just "k1",
                deadline = Nothing,
                awaitedAt = now
              }
    -- Written as an older kioku wrote them: no partition keys at all.
    void $
      appendToStream
        (Stream.streamName (sessionStream sid))
        NoStream
        [ rawEvent "SessionStarted" (withoutPartitionKeys (toJSON started)),
          rawEvent "SessionAwaiting" (withoutPartitionKeys (toJSON awaiting)),
          rawEvent "SessionResumed" (legacyResumedPayload sid resumedKey now)
        ]
    -- A command in some *other* space must not be able to drive this session. The events
    -- carry no partition, so this is the assertion that a missing partition resolves to the
    -- legacy space rather than to "any space".
    crossSpace <-
      runSessionCommandDirect sid (AwaitInput (awaitIn testSpace testActorPrincipal sid now))
    case crossSpace of
      Left _ -> pure ()
      Right _ ->
        liftIO (assertFailure "a command in another memory space drove a legacy session")
    -- The stream ends in Running. A fresh AwaitInput in the legacy space must hydrate it and
    -- be accepted.
    result <-
      runSessionCommandDirect
        sid
        (AwaitInput (awaitIn legacyMemorySpaceId UnattributedPrincipal sid now))
    case result of
      Right _ -> pure ()
      Left err ->
        liftIO (assertFailure ("a pre-force stream failed to hydrate: " <> show err))
    events <- readSessionEvents sid
    liftIO $
      assertEqual
        "the new event landed on top of the replayed history"
        ["SessionStarted", "SessionAwaiting", "SessionResumed", "SessionAwaiting"]
        (eventName <$> events)

-- | An @AwaitInput@ for a given space, so the two attempts above differ in exactly one thing.
awaitIn :: MemorySpaceId -> RecordedPrincipal -> SessionId -> UTCTime -> AwaitInputData
awaitIn memorySpaceId actorPrincipal sid now =
  AwaitInputData
    { sessionId = sid,
      memorySpaceId,
      actorPrincipal,
      reason = "approval",
      correlationKey = Just "k2",
      deadline = Nothing,
      awaitedAt = now
    }

-- | Strip the partition keys an older kioku never wrote.
--
-- Building the value and then removing the keys keeps the fixture honest in both directions: it
-- is exactly the current encoder's output minus the fields this change added, so it cannot
-- drift away from the real shape and cannot accidentally test the new one.
withoutPartitionKeys :: Value -> Value
withoutPartitionKeys = \case
  Object o -> Object (foldr KeyMap.delete o ["memorySpaceId", "actorPrincipal", "ownerPrincipal"])
  other -> other

-- * Turn identity

testTurnReRecordIsDuplicate :: Assertion
testTurnReRecordIsDuplicate =
  withApp do
    sid <- startFixture
    let turn = turnData sid "turn-a" 0 "hello"
    void (liftEither "first recordTurn" =<< Session.recordTurnWithContext testContext turn)
    void (liftEither "duplicate recordTurn" =<< Session.recordTurnWithContext testContext turn)
    events <- readSessionEvents sid
    liftIO $
      assertEqual
        "the duplicate appended no second TurnRecorded"
        1
        (length [() | TurnRecorded _ <- events])
    turns <- liftEither "getTurns" =<< Session.getTurns sid
    liftIO $ assertEqual "exactly one turn row" 1 (length turns)

testTurnSameIndexConflict :: Assertion
testTurnSameIndexConflict =
  withApp do
    sid <- startFixture
    void (liftEither "first recordTurn" =<< Session.recordTurnWithContext testContext (turnData sid "turn-a" 0 "hello"))
    result <- Session.recordTurnWithContext testContext (turnData sid "turn-a" 0 "something else")
    liftIO $ assertConflict "same index, different content" result
    events <- readSessionEvents sid
    liftIO $
      assertEqual "no second TurnRecorded" 1 (length [() | TurnRecorded _ <- events])

testTurnIdReuseConflict :: Assertion
testTurnIdReuseConflict =
  withApp do
    sid <- startFixture
    void (liftEither "first recordTurn" =<< Session.recordTurnWithContext testContext (turnData sid "turn-a" 0 "hello"))
    result <- Session.recordTurnWithContext testContext (turnData sid "turn-a" 1 "a new turn reusing the id")
    liftIO $ assertConflict "turn id reused at a different index" result
    events <- readSessionEvents sid
    liftIO $
      assertEqual "no second TurnRecorded" 1 (length [() | TurnRecorded _ <- events])

-- | The command layer's dedup is a convenience; this proves the state machine enforces the
-- strictly-increasing index on its own, with every precheck bypassed.
testAggregateRejectsNonIncreasingTurn :: Assertion
testAggregateRejectsNonIncreasingTurn =
  withApp do
    sid <- startFixture
    void (liftEither "recordTurn 0" =<< Session.recordTurnWithContext testContext (turnData sid "turn-a" 0 "hello"))
    void (liftEither "recordTurn 1" =<< Session.recordTurnWithContext testContext (turnData sid "turn-b" 1 "again"))
    now <- liftIO getCurrentTime
    result <-
      runSessionCommandDirect
        sid
        ( RecordTurn
            RecordTurnData
              { sessionId = sid,
                memorySpaceId = testSpace,
                actorPrincipal = testActorPrincipal,
                turnId = "turn-c",
                turnIndex = 1,
                role = "user",
                content = "a stale index",
                toolSummary = Nothing,
                promptTokens = Nothing,
                outputTokens = Nothing,
                recordedAt = now
              }
        )
    liftIO $ assertRejected "non-increasing turn index" result
    events <- readSessionEvents sid
    liftIO $
      assertEqual "still only the two committed turns" 2 (length [() | TurnRecorded _ <- events])

turnData :: SessionId -> Text -> Int -> Text -> RecordTurnData
turnData sid turnId turnIndex content =
  RecordTurnData
    { sessionId = sid,
      memorySpaceId = testSpace,
      actorPrincipal = testActorPrincipal,
      turnId,
      turnIndex,
      role = "user",
      content,
      toolSummary = Nothing,
      promptTokens = Nothing,
      outputTokens = Nothing,
      recordedAt = fixedRecordedAt
    }

-- | Turn recording compares semantic fields, not the clock (see 'Kioku.Session.mismatchOf'),
-- but pinning the timestamp keeps these fixtures obviously identical.
fixedRecordedAt :: UTCTime
fixedRecordedAt = UTCTime (fromGregorian 2026 7 11) 0

assertConflict :: String -> Either Session.SessionWriteError SessionId -> Assertion
assertConflict label = \case
  Left (Session.SessionConflict _) -> pure ()
  other -> assertFailure (label <> ": expected SessionConflict, got " <> show other)

-- | The @SessionResumed@ JSON exactly as it was written before this plan: no @force@ key.
legacyResumedPayload :: SessionId -> Maybe Text -> UTCTime -> Value
legacyResumedPayload sid key resumedAt =
  object
    [ "type" .= ("session_resumed" :: Text),
      "data"
        .= object
          [ "sessionId" .= idText sid,
            "correlationKey" .= key,
            "input" .= ("approved" :: Text),
            "resumedAt" .= resumedAt
          ]
    ]

rawEvent :: Text -> Value -> EventData
rawEvent typ payload =
  EventData
    { eventId = Nothing,
      eventType = EventType typ,
      payload,
      metadata = Nothing,
      causationId = Nothing,
      correlationId = Nothing
    }

-- | Run a command straight at the aggregate, skipping 'Kioku.Session''s read-model
-- prechecks. This is the harness that makes "the aggregate enforces it" a testable claim.
runSessionCommandDirect ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  SessionCommand ->
  Eff es (Either CommandError ())
runSessionCommandDirect sid cmd =
  void
    <$> runCommandWithProjections
      defaultRunCommandOptions
      sessionEventStream
      (sessionStream sid)
      cmd
      [sessionInlineProjection, l1TimerScheduleProjection]

assertRejected :: String -> Either CommandError () -> Assertion
assertRejected label = \case
  Left CommandRejected -> pure ()
  Left err -> assertFailure (label <> ": expected CommandRejected, got " <> show err)
  Right () -> assertFailure (label <> ": expected CommandRejected, but the command was accepted")

withApp :: Eff AppEffects a -> IO a
withApp action =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) \env -> do
      result <- runAppIO env action
      case result of
        Left storeErr -> assertFailure ("store error: " <> show storeErr)
        Right value -> pure value

startFixture ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  Eff es SessionId
startFixture = do
  sid <- liftIO genSessionId
  now <- liftIO getCurrentTime
  result <-
    Session.startWithContext
      testContext
      StartSessionData
        { sessionId = sid,
          memorySpaceId = testSpace,
          actorPrincipal = testActorPrincipal,
          ownerPrincipal = Nothing,
          agentId = "test-agent",
          focus = "session invariants",
          scope = testScope,
          subjectRef = Nothing,
          previousSessionId = Nothing,
          parentSessionId = Nothing,
          delegationDepth = 0,
          startedAt = now
        }
  void (liftEither "Session.startWithContext" result)
  pure sid

parkFixture ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  Maybe Text ->
  Eff es ()
parkFixture sid key = do
  now <- liftIO getCurrentTime
  result <-
    Session.awaitInputWithContext
      testContext
      AwaitInputData
        { sessionId = sid,
          memorySpaceId = testSpace,
          actorPrincipal = testActorPrincipal,
          reason = "approval",
          correlationKey = key,
          deadline = Nothing,
          awaitedAt = now
        }
  void (liftEither "Session.awaitInputWithContext" result)

resumeFixture ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  Maybe Text ->
  Text ->
  Eff es ()
resumeFixture sid key input = do
  now <- liftIO getCurrentTime
  result <-
    Session.resumeWithContext
      testContext
      ResumeSessionData
        { sessionId = sid,
          memorySpaceId = testSpace,
          actorPrincipal = testActorPrincipal,
          correlationKey = key,
          force = False,
          input,
          resumedAt = now
        }
  void (liftEither "Session.resumeWithContext" result)

getExisting ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  Eff es SessionRow
getExisting sid = do
  result <- Session.getById sid >>= liftEither "Session.getById"
  case result of
    Nothing -> liftIO (assertFailure ("missing session row " <> show (idText sid)))
    Just row -> pure row

readSessionEvents ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  Eff es [SessionEvent]
readSessionEvents sid = do
  recorded <- Vector.toList <$> readStreamForward (Stream.streamName (sessionStream sid)) (StreamVersion 0) 100
  traverse decodeRecorded recorded
  where
    decodeRecorded recorded =
      case parseSessionEvent recorded.payload of
        Left err -> liftIO (assertFailure ("parseSessionEvent: " <> show err))
        Right event -> pure event

liftEither :: (Show e, IOE :> es) => String -> Either e a -> Eff es a
liftEither label = \case
  Left err -> liftIO (assertFailure (label <> ": " <> show err))
  Right value -> pure value

eventName :: SessionEvent -> Text
eventName = \case
  SessionStarted {} -> "SessionStarted"
  SessionAwaiting {} -> "SessionAwaiting"
  SessionResumed {} -> "SessionResumed"
  SessionCompleted {} -> "SessionCompleted"
  SessionFailed {} -> "SessionFailed"
  InteractiveSessionRecorded {} -> "InteractiveSessionRecorded"
  TurnRecorded {} -> "TurnRecorded"

testScope :: MemoryScope
testScope = ScopeGlobal (Namespace "kioku-test")
