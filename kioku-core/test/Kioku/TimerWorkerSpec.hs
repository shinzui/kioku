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
import Kioku.Api.Access
  ( MemoryAccessContext,
    MemoryAccessDenial (..),
    MemoryContextProvider (..),
    MemoryPermission (..),
    MemorySpaceId,
    legacyMemorySpaceId,
    memoryContextRecordedActor,
    memorySpaceIdText,
  )
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.App (AppEffects, AppEnv, runAppIO, withNoopAppEnv)
import Kioku.Distill.L1 (scopedScanCandidates)
import Kioku.Distill.L2 (SceneTimerPayload (..), l2SceneProcessManagerName, l2SceneTimerId)
import Kioku.Distill.L3 (partitionedCorrelationId)
import Kioku.Distill.Runtime (DistillRuntime (..), newDistillRuntime)
import Kioku.Distill.Timer (L1TimerPayload (..), l1ExtractProcessManagerName)
import Kioku.Distill.Timer.Worker (drainKiokuTimers, runKiokuTimerWorkerOnce)
import Kioku.Id (SessionId, genSessionId, idText)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Prelude
import Kioku.Session qualified as Session
import Kioku.Session.Domain (StartSessionData (..))
import Kioku.SpaceFixtures (legacyContext, otherContext, otherSpace, testContext, testContextProvider, testSpace)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Shibuya.Telemetry.Effect (Tracing)
import Shikumi.Error (ShikumiError (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Timer worker"
    [ testCase "permanent failure dead-letters the timer" testPermanentFailureDeadLetters,
      testCase "transient failure reschedules with backoff" testTransientFailureReschedules,
      testCase "a timer scheduled before memory spaces fires in the legacy space" testPrePartitionPayloadFiresInLegacySpace,
      testCase "a pre-partition timer cannot reach a session in another space" testPrePartitionPayloadCannotReachAnotherSpace,
      testCase "a malformed L1 payload dead-letters" testMalformedL1PayloadDeadLetters,
      testCase "unknown process manager requeues with a long delay" testUnknownProcessManagerRequeues,
      testCase "the attempt ceiling dead-letters" testAttemptCeilingDeadLetters,
      testCase "success marks the timer fired" testSuccessMarksFired,
      testCase "drain processes every due timer in one pass" testDrainProcessesAllDueTimers,
      testCase "two spaces sharing a scope schedule two timers, and both fire" testTwoSpacesTwoTimers,
      testCase "a refused memory space dead-letters" testRefusedSpaceDeadLetters,
      testCase "a provider returning the wrong memory space dead-letters" testWrongSpaceContextDeadLetters,
      testCase "every dead-letter row names the memory space" testDeadLetterNamesTheSpace
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
      scheduleTestTimer timerId l1ExtractProcessManagerName (idText sid) (l1Payload testSpace) (-1)
      fireOnce failing
      fetchTimer timerId
    row.status @?= "scheduled"
    -- keiro increments attempts at claim time, so one claim means attempts = 1,
    -- and the first backoff step is 30s.
    row.attempts @?= 1
    assertDelayNear "first retry" before 30 row.fireAt

-- | An L1 timer written before memory spaces existed has no @memorySpaceId@ in its payload.
--
-- It must still fire, in the legacy space, exactly like a stored event with no partition. The
-- proof is indirect but decisive: the pass runs (and here fails on the stubbed extractor, so the
-- timer is rescheduled) rather than dead-lettering, which is what an unreadable payload or a
-- refused space would do.
--
-- The session lives in the legacy space too, because that is the only arrangement a
-- pre-partition database can produce. The companion case below is what happens when it does
-- not.
testPrePartitionPayloadFiresInLegacySpace :: Assertion
testPrePartitionPayloadFiresInLegacySpace =
  withTimerEnv \env rt -> do
    timerId <- freshTimerId
    sid <- genSessionId
    let failing = rt {runExtract = \_ -> pure (Left (ProviderFailure "the model is down"))}
    row <- runOrFail env do
      startFixtureSessionIn legacyContext legacyMemorySpaceId sid
      scheduleTestTimer timerId l1ExtractProcessManagerName (idText sid) prePartitionL1Payload (-1)
      fireOnce failing
      fetchTimer timerId
    row.status @?= "scheduled"

-- | The same pre-partition timer, against a session that belongs to another space.
--
-- The pass looks the session up in the legacy space, does not find it, and treats it as a
-- session that is gone — which marks the timer fired. That is the right outcome and the
-- important one: a timer defaulted into the legacy space must never reach into a space that
-- was created after it.
testPrePartitionPayloadCannotReachAnotherSpace :: Assertion
testPrePartitionPayloadCannotReachAnotherSpace =
  withTimerEnv \env rt -> do
    timerId <- freshTimerId
    sid <- genSessionId
    let failing = rt {runExtract = \_ -> liftIO (assertFailure "the extractor must not run")}
    row <- runOrFail env do
      startFixtureSession sid
      scheduleTestTimer timerId l1ExtractProcessManagerName (idText sid) prePartitionL1Payload (-1)
      fireOnce failing
      fetchTimer timerId
    row.status @?= "fired"

-- | An L1 timer payload as it was written before memory spaces existed.
prePartitionL1Payload :: Aeson.Value
prePartitionL1Payload =
  Aeson.object ["kind" Aeson..= ("idle" :: Text), "turnCount" Aeson..= (1 :: Int)]

-- | A payload this handler cannot read will not become readable on the next attempt, so it
-- dead-letters where an operator can see it rather than retrying for an hour first.
testMalformedL1PayloadDeadLetters :: Assertion
testMalformedL1PayloadDeadLetters =
  withTimerEnv \env rt -> do
    timerId <- freshTimerId
    sid <- genSessionId
    row <- runOrFail env do
      startFixtureSession sid
      scheduleTestTimer timerId l1ExtractProcessManagerName (idText sid) Aeson.Null (-1)
      fireOnce rt
      fetchTimer timerId
    row.status @?= "dead"
    assertBool
      ("last_error names the payload, got: " <> show row.lastError)
      (maybe False (Text.isInfixOf "payload") row.lastError)

-- | An L1 timer payload as the projection writes one today.
l1Payload :: MemorySpaceId -> Aeson.Value
l1Payload space =
  Aeson.toJSON L1TimerPayload {kind = "idle", turnCount = Just 1, memorySpaceId = space}

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
      processed <- drainKiokuTimers Nothing testContextProvider rt (scopedScanCandidates 5)
      rows <- traverse fetchTimer timerIds
      pure (processed, rows)
    processed @?= 3
    fmap (.status) rows @?= ["dead", "dead", "dead"]

-- | Two L2 scene timers for the same namespace and scope, one per memory space.
--
-- The timer id is a UUIDv5 over the process manager, the correlation id, and a source id, and
-- the correlation id is @\<space\>:\<scope identity\>@. Without the space in there both spaces
-- derive one id, and keiro's scheduling upsert would treat the second schedule as a re-arming of
-- the first — one timer, one payload, one space's scene regenerated and the other's silently
-- dropped. Two distinct ids, two rows, and both fired is the whole invariant.
testTwoSpacesTwoTimers :: Assertion
testTwoSpacesTwoTimers =
  withTimerEnv \env rt -> do
    let mineTimer = l2SceneTimerId testSpace emptyScope "shared-source"
        theirsTimer = l2SceneTimerId otherSpace emptyScope "shared-source"
    assertBool "two spaces derived one scene timer id" (mineTimer /= theirsTimer)
    rows <- runOrFail env do
      scheduleTestTimer
        mineTimer
        l2SceneProcessManagerName
        (partitionedCorrelationId testSpace emptyScope)
        (sceneTimerPayload testSpace)
        (-1)
      scheduleTestTimer
        theirsTimer
        l2SceneProcessManagerName
        (partitionedCorrelationId otherSpace emptyScope)
        (sceneTimerPayload otherSpace)
        (-1)
      void (drainKiokuTimers Nothing testContextProvider rt (scopedScanCandidates 5))
      traverse fetchTimer [mineTimer, theirsTimer]
    fmap (.status) rows @?= ["fired", "fired"]

-- | A worker that may not act in a space must say so where an operator can see it.
--
-- Dead-letter rather than retry, for the same reason the embedding worker does: a refusal is a
-- configuration fact, and retrying it every thirty seconds for an hour before giving up would
-- spend an hour hiding it.
testRefusedSpaceDeadLetters :: Assertion
testRefusedSpaceDeadLetters =
  withTimerEnv \env rt -> do
    timerId <- freshTimerId
    row <- runOrFail env do
      scheduleTestTimer
        timerId
        l2SceneProcessManagerName
        (partitionedCorrelationId testSpace emptyScope)
        (sceneTimerPayload testSpace)
        (-1)
      fireOnceWith refusingContextProvider rt
      fetchTimer timerId
    row.status @?= "dead"
    assertBool
      ("last_error should name the refusal, got: " <> show row.lastError)
      (maybe False (Text.isInfixOf "not authorized") row.lastError)

-- | A buggy host provider may answer a request for one space with a context minted for another.
-- The worker must diagnose that configuration error rather than silently retargeting the timer.
testWrongSpaceContextDeadLetters :: Assertion
testWrongSpaceContextDeadLetters =
  withTimerEnv \env rt -> do
    timerId <- freshTimerId
    row <- runOrFail env do
      scheduleTestTimer
        timerId
        l2SceneProcessManagerName
        (partitionedCorrelationId testSpace emptyScope)
        (sceneTimerPayload testSpace)
        (-1)
      fireOnceWith wrongSpaceContextProvider rt
      fetchTimer timerId
    row.status @?= "dead"
    assertBool
      ("last_error should name the wrong-space context, got: " <> show row.lastError)
      ( maybe
          False
          (\err -> memorySpaceIdText testSpace `Text.isInfixOf` err && memorySpaceIdText otherSpace `Text.isInfixOf` err)
          row.lastError
      )

-- | @last_error@ is the column an operator reads when a distillation stops happening, and a
-- dead-lettered timer that does not say which tenant it belongs to is a question, not an answer.
testDeadLetterNamesTheSpace :: Assertion
testDeadLetterNamesTheSpace =
  withTimerEnv \env rt -> do
    timerId <- freshTimerId
    sid <- genSessionId
    row <- runOrFail env do
      startFixtureSession sid
      -- A correlation id that is not a session id: a permanent failure whose own message has no
      -- reason to mention a space, so what shows up can only have come from the annotation.
      scheduleTestTimer timerId l1ExtractProcessManagerName "not-a-session-id" (l1Payload testSpace) (-1)
      fireOnce rt
      fetchTimer timerId
    row.status @?= "dead"
    assertBool
      ("last_error should name the memory space, got: " <> show row.lastError)
      (maybe False (Text.isInfixOf (memorySpaceIdText testSpace)) row.lastError)

-- | An L2 scene timer payload as the projection writes one.
sceneTimerPayload :: MemorySpaceId -> Aeson.Value
sceneTimerPayload space =
  Aeson.toJSON SceneTimerPayload {memorySpaceId = space, scope = emptyScope}

-- | A provider that refuses every space, as a host with a real authorization engine would when
-- this worker is not allowed to touch this tenant.
refusingContextProvider :: (Applicative m) => MemoryContextProvider m
refusingContextProvider =
  MemoryContextProvider \space -> pure (Left (MemoryPermissionDenied space MemoryDistill))

wrongSpaceContextProvider :: (Applicative m) => MemoryContextProvider m
wrongSpaceContextProvider =
  MemoryContextProvider \_ -> pure (Right otherContext)

fireOnce ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es, Tracing :> es) =>
  DistillRuntime ->
  Eff es ()
fireOnce = fireOnceWith testContextProvider

fireOnceWith ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es, Tracing :> es) =>
  MemoryContextProvider (Eff es) ->
  DistillRuntime ->
  Eff es ()
fireOnceWith provider rt = do
  now <- liftIO getCurrentTime
  void (runKiokuTimerWorkerOnce Nothing provider rt (scopedScanCandidates 5) now)

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
startFixtureSession = startFixtureSessionIn testContext testSpace

-- | Start a fixture session in a named space. The pre-partition case needs the legacy one:
-- in a genuinely pre-partition database the timer and its session are both there, and a
-- fixture that put them in different spaces would be testing nothing that can happen.
startFixtureSessionIn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  MemorySpaceId ->
  SessionId ->
  Eff es ()
startFixtureSessionIn context space sid = do
  now <- liftIO getCurrentTime
  started <-
    Session.startWithContext
      context
      StartSessionData
        { sessionId = sid,
          memorySpaceId = space,
          actorPrincipal = memoryContextRecordedActor context,
          ownerPrincipal = Nothing,
          agentId = "test-agent",
          focus = "timer worker spec",
          scope = emptyScope,
          subjectRef = Nothing,
          previousSessionId = Nothing,
          parentSessionId = Nothing,
          delegationDepth = 0,
          startedAt = now
        }
  void (liftIO (expectRight "Session.startWithContext" started))

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
