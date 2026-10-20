{-# OPTIONS_GHC -Wno-deprecations #-}

-- | Exercise deprecated legacy receipt compatibility through the public facade.
-- Stream inspection is independent evidence, never the source of a receipt.
module Kioku.ArchiveReceiptSpec (tests) where

import Control.Concurrent.Async (concurrently)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (sort)
import Data.Set qualified as Set
import Data.Time (addUTCTime)
import Data.Vector qualified as Vector
import Effectful (Eff)
import Keiro.Stream qualified as Stream
import Kioku.Api.Access (MemoryAccessContext, RecordedPrincipal (..), legacyMemorySpaceId, legacyPrincipalRef, memoryContextRecordedActor, memoryContextSpace)
import Kioku.Api.Access.Internal qualified as Internal
import Kioku.Api.Scope (MemoryScope (..), Namespace (..))
import Kioku.Api.Types (Confidence (..), MemoryType (..))
import Kioku.App (AppEffects, runAppIO, withNoopAppEnv)
import Kioku.Id (MemoryId, genMemoryId)
import Kioku.Memory qualified as M
import Kioku.Memory.Domain (ArchiveMemoryData (..), MemoryArchivedData (..), MemoryEvent (..), RecordMemoryData (..), SupersedeMemoryData (..))
import Kioku.Memory.Domain qualified as Archive (ArchiveMemoryData (..))
import Kioku.Memory.EventStream (memoryStream, parseMemoryEvent)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Prelude
import Kioku.SpaceFixtures (legacyContext, otherActorPrincipal, testActor, testContext, testSpace)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Types (RecordedEvent (..), StreamVersion (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Archive receipts"
    [ testCase "first and repeat preserve unattributed archive payload" (withApp firstAndRepeat),
      testCase "two legacy commands have one append owner" (archiveRace False),
      testCase "legacy and context commands share one append owner" (archiveRace True),
      testCase "foreign active and archived IDs stay absent" (withApp partitionRefusals),
      testCase "context gates precede work and idempotence" (withApp contextRefusals),
      testCase "missing and terminal errors match the ID-only wrapper" (withApp failureParity),
      testCase "known and legacy attribution and ID-only APIs retain parity" (withApp attributionParity)
    ]

right :: (Show e) => Either e a -> Eff AppEffects a
right = either (liftIO . assertFailure . show) pure

check :: (Eq a, Show a) => String -> a -> a -> Eff AppEffects ()
check label expected actual = liftIO (assertEqual label expected actual)

withApp :: Eff AppEffects a -> IO a
withApp action = withKiokuMigratedDatabase \conn -> withNoopAppEnv (defaultConnectionSettings conn) \env ->
  runAppIO env action >>= either (assertFailure . show) pure

record :: MemoryAccessContext -> UTCTime -> Eff AppEffects MemoryId
record context recordedAt = do
  memoryId <- liftIO genMemoryId
  right
    =<< M.recordWithContext
      context
      RecordMemoryData
        { memoryId,
          memorySpaceId = memoryContextSpace context,
          actorPrincipal = memoryContextRecordedActor context,
          ownerPrincipal = Nothing,
          agentId = "archive-receipt-test",
          sessionId = Nothing,
          scope = ScopeGlobal (Namespace "archive_receipts"),
          memoryType = MemoryFact,
          content = "archive receipt fixture",
          priority = 100,
          confidence = HighConfidence,
          tags = Set.empty,
          supersedes = Nothing,
          recordedAt
        }

archiveData :: MemoryId -> RecordedPrincipal -> UTCTime -> ArchiveMemoryData
archiveData memoryId actorPrincipal archivedAt =
  ArchiveMemoryData {memoryId, memorySpaceId = legacyMemorySpaceId, actorPrincipal, archivedAt}

-- Read exact serialized values as well as decoded canonical events, so a codec
-- default cannot conceal an invented actor in the durable payload.
readEvents :: MemoryId -> Eff AppEffects [(Value, MemoryEvent)]
readEvents mid = do
  stored <- Vector.toList <$> readStreamForward (Stream.streamName (memoryStream mid)) (StreamVersion 0) 100
  forM stored \event -> do
    decoded <- right (parseMemoryEvent event.payload)
    pure (event.payload, decoded)

assertArchive :: MemoryId -> ArchiveMemoryData -> Eff AppEffects ()
assertArchive mid command = do
  events <- readEvents mid
  check "record plus exactly one archive" 2 (length events)
  check
    "one canonical archive, unchanged actor and timestamp"
    [MemoryArchivedData mid legacyMemorySpaceId command.actorPrincipal command.archivedAt]
    [d | (_, MemoryArchived d) <- events]

firstAndRepeat :: Eff AppEffects ()
firstAndRepeat = do
  now <- liftIO getCurrentTime
  mid <- record legacyContext now
  let command = archiveData mid UnattributedPrincipal now
  first <- right =<< M.archiveLegacyChanged command
  again <- right =<< M.archiveLegacyChanged command {Archive.archivedAt = addUTCTime 60 now}
  check "first appended" (mid, True) first
  check "repeat appended nothing" (mid, False) again
  assertArchive mid command
  events <- readEvents mid
  let actors = [KeyMap.lookup "actorPrincipal" dat | (Object payload, MemoryArchived _) <- events, Just (Object dat) <- [KeyMap.lookup "data" payload]]
  check "durable actor is the existing marker" [Just (String "kioku:unattributed")] actors

-- Both workers announce readiness before either may call the facade. Different
-- timestamps/actors let the durable event independently identify the winner.
archiveRace :: Bool -> IO ()
archiveRace mixed = withKiokuMigratedDatabase \conn -> withNoopAppEnv (defaultConnectionSettings conn) \env -> do
  let run :: Eff AppEffects a -> IO a
      run action = runAppIO env action >>= either (assertFailure . show) pure
  now <- getCurrentTime
  mid <- run (record legacyContext now)
  readyA <- newEmptyMVar
  readyB <- newEmptyMVar
  startA <- newEmptyMVar
  startB <- newEmptyMVar
  let a = archiveData mid UnattributedPrincipal now
      b = archiveData mid (if mixed then memoryContextRecordedActor legacyContext else LegacyPrincipal (legacyPrincipalRef "old-host")) (addUTCTime 1 now)
      worker ready start action = putMVar ready () >> takeMVar start >> run (right =<< action)
      second = if mixed then M.archiveWithContextChanged legacyContext b else M.archiveLegacyChanged b
      release = takeMVar readyA >> takeMVar readyB >> putMVar startA () >> putMVar startB ()
  ((receiptA, receiptB), ()) <-
    concurrently
      (concurrently (worker readyA startA (M.archiveLegacyChanged a)) (worker readyB startB second))
      release
  assertEqual "both return the requested ID" [mid, mid] [fst receiptA, fst receiptB]
  assertEqual "exactly one authoritative append" [False, True] (sort [snd receiptA, snd receiptB])
  run (assertArchive mid (if snd receiptA then a else b))

-- Every refused call must preserve both stream and projected row, even if the
-- foreign row is already archived (where an unscoped lookup could leak a no-op).
partitionRefusals :: Eff AppEffects ()
partitionRefusals = do
  now <- liftIO getCurrentTime
  mid <- record testContext now
  let command = (archiveData mid (memoryContextRecordedActor testContext) now) {Archive.memorySpaceId = testSpace}
  before <- snapshot testContext mid
  expectFailure (M.MemorySpaceMismatch testSpace legacyMemorySpaceId) command
  check "wrong-space payload did not change row or stream" before =<< snapshot testContext mid
  missing <- liftIO genMemoryId
  forM_ [False, True] \archived -> do
    when archived $ void (right =<< M.archiveWithContext testContext command)
    stored <- snapshot testContext mid
    let hidden = archiveData mid UnattributedPrincipal now
    expectFailure M.MemoryNotFound hidden
    expectFailure M.MemoryNotFound (archiveData missing UnattributedPrincipal now)
    check "foreign ID is unchanged" stored =<< snapshot testContext mid
  check "missing ID has no stream" [] =<< readEvents missing

snapshot :: MemoryAccessContext -> MemoryId -> Eff AppEffects (String, [(Value, MemoryEvent)])
snapshot context mid = do
  row <- right =<< M.getMemoryRowById (memoryContextSpace context) mid
  events <- readEvents mid
  -- Show covers every projected column, including status and update timestamps.
  pure (show row, events)

expectFailure :: M.MemoryWriteError -> ArchiveMemoryData -> Eff AppEffects ()
expectFailure expected command = do
  result <- M.archiveLegacyChanged command
  old <- M.archive command
  checkFailure "receipt failure matches expected constructor" expected result
  checkFailure "ID-only wrapper returns exactly the same failure" expected old

checkFailure :: String -> M.MemoryWriteError -> Either M.MemoryWriteError a -> Eff AppEffects ()
checkFailure label expected actual =
  check label (show (Left expected :: Either M.MemoryWriteError ())) (show (void actual))

contextRefusals :: Eff AppEffects ()
contextRefusals = do
  now <- liftIO getCurrentTime
  mid <- record legacyContext now
  let command = archiveData mid (memoryContextRecordedActor legacyContext) now
      noForget =
        Internal.MemoryAccessContext
          { Internal.memorySpaceId = legacyMemorySpaceId,
            Internal.actor = testActor,
            Internal.grantedPermissions = Set.singleton Internal.MemoryRead,
            Internal.decisionToken = Nothing
          }
      refused context payload expected = do
        result <- M.archiveWithContextChanged context payload
        checkFailure "context refusal remains typed" expected result
  forM_ [False, True] \archived -> do
    when archived $ void (right =<< M.archiveLegacyChanged command)
    before <- snapshot legacyContext mid
    refused noForget command (M.MemoryNotPermitted Internal.MemoryForget)
    refused legacyContext command {Archive.memorySpaceId = testSpace} (M.MemorySpaceMismatch testSpace legacyMemorySpaceId)
    forM_ [otherActorPrincipal, UnattributedPrincipal] \actor ->
      refused legacyContext command {Archive.actorPrincipal = actor} (M.MemoryActorMismatch actor (memoryContextRecordedActor legacyContext))
    check "gates did not change row or stream" before =<< snapshot legacyContext mid

failureParity :: Eff AppEffects ()
failureParity = do
  now <- liftIO getCurrentTime
  missing <- liftIO genMemoryId
  expectFailure M.MemoryNotFound (archiveData missing UnattributedPrincipal now)
  check "missing has no facts" [] =<< readEvents missing
  winner <- record legacyContext now
  forM_ [False, True] \merged -> do
    mid <- record legacyContext now
    if merged
      then void (right =<< M.mergeWithContext legacyContext mid winner)
      else
        void
          ( right
              =<< M.supersedeWithContext
                legacyContext
                SupersedeMemoryData
                  { memoryId = mid,
                    memorySpaceId = legacyMemorySpaceId,
                    actorPrincipal = memoryContextRecordedActor legacyContext,
                    supersededBy = winner,
                    supersededAt = now
                  }
          )
    before <- snapshot legacyContext mid
    expectFailure (M.MemoryConflict "archive: status differs from the recorded memory") (archiveData mid UnattributedPrincipal now)
    check "terminal failure did not change row or stream" before =<< snapshot legacyContext mid

attributionParity :: Eff AppEffects ()
attributionParity = do
  now <- liftIO getCurrentTime
  forM_ [memoryContextRecordedActor legacyContext, LegacyPrincipal (legacyPrincipalRef "historic host label")] \actor -> do
    mid <- record legacyContext now
    let command = archiveData mid actor now
        retry = command {Archive.actorPrincipal = UnattributedPrincipal, Archive.archivedAt = addUTCTime 30 now}
    check "first receipt" (mid, True) =<< right =<< M.archiveLegacyChanged command
    check "accepted repeat retains ID" (mid, False) =<< right =<< M.archiveLegacyChanged retry
    check "old wrapper retains ID" mid =<< right =<< M.archive retry
    check "context ID-only wrapper retains ID" mid =<< right =<< M.archiveWithContext legacyContext command {Archive.actorPrincipal = memoryContextRecordedActor legacyContext}
    assertArchive mid command
  -- An ID-only first archive also owns the append; the bridge then reports a repeat.
  mid <- record legacyContext now
  let command = archiveData mid UnattributedPrincipal now
  check "old wrapper first ID" mid =<< right =<< M.archive command
  check "bridge observes accepted repeat" (mid, False) =<< right =<< M.archiveLegacyChanged command
  assertArchive mid command
