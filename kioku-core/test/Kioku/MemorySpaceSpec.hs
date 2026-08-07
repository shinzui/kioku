{-# OPTIONS_GHC -Wno-deprecations #-}

-- | The isolation boundary itself: what a caller authorized for one memory space can and
-- cannot do to another one's data.
--
-- Everything here drives the real write path against a real database, because the property
-- being tested is not "the function returns Left" but "no event was appended". A guard that
-- rejects the command and an aggregate that quietly accepted it look identical if you only
-- inspect the return value.
--
-- The module deliberately calls the deprecated compatibility wrappers, so it turns their
-- warning off. That is the point of those tests: the wrappers still exist for one release, and
-- what has to be proved about them is that they cannot reach anything outside the legacy space.
module Kioku.MemorySpaceSpec (tests) where

import Data.Set qualified as Set
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Stream qualified as Stream
import Kioku.Api.Access
  ( MemoryAccessContext,
    MemoryPermission (..),
    MemorySpaceId,
    RecordedPrincipal,
    legacyMemorySpaceId,
    memoryContextRecordedActor,
    memoryContextSpace,
  )
import Kioku.Api.Access.Internal qualified as Internal
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (Confidence (..), MemoryType (..))
import Kioku.App (AppEffects, runAppIO, withNoopAppEnv)
import Kioku.Distill.L1 (L1Error (..), L1RunMode (..), distillSessionL1, scopedScanCandidates)
import Kioku.Distill.Runtime (DistillRuntime (..), newDistillRuntime)
import Kioku.Id (MemoryId, SessionId, genMemoryId, genSessionId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (ArchiveMemoryData (..), MemoryEvent (..), MemoryRecordedData (..), RecordMemoryData (..))
import Kioku.Memory.EventStream (memoryStream, parseMemoryEvent)
import Kioku.Memory.ReadModel (MemoryRow (..))
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Prelude
import Kioku.Session qualified as Session
import Kioku.Session.Domain (RecordTurnData (..), SessionEvent (..), StartSessionData (..))
import Kioku.Session.EventStream (parseSessionEvent, sessionStream)
import Kioku.SpaceFixtures
  ( legacyContext,
    otherActorPrincipal,
    otherContext,
    otherSpace,
    testActor,
    testActorPrincipal,
    testContext,
    testSpace,
  )
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Types (RecordedEvent (..), StreamVersion (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Memory space isolation"
    [ testGroup
        "a command from another space cannot see, let alone change, the row"
        [ testCase "a memory cannot be archived from another space" testCrossSpaceArchiveRejected,
          testCase "a turn cannot be appended from another space" testCrossSpaceTurnRejected,
          testCase "an id in another space is indistinguishable from one that does not exist" testCrossSpaceIsNotAnOracle
        ],
      testGroup
        "the context and the command must agree"
        [ testCase "a payload naming another space is refused" testPayloadSpaceMismatch,
          testCase "a payload naming another principal is refused" testPayloadActorMismatch,
          testCase "a read-only context cannot record" testReadContextCannotRecord,
          testCase "a context without distill cannot distill" testContextWithoutDistill
        ],
      testGroup
        "the deprecated wrappers reach only the legacy space"
        [ testCase "record refuses a non-legacy payload" testWrapperRefusesNonLegacy,
          testCase "record accepts a legacy payload" testWrapperAcceptsLegacy,
          testCase "the wrapper cannot mutate another space's memory" testWrapperCannotTouchOtherSpace
        ],
      testCase "the same scope in two spaces is two independent memories" testSameScopeTwoSpaces
    ]

-- | The load-bearing case. A caller legitimately authorized for @space_other@ presents the id
-- of a memory that lives in @space_test@.
--
-- The refusal now arrives before the aggregate is reached at all: the read-model precheck is
-- scoped to the caller's own space, so the row is simply not there and the write fails with
-- 'Memory.MemoryNotFound'. The aggregate's guard is still behind it and would refuse the
-- command too — see 'testPayloadSpaceMismatch' for the context check and the plan's Decision
-- Log for why the guard lives in the state machine — but nothing gets that far.
--
-- The proof is unchanged: the memory's event stream still contains exactly one event and the
-- row is still active.
testCrossSpaceArchiveRejected :: Assertion
testCrossSpaceArchiveRejected =
  withApp do
    mid <- recordFixture testContext "cross-space archive"
    now <- liftIO getCurrentTime
    result <-
      Memory.archiveWithContext
        otherContext
        ArchiveMemoryData
          { memoryId = mid,
            memorySpaceId = otherSpace,
            actorPrincipal = otherActorPrincipal,
            archivedAt = now
          }
    liftIO case result of
      Left Memory.MemoryNotFound -> pure ()
      other -> assertFailure ("expected the archive to be refused, got " <> show other)
    events <- readMemoryEvents mid
    row <- getMemory mid
    liftIO do
      assertEqual "no event was appended" ["MemoryRecorded"] (memoryEventName <$> events)
      assertEqual "the memory is still active" "active" row.status

-- | The residual this plan closed.
--
-- Before the read models carried a memory space, the write-path precheck compared against a
-- row it could see whatever space that row was in, so an idempotent answer told a caller in
-- another space that the id existed and whether it was still active. Now the two cases are
-- byte-identical, which is the only way \"you may not look here\" and \"there is nothing here\"
-- can stay indistinguishable.
testCrossSpaceIsNotAnOracle :: Assertion
testCrossSpaceIsNotAnOracle =
  withApp do
    real <- recordFixture testContext "cross-space oracle"
    absent <- liftIO genMemoryId
    now <- liftIO getCurrentTime
    let archiveFrom mid =
          Memory.archiveWithContext
            otherContext
            ArchiveMemoryData
              { memoryId = mid,
                memorySpaceId = otherSpace,
                actorPrincipal = otherActorPrincipal,
                archivedAt = now
              }
    existsElsewhere <- archiveFrom real
    doesNotExist <- archiveFrom absent
    liftIO $
      assertEqual
        "an id in another space answers exactly as an id that does not exist"
        (show doesNotExist)
        (show existsElsewhere)

testCrossSpaceTurnRejected :: Assertion
testCrossSpaceTurnRejected =
  withApp do
    sid <- startFixture testContext
    now <- liftIO getCurrentTime
    result <-
      Session.recordTurnWithContext
        otherContext
        RecordTurnData
          { sessionId = sid,
            memorySpaceId = otherSpace,
            actorPrincipal = otherActorPrincipal,
            turnId = idText sid <> "-turn-1",
            turnIndex = 0,
            role = "user",
            content = "not yours",
            toolSummary = Nothing,
            promptTokens = Nothing,
            outputTokens = Nothing,
            recordedAt = now
          }
    liftIO case result of
      Left Session.SessionNotFound -> pure ()
      other -> assertFailure ("expected the turn to be refused, got " <> show other)
    events <- readSessionEvents sid
    liftIO $
      assertEqual "no turn was appended" ["SessionStarted"] (sessionEventName <$> events)

-- | Before any of that, the payload has to agree with the decision that authorized it. A
-- mismatch is refused without touching the store at all.
testPayloadSpaceMismatch :: Assertion
testPayloadSpaceMismatch =
  withApp do
    mid <- liftIO genMemoryId
    now <- liftIO getCurrentTime
    result <-
      Memory.recordWithContext
        testContext
        (recordData mid testContext now) {memorySpaceId = otherSpace}
    liftIO case result of
      Left (Memory.MemorySpaceMismatch requested authorized) -> do
        assertEqual "names the requested space" otherSpace requested
        assertEqual "names the authorized space" testSpace authorized
      other -> assertFailure ("expected MemorySpaceMismatch, got " <> show other)
    stored <- Memory.getMemoryRowById testSpace mid
    liftIO case stored of
      Right Nothing -> pure ()
      other -> assertFailure ("nothing should have been written, got " <> show other)

-- | Attribution is not caller-supplied. A context authorized as one principal cannot be used
-- to write an event saying somebody else acted.
testPayloadActorMismatch :: Assertion
testPayloadActorMismatch =
  withApp do
    mid <- liftIO genMemoryId
    now <- liftIO getCurrentTime
    result <-
      Memory.recordWithContext
        testContext
        (recordData mid testContext now) {actorPrincipal = otherActorPrincipal}
    liftIO case result of
      Left (Memory.MemoryActorMismatch claimed authorized) -> do
        assertEqual "names the claimed actor" otherActorPrincipal claimed
        assertEqual "names the authorized actor" testActorPrincipal authorized
      other -> assertFailure ("expected MemoryActorMismatch, got " <> show other)

-- | A context is minted for specific actions. One obtained by checking @read@ must not spend
-- itself on a write.
testReadContextCannotRecord :: Assertion
testReadContextCannotRecord =
  withApp do
    mid <- liftIO genMemoryId
    now <- liftIO getCurrentTime
    let readOnly = narrowContext testSpace [MemoryRead]
    result <- Memory.recordWithContext readOnly (recordData mid readOnly now)
    liftIO case result of
      Left (Memory.MemoryNotPermitted MemoryRecord) -> pure ()
      other -> assertFailure ("expected MemoryNotPermitted MemoryRecord, got " <> show other)

-- | Distillation asks for its own permission, and asks before spending an LLM call rather than
-- after, at the first write.
testContextWithoutDistill :: Assertion
testContextWithoutDistill =
  withApp do
    sid <- startFixture testContext
    runtime <- liftIO newDistillRuntime
    let refuse = runtime {runExtract = \_ -> liftIO (assertFailure "the extractor must not run")}
    result <- distillSessionL1 (narrowContext testSpace [MemoryRecord]) RespectWatermark refuse (scopedScanCandidates 5) sid
    liftIO case result of
      Left (L1NotPermitted MemoryDistill) -> pure ()
      other -> assertFailure ("expected L1NotPermitted MemoryDistill, got " <> show other)

testWrapperRefusesNonLegacy :: Assertion
testWrapperRefusesNonLegacy =
  withApp do
    mid <- liftIO genMemoryId
    now <- liftIO getCurrentTime
    result <- Memory.record (recordData mid testContext now)
    liftIO case result of
      Left (Memory.MemorySpaceMismatch requested authorized) -> do
        assertEqual "names the requested space" testSpace requested
        assertEqual "the wrapper only reaches the legacy space" legacyMemorySpaceId authorized
      other -> assertFailure ("expected MemorySpaceMismatch, got " <> show other)

testWrapperAcceptsLegacy :: Assertion
testWrapperAcceptsLegacy =
  withApp do
    mid <- liftIO genMemoryId
    now <- liftIO getCurrentTime
    result <- Memory.record (recordData mid legacyContext now)
    liftIO case result of
      Right written -> assertEqual "wrote the memory it was asked to" mid written
      other -> assertFailure ("expected the legacy wrapper to write, got " <> show other)
    events <- readMemoryEvents mid
    liftIO case events of
      [MemoryRecorded d] -> assertEqual "in the legacy space" legacyMemorySpaceId d.memorySpaceId
      other -> assertFailure ("expected one MemoryRecorded, got " <> show other)

-- | The wrapper is confined by its payload, and its payload is confined to the legacy space, so
-- there is no argument it can be given that reaches a memory living anywhere else.
testWrapperCannotTouchOtherSpace :: Assertion
testWrapperCannotTouchOtherSpace =
  withApp do
    mid <- recordFixture testContext "not reachable from the wrapper"
    now <- liftIO getCurrentTime
    -- Named honestly: the only payload the wrapper accepts claims the legacy space, and this
    -- memory is not in it — so the wrapper's own lookup, scoped to the legacy space, does not
    -- find it and the write is refused before the aggregate is consulted.
    result <-
      Memory.archive
        ArchiveMemoryData
          { memoryId = mid,
            memorySpaceId = legacyMemorySpaceId,
            actorPrincipal = Internal.UnattributedPrincipal,
            archivedAt = now
          }
    liftIO case result of
      Left Memory.MemoryNotFound -> pure ()
      other -> assertFailure ("expected the archive to be refused, got " <> show other)
    row <- getMemory mid
    liftIO $ assertEqual "the memory is still active" "active" row.status

-- | Scopes organize; spaces isolate. The same namespace and scope in two spaces are two
-- unrelated memories, and neither write interferes with the other.
testSameScopeTwoSpaces :: Assertion
testSameScopeTwoSpaces =
  withApp do
    mine <- recordFixture testContext "shared scope, my space"
    theirs <- recordFixture otherContext "shared scope, their space"
    mineEvents <- readMemoryEvents mine
    theirsEvents <- readMemoryEvents theirs
    liftIO do
      assertEqual "my memory is in my space" [testSpace] (recordedSpaces mineEvents)
      assertEqual "their memory is in theirs" [otherSpace] (recordedSpaces theirsEvents)
  where
    recordedSpaces events = [d.memorySpaceId | MemoryRecorded d <- events]

-- * Fixtures

recordFixture ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  Text ->
  Eff es MemoryId
recordFixture context content = do
  mid <- liftIO genMemoryId
  now <- liftIO getCurrentTime
  result <- Memory.recordWithContext context (recordData mid context now) {content}
  case result of
    Left err -> liftIO (assertFailure ("Memory.recordWithContext: " <> show err))
    Right written -> pure written

recordData :: MemoryId -> MemoryAccessContext -> UTCTime -> RecordMemoryData
recordData memoryId context recordedAt =
  RecordMemoryData
    { memoryId,
      memorySpaceId = memoryContextSpace context,
      actorPrincipal = memoryContextRecordedActor context,
      ownerPrincipal = Nothing,
      agentId = "test-agent",
      sessionId = Nothing,
      scope = testScope,
      memoryType = MemoryFact,
      content = "a memory",
      priority = 100,
      confidence = HighConfidence,
      tags = Set.empty,
      supersedes = Nothing,
      recordedAt
    }

startFixture ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  Eff es SessionId
startFixture context = do
  sid <- liftIO genSessionId
  now <- liftIO getCurrentTime
  result <-
    Session.startWithContext
      context
      StartSessionData
        { sessionId = sid,
          memorySpaceId = memoryContextSpace context,
          actorPrincipal = memoryContextRecordedActor context,
          ownerPrincipal = Nothing,
          agentId = "test-agent",
          focus = "isolation",
          scope = testScope,
          subjectRef = Nothing,
          previousSessionId = Nothing,
          parentSessionId = Nothing,
          delegationDepth = 0,
          startedAt = now
        }
  case result of
    Left err -> liftIO (assertFailure ("Session.startWithContext: " <> show err))
    Right written -> pure written

-- | A context minted for exactly the listed actions.
--
-- 'Kioku.Api.Access.assumeAuthorizedMemoryContext' grants everything, so it cannot demonstrate
-- that the granted set is consulted at all. Building one through the internal constructor is
-- the only way to express "authorized to read, and nothing else".
narrowContext :: MemorySpaceId -> [MemoryPermission] -> MemoryAccessContext
narrowContext space permissions =
  Internal.MemoryAccessContext
    { Internal.memorySpaceId = space,
      Internal.actor = testActor,
      Internal.grantedPermissions = Set.fromList permissions,
      Internal.decisionToken = Nothing
    }

testScope :: MemoryScope
testScope = ScopeEntity (Namespace "kioku_test") (ScopeKind "space") "isolation"

-- * Store helpers

withApp :: Eff AppEffects a -> IO a
withApp action =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) \env -> do
      result <- runAppIO env action
      case result of
        Left storeErr -> assertFailure ("store error: " <> show storeErr)
        Right value -> pure value

getMemory :: (IOE :> es, Store :> es) => MemoryId -> Eff es MemoryRow
getMemory mid = do
  result <- Memory.getMemoryRowById testSpace mid
  case result of
    Right (Just row) -> pure row
    other -> liftIO (assertFailure ("missing memory row: " <> show other))

readMemoryEvents :: (IOE :> es, Store :> es) => MemoryId -> Eff es [MemoryEvent]
readMemoryEvents mid = do
  recorded <- Vector.toList <$> readStreamForward (Stream.streamName (memoryStream mid)) (StreamVersion 0) 100
  traverse decode recorded
  where
    decode recorded =
      case parseMemoryEvent recorded.payload of
        Left err -> liftIO (assertFailure ("parseMemoryEvent: " <> show err))
        Right event -> pure event

readSessionEvents :: (IOE :> es, Store :> es) => SessionId -> Eff es [SessionEvent]
readSessionEvents sid = do
  recorded <- Vector.toList <$> readStreamForward (Stream.streamName (sessionStream sid)) (StreamVersion 0) 100
  traverse decode recorded
  where
    decode recorded =
      case parseSessionEvent recorded.payload of
        Left err -> liftIO (assertFailure ("parseSessionEvent: " <> show err))
        Right event -> pure event

memoryEventName :: MemoryEvent -> Text
memoryEventName = \case
  MemoryRecorded {} -> "MemoryRecorded"
  MemorySuperseded {} -> "MemorySuperseded"
  MemoryArchived {} -> "MemoryArchived"
  MemoryTagsUpdated {} -> "MemoryTagsUpdated"
  MemoryConfidenceUpdated {} -> "MemoryConfidenceUpdated"
  MemoryMerged {} -> "MemoryMerged"

sessionEventName :: SessionEvent -> Text
sessionEventName = \case
  SessionStarted {} -> "SessionStarted"
  SessionCompleted {} -> "SessionCompleted"
  SessionFailed {} -> "SessionFailed"
  SessionAwaiting {} -> "SessionAwaiting"
  SessionResumed {} -> "SessionResumed"
  InteractiveSessionRecorded {} -> "InteractiveSessionRecorded"
  TurnRecorded {} -> "TurnRecorded"
