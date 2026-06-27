module Kioku.AwaitingSpec (tests) where

import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Stream qualified as Stream
import Kioku.Api.Scope (MemoryScope (..), Namespace (..))
import Kioku.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Kioku.Id (SessionId, genSessionId, idText)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Prelude
import Kioku.Session qualified as Session
import Kioku.Session.Domain
  ( AwaitInputData (..),
    CompleteSessionData (..),
    FailSessionData (..),
    ResumeSessionData (..),
    SessionEvent (..),
    StartSessionData (..),
  )
import Kioku.Session.EventStream (parseSessionEvent, sessionStream)
import Kioku.Session.ReadModel (SessionRow (..))
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Types (RecordedEvent (..), StreamVersion (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Awaiting park-and-resume"
    [ testCase "park then resume" testParkAndResume,
      testCase "find awaiting by correlation key" testFindAwaitingByCorrelationKey,
      testCase "reconstruct aggregate after crash" testReconstructAfterCrash,
      testCase "idempotent resume on re-delivery" testIdempotentResume,
      testCase "correlation mismatch is rejected" testCorrelationMismatchRejected,
      testCase "complete an awaiting session" testCompleteAwaitingSession,
      testCase "fail an awaiting session" testFailAwaitingSession
    ]

testParkAndResume :: Assertion
testParkAndResume =
  withAwaitingApp do
    sid <- startFixture
    parkFixture sid "approval_req_1"
    parked <- getExisting sid
    liftIO do
      assertEqual "parked status" "awaiting" parked.status
      assertEqual "awaiting reason" (Just "approval") parked.awaitingReason
      assertEqual "awaiting correlation key" (Just "approval_req_1") parked.awaitingCorrelationKey
    eventsAfterPark <- readSessionEvents sid
    liftIO $
      assertBool "tail event is SessionAwaiting" $
        case lastMay eventsAfterPark of
          Just SessionAwaiting {} -> True
          _ -> False
    resumeFixture sid (Just "approval_req_1") "approved"
    resumed <- getExisting sid
    liftIO do
      assertEqual "resumed status" "running" resumed.status
      assertEqual "resume input" (Just "approved") resumed.resumeInput
      assertEqual "awaiting reason cleared" Nothing resumed.awaitingReason
      assertEqual "awaiting key cleared" Nothing resumed.awaitingCorrelationKey
      assertEqual "awaiting deadline cleared" Nothing resumed.awaitingDeadline
    eventsAfterResume <- readSessionEvents sid
    liftIO $
      assertBool "SessionResumed was appended" $
        any isSessionResumed eventsAfterResume

testFindAwaitingByCorrelationKey :: Assertion
testFindAwaitingByCorrelationKey =
  withAwaitingApp do
    sid1 <- startFixture
    sid2 <- startFixture
    parkFixture sid1 "approval_req_1"
    parkFixture sid2 "approval_req_2"
    found <- Session.getAwaitingByCorrelationKey testNamespace "approval_req_1" >>= liftEither "getAwaitingByCorrelationKey"
    liftIO $
      assertEqual "only matching parked session is returned" [idText sid1] (map (.sessionId) found)

testReconstructAfterCrash :: Assertion
testReconstructAfterCrash =
  withAwaitingApp do
    sid <- startFixture
    parkFixture sid "approval_req_1"
    eventsAfterPark <- readSessionEvents sid
    liftIO $
      assertEqual "events end parked" ["SessionStarted", "SessionAwaiting"] (eventName <$> eventsAfterPark)
    resumeFixture sid (Just "approval_req_1") "approved"
    resumed <- getExisting sid
    liftIO $
      assertEqual "resume after log-backed park succeeds" "running" resumed.status

testIdempotentResume :: Assertion
testIdempotentResume =
  withAwaitingApp do
    sid <- startFixture
    parkFixture sid "approval_req_1"
    resumeFixture sid (Just "approval_req_1") "approved"
    resumeFixture sid (Just "approval_req_1") "approved"
    eventsAfterResume <- readSessionEvents sid
    liftIO $
      assertEqual "only one SessionResumed event is emitted" 1 (length (filter isSessionResumed eventsAfterResume))

testCorrelationMismatchRejected :: Assertion
testCorrelationMismatchRejected =
  withAwaitingApp do
    sid <- startFixture
    parkFixture sid "k1"
    now <- liftIO getCurrentTime
    result <-
      Session.resume
        ResumeSessionData
          { sessionId = sid,
            correlationKey = Just "k2",
            input = "approved",
            resumedAt = now
          }
    case result of
      Left Session.SessionCorrelationMismatch -> pure ()
      other -> liftIO (assertFailure ("expected SessionCorrelationMismatch, got " <> show other))
    eventsAfterRejectedResume <- readSessionEvents sid
    liftIO $
      assertBool "mismatched resume emits no SessionResumed event" $
        not (any isSessionResumed eventsAfterRejectedResume)

testCompleteAwaitingSession :: Assertion
testCompleteAwaitingSession =
  withAwaitingApp do
    sid <- startFixture
    parkFixture sid "approval_req_1"
    now <- liftIO getCurrentTime
    completeResult <-
      Session.complete
        CompleteSessionData
          { sessionId = sid,
            completedAt = now,
            modelUsed = Just "test-model",
            summary = Just "completed while parked"
          }
    void (liftEither "Session.complete" completeResult)
    completed <- getExisting sid
    events <- readSessionEvents sid
    liftIO do
      assertEqual "completed status" "completed" completed.status
      assertEqual "awaiting reason cleared" Nothing completed.awaitingReason
      assertEqual "awaiting key cleared" Nothing completed.awaitingCorrelationKey
      assertEqual "awaiting deadline cleared" Nothing completed.awaitingDeadline
      assertEqual "completed stream" ["SessionStarted", "SessionAwaiting", "SessionCompleted"] (eventName <$> events)

testFailAwaitingSession :: Assertion
testFailAwaitingSession =
  withAwaitingApp do
    sid <- startFixture
    parkFixture sid "approval_req_1"
    now <- liftIO getCurrentTime
    failResult <-
      Session.failSession
        FailSessionData
          { sessionId = sid,
            failedAt = now,
            errorMessage = "timed out"
          }
    void (liftEither "Session.failSession" failResult)
    failed <- getExisting sid
    events <- readSessionEvents sid
    liftIO do
      assertEqual "failed status" "failed" failed.status
      assertEqual "error message" (Just "timed out") failed.errorMessage
      assertEqual "awaiting reason cleared" Nothing failed.awaitingReason
      assertEqual "awaiting key cleared" Nothing failed.awaitingCorrelationKey
      assertEqual "awaiting deadline cleared" Nothing failed.awaitingDeadline
      assertEqual "failed stream" ["SessionStarted", "SessionAwaiting", "SessionFailed"] (eventName <$> events)

withAwaitingApp ::
  Eff AppEffects a ->
  IO a
withAwaitingApp action =
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
          focus = "awaiting lifecycle",
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
  Text ->
  Eff es ()
parkFixture sid key = do
  now <- liftIO getCurrentTime
  result <-
    Session.awaitInput
      AwaitInputData
        { sessionId = sid,
          reason = "approval",
          correlationKey = Just key,
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

isSessionResumed :: SessionEvent -> Bool
isSessionResumed = \case
  SessionResumed {} -> True
  _ -> False

eventName :: SessionEvent -> Text
eventName = \case
  SessionStarted {} -> "SessionStarted"
  SessionAwaiting {} -> "SessionAwaiting"
  SessionResumed {} -> "SessionResumed"
  SessionCompleted {} -> "SessionCompleted"
  SessionFailed {} -> "SessionFailed"
  InteractiveSessionRecorded {} -> "InteractiveSessionRecorded"
  TurnRecorded {} -> "TurnRecorded"

lastMay :: [a] -> Maybe a
lastMay [] = Nothing
lastMay xs = Just (last xs)

testNamespace :: Namespace
testNamespace = Namespace "kioku-test"

testScope :: MemoryScope
testScope = ScopeGlobal testNamespace
