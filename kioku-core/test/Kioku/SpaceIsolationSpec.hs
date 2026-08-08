-- | Two memory spaces holding the same namespace, the same scope, the same content, and the
-- same derived artifact keys — and every public read returning only the one it was asked for.
--
-- "Kioku.MemorySpaceSpec" proves the write side: a command naming another space cannot change
-- anything. This module proves the read side, which is the half the schema had to grow a column
-- for. The fixture is deliberately maximal: if any query anywhere still ignored the partition,
-- these rows are indistinguishable by every other column and it would show up immediately.
--
-- The last group is about plans rather than rows. A predicate that is correct but unindexed
-- degrades into a scan of every space's data, which is a correctness-preserving way to leak
-- one tenant's load onto another; asserting the partition-leading index is chosen is what keeps
-- the boundary cheap as well as real.
module Kioku.SpaceIsolationSpec (tests) where

import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as TextIO
import Data.Text.Read qualified as Text.Read
import Data.Time (addUTCTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Kioku.Api.Access
  ( MemoryAccessContext,
    MemorySpaceId,
    memoryContextRecordedActor,
    memoryContextSpace,
    memorySpaceIdText,
  )
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (Confidence (..), MemoryRecord (..), MemoryType (..))
import Kioku.App (AppEffects, runAppIO, withNoopAppEnv)
import Kioku.Distill.L2 (SceneRow (..), getScenesByScope, mirrorSceneToWorkspace)
import Kioku.Distill.L3 (PersonaRow (..), getPersonaByScope, mirrorPersonaToWorkspace)
import Kioku.Id (MemoryId, SessionId, genMemoryId, genSessionId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Memory.ReadModel (MemoryRow (..))
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Prelude
import Kioku.ReadModel (ReadModelSchema (..), ReconcileOutcome (..), reconcileReadModelRegistry)
import Kioku.Recall qualified as Recall
import Kioku.Recall.Capability (VectorCapability (..))
import Kioku.Session qualified as Session
import Kioku.Session.Domain (AwaitInputData (..), RecordTurnData (..), StartSessionData (..))
import Kioku.Session.ReadModel (SessionRow (..), TurnRow (..))
import Kioku.SpaceFixtures (otherContext, otherSpace, testContext, testSpace)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Memory space read isolation"
    [ testCase "every memory read returns only the requested space" testMemoryReads,
      testCase "every session read returns only the requested space" testSessionReads,
      testCase "recall never crosses a space, however wide its scope" testRecallReads,
      testCase "scenes and personas with identical scope keys stay apart" testDerivedArtifacts,
      testCase "reconciliation leaves both spaces readable" testReconcileKeepsBothSpaces,
      testCase "every partitioned lookup has a partition-leading index" testPartitionLeadingPlans
    ]

-- * The fixture

-- | Both spaces get the same namespace, the same entity scope, and the same content. Only the
-- ids differ, and they have to: memory and session ids are globally unique by construction.
sharedNamespace :: Namespace
sharedNamespace = Namespace "kioku_shared"

sharedScope :: MemoryScope
sharedScope = ScopeEntity sharedNamespace (ScopeKind "repo") "web"

sharedContent :: Text
sharedContent = "identical in both spaces"

sharedFocus :: Text
sharedFocus = "identical focus"

sharedCorrelationKey :: Text
sharedCorrelationKey = "approval_req_shared"

-- | What one space's fixture produced, so an assertion can name the row it expects and the row
-- it must not see.
data SpaceFixture = SpaceFixture
  { space :: !MemorySpaceId,
    memoryId :: !MemoryId,
    sessionId :: !SessionId
  }

-- | Record one memory and one session, with a turn and a park, in the context's space.
seedSpace ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  Eff es SpaceFixture
seedSpace context = do
  mid <- liftIO genMemoryId
  sid <- liftIO genSessionId
  now <- liftIO getCurrentTime
  let space = memoryContextSpace context
      actor = memoryContextRecordedActor context

  started <-
    Session.startWithContext
      context
      StartSessionData
        { sessionId = sid,
          memorySpaceId = space,
          actorPrincipal = actor,
          ownerPrincipal = Nothing,
          agentId = "shared-agent",
          focus = sharedFocus,
          scope = sharedScope,
          subjectRef = Nothing,
          previousSessionId = Nothing,
          parentSessionId = Nothing,
          delegationDepth = 0,
          startedAt = now
        }
  expectRight "Session.startWithContext" started

  turned <-
    Session.recordTurnWithContext
      context
      RecordTurnData
        { sessionId = sid,
          memorySpaceId = space,
          actorPrincipal = actor,
          turnId = idText sid <> "-turn-1",
          turnIndex = 1,
          role = "user",
          content = sharedContent,
          toolSummary = Nothing,
          promptTokens = Nothing,
          outputTokens = Nothing,
          recordedAt = now
        }
  expectRight "Session.recordTurnWithContext" turned

  parked <-
    Session.awaitInputWithContext
      context
      AwaitInputData
        { sessionId = sid,
          memorySpaceId = space,
          actorPrincipal = actor,
          reason = "waiting",
          correlationKey = Just sharedCorrelationKey,
          deadline = Nothing,
          awaitedAt = now
        }
  expectRight "Session.awaitInputWithContext" parked

  recorded <-
    Memory.recordWithContext
      context
      RecordMemoryData
        { memoryId = mid,
          memorySpaceId = space,
          actorPrincipal = actor,
          ownerPrincipal = Nothing,
          agentId = "shared-agent",
          sessionId = Just sid,
          scope = sharedScope,
          memoryType = MemoryFact,
          content = sharedContent,
          priority = 100,
          confidence = HighConfidence,
          tags = Set.empty,
          supersedes = Nothing,
          recordedAt = now
        }
  expectRight "Memory.recordWithContext" recorded

  pure SpaceFixture {space, memoryId = mid, sessionId = sid}

expectRight :: (IOE :> es, Show e) => String -> Either e a -> Eff es ()
expectRight label = \case
  Left err -> liftIO (assertFailure (label <> ": " <> show err))
  Right _ -> pure ()

withBothSpaces :: ((SpaceFixture, SpaceFixture) -> Eff AppEffects ()) -> Assertion
withBothSpaces action =
  withApp do
    mine <- seedSpace testContext
    theirs <- seedSpace otherContext
    action (mine, theirs)

-- * Reads

testMemoryReads :: Assertion
testMemoryReads =
  withBothSpaces \(mine, theirs) -> do
    -- By id, both directions. The id is globally unique, so this is the case where only the
    -- predicate can be doing the work.
    Memory.getMemoryRowById mine.space mine.memoryId
      >>= expectRows "my memory by id, in my space" [idText mine.memoryId] (fmap (\row -> row.memoryId) . maybe [] pure)
    Memory.getMemoryRowById mine.space theirs.memoryId
      >>= expectRows "their memory by id, in my space" [] (fmap (\row -> row.memoryId) . maybe [] pure)

    Memory.getActiveRowsInNamespace mine.space sharedNamespace
      >>= expectRows "namespace read" [idText mine.memoryId] (fmap (\row -> row.memoryId))
    Memory.getActiveRowsByScope mine.space sharedScope
      >>= expectRows "scope read" [idText mine.memoryId] (fmap (\row -> row.memoryId))
    Memory.getRowsBySession mine.space mine.sessionId
      >>= expectRows "session read" [idText mine.memoryId] (fmap (\row -> row.memoryId))
    Memory.getActiveRowsByType mine.space sharedNamespace MemoryFact
      >>= expectRows "type read" [idText mine.memoryId] (fmap (\row -> row.memoryId))
    Memory.getSupersessionChain mine.space mine.memoryId
      >>= expectRows "supersession chain" [idText mine.memoryId] (fmap (\row -> row.memoryId))

    -- The other space's session id names a session that exists, in another space. A memory
    -- read keyed by it must return nothing rather than the other space's memory.
    Memory.getRowsBySession mine.space theirs.sessionId
      >>= expectRows "their session, in my space" [] (fmap (\row -> row.memoryId))
    Memory.getSupersessionChain mine.space theirs.memoryId
      >>= expectRows "their chain, in my space" [] (fmap (\row -> row.memoryId))

testSessionReads :: Assertion
testSessionReads =
  withBothSpaces \(mine, theirs) -> do
    Session.getById mine.space mine.sessionId
      >>= expectRows "my session by id" [idText mine.sessionId] (fmap (\row -> row.sessionId) . maybe [] pure)
    Session.getById mine.space theirs.sessionId
      >>= expectRows "their session by id, in my space" [] (fmap (\row -> row.sessionId) . maybe [] pure)

    Session.getRecentInNamespace mine.space sharedNamespace 10
      >>= expectRows "namespace list" [idText mine.sessionId] (fmap (\row -> row.sessionId))
    Session.getByScope mine.space sharedScope
      >>= expectRows "scope list" [idText mine.sessionId] (fmap (\row -> row.sessionId))
    Session.getByFocus mine.space sharedNamespace sharedFocus
      >>= expectRows "focus list" [idText mine.sessionId] (fmap (\row -> row.sessionId))
    Session.getAwaitingByCorrelationKey mine.space sharedNamespace sharedCorrelationKey
      >>= expectRows "awaiting by correlation key" [idText mine.sessionId] (fmap (\row -> row.sessionId))
    Session.getChain mine.space mine.sessionId
      >>= expectRows "chain" [idText mine.sessionId] (fmap (\row -> row.sessionId))
    Session.getTurns mine.space mine.sessionId
      >>= expectRows "turns" [idText mine.sessionId <> "-turn-1"] (fmap (\row -> row.turnId))
    Session.getTurns mine.space theirs.sessionId
      >>= expectRows "their turns, in my space" [] (fmap (\row -> row.turnId))

    now <- liftIO getCurrentTime
    Session.getByStartedRange mine.space sharedNamespace (addHours (-1) now) (addHours 1 now)
      >>= expectRows "started range" [idText mine.sessionId] (fmap (\row -> row.sessionId))

-- | Recall's global scope means \"every scope in this namespace\", which is the widest target
-- the current API can express. It must still stop at the space boundary — a target that widens
-- the scope must never widen the tenancy.
testRecallReads :: Assertion
testRecallReads =
  withBothSpaces \(mine, theirs) -> do
    Recall.getActiveByScope mine.space sharedScope
      >>= expectRows "exact scope" [idText mine.memoryId] (fmap (\r -> r.memoryId))
    Recall.getActiveInNamespace mine.space sharedNamespace
      >>= expectRows "whole namespace" [idText mine.memoryId] (fmap (\r -> r.memoryId))
    Recall.getGlobal mine.space sharedNamespace
      >>= expectRows "global bucket" [] (fmap (\r -> r.memoryId))
    Recall.getById mine.space theirs.memoryId
      >>= expectRows "their memory by id" [] (fmap (\r -> r.memoryId) . maybe [] pure)
    Recall.getBySession mine.space mine.sessionId
      >>= expectRows "by session" [idText mine.memoryId] (fmap (\r -> r.memoryId))
    Recall.getByType mine.space sharedNamespace MemoryFact
      >>= expectRows "by type" [idText mine.memoryId] (fmap (\r -> r.memoryId))

    -- The keyword channel, which is the one that runs without an embedding endpoint. Its
    -- namespace-wide form is the widest read in the codebase, and the space it searches comes
    -- from the context rather than from the request -- so there is no argument a caller could
    -- pass here that would reach the other space.
    hits <-
      Recall.recall
        undefinedModel
        VectorExtensionUnavailable
        testContext
        Recall.RecallQuery
          { target = Recall.NamespaceWide sharedNamespace,
            query = "identical",
            strategy = Recall.Keyword,
            maxResults = expectValidLimit 10
          }
    liftIO $
      case hits of
        Left err -> assertFailure ("recall refused: " <> show err)
        Right rows ->
          assertEqual
            "namespace-wide keyword recall stays in its space"
            [idText mine.memoryId]
            (sort ((\hit -> hit.memory.memoryId) <$> rows))
  where
    -- The keyword channel never embeds, and 'VectorExtensionUnavailable' makes that a
    -- guarantee rather than a hope: 'planRecallExecution' returns a keyword-only plan, so the
    -- model is never forced.
    undefinedModel = error "the keyword channel must not embed"

    expectValidLimit =
      either (error . Text.unpack) id . Recall.mkRecallLimit

-- | Scene and persona ids are derived from the scope alone, so both spaces derive the same
-- ones. They are inserted directly rather than distilled, because what is under test is the
-- read: an LLM is not needed to prove that two rows with one id stay apart.
testDerivedArtifacts :: Assertion
testDerivedArtifacts =
  withApp do
    runTransaction (Tx.sql (encodeUtf8 (derivedArtifactRows testSpace "mine")))
    runTransaction (Tx.sql (encodeUtf8 (derivedArtifactRows otherSpace "theirs")))

    mineScenes <- getScenesByScope testSpace sharedScope
    theirsScenes <- getScenesByScope otherSpace sharedScope
    minePersona <- getPersonaByScope testSpace sharedScope
    theirsPersona <- getPersonaByScope otherSpace sharedScope

    liftIO do
      assertEqual "my scene" ["mine"] ((\row -> row.title) <$> mineScenes)
      assertEqual "their scene" ["theirs"] ((\row -> row.title) <$> theirsScenes)
      assertEqual "my persona" (Just "mine") ((\row -> row.bodyMd) <$> minePersona)
      assertEqual "their persona" (Just "theirs") ((\row -> row.bodyMd) <$> theirsPersona)
      -- Same derived id, two rows. Before the primary key became composite, the second insert
      -- would have replaced the first through the upsert's ON CONFLICT clause.
      assertEqual
        "both spaces derived the same scene id"
        ((\row -> row.sceneId) <$> mineScenes)
        ((\row -> row.sceneId) <$> theirsScenes)

    -- The same collision, one layer out. The scope slug in the filename is derived from the
    -- namespace, kind, and ref alone, so these four rows produce two filenames; only the
    -- per-space directory keeps them apart. Written for real rather than compared as strings,
    -- because a path that differs but resolves to the same file on a case-folding filesystem
    -- would still lose one space's mirror.
    liftIO $ withSystemTempDirectory "kioku-space-mirrors" \workspace -> do
      mineScenePaths <- traverse (mirrorSceneToWorkspace workspace) mineScenes
      theirsScenePaths <- traverse (mirrorSceneToWorkspace workspace) theirsScenes
      minePersonaPath <- traverse (mirrorPersonaToWorkspace workspace) minePersona
      theirsPersonaPath <- traverse (mirrorPersonaToWorkspace workspace) theirsPersona

      assertBool
        ("the two spaces' scene mirrors are the same file: " <> show mineScenePaths)
        (mineScenePaths /= theirsScenePaths)
      assertBool
        ("the two spaces' persona mirrors are the same file: " <> show minePersonaPath)
        (minePersonaPath /= theirsPersonaPath)

      traverse_ (assertFileContains "my scene mirror" "mine") mineScenePaths
      traverse_ (assertFileContains "their scene mirror" "theirs") theirsScenePaths
      traverse_ (assertFileContains "my persona mirror" "mine") minePersonaPath
      traverse_ (assertFileContains "their persona mirror" "theirs") theirsPersonaPath

assertFileContains :: String -> Text -> FilePath -> Assertion
assertFileContains label needle path = do
  body <- TextIO.readFile path
  assertBool
    (label <> " at " <> path <> " does not contain " <> Text.unpack needle <> ": " <> Text.unpack body)
    (needle `Text.isInfixOf` body)

derivedArtifactRows :: MemorySpaceId -> Text -> Text
derivedArtifactRows space marker =
  "INSERT INTO kioku.scenes\
  \ (memory_space_id, scene_id, namespace, scope_kind, scope_ref, scene_key, title, body_md, source_hash)\
  \ VALUES ('"
    <> memorySpaceIdText space
    <> "', 'kioku_scene:kioku_shared/repo/web:default', 'kioku_shared', 'repo', 'web', 'default', '"
    <> marker
    <> "', 'body', 'hash');\
       \ INSERT INTO kioku.personas\
       \ (memory_space_id, persona_id, namespace, scope_kind, scope_ref, body_md, source_hash)\
       \ VALUES ('"
    <> memorySpaceIdText space
    <> "', 'kioku_persona:kioku_shared/repo/web', 'kioku_shared', 'repo', 'web', '"
    <> marker
    <> "', 'hash')"

-- | The registry guard moved with the schema: memory models to v2, sessions to v4, turns to v2.
-- A database that has just been migrated must therefore report every model already current, and
-- both spaces must still be readable afterwards — the version bump is a guard advance, not a
-- rebuild, and a rebuild would be the thing that could lose a space.
testReconcileKeepsBothSpaces :: Assertion
testReconcileKeepsBothSpaces =
  withBothSpaces \(mine, theirs) -> do
    outcomes <- reconcileReadModelRegistry
    liftIO $
      assertEqual
        "a freshly migrated database has nothing to reconcile"
        ([] :: [Text])
        [schema.readModelName | (schema, outcome) <- outcomes, outcome /= AlreadyCurrent]

    Memory.getActiveRowsByScope mine.space sharedScope
      >>= expectRows "my space still reads" [idText mine.memoryId] (fmap (\row -> row.memoryId))
    Memory.getActiveRowsByScope theirs.space sharedScope
      >>= expectRows "their space still reads" [idText theirs.memoryId] (fmap (\row -> row.memoryId))

-- * Plans

-- | Every plan below must reach its rows through an index whose leading column is
-- @memory_space_id@, and must not fall back to a scan of the whole table.
--
-- The SQL here is a copy of the shipped statements, which is a real hazard — the recall
-- harness's copy silently drifted out of date the moment this partition landed and started
-- reporting a plan no live query could produce. So each case also runs the public read it
-- claims to describe and asserts the plan's own row count matches what that read returned. A
-- copy that has drifted apart from the statement it mirrors fails there.
testPartitionLeadingPlans :: Assertion
testPartitionLeadingPlans =
  withBothSpaces \(mine, _theirs) -> do
    -- @enable_seqscan = off@ does not make the planner use the index we want; it removes the
    -- alternative that a four-row test table would otherwise always make cheapest, so that the
    -- question being asked is "is a partition-leading index available and applicable" rather
    -- than "is this table big enough to bother".
    memoriesByScope <-
      explainPartitioned
        mine.space
        "SELECT memory_id FROM kioku.memories WHERE status = 'active' AND memory_space_id = $1 \
        \AND namespace = 'kioku_shared' AND ((scope_kind = 'repo' AND scope_ref = 'web') \
        \OR (NULL IS NULL AND scope_kind IS NULL AND NULL IS NULL AND scope_ref IS NULL)) \
        \ORDER BY priority ASC, created_at DESC"
    memoriesByType <-
      explainPartitioned
        mine.space
        "SELECT memory_id FROM kioku.memories WHERE status = 'active' AND memory_space_id = $1 \
        \AND namespace = 'kioku_shared' AND memory_type = 'fact' ORDER BY priority ASC, created_at DESC"
    sessionsByNamespace <-
      explainPartitioned
        mine.space
        "SELECT session_id FROM kioku.sessions WHERE memory_space_id = $1 \
        \AND namespace = 'kioku_shared' ORDER BY started_at DESC LIMIT 10"
    sessionsAwaiting <-
      explainPartitioned
        mine.space
        "SELECT session_id FROM kioku.sessions WHERE memory_space_id = $1 \
        \AND namespace = 'kioku_shared' AND status = 'awaiting' \
        \AND awaiting_correlation_key = 'approval_req_shared' ORDER BY started_at DESC"

    scopeRows <- rowCount <$> Memory.getActiveRowsByScope mine.space sharedScope
    typeRows <- rowCount <$> Memory.getActiveRowsByType mine.space sharedNamespace MemoryFact
    namespaceSessions <- rowCount <$> Session.getRecentInNamespace mine.space sharedNamespace 10
    awaitingSessions <-
      rowCount <$> Session.getAwaitingByCorrelationKey mine.space sharedNamespace sharedCorrelationKey

    liftIO $
      mapM_
        assertPartitionLeading
        [ ("memories by scope", "kioku_memories_space_", memoriesByScope, scopeRows),
          ("memories by type", "kioku_memories_space_", memoriesByType, typeRows),
          ("sessions by namespace", "kioku_sessions_space_", sessionsByNamespace, namespaceSessions),
          ("sessions awaiting", "kioku_sessions_space_", sessionsAwaiting, awaitingSessions)
        ]
  where
    rowCount = either (const (-1)) length

-- | What is asserted is the plan /shape/, not which particular index won.
--
-- The migration installs several partition-first indexes on each table and they overlap on
-- their @(memory_space_id, namespace)@ prefix, so the planner is free to choose between them —
-- and it does: the by-scope query is served by @kioku_memories_space_namespace_idx@ rather than
-- @…_space_scope_idx@, because the scope predicate is a disjunction that no index can answer
-- and the namespace index also supplies the @ORDER BY@. Pinning the winner would make this case
-- fail on a better plan. What must hold is that /some/ partition-first index on the right table
-- was used, that the space was an index condition rather than a filter applied afterwards, and
-- that nothing fell back to reading every space's rows.
assertPartitionLeading :: (String, Text, Text, Int) -> Assertion
assertPartitionLeading (label, indexPrefix, plan, expectedRows) = do
  assertBool
    ( label
        <> ": no index named "
        <> Text.unpack indexPrefix
        <> "* appears in the plan:\n"
        <> Text.unpack plan
    )
    (indexPrefix `Text.isInfixOf` plan)
  assertBool
    (label <> ": the index condition does not mention memory_space_id:\n" <> Text.unpack plan)
    (any (\line -> "Index Cond" `Text.isInfixOf` line && "memory_space_id" `Text.isInfixOf` line) (Text.lines plan))
  assertBool
    (label <> ": the plan falls back to a scan of every space:\n" <> Text.unpack plan)
    (not ("Seq Scan" `Text.isInfixOf` plan))
  assertEqual
    (label <> ": the explained query is not the one the read function runs:\n" <> Text.unpack plan)
    expectedRows
    (planTopRows plan)

-- | The @rows=N@ of the plan's outermost node, as @EXPLAIN ANALYZE@ actually observed it —
-- the @rows=@ that follows @actual time=@, not the planner's estimate that precedes it.
planTopRows :: Text -> Int
planTopRows plan =
  case Text.lines plan of
    line : _ ->
      case Text.splitOn "rows=" (snd (Text.breakOn "actual time=" line)) of
        _ : rest : _ -> either (const (-1)) fst (Text.Read.decimal rest)
        _ -> -1
    [] -> -1

explainPartitioned :: (Store :> es) => MemorySpaceId -> Text -> Eff es Text
explainPartitioned space sql =
  Text.unlines <$> runTransaction do
    Tx.sql "SET LOCAL enable_seqscan = off"
    Tx.statement space (explainStmt sql)

explainStmt :: Text -> Statement MemorySpaceId [Text]
explainStmt sql =
  preparable
    ("EXPLAIN (ANALYZE, BUFFERS) " <> sql)
    (memorySpaceIdText >$< E.param (E.nonNullable E.text))
    (D.rowList (D.column (D.nonNullable D.text)))

-- * Helpers

expectRows ::
  (IOE :> es, Show e) =>
  String ->
  [Text] ->
  (a -> [Text]) ->
  Either e a ->
  Eff es ()
expectRows label expected project = \case
  Left err -> liftIO (assertFailure (label <> ": " <> show err))
  Right value -> liftIO (assertEqual label (sort expected) (sort (project value)))

addHours :: Int -> UTCTime -> UTCTime
addHours hours = addUTCTime (fromIntegral (hours * 3600))

withApp :: Eff AppEffects a -> IO a
withApp action =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) \env -> do
      result <- runAppIO env action
      case result of
        Left storeErr -> assertFailure ("store error: " <> show storeErr)
        Right value -> pure value
