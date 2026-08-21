-- | The idempotent-accept contract for session and memory writes.
--
-- Every case here asserts two things: the right value came back, /and/ the event stream
-- gained no extra event. A write that returns @Right@ but quietly appended a second event
-- is not idempotent, and a write that returns a conflict but appended anyway has already
-- done the damage.
module Kioku.IdempotencySpec (tests) where

import Control.Monad (void)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import Keiro.Stream qualified as Stream
import Kioku.Api.Scope (MemoryScope (..), Namespace (..))
import Kioku.Api.Types (Confidence (..), MemoryType (..))
import Kioku.App (AppEffects, runAppIO, withNoopAppEnv)
import Kioku.Id (MemoryId, SessionId, genMemoryId, genSessionId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (ArchiveMemoryData (..), RecordMemoryData (..), SupersedeMemoryData (..))
import Kioku.Memory.EventStream (memoryStream)
import Kioku.Memory.ReadModel (MemoryRow (..))
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Session qualified as Session
import Kioku.Session.Domain
  ( AwaitInputData (..),
    CompleteSessionData (..),
    FailSessionData (..),
    ResumeSessionData (..),
    StartSessionData (..),
  )
import Kioku.Session.EventStream (sessionStream)
import Kioku.SpaceFixtures (testActorPrincipal, testContext, testSpace)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Types (StreamVersion (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Idempotent accepts"
    [ testGroup
        "sessions"
        [ testCase "an identical start is a duplicate" testStartDuplicate,
          testCase "a start with a different focus is a conflict" testStartConflict,
          testCase "an identical awaitInput is a duplicate" testAwaitDuplicate,
          testCase "an awaitInput with a different reason is a conflict" testAwaitConflict,
          testCase "an identical resume is a duplicate" testResumeDuplicate,
          testCase "a resume with different input is a conflict" testResumeConflict,
          testCase "an identical complete is a duplicate" testCompleteDuplicate,
          testCase "completing a failed session is a conflict" testCompleteAfterFail,
          testCase "failing a completed session is a conflict" testFailAfterComplete
        ],
      testGroup
        "memories"
        [ testCase "an identical record is a duplicate" testRecordDuplicate,
          testCase "a record retried with a fresh clock is a duplicate" testRecordRetriedWithNewClock,
          testCase "a record can supersede a same-space target" testRecordLineageTarget,
          testCase "a record with different content is a conflict" testRecordConflict,
          testCase "an identical supersede remains a duplicate after its winner retires" testSupersedeDuplicate,
          testCase "superseding by a different winner is a conflict" testSupersedeConflict,
          testCase "archiving a superseded memory is a conflict" testArchiveAfterSupersede,
          testCase "an identical merge remains a duplicate after its winner retires" testMergeDuplicate,
          testCase "merging into a different winner is a conflict" testMergeConflict
        ]
    ]

-- * Sessions

testStartDuplicate :: Assertion
testStartDuplicate =
  withApp do
    sid <- liftIO genSessionId
    now <- liftIO getCurrentTime
    let cmd = startData sid now
    void (expectRight "first start" =<< Session.startWithContext testContext cmd)
    void (expectRight "duplicate start" =<< Session.startWithContext testContext cmd)
    assertSessionEvents sid 1

testStartConflict :: Assertion
testStartConflict =
  withApp do
    sid <- liftIO genSessionId
    now <- liftIO getCurrentTime
    let cmd = startData sid now
    void (expectRight "first start" =<< Session.startWithContext testContext cmd)
    expectConflict "start with a different focus"
      =<< Session.startWithContext testContext cmd {focus = "a different focus"}
    assertSessionEvents sid 1

testAwaitDuplicate :: Assertion
testAwaitDuplicate =
  withApp do
    sid <- startedSession
    now <- liftIO getCurrentTime
    let cmd = awaitData sid now
    void (expectRight "first awaitInput" =<< Session.awaitInputWithContext testContext cmd)
    void (expectRight "duplicate awaitInput" =<< Session.awaitInputWithContext testContext cmd)
    assertSessionEvents sid 2

testAwaitConflict :: Assertion
testAwaitConflict =
  withApp do
    sid <- startedSession
    now <- liftIO getCurrentTime
    let cmd = awaitData sid now
    void (expectRight "first awaitInput" =<< Session.awaitInputWithContext testContext cmd)
    expectConflict "awaitInput with a different reason"
      =<< Session.awaitInputWithContext testContext cmd {reason = "a different reason"}
    assertSessionEvents sid 2

testResumeDuplicate :: Assertion
testResumeDuplicate =
  withApp do
    sid <- startedSession
    now <- liftIO getCurrentTime
    void (expectRight "awaitInput" =<< Session.awaitInputWithContext testContext (awaitData sid now))
    let cmd = resumeData sid now "approved"
    void (expectRight "first resume" =<< Session.resumeWithContext testContext cmd)
    void (expectRight "duplicate resume" =<< Session.resumeWithContext testContext cmd)
    assertSessionEvents sid 3

testResumeConflict :: Assertion
testResumeConflict =
  withApp do
    sid <- startedSession
    now <- liftIO getCurrentTime
    void (expectRight "awaitInput" =<< Session.awaitInputWithContext testContext (awaitData sid now))
    void (expectRight "first resume" =<< Session.resumeWithContext testContext (resumeData sid now "approved"))
    -- The session is running again; a re-delivery carrying a *different* answer is not this
    -- request's own echo.
    expectConflict "resume with different input"
      =<< Session.resumeWithContext testContext (resumeData sid now "rejected")
    assertSessionEvents sid 3

testCompleteDuplicate :: Assertion
testCompleteDuplicate =
  withApp do
    sid <- startedSession
    now <- liftIO getCurrentTime
    let cmd = completeData sid now
    void (expectRight "first complete" =<< Session.completeWithContext testContext cmd)
    void (expectRight "duplicate complete" =<< Session.completeWithContext testContext cmd)
    assertSessionEvents sid 2

-- | The headline regression: this used to return @Right@ and report success for a session
-- that had actually failed.
testCompleteAfterFail :: Assertion
testCompleteAfterFail =
  withApp do
    sid <- startedSession
    now <- liftIO getCurrentTime
    void (expectRight "failSession" =<< Session.failSessionWithContext testContext (failData sid now))
    expectConflict "complete after fail" =<< Session.completeWithContext testContext (completeData sid now)
    assertSessionEvents sid 2

testFailAfterComplete :: Assertion
testFailAfterComplete =
  withApp do
    sid <- startedSession
    now <- liftIO getCurrentTime
    void (expectRight "complete" =<< Session.completeWithContext testContext (completeData sid now))
    expectConflict "fail after complete" =<< Session.failSessionWithContext testContext (failData sid now)
    assertSessionEvents sid 2

-- * Memories

testRecordDuplicate :: Assertion
testRecordDuplicate =
  withApp do
    mid <- liftIO genMemoryId
    now <- liftIO getCurrentTime
    let cmd = recordData mid now "the original content"
    void (expectRightM "first record" =<< Memory.recordWithContext testContext cmd)
    void (expectRightM "duplicate record" =<< Memory.recordWithContext testContext cmd)
    assertMemoryEvents mid 1

-- | @recordedAt@ must not participate in conflict detection. Distillation depends on this:
-- 'Kioku.Distill.L1.recordAtom' derives a deterministic memory id but stamps
-- @recordedAt = now@, so a timer re-fire re-records the same atom with a later clock. If
-- that were a conflict, every re-fire of an L1 pass would hard-fail — which is exactly what
-- happened when this contract was first written the other way.
testRecordRetriedWithNewClock :: Assertion
testRecordRetriedWithNewClock =
  withApp do
    mid <- liftIO genMemoryId
    firstAt <- liftIO getCurrentTime
    let content = "identical content, later clock"
    void (expectRightM "first record" =<< Memory.recordWithContext testContext (recordData mid firstAt content))
    laterAt <- liftIO getCurrentTime
    void (expectRightM "retry with a fresh clock" =<< Memory.recordWithContext testContext (recordData mid laterAt content))
    assertMemoryEvents mid 1
    lookedUp <- Memory.getMemoryRowById testSpace mid
    liftIO case lookedUp of
      Left err -> assertFailure ("lookup: " <> show err)
      Right Nothing -> assertFailure "the memory row vanished"
      Right (Just r) -> assertEqual "the first write's createdAt is kept" firstAt r.createdAt

testRecordConflict :: Assertion
testRecordConflict =
  withApp do
    mid <- liftIO genMemoryId
    now <- liftIO getCurrentTime
    void (expectRightM "first record" =<< Memory.recordWithContext testContext (recordData mid now "the original content"))
    expectConflictM "record with different content"
      =<< Memory.recordWithContext testContext (recordData mid now "something else entirely")
    assertMemoryEvents mid 1

testRecordLineageTarget :: Assertion
testRecordLineageTarget =
  withApp do
    target <- recordedMemory "record lineage target"
    source <- liftIO genMemoryId
    now <- liftIO getCurrentTime
    void $
      expectRightM "record with supersedes"
        =<< Memory.recordWithContext
          testContext
          (recordData source now "record lineage source") {supersedes = Just target}
    row <- getMemoryRow source
    liftIO $ assertEqual "the record projection keeps its target" (Just (idText target)) row.supersedes
    assertMemoryEvents source 1

testSupersedeDuplicate :: Assertion
testSupersedeDuplicate =
  withApp do
    loser <- recordedMemory "loser"
    winner <- recordedMemory "winner"
    now <- liftIO getCurrentTime
    let cmd = SupersedeMemoryData {memorySpaceId = testSpace, actorPrincipal = testActorPrincipal, memoryId = loser, supersededBy = winner, supersededAt = now}
    void (expectRightM "first supersede" =<< Memory.supersedeWithContext testContext cmd)
    void $
      expectRightM "retire the winner"
        =<< Memory.archiveWithContext testContext ArchiveMemoryData {memorySpaceId = testSpace, actorPrincipal = testActorPrincipal, memoryId = winner, archivedAt = now}
    void (expectRightM "duplicate supersede after winner retirement" =<< Memory.supersedeWithContext testContext cmd)
    row <- getMemoryRow loser
    liftIO $ assertEqual "the supersede projection keeps its winner" (Just (idText winner)) row.supersededBy
    assertMemoryEvents loser 2

-- | The other headline regression: supersede by X, then by Y, used to report success for Y
-- while X remained the recorded winner.
testSupersedeConflict :: Assertion
testSupersedeConflict =
  withApp do
    loser <- recordedMemory "loser"
    winnerX <- recordedMemory "winner x"
    winnerY <- recordedMemory "winner y"
    now <- liftIO getCurrentTime
    void $
      expectRightM "supersede by X"
        =<< Memory.supersedeWithContext testContext SupersedeMemoryData {memorySpaceId = testSpace, actorPrincipal = testActorPrincipal, memoryId = loser, supersededBy = winnerX, supersededAt = now}
    expectConflictM "supersede by Y after X"
      =<< Memory.supersedeWithContext testContext SupersedeMemoryData {memorySpaceId = testSpace, actorPrincipal = testActorPrincipal, memoryId = loser, supersededBy = winnerY, supersededAt = now}
    assertMemoryEvents loser 2

testArchiveAfterSupersede :: Assertion
testArchiveAfterSupersede =
  withApp do
    loser <- recordedMemory "loser"
    winner <- recordedMemory "winner"
    now <- liftIO getCurrentTime
    void $
      expectRightM "supersede"
        =<< Memory.supersedeWithContext testContext SupersedeMemoryData {memorySpaceId = testSpace, actorPrincipal = testActorPrincipal, memoryId = loser, supersededBy = winner, supersededAt = now}
    expectConflictM "archive after supersede"
      =<< Memory.archiveWithContext testContext ArchiveMemoryData {memorySpaceId = testSpace, actorPrincipal = testActorPrincipal, memoryId = loser, archivedAt = now}
    assertMemoryEvents loser 2

testMergeDuplicate :: Assertion
testMergeDuplicate =
  withApp do
    loser <- recordedMemory "loser"
    winner <- recordedMemory "winner"
    void (expectRightM "first merge" =<< Memory.mergeWithContext testContext loser winner)
    now <- liftIO getCurrentTime
    void $
      expectRightM "retire the winner"
        =<< Memory.archiveWithContext testContext ArchiveMemoryData {memorySpaceId = testSpace, actorPrincipal = testActorPrincipal, memoryId = winner, archivedAt = now}
    void (expectRightM "duplicate merge after winner retirement" =<< Memory.mergeWithContext testContext loser winner)
    row <- getMemoryRow loser
    liftIO $ assertEqual "the merge projection keeps its winner" (Just (idText winner)) row.supersededBy
    assertMemoryEvents loser 2

testMergeConflict :: Assertion
testMergeConflict =
  withApp do
    loser <- recordedMemory "loser"
    winnerX <- recordedMemory "winner x"
    winnerY <- recordedMemory "winner y"
    void (expectRightM "merge into X" =<< Memory.mergeWithContext testContext loser winnerX)
    expectConflictM "merge into Y after X" =<< Memory.mergeWithContext testContext loser winnerY
    assertMemoryEvents loser 2

-- * Fixtures

startData :: SessionId -> UTCTime -> StartSessionData
startData sid startedAt =
  StartSessionData
    { sessionId = sid,
      memorySpaceId = testSpace,
      actorPrincipal = testActorPrincipal,
      ownerPrincipal = Nothing,
      agentId = "test-agent",
      focus = "idempotency",
      scope = testScope,
      subjectRef = Nothing,
      previousSessionId = Nothing,
      parentSessionId = Nothing,
      delegationDepth = 0,
      startedAt
    }

awaitData :: SessionId -> UTCTime -> AwaitInputData
awaitData sid awaitedAt =
  AwaitInputData
    { sessionId = sid,
      memorySpaceId = testSpace,
      actorPrincipal = testActorPrincipal,
      reason = "approval",
      correlationKey = Just "k1",
      deadline = Nothing,
      awaitedAt
    }

resumeData :: SessionId -> UTCTime -> Text -> ResumeSessionData
resumeData sid resumedAt input =
  ResumeSessionData
    { sessionId = sid,
      memorySpaceId = testSpace,
      actorPrincipal = testActorPrincipal,
      correlationKey = Just "k1",
      force = False,
      input,
      resumedAt
    }

completeData :: SessionId -> UTCTime -> CompleteSessionData
completeData sid completedAt =
  CompleteSessionData
    { sessionId = sid,
      memorySpaceId = testSpace,
      actorPrincipal = testActorPrincipal,
      completedAt,
      modelUsed = Just "test-model",
      summary = Just "done"
    }

failData :: SessionId -> UTCTime -> FailSessionData
failData sid failedAt =
  FailSessionData
    { sessionId = sid,
      memorySpaceId = testSpace,
      actorPrincipal = testActorPrincipal,
      failedAt,
      errorMessage = "boom"
    }

recordData :: MemoryId -> UTCTime -> Text -> RecordMemoryData
recordData mid recordedAt content =
  RecordMemoryData
    { memoryId = mid,
      memorySpaceId = testSpace,
      actorPrincipal = testActorPrincipal,
      ownerPrincipal = Nothing,
      agentId = "test-agent",
      sessionId = Nothing,
      scope = testScope,
      memoryType = MemoryFact,
      content,
      priority = 50,
      confidence = HighConfidence,
      tags = Set.fromList ["t"],
      supersedes = Nothing,
      recordedAt
    }

startedSession ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  Eff es SessionId
startedSession = do
  sid <- liftIO genSessionId
  now <- liftIO getCurrentTime
  void (expectRight "Session.startWithContext" =<< Session.startWithContext testContext (startData sid now))
  pure sid

recordedMemory ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  Text ->
  Eff es MemoryId
recordedMemory content = do
  mid <- liftIO genMemoryId
  now <- liftIO getCurrentTime
  void (expectRightM "Memory.recordWithContext" =<< Memory.recordWithContext testContext (recordData mid now content))
  pure mid

getMemoryRow ::
  (IOE :> es, Store :> es) =>
  MemoryId ->
  Eff es MemoryRow
getMemoryRow mid = do
  result <- Memory.getMemoryRowById testSpace mid
  case result of
    Right (Just row) -> pure row
    other -> liftIO (assertFailure ("Memory.getMemoryRowById: expected a row, got " <> show other))

-- * Assertions

assertSessionEvents ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  Int ->
  Eff es ()
assertSessionEvents sid expected = do
  events <- readStreamForward (Stream.streamName (sessionStream sid)) (StreamVersion 0) 100
  liftIO $
    assertEqual
      "the session stream gained no extra event"
      expected
      (Vector.length events)

assertMemoryEvents ::
  (IOE :> es, Store :> es) =>
  MemoryId ->
  Int ->
  Eff es ()
assertMemoryEvents mid expected = do
  events <- readStreamForward (Stream.streamName (memoryStream mid)) (StreamVersion 0) 100
  liftIO $
    assertEqual
      "the memory stream gained no extra event"
      expected
      (Vector.length events)

expectRight :: (IOE :> es) => String -> Either Session.SessionWriteError a -> Eff es a
expectRight label = \case
  Right value -> pure value
  Left err -> liftIO (assertFailure (label <> ": expected success, got " <> show err))

expectConflict :: (IOE :> es) => String -> Either Session.SessionWriteError SessionId -> Eff es ()
expectConflict label = \case
  Left (Session.SessionConflict reason) ->
    liftIO $ assertBool (label <> ": the conflict names a field") (reason /= "")
  other -> liftIO (assertFailure (label <> ": expected SessionConflict, got " <> show other))

expectRightM :: (IOE :> es) => String -> Either Memory.MemoryWriteError a -> Eff es a
expectRightM label = \case
  Right value -> pure value
  Left err -> liftIO (assertFailure (label <> ": expected success, got " <> show err))

expectConflictM :: (IOE :> es) => String -> Either Memory.MemoryWriteError MemoryId -> Eff es ()
expectConflictM label = \case
  Left (Memory.MemoryConflict reason) ->
    liftIO $ assertBool (label <> ": the conflict names a field") (reason /= "")
  other -> liftIO (assertFailure (label <> ": expected MemoryConflict, got " <> show other))

withApp :: Eff AppEffects a -> IO a
withApp action =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) \env -> do
      result <- runAppIO env action
      case result of
        Left storeErr -> assertFailure ("store error: " <> show storeErr)
        Right value -> pure value

testScope :: MemoryScope
testScope = ScopeGlobal (Namespace "kioku-test")
