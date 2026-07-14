{-# LANGUAGE DataKinds #-}

module Kioku.TimerWorkerSpec
  ( tests,
  )
where

import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, addUTCTime, diffUTCTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUIDv4
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Timer (TimerId (..), TimerRequest (..), scheduleTimerTx)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.App (AppEffects, AppEnv, runAppIO, withNoopAppEnv)
import Kioku.Distill.L1 (scopedScanCandidates)
import Kioku.Distill.L2 (l2SceneProcessManagerName)
import Kioku.Distill.Runtime (DistillRuntime (..), newDistillRuntime)
import Kioku.Distill.Timer (l1ExtractProcessManagerName)
import Kioku.Distill.Timer.Worker (drainKiokuTimers, runKiokuTimerWorkerOnce)
import Kioku.Id (SessionId, genSessionId, idText)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Prelude
import Kioku.Session qualified as Session
import Kioku.Session.Domain (StartSessionData (..))
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Shikumi.Error (ShikumiError (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Timer worker"
    [ testCase "permanent failure dead-letters the timer" testPermanentFailureDeadLetters,
      testCase "transient failure reschedules with backoff" testTransientFailureReschedules,
      testCase "unknown process manager requeues with a long delay" testUnknownProcessManagerRequeues,
      testCase "the attempt ceiling dead-letters" testAttemptCeilingDeadLetters,
      testCase "success marks the timer fired" testSuccessMarksFired,
      testCase "drain processes every due timer in one pass" testDrainProcessesAllDueTimers
    ]

-- | A correlation id that is not a session id can never become one. It used to
-- be marked fired — a fake success that lost the distillation silently.
testPermanentFailureDeadLetters :: Assertion
testPermanentFailureDeadLetters =
  withTimerEnv \env rt -> do
    timerId <- freshTimerId
    row <- runOrFail env do
      scheduleTestTimer timerId l1ExtractProcessManagerName "not-a-session-id" Aeson.Null (-1)
      fireOnce rt
      fetchTimer timerId
    row.status @?= "dead"
    assertBool
      ("last_error names the correlation id, got: " <> show row.lastError)
      (maybe False (Text.isInfixOf "correlation id") row.lastError)

-- | A failing LLM extraction is worth retrying — but on a schedule, and only
-- until the ceiling. The timer must land back in @scheduled@ with @fire_at@
-- pushed out, not sit in @firing@ waiting on keiro's 300-second stale requeue.
testTransientFailureReschedules :: Assertion
testTransientFailureReschedules =
  withTimerEnv \env rt -> do
    timerId <- freshTimerId
    sid <- genSessionId
    let failing = rt {runExtract = \_ -> pure (Left (ProviderFailure "the model is down"))}
    before <- getCurrentTime
    row <- runOrFail env do
      startFixtureSession sid
      scheduleTestTimer timerId l1ExtractProcessManagerName (idText sid) Aeson.Null (-1)
      fireOnce failing
      fetchTimer timerId
    row.status @?= "scheduled"
    -- keiro increments attempts at claim time, so one claim means attempts = 1,
    -- and the first backoff step is 30s.
    row.attempts @?= 1
    assertDelayNear "first retry" before 30 row.fireAt

-- | keiro's claimDueTimer claims the earliest due timer regardless of process
-- manager, so a timer no handler owns cannot be left alone — it must be put
-- back, or it starves every other timer behind it forever.
testUnknownProcessManagerRequeues :: Assertion
testUnknownProcessManagerRequeues =
  withTimerEnv \env rt -> do
    timerId <- freshTimerId
    before <- getCurrentTime
    row <- runOrFail env do
      scheduleTestTimer timerId "kioku-nonexistent" "whatever" Aeson.Null (-1)
      fireOnce rt
      fetchTimer timerId
    row.status @?= "scheduled"
    row.attempts @?= 1
    assertDelayNear "unknown-PM requeue" before 600 row.fireAt

-- | The requeue above is bounded: an orphaned timer eventually dies visibly
-- instead of cycling forever. keiro applies the ceiling at claim time.
testAttemptCeilingDeadLetters :: Assertion
testAttemptCeilingDeadLetters =
  withTimerEnv \env rt -> do
    timerId <- freshTimerId
    row <- runOrFail env do
      scheduleTestTimer timerId "kioku-nonexistent" "whatever" Aeson.Null (-1)
      forceAttempts timerId 8
      fireOnce rt
      fetchTimer timerId
    row.status @?= "dead"
    assertBool
      ("last_error mentions the ceiling, got: " <> show row.lastError)
      (maybe False (Text.isInfixOf "attempt ceiling") row.lastError)

-- | The happy path: an L2 timer for a scope with no memories regenerates
-- nothing, succeeds without calling the LLM, and is marked fired with the timer's
-- own id as the marker event id.
testSuccessMarksFired :: Assertion
testSuccessMarksFired =
  withTimerEnv \env rt -> do
    timerId@(TimerId timerUuid) <- freshTimerId
    row <- runOrFail env do
      scheduleTestTimer
        timerId
        l2SceneProcessManagerName
        "rei/intention/empty"
        (Aeson.object ["scope" Aeson..= emptyScope])
        (-1)
      fireOnce rt
      fetchTimer timerId
    row.status @?= "fired"
    row.firedEventId @?= Just (UUID.toText timerUuid)

-- | The old loop slept between every timer, so N due timers took N poll
-- intervals. Draining processes them all in one pass.
testDrainProcessesAllDueTimers :: Assertion
testDrainProcessesAllDueTimers =
  withTimerEnv \env rt -> do
    timerIds <- traverse (const freshTimerId) [1 :: Int, 2, 3]
    (processed, rows) <- runOrFail env do
      forM_ timerIds \timerId ->
        scheduleTestTimer timerId l1ExtractProcessManagerName "not-a-session-id" Aeson.Null (-1)
      processed <- drainKiokuTimers Nothing rt (scopedScanCandidates 5)
      rows <- traverse fetchTimer timerIds
      pure (processed, rows)
    processed @?= 3
    fmap (.status) rows @?= ["dead", "dead", "dead"]

fireOnce ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  DistillRuntime ->
  Eff es ()
fireOnce rt = do
  now <- liftIO getCurrentTime
  void (runKiokuTimerWorkerOnce Nothing rt (scopedScanCandidates 5) now)

-- | Schedule a timer @offset@ seconds from now (negative means already due).
scheduleTestTimer ::
  (IOE :> es, Store :> es) =>
  TimerId ->
  Text ->
  Text ->
  Aeson.Value ->
  NominalDiffTime ->
  Eff es ()
scheduleTestTimer timerId processManagerName correlationId payload offset = do
  now <- liftIO getCurrentTime
  runTransaction $
    scheduleTimerTx
      TimerRequest
        { timerId,
          processManagerName,
          correlationId,
          fireAt = addUTCTime offset now,
          payload
        }

startFixtureSession ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  Eff es ()
startFixtureSession sid = do
  now <- liftIO getCurrentTime
  started <-
    Session.start
      StartSessionData
        { sessionId = sid,
          agentId = "test-agent",
          focus = "timer worker spec",
          scope = emptyScope,
          subjectRef = Nothing,
          previousSessionId = Nothing,
          parentSessionId = Nothing,
          delegationDepth = 0,
          startedAt = now
        }
  void (liftIO (expectRight "Session.start" started))

-- | Drive the row to the brink of the ceiling so the next claim trips it.
forceAttempts :: (Store :> es) => TimerId -> Int -> Eff es ()
forceAttempts (TimerId uuid) attempts =
  runTransaction (Tx.statement (uuid, fromIntegral @Int @Int64 attempts) forceAttemptsStmt)

forceAttemptsStmt :: Statement (UUID.UUID, Int64) ()
forceAttemptsStmt =
  preparable
    """
    UPDATE keiro.keiro_timers
    SET attempts = $2,
        fire_at = now() - interval '1 second'
    WHERE timer_id = $1
    """
    ( ((\(u, _) -> u) >$< E.param (E.nonNullable E.uuid))
        <> ((\(_, a) -> a) >$< E.param (E.nonNullable E.int8))
    )
    D.noResult

data TimerStateRow = TimerStateRow
  { status :: !Text,
    attempts :: !Int,
    fireAt :: !UTCTime,
    lastError :: !(Maybe Text),
    firedEventId :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

fetchTimer :: (Store :> es) => TimerId -> Eff es TimerStateRow
fetchTimer (TimerId uuid) =
  runTransaction (Tx.statement uuid selectTimerStateStmt)

selectTimerStateStmt :: Statement UUID.UUID TimerStateRow
selectTimerStateStmt =
  preparable
    """
    SELECT status, attempts, fire_at, last_error, fired_event_id::text
    FROM keiro.keiro_timers
    WHERE timer_id = $1
    """
    (E.param (E.nonNullable E.uuid))
    (D.singleRow timerStateDecoder)

timerStateDecoder :: D.Row TimerStateRow
timerStateDecoder =
  TimerStateRow
    <$> D.column (D.nonNullable D.text)
    <*> (fromIntegral @Int64 @Int <$> D.column (D.nonNullable D.int8))
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)

-- | The delay is measured against a clock read taken before the pass, so the
-- window has to absorb the pass's own duration. A generous window still
-- distinguishes 30s from 600s, which is the distinction under test.
assertDelayNear :: String -> UTCTime -> NominalDiffTime -> UTCTime -> Assertion
assertDelayNear label before expected actual =
  assertBool
    ( label
        <> ": expected fire_at about "
        <> show expected
        <> "s out, but it was "
        <> show delay
        <> "s out"
    )
    (delay >= expected - 5 && delay <= expected + 15)
  where
    delay = actual `diffUTCTime` before

emptyScope :: MemoryScope
emptyScope =
  ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_timer_worker_spec"

freshTimerId :: IO TimerId
freshTimerId = TimerId <$> UUIDv4.nextRandom

withTimerEnv :: (AppEnv -> DistillRuntime -> IO ()) -> Assertion
withTimerEnv action =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) \env -> do
      rt <- newDistillRuntime
      action env rt

runOrFail :: AppEnv -> Eff AppEffects a -> IO a
runOrFail env action = runAppIO env action >>= expectRight "runAppIO"

expectRight :: (Show e) => String -> Either e a -> IO a
expectRight label = \case
  Left err -> assertFailure (label <> " failed: " <> show err)
  Right value -> pure value
