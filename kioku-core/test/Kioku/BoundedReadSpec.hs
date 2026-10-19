module Kioku.BoundedReadSpec (tests) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (replicateM)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Keiro.ReadModel (ReadModelError (..))
import Kioku.Api.Access (MemoryAccessContext, MemoryPermission (..), memoryContextRecordedActor, memoryContextSpace)
import Kioku.Api.Access.Internal qualified as Internal
import Kioku.Api.Recall (RecallTarget (..))
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (Confidence (..), MemoryStatus (..), MemoryType (..))
import Kioku.App (AppEffects, runAppIO, withNoopAppEnv)
import Kioku.Id (MemoryId, SessionId, genMemoryId, genSessionId, idText)
import Kioku.Memory qualified as M
import Kioku.Memory.Domain (ArchiveMemoryData (..), RecordMemoryData (..), SupersedeMemoryData (..), UpdateMemoryTagsData (..))
import Kioku.Memory.ReadModel qualified as Filter (MemoryFilter (..))
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Pagination (BoundedPageError (..), BoundedReadError (..))
import Kioku.Prelude
import Kioku.ReadModel (reconcileReadModelRegistry)
import Kioku.Session qualified as S
import Kioku.Session.Domain (RecordTurnData (..), StartSessionData (..))
import Kioku.SpaceFixtures (otherContext, testActor, testContext, testSpace)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Relay.Pagination (Connection (..), Cursor (..), Direction (..), Edge (..), PageInfo (..), PageRequest (..), PageRequestError (..), cursorToText)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Bounded facade"
    [ testCase "session pages, scalar counts and subject filters respect space and explicit scope" (withApp sessionPages),
      testCase "memory pages filter before bounds and archive reports its own append" (withApp memoryPages),
      testCase "fixed metadata traverses tied populations without tag arrays" (withApp metadataPages),
      testCase "tags page complete Unicode values with bounded ordinal cursors" (withApp tagPages),
      testCase "kind filters and newest active reads intersect before page bounds" (withApp recencyAndKinds),
      testCase "denied Memory reads execute zero Store operations" deniedWithoutStore,
      testCase "missing, malformed, stale and unavailable Memory reads stay distinct" (withApp memoryFailures),
      testCase "Memory storage failures preserve the outer Store channel" storageFailures,
      testCase "recency and metadata access plans on a multi-space fixture" (withApp memoryAccessPlans),
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
recordMemory context scope now priority session memoryType = recordTagged context scope now priority session memoryType Set.empty

recordTagged :: MemoryAccessContext -> MemoryScope -> UTCTime -> Int -> Maybe SessionId -> MemoryType -> Set.Set Text -> Eff AppEffects MemoryId
recordTagged context scope now priority session memoryType tags = do
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
          content = if Set.null tags then "content" else Text.replicate 1000 "complete 記憶🌱",
          priority,
          confidence = HighConfidence,
          tags,
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
  let filters = M.MemoryFilter (ExactScope entity) (Just MemoryActive) Nothing Nothing Nothing
      selection = M.FilteredMemories filters
      get req = right =<< M.getPageWithContext testContext selection req
  first <- get (page 3)
  second <- get (PageRequest 3 Forward first.pageInfo.endCursor)
  third <- get (PageRequest 3 Forward second.pageInfo.endCursor)
  check "all tied rows" (sort (map idText ids)) (sort (map (.memoryId) (nodes first <> nodes second <> nodes third)))
  back <- get (PageRequest 3 Backward second.pageInfo.startCursor)
  check "backward order" (map (.memoryId) (nodes first)) (map (.memoryId) (nodes back))
  prioritized <- right =<< M.getPageWithContext testContext (M.FilteredMemories (filters {Filter.target = NamespaceWide ns})) (page 1)
  check "native priority order" [idText global] (map (.memoryId) (nodes prioritized))
  let archive = ArchiveMemoryData {memoryId = global, memorySpaceId = memoryContextSpace testContext, actorPrincipal = memoryContextRecordedActor testContext, archivedAt = now}
  initial <- right =<< M.archiveWithContextChanged testContext archive
  duplicate <- right =<< M.archiveWithContextChanged testContext archive
  check "archive changed" (global, True) initial
  check "archive repeated" (global, False) duplicate
  counts <- right =<< M.getCountsWithContext testContext (M.FilteredMemories (filters {Filter.target = NamespaceWide ns, Filter.status = Nothing}))
  check "all statuses count" (8, 7, 1) (counts.total, counts.active, counts.archived)
  archived <- right =<< M.getPageWithContext testContext (M.FilteredMemories (filters {Filter.target = NamespaceWide ns, Filter.status = Just MemoryArchived})) (page 1)
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
  metadata <- walkForward (\req -> right =<< M.getMetadataPageWithContext testContext selection req)
  check "metadata shares cycle-safe chain semantics and order" (sort (map idText [a, b, c])) (map (.memoryId) metadata)
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
  let filters = M.MemoryFilter (NamespaceWide ns) Nothing Nothing (Just (idText sid)) Nothing
      get req = right =<< M.getPageWithContext testContext (M.FilteredMemories filters) req
  first <- get (page 2)
  second <- get (PageRequest 2 Forward first.pageInfo.endCursor)
  third <- get (PageRequest 2 Forward second.pageInfo.endCursor)
  sessionMetadata <- walkForward (\req -> right =<< M.getMetadataPageWithContext testContext (M.FilteredMemories filters) req)
  check "metadata native session order" (map idText (reverse inSession)) (map (.memoryId) sessionMetadata)
  check "session order ignores priority" (map idText (reverse inSession)) (map (.memoryId) (nodes first <> nodes second <> nodes third))
  back <- get (PageRequest 2 Backward second.pageInfo.startCursor)
  check "session backward order" (map (.memoryId) (nodes first)) (map (.memoryId) (nodes back))
  typed <- right =<< M.getPageWithContext testContext (M.FilteredMemories (M.MemoryFilter (NamespaceWide ns) Nothing (Just MemoryPreference) Nothing Nothing)) (page 100)
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
  memoryPage <- M.getPageWithContext writer (M.FilteredMemories (M.MemoryFilter (NamespaceWide ns) Nothing Nothing Nothing Nothing)) (page 1)
  memoryCounts <- M.getCountsWithContext writer (M.SupersessionChain "absent")
  check "all six reads refused" [True, True, True, True, True, True] [denied sessionPage, denied sessionCounts, denied turnsPage, denied relations, denied memoryPage, denied memoryCounts]
  -- The gate runs before page validation, so an invalid page cannot probe a refused space.
  invalid <- S.getPageWithContext writer (S.DelegationChildren (idText sid)) (page 101)
  check "permission before page size" True (denied invalid)

metadataPages :: Eff AppEffects ()
metadataPages = do
  now <- liftIO getCurrentTime
  ids <- replicateM 105 (record testContext entity now)
  let tags = Set.fromList ["tag-" <> Text.pack (show i) | i <- [1 :: Int .. 205]]
  tagged <- recordTagged testContext entity now 100 Nothing MemoryFact tags
  foreignId <- record otherContext entity now
  missing <- liftIO genMemoryId
  let selection = M.FilteredMemories (M.MemoryFilter (NamespaceWide ns) Nothing Nothing Nothing Nothing)
      get req = right =<< M.getMetadataPageWithContext testContext selection req
  rows <- walkForward get
  check "all metadata in native tie order" (sort (map idText (tagged : ids))) (map (.memoryId) rows)
  reverseRows <- walkBackward get
  check "reverse traversal returns complete population" rows reverseRows
  detail <- right =<< M.getMetadataWithContext testContext tagged
  rich <- right =<< M.getMemoryRowById testSpace tagged
  case (detail, rich) of
    (Just meta, Just row) -> do
      check "fixed count" 205 meta.tagCount
      check
        "all scalar fields retained"
        ((row.memorySpaceId, row.memoryId, row.agentId, row.sessionId, row.namespace, row.scopeKind, row.scopeRef, row.memoryType), (row.content, row.priority, row.confidence, row.status, row.supersededBy, row.supersedes, row.createdAt, row.updatedAt))
        ((meta.memorySpaceId, meta.memoryId, meta.agentId, meta.sessionId, meta.namespace, meta.scopeKind, meta.scopeRef, meta.memoryType), (meta.content, meta.priority, meta.confidence, meta.status, meta.supersededBy, meta.supersedes, meta.createdAt, meta.updatedAt))
    other -> liftIO (assertFailure (show other))
  forM_ [missing, foreignId] \mid -> do
    absent <- right =<< M.getMetadataWithContext testContext mid
    check "missing/foreign point is absent" Nothing absent
  checkPageBounds (M.getMetadataPageWithContext testContext selection)

walkForward :: (PageRequest -> Eff AppEffects (Connection a)) -> Eff AppEffects [a]
walkForward get = go Nothing
  where
    go cursor = do
      connection <- get (PageRequest 37 Forward cursor)
      rest <- if connection.pageInfo.hasNextPage then go connection.pageInfo.endCursor else pure []
      pure (nodes connection <> rest)

walkBackward :: (PageRequest -> Eff AppEffects (Connection a)) -> Eff AppEffects [a]
walkBackward get = go Nothing
  where
    go cursor = do
      connection <- get (PageRequest 37 Backward cursor)
      rest <- if connection.pageInfo.hasPreviousPage then go connection.pageInfo.startCursor else pure []
      pure (rest <> nodes connection)

checkPageBounds :: (PageRequest -> Eff AppEffects (Either BoundedReadError (Connection a))) -> Eff AppEffects ()
checkPageBounds get = do
  negative <- get (page (-1))
  oversized <- get (page 101)
  zero <- right =<< get (page 0)
  check "negative page" (Just (InvalidPageSize (NegativePageSize (-1)))) (pageError negative)
  check "oversized page" (Just (InvalidPageSize (PageSizeTooLarge 101 100))) (pageError oversized)
  check "zero page returns no edges" 0 (length zero.edges)

tagPages :: Eff AppEffects ()
tagPages = do
  now <- liftIO getCurrentTime
  let longTag = "a" <> Text.replicate 20000 "記憶🌱"
      tags = Set.insert longTag (Set.fromList ["tag-" <> Text.pack (show i) | i <- [1 :: Int .. 204]])
  mid <- recordTagged testContext entity now 100 Nothing MemoryFact tags
  short <- recordTagged testContext entity now 100 Nothing MemoryFact (Set.singleton "a")
  empty <- record testContext entity now
  foreignId <- record otherContext entity now
  missing <- liftIO genMemoryId
  let get req = do
        result <- right =<< M.getTagsPageWithContext testContext mid req
        maybe (liftIO (assertFailure "existing parent absent")) pure result
  forward <- walkForward get
  reverseRows <- walkBackward get
  check "all full values" (Set.toAscList tags) (map (.value) forward)
  check "no omitted or duplicate ordinals" [1 .. 205] (map (.ordinal) forward)
  check "backward traversal" forward reverseRows
  first <- get (page 1)
  shortFirst <- right =<< M.getTagsPageWithContext testContext short (page 1)
  check
    "cursor size independent of value length"
    (fmap (Text.length . cursorToText) (shortFirst >>= (.pageInfo.endCursor)))
    (Text.length . cursorToText <$> first.pageInfo.endCursor)
  checkPageBounds (\req -> fmap (fmap (fromMaybe (error "existing parent absent"))) (M.getTagsPageWithContext testContext mid req))
  emptyResult <- right =<< M.getTagsPageWithContext testContext empty (page 10)
  check "existing empty parent" (Just 0) (length . (.edges) <$> emptyResult)
  forM_ [missing, foreignId] \identity -> do
    result <- right =<< M.getTagsPageWithContext testContext identity (page 10)
    check "absent parent" Nothing result
    zero <- right =<< M.getTagsPageWithContext testContext identity (page 0)
    check "absent zero-size parent" Nothing zero
    invalid <- M.getTagsPageWithContext testContext identity (PageRequest 10 Forward (Just (Cursor "!")))
    check "invalid cursor does not become absence" True (case pageError invalid of Just (InvalidPageCursor _) -> True; _ -> False)
    forM_ [-1, 101] \n -> do
      failure <- M.getTagsPageWithContext testContext identity (page n)
      check "missing parent still validates size" True (case pageError failure of Just (InvalidPageSize _) -> True; _ -> False)
  _ <-
    right
      =<< M.archiveWithContext
        testContext
        ArchiveMemoryData
          { memoryId = mid,
            memorySpaceId = testSpace,
            actorPrincipal = memoryContextRecordedActor testContext,
            archivedAt = now
          }
  retained <- get (page 1)
  check "archived tags retained" [longTag] (map (.value) (nodes retained))
  archived <- right =<< M.getMetadataWithContext testContext mid
  check "archived metadata retained" (Just ("archived", 205)) ((\row -> (row.status, row.tagCount)) <$> archived)
  let replacement = Set.fromList ["replacement", "新しい"]
  _ <-
    right
      =<< M.updateTagsWithContext
        testContext
        UpdateMemoryTagsData
          { memoryId = short,
            memorySpaceId = testSpace,
            actorPrincipal = memoryContextRecordedActor testContext,
            tags = replacement,
            updatedAt = addUTCTime 1 now
          }
  replaced <-
    walkForward
      ( \req -> do
          result <- right =<< M.getTagsPageWithContext testContext short req
          maybe (liftIO (assertFailure "updated parent absent")) pure result
      )
  check "fresh traversal after update" (Set.toAscList replacement) (map (.value) replaced)
  metadata <- right =<< M.getMetadataWithContext testContext short
  check "updated scalar count" (Just 2) ((.tagCount) <$> metadata)

recencyAndKinds :: Eff AppEffects ()
recencyAndKinds = do
  now <- liftIO getCurrentTime
  globals <- replicateM 105 (recordWithPriority testContext (ScopeGlobal ns) now 1)
  let otherRef = ScopeEntity ns (ScopeKind "intention") "two"
      differentKind = ScopeEntity ns (ScopeKind "habit") "one"
      later = addUTCTime 10 now
  scoped <- forM [1 :: Int .. 105] \i -> recordWithPriority testContext (if even i then entity else otherRef) later 100
  sid <- start testContext entity later Nothing
  preference <- recordMemory testContext entity (addUTCTime 20 now) 100 (Just sid) MemoryPreference
  archived <- record testContext entity (addUTCTime 30 now)
  _ <-
    right
      =<< M.archiveWithContext
        testContext
        ArchiveMemoryData
          { memoryId = archived,
            memorySpaceId = testSpace,
            actorPrincipal = memoryContextRecordedActor testContext,
            archivedAt = addUTCTime 31 now
          }
  _ <- record otherContext entity (addUTCTime 40 now)
  habit <- record testContext differentKind later
  let filters = M.MemoryFilter (NamespaceWide ns) Nothing Nothing Nothing Nothing
      kind = filters {Filter.scopeKind = Just (ScopeKind "intention")}
      getNewest f = fmap (.memoryId) <$> (right =<< M.getNewestActiveMetadataWithContext testContext f)
      assertPopulation label f expected = do
        rich <- walkForward (\req -> right =<< M.getPageWithContext testContext (M.FilteredMemories f) req)
        metadata <- walkForward (\req -> right =<< M.getMetadataPageWithContext testContext (M.FilteredMemories f) req)
        counts <- right =<< M.getCountsWithContext testContext (M.FilteredMemories f)
        check (label <> " rich/metadata agree") (map (.memoryId) rich) (map (.memoryId) metadata)
        check (label <> " complete count") (fromIntegral expected) counts.total
        check (label <> " population") expected (length metadata)
  ordinary <- right =<< M.getPageWithContext testContext (M.FilteredMemories filters) (page 1)
  check "ordinary list chooses older priority one" [minimum (map idText globals)] (map (.memoryId) (nodes ordinary))
  newest <- getNewest filters
  check "recency ignores priority and archived/foreign newer rows" (Just (idText preference)) newest
  tied <- getNewest (kind {Filter.memoryType = Just MemoryFact})
  check "recency ties use ascending id" (Just (minimum (map idText scoped))) tied
  assertPopulation "namespace" filters 213
  assertPopulation "kind beyond first unfiltered page" kind 107
  kindCounts <- right =<< M.getCountsWithContext testContext (M.FilteredMemories kind)
  check "complete kind status scalars" (107, 106, 1, 0, 0) (kindCounts.total, kindCounts.active, kindCounts.archived, kindCounts.superseded, kindCounts.merged)
  assertPopulation "exact global" (filters {Filter.target = ExactScope (ScopeGlobal ns)}) 105
  assertPopulation "global plus entity kind" (kind {Filter.target = ExactScope (ScopeGlobal ns)}) 0
  assertPopulation "mismatched exact entity kind" (kind {Filter.target = ExactScope differentKind}) 0
  assertPopulation "exact entity intersection" (kind {Filter.target = ExactScope entity}) 54
  assertPopulation "kind/type/status/session" (kind {Filter.status = Just MemoryActive, Filter.memoryType = Just MemoryPreference, Filter.sessionId = Just (idText sid)}) 1
  assertPopulation "archived kind" (kind {Filter.status = Just MemoryArchived}) 1
  forM_ [filters {Filter.status = Just MemoryArchived}, kind {Filter.target = ExactScope (ScopeGlobal ns)}, kind {Filter.memoryType = Just MemoryConstraint}] \f -> do
    absent <- getNewest f
    check "incompatible/empty newest is absent" Nothing absent
  globalNewest <- getNewest (filters {Filter.target = ExactScope (ScopeGlobal ns)})
  check "exact global recency" (Just (minimum (map idText globals))) globalNewest
  exactNewest <- getNewest (kind {Filter.target = ExactScope entity})
  check "exact entity recency" (Just (idText preference)) exactNewest
  habitNewest <- getNewest (filters {Filter.scopeKind = Just (ScopeKind "habit")})
  check "kind selects independent vocabulary" (Just (idText habit)) habitNewest

-- Include valid, malformed and missing-parent inputs for every paged facade.
memoryProbes :: (IOE :> es, Store :> es) => MemoryAccessContext -> MemoryId -> Eff es [Either BoundedReadError ()]
memoryProbes context mid =
  sequence
    [ fmap (const ()) <$> M.getMetadataWithContext context mid,
      fmap (const ()) <$> M.getMetadataPageWithContext context selection (page 1),
      fmap (const ()) <$> M.getTagsPageWithContext context mid (page 1),
      fmap (const ()) <$> M.getNewestActiveMetadataWithContext context filters,
      fmap (const ()) <$> M.getCountsWithContext context selection
    ]
  where
    filters = M.MemoryFilter (NamespaceWide ns) Nothing Nothing Nothing (Just (ScopeKind "intention"))
    selection = M.FilteredMemories filters

deniedWithoutStore :: IO ()
deniedWithoutStore = do
  missing <- genMemoryId
  let writer = Internal.MemoryAccessContext {Internal.memorySpaceId = testSpace, Internal.actor = testActor, Internal.grantedPermissions = Set.singleton MemoryRecord, Internal.decisionToken = Nothing}
      filters = M.MemoryFilter (NamespaceWide ns) Nothing Nothing Nothing (Just (ScopeKind "intention"))
      selection = M.FilteredMemories filters
      run :: Eff '[Store, IOE] a -> IO a
      run = runEff . interpret_ (\_ -> liftIO (assertFailure "permission denial invoked Store"))
  results <- run do
    regular <- memoryProbes writer missing
    invalid <- forM [page (-1), page 101, PageRequest 1 Forward (Just (Cursor "!"))] \request -> do
      metadata <- M.getMetadataPageWithContext writer selection request
      tags <- M.getTagsPageWithContext writer missing request
      pure [fmap (const ()) metadata, fmap (const ()) tags]
    pure (regular <> concat invalid)
  assertEqual "every denial precedes Store and validation" (replicate 11 (Left (BoundedReadNotPermitted MemoryRead))) results

memoryFailures :: Eff AppEffects ()
memoryFailures = do
  missing <- liftIO genMemoryId
  let selection = M.FilteredMemories (M.MemoryFilter (NamespaceWide ns) Nothing Nothing Nothing Nothing)
  invalid <- M.getMetadataPageWithContext testContext selection (PageRequest 1 Forward (Just (Cursor "!")))
  check "metadata malformed cursor" True (case pageError invalid of Just (InvalidPageCursor _) -> True; _ -> False)
  healthy <- memoryProbes testContext missing
  check "absence is healthy" (replicate 5 (Right ())) healthy
  runTransaction (Tx.sql "UPDATE keiro.keiro_read_models SET version=0 WHERE name LIKE 'kioku-memory-%' OR name='kioku-memories-count'")
  stale <- memoryProbes testContext missing
  check "all new models and kind counts fail stale" True (all (\case Left (BoundedReadFailed (ReadModelStaleSchema {})) -> True; _ -> False) stale)
  _ <- reconcileReadModelRegistry
  runTransaction (Tx.sql "UPDATE keiro.keiro_read_models SET status='rebuilding' WHERE name LIKE 'kioku-memory-%' OR name='kioku-memories-count'")
  unavailable <- memoryProbes testContext missing
  check "rebuilding is unavailable" True (all (\case Left (BoundedReadFailed (ReadModelNotLive {})) -> True; _ -> False) unavailable)
  runTransaction (Tx.sql "DELETE FROM keiro.keiro_read_models WHERE name LIKE 'kioku-memory-%' OR name='kioku-memories-count'")
  absent <- memoryProbes testContext missing
  check "unregistered is distinct from absent Memory" True (all (\case Left (BoundedReadFailed (ReadModelUnregistered _)) -> True; _ -> False) absent)
  _ <- reconcileReadModelRegistry
  repaired <- memoryProbes testContext missing
  check "reconciled extended inventory serves reads" (replicate 5 (Right ())) repaired

storageFailures :: IO ()
storageFailures = withKiokuMigratedDatabase \conn -> withNoopAppEnv (defaultConnectionSettings conn) \env -> do
  missing <- genMemoryId
  renamed <- runAppIO env (runTransaction (Tx.sql "ALTER TABLE kioku.memories RENAME TO memories_unavailable"))
  either (assertFailure . show) pure renamed
  let filters = M.MemoryFilter (NamespaceWide ns) Nothing Nothing Nothing (Just (ScopeKind "intention"))
      selection = M.FilteredMemories filters
      probes =
        [ fmap (const ()) <$> M.getMetadataWithContext testContext missing,
          fmap (const ()) <$> M.getMetadataPageWithContext testContext selection (page 1),
          fmap (const ()) <$> M.getTagsPageWithContext testContext missing (page 1),
          fmap (const ()) <$> M.getNewestActiveMetadataWithContext testContext filters,
          fmap (const ()) <$> M.getCountsWithContext testContext selection
        ]
  forM_ probes \probe -> do
    result <- runAppIO env probe
    case result of
      Left _ -> pure ()
      Right other -> assertFailure ("storage failure was swallowed: " <> show other)

-- The direct SQL rows are planner-scale projection noise; semantic fixtures above
-- are written through real commands. No planner switches force an index choice.
memoryAccessPlans :: Eff AppEffects ()
memoryAccessPlans = do
  runTransaction
    ( Tx.sql
        """
        INSERT INTO kioku.memories
          (memory_space_id,memory_id,agent_id,namespace,scope_kind,scope_ref,memory_type,content,priority,confidence,tags,status,created_at,updated_at)
        SELECT 'plan-space-' || (i % 4), 'plan-memory-' || i, 'planner', 'bounded',
          CASE WHEN i % 8 < 4 THEN 'intention' ELSE 'habit' END, 'ref-' || (i % 50),
          'fact', repeat('content ',20), (i % 100)+1, 'high', '[]'::jsonb,
          CASE WHEN i % 5 = 0 THEN 'archived' ELSE 'active' END,
          '2026-01-01'::timestamptz + i * interval '1 second', '2026-01-01'::timestamptz
        FROM generate_series(1,40000) i;
        ANALYZE kioku.memories;
        """
    )
  forM_ [("namespace recency", ""), ("kind recency", " AND scope_kind='intention'")] \(label, kind) -> do
    explainPlan label ("SELECT memory_space_id,memory_id,agent_id,session_id,namespace,scope_kind,scope_ref,memory_type,content,priority,confidence,jsonb_array_length(tags)::bigint,status,superseded_by,supersedes,created_at,updated_at FROM kioku.memories WHERE memory_space_id='plan-space-1' AND namespace='bounded' AND status='active'" <> kind <> " ORDER BY created_at DESC,memory_id ASC LIMIT 1")
  explainPlan "metadata page" "SELECT memory_space_id,memory_id,agent_id,session_id,namespace,scope_kind,scope_ref,memory_type,content,priority,confidence,jsonb_array_length(tags)::bigint,status,superseded_by,supersedes,created_at,updated_at FROM kioku.memories WHERE memory_space_id='plan-space-1' AND namespace='bounded' ORDER BY priority ASC,created_at DESC,memory_id ASC LIMIT 38"

explainPlan :: Text -> Text -> Eff AppEffects ()
explainPlan label query = do
  rows <- runTransaction (Tx.statement () (preparable ("EXPLAIN (ANALYZE, BUFFERS) " <> query) E.noParams (D.rowList (D.column (D.nonNullable D.text)))))
  liftIO (putStrLn (Text.unpack ("\n" <> label <> "\n" <> Text.unlines rows)))
  check "plan uses a partition-first ordered index" True (any (Text.isInfixOf (if label == "metadata page" then "memories_space_namespace_page_idx" else "memories_space_active_recency_idx")) rows)
  check "plan needs no collection sort" False (any (Text.isInfixOf "Sort Key:") rows)
  check "plan retains space predicate" True (any (Text.isInfixOf "memory_space_id") rows)
