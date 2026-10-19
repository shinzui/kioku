module Kioku.BoundedReadSpec (tests) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (replicateM)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff)
import Kioku.Api.Access (MemoryAccessContext, MemoryPermission (..), memoryContextRecordedActor, memoryContextSpace)
import Kioku.Api.Access.Internal qualified as Internal
import Kioku.Api.Recall (RecallTarget (..))
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (Confidence (..), MemoryStatus (..), MemoryType (..))
import Kioku.App (AppEffects, runAppIO, withNoopAppEnv)
import Kioku.Id (MemoryId, SessionId, genMemoryId, genSessionId, idText)
import Kioku.Memory qualified as M
import Kioku.Memory.Domain (ArchiveMemoryData (..), RecordMemoryData (..), SupersedeMemoryData (..))
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Pagination (BoundedPageError (..), BoundedReadError (..))
import Kioku.Prelude
import Kioku.Session qualified as S
import Kioku.Session.Domain (RecordTurnData (..), StartSessionData (..))
import Kioku.SpaceFixtures (otherContext, testActor, testContext, testSpace)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Relay.Pagination (Connection (..), Direction (..), Edge (..), PageInfo (..), PageRequest (..), PageRequestError (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Bounded facade"
    [ testCase "session pages, scalar counts and subject filters respect space and explicit scope" (withApp sessionPages),
      testCase "memory pages filter before bounds and archive reports its own append" (withApp memoryPages),
      testCase "turn and continuation pages retain complete relation counts" (withApp relationPages),
      testCase "concurrent archives report exactly one appending command" archiveRace,
      testCase "supersession pages traverse both directions and stay in their space" (withApp supersessionPages),
      testCase "delegation children and started ranges select before bounds" (withApp delegationAndRange),
      testCase "memory type and session filters page in native session order" (withApp memoryFilters),
      testCase "every bounded read refuses a context without MemoryRead before SQL" (withApp readPermission)
    ]

ns :: Namespace
ns = Namespace "bounded"

entity :: MemoryScope
entity = ScopeEntity ns (ScopeKind "intention") "one"

right :: (Show e) => Either e a -> Eff AppEffects a
right = either (liftIO . assertFailure . show) pure

check :: (Eq a, Show a) => String -> a -> a -> Eff AppEffects ()
check label expected actual = liftIO (assertEqual label expected actual)

withApp :: Eff AppEffects a -> IO a
withApp action = withKiokuMigratedDatabase \conn -> withNoopAppEnv (defaultConnectionSettings conn) \env -> do
  result <- runAppIO env action
  either (assertFailure . show) pure result

start :: MemoryAccessContext -> MemoryScope -> UTCTime -> Maybe SessionId -> Eff AppEffects SessionId
start context scope now previous = startSession context scope now previous Nothing

startSession :: MemoryAccessContext -> MemoryScope -> UTCTime -> Maybe SessionId -> Maybe SessionId -> Eff AppEffects SessionId
startSession context scope now previous parent = do
  sid <- liftIO genSessionId
  right
    =<< S.startWithContext
      context
      StartSessionData
        { sessionId = sid,
          memorySpaceId = memoryContextSpace context,
          actorPrincipal = memoryContextRecordedActor context,
          ownerPrincipal = Nothing,
          agentId = "bounded",
          focus = "review",
          scope,
          subjectRef = Just "same-subject",
          previousSessionId = previous,
          parentSessionId = parent,
          delegationDepth = maybe 0 (const 1) parent,
          startedAt = now
        }

record :: MemoryAccessContext -> MemoryScope -> UTCTime -> Eff AppEffects MemoryId
record context scope now = recordWithPriority context scope now 100

recordWithPriority :: MemoryAccessContext -> MemoryScope -> UTCTime -> Int -> Eff AppEffects MemoryId
recordWithPriority context scope now priority = recordMemory context scope now priority Nothing MemoryFact

recordMemory :: MemoryAccessContext -> MemoryScope -> UTCTime -> Int -> Maybe SessionId -> MemoryType -> Eff AppEffects MemoryId
recordMemory context scope now priority session memoryType = do
  mid <- liftIO genMemoryId
  right
    =<< M.recordWithContext
      context
      RecordMemoryData
        { memoryId = mid,
          memorySpaceId = memoryContextSpace context,
          actorPrincipal = memoryContextRecordedActor context,
          ownerPrincipal = Nothing,
          agentId = "bounded",
          sessionId = session,
          scope,
          memoryType,
          content = "content",
          priority,
          confidence = HighConfidence,
          tags = Set.empty,
          supersedes = Nothing,
          recordedAt = now
        }

page :: Int -> PageRequest
page n = PageRequest n Forward Nothing

nodes :: Connection a -> [a]
nodes connection = map (.node) connection.edges

pageError :: Either BoundedReadError a -> Maybe BoundedPageError
pageError = \case
  Left (BoundedReadInvalidPage err) -> Just err
  _ -> Nothing

sessionPages :: Eff AppEffects ()
sessionPages = do
  now <- liftIO getCurrentTime
  ids <- replicateM 7 (start testContext entity now Nothing)
  global <- start testContext (ScopeGlobal ns) now Nothing
  _ <- start otherContext entity now Nothing
  let filters = S.SessionFilter (NamespaceWide ns) Nothing Nothing Nothing Nothing Nothing
      selection = S.FilteredSessions filters
      get req = right =<< S.getPageWithContext testContext selection req
  first <- get (page 3)
  second <- get (PageRequest 3 Forward first.pageInfo.endCursor)
  third <- get (PageRequest 3 Forward second.pageInfo.endCursor)
  check "all tied rows" (sort (map idText (global : ids))) (sort (map (.sessionId) (nodes first <> nodes second <> nodes third)))
  back <- get (PageRequest 3 Backward second.pageInfo.startCursor)
  check "backward order" (map (.sessionId) (nodes first)) (map (.sessionId) (nodes back))
  counts <- right =<< S.getCountsWithContext testContext selection
  check "complete count" 8 counts.total
  exact <- right =<< S.getPageWithContext testContext (S.FilteredSessions (filters {S.target = ExactScope (ScopeGlobal ns)})) (page 3)
  check "exact global is narrow" [idText global] (map (.sessionId) (nodes exact))
  subject <- right =<< S.getCountsWithContext testContext (S.FilteredSessions (S.SessionFilter (NamespaceWide ns) Nothing Nothing (Just "absent") Nothing Nothing))
  check "subject filter" 0 subject.total
  tooLarge <- S.getPageWithContext testContext selection (page 101)
  check "maximum enforced" (Just (InvalidPageSize (PageSizeTooLarge 101 100))) (pageError tooLarge)
  negative <- S.getPageWithContext testContext selection (page (-1))
  check "negative refused" (Just (InvalidPageSize (NegativePageSize (-1)))) (pageError negative)
  running <- right =<< S.getCountsWithContext testContext (S.FilteredSessions (S.SessionFilter (NamespaceWide ns) Nothing (Just S.StatusRunning) Nothing Nothing Nothing))
  check "typed status filter" 8 running.total
  completed <- right =<< S.getCountsWithContext testContext (S.FilteredSessions (S.SessionFilter (NamespaceWide ns) Nothing (Just S.StatusCompleted) Nothing Nothing Nothing))
  check "absent status" 0 completed.total

memoryPages :: Eff AppEffects ()
memoryPages = do
  now <- liftIO getCurrentTime
  ids <- replicateM 7 (record testContext entity now)
  global <- recordWithPriority testContext (ScopeGlobal ns) now 1
  _ <- record otherContext entity now
  let filters = M.MemoryFilter (ExactScope entity) (Just MemoryActive) Nothing Nothing
      selection = M.FilteredMemories filters
      get req = right =<< M.getPageWithContext testContext selection req
  first <- get (page 3)
  second <- get (PageRequest 3 Forward first.pageInfo.endCursor)
  third <- get (PageRequest 3 Forward second.pageInfo.endCursor)
  check "all tied rows" (sort (map idText ids)) (sort (map (.memoryId) (nodes first <> nodes second <> nodes third)))
  back <- get (PageRequest 3 Backward second.pageInfo.startCursor)
  check "backward order" (map (.memoryId) (nodes first)) (map (.memoryId) (nodes back))
  prioritized <- right =<< M.getPageWithContext testContext (M.FilteredMemories (filters {M.target = NamespaceWide ns})) (page 1)
  check "native priority order" [idText global] (map (.memoryId) (nodes prioritized))
  let archive = ArchiveMemoryData {memoryId = global, memorySpaceId = memoryContextSpace testContext, actorPrincipal = memoryContextRecordedActor testContext, archivedAt = now}
  initial <- right =<< M.archiveWithContextChanged testContext archive
  duplicate <- right =<< M.archiveWithContextChanged testContext archive
  check "archive changed" (global, True) initial
  check "archive repeated" (global, False) duplicate
  counts <- right =<< M.getCountsWithContext testContext (M.FilteredMemories (filters {M.target = NamespaceWide ns, M.status = Nothing}))
  check "all statuses count" (8, 7, 1) (counts.total, counts.active, counts.archived)
  archived <- right =<< M.getPageWithContext testContext (M.FilteredMemories (filters {M.target = NamespaceWide ns, M.status = Just MemoryArchived})) (page 1)
  check "status before bounds" [idText global] (map (.memoryId) (nodes archived))

relationPages :: Eff AppEffects ()
relationPages = do
  now <- liftIO getCurrentTime
  root <- start testContext entity now Nothing
  next <- start testContext entity now (Just root)
  latest <- start testContext entity now (Just next)
  forM_ [1 .. 7] \i -> do
    _ <-
      right
        =<< S.recordTurnWithContext
          testContext
          RecordTurnData
            { sessionId = latest,
              memorySpaceId = memoryContextSpace testContext,
              actorPrincipal = memoryContextRecordedActor testContext,
              turnId = "bounded-" <> Text.pack (show i),
              turnIndex = i,
              role = "user",
              content = "content",
              toolSummary = Nothing,
              promptTokens = Nothing,
              outputTokens = Nothing,
              recordedAt = now
            }
    pure ()
  relations <- right =<< S.getRelationsWithContext testContext latest
  check "complete counts" (True, 7, 3, 0) (relations.found, relations.turns, relations.chainMembers, relations.delegationChildren)
  turns <- right =<< S.getTurnsPageWithContext testContext latest (page 2)
  rest <- right =<< S.getTurnsPageWithContext testContext latest (PageRequest 100 Forward turns.pageInfo.endCursor)
  check "all turns" [1 .. 7] (map (.turnIndex) (nodes turns <> nodes rest))
  chain <- right =<< S.getPageWithContext testContext (S.ContinuationChain (idText latest)) (page 100)
  check "all ancestors" (sort (map idText [root, next, latest])) (sort (map (.sessionId) (nodes chain)))
  hidden <- right =<< S.getRelationsWithContext otherContext latest
  check "foreign relation invisible" (False, 0, 0, 0) (hidden.found, hidden.turns, hidden.chainMembers, hidden.delegationChildren)

archiveRace :: IO ()
archiveRace = withKiokuMigratedDatabase \conn -> withNoopAppEnv (defaultConnectionSettings conn) \env -> do
  let run :: Eff AppEffects a -> IO a
      run action = runAppIO env action >>= either (assertFailure . show) pure
  now <- getCurrentTime
  mid <- run (record testContext entity now)
  let command =
        M.archiveWithContextChanged
          testContext
          ArchiveMemoryData
            { memoryId = mid,
              memorySpaceId = memoryContextSpace testContext,
              actorPrincipal = memoryContextRecordedActor testContext,
              archivedAt = now
            }
  (a, b) <- concurrently (run (right =<< command)) (run (right =<< command))
  assertEqual "one authoritative append" [False, True] (sort [snd a, snd b])

supersessionPages :: Eff AppEffects ()
supersessionPages = do
  now <- liftIO getCurrentTime
  a <- record testContext entity now
  b <- record testContext entity now
  c <- record testContext entity now
  _ <-
    right
      =<< M.supersedeWithContext
        testContext
        SupersedeMemoryData
          { memoryId = a,
            memorySpaceId = memoryContextSpace testContext,
            actorPrincipal = memoryContextRecordedActor testContext,
            supersededBy = b,
            supersededAt = now
          }
  _ <-
    right
      =<< M.supersedeWithContext
        testContext
        SupersedeMemoryData
          { memoryId = b,
            memorySpaceId = memoryContextSpace testContext,
            actorPrincipal = memoryContextRecordedActor testContext,
            supersededBy = c,
            supersededAt = now
          }
  let selection = M.SupersessionChain (idText b)
      get req = right =<< M.getPageWithContext testContext selection req
  first <- get (page 1)
  rest <- get (PageRequest 100 Forward first.pageInfo.endCursor)
  check "both directions" (sort (map idText [a, b, c])) (sort (map (.memoryId) (nodes first <> nodes rest)))
  counts <- right =<< M.getCountsWithContext testContext selection
  check "complete chain counts" (3, 1, 2) (counts.total, counts.active, counts.superseded)
  foreignPage <- right =<< M.getPageWithContext otherContext selection (page 100)
  check "foreign chain invisible" [] (map (.memoryId) (nodes foreignPage))

delegationAndRange :: Eff AppEffects ()
delegationAndRange = do
  now <- liftIO getCurrentTime
  parent <- start testContext entity now Nothing
  delegated <- forM [1 .. 4] \i -> startSession testContext entity (addUTCTime (fromInteger i) now) Nothing (Just parent)
  _ <- startSession otherContext entity now Nothing Nothing
  let get req = right =<< S.getPageWithContext testContext (S.DelegationChildren (idText parent)) req
  first <- get (page 3)
  rest <- get (PageRequest 3 Forward first.pageInfo.endCursor)
  check "children ascend by start" (map idText delegated) (map (.sessionId) (nodes first <> nodes rest))
  relations <- right =<< S.getRelationsWithContext testContext parent
  check "child count" 4 relations.delegationChildren
  let filters = S.SessionFilter (ExactScope entity) Nothing Nothing Nothing (Just (addUTCTime 2 now)) (Just (addUTCTime 4 now))
  ranged <- right =<< S.getPageWithContext testContext (S.FilteredSessions filters) (page 100)
  check "half-open started range" (map idText (reverse (take 2 (drop 1 delegated)))) (map (.sessionId) (nodes ranged))
  rangedCount <- right =<< S.getCountsWithContext testContext (S.FilteredSessions filters)
  check "range count" 2 rangedCount.total

memoryFilters :: Eff AppEffects ()
memoryFilters = do
  now <- liftIO getCurrentTime
  sid <- start testContext entity now Nothing
  inSession <- forM [1 .. 5] \i -> recordMemory testContext entity (addUTCTime (fromInteger i) now) (fromInteger i) (Just sid) MemoryFact
  preference <- recordMemory testContext entity now 100 Nothing MemoryPreference
  _ <- recordMemory testContext entity now 100 Nothing MemoryFact
  let filters = M.MemoryFilter (NamespaceWide ns) Nothing Nothing (Just (idText sid))
      get req = right =<< M.getPageWithContext testContext (M.FilteredMemories filters) req
  first <- get (page 2)
  second <- get (PageRequest 2 Forward first.pageInfo.endCursor)
  third <- get (PageRequest 2 Forward second.pageInfo.endCursor)
  check "session order ignores priority" (map idText (reverse inSession)) (map (.memoryId) (nodes first <> nodes second <> nodes third))
  back <- get (PageRequest 2 Backward second.pageInfo.startCursor)
  check "session backward order" (map (.memoryId) (nodes first)) (map (.memoryId) (nodes back))
  typed <- right =<< M.getPageWithContext testContext (M.FilteredMemories (M.MemoryFilter (NamespaceWide ns) Nothing (Just MemoryPreference) Nothing)) (page 100)
  check "memory type filter" [idText preference] (map (.memoryId) (nodes typed))

readPermission :: Eff AppEffects ()
readPermission = do
  now <- liftIO getCurrentTime
  let writer = Internal.MemoryAccessContext {Internal.memorySpaceId = testSpace, Internal.actor = testActor, Internal.grantedPermissions = Set.fromList [MemoryRecord, MemoryForget], Internal.decisionToken = Nothing}
      denied :: Either BoundedReadError a -> Bool
      denied = \case
        Left (BoundedReadNotPermitted MemoryRead) -> True
        _ -> False
  sid <- start writer entity now Nothing
  _ <- record writer entity now
  sessionPage <- S.getPageWithContext writer (S.FilteredSessions (S.SessionFilter (NamespaceWide ns) Nothing Nothing Nothing Nothing Nothing)) (page 1)
  sessionCounts <- S.getCountsWithContext writer (S.ContinuationChain (idText sid))
  turnsPage <- S.getTurnsPageWithContext writer sid (page 1)
  relations <- S.getRelationsWithContext writer sid
  memoryPage <- M.getPageWithContext writer (M.FilteredMemories (M.MemoryFilter (NamespaceWide ns) Nothing Nothing Nothing)) (page 1)
  memoryCounts <- M.getCountsWithContext writer (M.SupersessionChain "absent")
  check "all six reads refused" [True, True, True, True, True, True] [denied sessionPage, denied sessionCounts, denied turnsPage, denied relations, denied memoryPage, denied memoryCounts]
  -- The gate runs before page validation, so an invalid page cannot probe a refused space.
  invalid <- S.getPageWithContext writer (S.DelegationChildren (idText sid)) (page 101)
  check "permission before page size" True (denied invalid)
