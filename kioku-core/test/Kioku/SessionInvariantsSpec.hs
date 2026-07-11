-- | Invariants the session aggregate enforces itself, independent of any read-model
-- precheck. Every test here that matters drives 'runCommandWithProjections' directly, so a
-- passing assertion proves the state machine rejected (or accepted) the command — not that
-- a precheck happened to run first.
module Kioku.SessionInvariantsSpec (tests) where

import Control.Monad (void)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import Keiro.Command (CommandError (..), defaultRunCommandOptions)
import Keiro.Projection (runCommandWithProjections)
import Keiro.Stream qualified as Stream
import Kioku.Api.Scope (MemoryScope (..), Namespace (..))
import Kioku.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Kioku.Distill.Timer (l1TimerScheduleProjection)
import Kioku.Id (SessionId, genSessionId, idText)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Session qualified as Session
import Kioku.Session.Domain
  ( AwaitInputData (..),
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
import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (Store)
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
      testCase "pre-force keyed resume events still hydrate" testHydratesLegacyKeyedResume
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
              correlationKey = Just "k1",
              force = False,
              input = "stale answer",
              resumedAt = now
            }
    -- Through the public API the precheck catches it early ...
    apiResult <- Session.resume staleResume
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
    result <- Session.forceResume sid "forced answer" now
    void (liftEither "Session.forceResume" result)
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
-- The command runs through 'runCommandWithProjections' rather than 'Session.awaitInput'
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
              { sessionId = sid,
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
              { sessionId = sid,
                reason = "approval",
                correlationKey = Just "k1",
                deadline = Nothing,
                awaitedAt = now
              }
    void $
      appendToStream
        (Stream.streamName (sessionStream sid))
        NoStream
        [ rawEvent "SessionStarted" (toJSON started),
          rawEvent "SessionAwaiting" (toJSON awaiting),
          rawEvent "SessionResumed" (legacyResumedPayload sid resumedKey now)
        ]
    -- The stream now ends in Running. A fresh AwaitInput must hydrate it and be accepted.
    result <-
      runSessionCommandDirect
        sid
        ( AwaitInput
            AwaitInputData
              { sessionId = sid,
                reason = "approval",
                correlationKey = Just "k2",
                deadline = Nothing,
                awaitedAt = now
              }
        )
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
  (IOE :> es, Store :> es, Error StoreError :> es) =>
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
    withStore (defaultConnectionSettings connStr) \st -> do
      tracer <- noopTracer
      let env = AppEnv {store = st, tracer, metrics = Nothing}
      result <- runAppIO env action
      case result of
        Left storeErr -> assertFailure ("store error: " <> show storeErr)
        Right value -> pure value

startFixture ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  Eff es SessionId
startFixture = do
  sid <- liftIO genSessionId
  now <- liftIO getCurrentTime
  result <-
    Session.start
      StartSessionData
        { sessionId = sid,
          agentId = "test-agent",
          focus = "session invariants",
          scope = testScope,
          subjectRef = Nothing,
          previousSessionId = Nothing,
          parentSessionId = Nothing,
          delegationDepth = 0,
          startedAt = now
        }
  void (liftEither "Session.start" result)
  pure sid

parkFixture ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  Maybe Text ->
  Eff es ()
parkFixture sid key = do
  now <- liftIO getCurrentTime
  result <-
    Session.awaitInput
      AwaitInputData
        { sessionId = sid,
          reason = "approval",
          correlationKey = key,
          deadline = Nothing,
          awaitedAt = now
        }
  void (liftEither "Session.awaitInput" result)

resumeFixture ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  Maybe Text ->
  Text ->
  Eff es ()
resumeFixture sid key input = do
  now <- liftIO getCurrentTime
  result <-
    Session.resume
      ResumeSessionData
        { sessionId = sid,
          correlationKey = key,
          force = False,
          input,
          resumedAt = now
        }
  void (liftEither "Session.resume" result)

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
