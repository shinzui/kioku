-- | The fail-closed outage and its repair, end to end.
--
-- Keiro refuses to serve a read model whose registry row disagrees with the code's
-- declared version — a deliberate safety property. The hazard is that nothing used to
-- bring those rows back into agreement: 'Keiro.ReadModel.Schema.registerReadModel' only
-- inserts, so an additive migration that advances a model's version leaves every query
-- for it failing with 'ReadModelStaleSchema' until a human hand-writes a registry
-- migration. That is not hypothetical; it is what happened when the session models went
-- v1 -> v2 -> v3.
--
-- 'reconcileReadModelRegistry' is the repair, and this spec walks the whole arc: startup
-- registration, a healthy query, a downgraded registry row, the resulting outage, the
-- reconcile, and the query working again.
--
-- The relocation of the projections into the @kioku@ schema (migration 0012) leans on the same
-- guard for a second purpose. Nothing in the registry records /where/ a projection physically
-- lives, so the only way to stop a binary from the wrong side of that migration serving traffic
-- is to advance the declared version — memory v2 -> v3, session v4 -> v5, turn v2 -> v3 — and
-- let the check refuse the disagreement in both directions.
module Kioku.ReadModelReconcileSpec (tests) where

import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Time (getCurrentTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import Hasql.Transaction qualified as Tx
import Keiro.ReadModel
  ( ConsistencyMode (Eventual),
    ReadModel (..),
    ReadModelError (..),
    runQueryWith,
  )
import Kioku.Api.Scope (MemoryScope (..), Namespace (..))
import Kioku.App (AppEffects, runAppIO, withNoopAppEnv)
import Kioku.Id (SessionId, genMemoryId, genSessionId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Prelude
import Kioku.ReadModel
  ( ReadModelSchema (..),
    ReconcileOutcome (..),
    kiokuReadModelSchemas,
    reconcileReadModelRegistry,
  )
import Kioku.Session qualified as Session
import Kioku.Session.Domain (StartSessionData (..))
import Kioku.Session.ReadModel qualified as Session
import Kioku.SpaceFixtures (testActorPrincipal, testContext, testSpace)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "ReadModel.Reconcile"
    [ testCase "the pre-relocation registry fails every query closed, then reconciles" testStaleThenReconcile,
      testCase "reconciliation is idempotent" testIdempotent,
      testCase "a binary declaring a pre-relocation identity fails closed" testOldBinaryFailsClosed
    ]

-- | The whole arc. Each step is asserted, including the outage itself — without that
-- assertion the test could pass against a build where the guard never fires at all.
--
-- The registry state it starts from is not invented: it is exactly what a database looks like
-- in the instant after migration 0012 commits. The seven projections have moved to the @kioku@
-- schema, the binary declares memory v3 \/ session v5 \/ turn v3, and every registry row still
-- says v2 \/ v4 \/ v2. Keiro records no physical relation name, so this version disagreement is
-- the only thing standing between an unreconciled deployment and SQL aimed at relations that
-- are no longer where the old code thinks they are.
testStaleThenReconcile :: Assertion
testStaleThenReconcile =
  withApp \sid -> do
    -- Application startup registered every model at the identity the code declares.
    healthy <- Session.getById testSpace sid
    liftIO $ assertBool "a fresh database serves session queries" (isRight healthy)

    downgradeToPreRelocationIdentities

    stale <- Session.getById testSpace sid
    liftIO case stale of
      Left (ReadModelStaleSchema name expectedVersion foundVersion expectedHash foundHash) -> do
        assertEqual "the stale model" "kioku-session-by-id" name
        assertEqual "expected version" 5 expectedVersion
        assertEqual "found version" 4 foundVersion
        assertEqual "expected hash" "kioku-session-v5" expectedHash
        assertEqual "found hash" "kioku-session-v4" foundHash
      other ->
        assertFailure
          ("expected the session query to fail closed on the stale row, got " <> show (() <$ other))

    -- The memory family moved too, so it must be just as closed. A relocation that bumped only
    -- the session identity would leave memory reads running against a vanished relation.
    -- Any id at all: the guard runs before the query, and on the repaired path finding no row
    -- is a success.
    probeMemoryId <- genMemoryId
    staleMemory <- Memory.getMemoryRowById testSpace probeMemoryId
    liftIO case staleMemory of
      Left (ReadModelStaleSchema name _ _ expectedHash foundHash) -> do
        assertEqual "the stale model" "kioku-memory-by-id" name
        assertEqual "expected hash" "kioku-memory-v3" expectedHash
        assertEqual "found hash" "kioku-memory-v2" foundHash
      other ->
        assertFailure
          ("expected the memory query to fail closed on the stale row, got " <> show (() <$ other))

    outcomes <- reconcileReadModelRegistry
    liftIO do
      assertEqual
        "every declared model was accounted for"
        (map (.readModelName) kiokuReadModelSchemas)
        (map ((.readModelName) . fst) outcomes)
      -- Every Kioku read model reads one of the three relocated projections, so the relocation
      -- leaves none of them current and reconciliation has to advance all of them.
      assertEqual
        "every model was advanced"
        []
        [schema.readModelName | (schema, outcome) <- outcomes, outcome /= Reconciled]

    repaired <- Session.getById testSpace sid
    liftIO $ assertBool "the session query works again" (isRight repaired)
    repairedMemory <- Memory.getMemoryRowById testSpace probeMemoryId
    liftIO $ assertBool "the memory query works again" (isRight repairedMemory)

-- | The other direction of the same guard, and the one that makes the deployment order safe:
-- against a reconciled registry, code still declaring the pre-relocation identity is refused.
--
-- That is what stops an old binary — one whose SQL still says @kiroku.kioku_sessions@ — from
-- serving traffic after the migration. It fails closed on the registry check before it ever
-- reaches a relation that has moved.
testOldBinaryFailsClosed :: Assertion
testOldBinaryFailsClosed =
  withApp \sid -> do
    _ <- reconcileReadModelRegistry
    result <-
      runQueryWith
        Nothing
        Eventual
        preRelocationSessionByIdReadModel
        Session.SessionByIdQuery {memorySpaceId = testSpace, sessionId = idText sid}
    liftIO case result of
      Left (ReadModelStaleSchema name expectedVersion foundVersion _ _) -> do
        assertEqual "the stale model" "kioku-session-by-id" name
        assertEqual "the old binary's declared version" 4 expectedVersion
        assertEqual "the reconciled row" 5 foundVersion
      other ->
        assertFailure
          ("expected the pre-relocation read model to be refused, got " <> show (() <$ other))

-- | The session read model exactly as the previous release declared it: same name, same query,
-- the identity it carried before the projections moved.
preRelocationSessionByIdReadModel :: ReadModel Session.SessionByIdQuery (Maybe Session.SessionRow)
preRelocationSessionByIdReadModel =
  Session.sessionByIdReadModel {version = 4, shapeHash = "kioku-session-v4"}

-- | A second pass must write nothing. If it reported 'Reconciled' again, the reconciler
-- would be rewriting @last_built_at@ on every @just migrate@ — and, worse, would be lying
-- about what it changed.
testIdempotent :: Assertion
testIdempotent =
  withApp \sid -> do
    void (Session.getById testSpace sid)
    _ <- reconcileReadModelRegistry
    second <- reconcileReadModelRegistry
    liftIO $
      assertEqual
        "every model is already current on the second pass"
        []
        [schema.readModelName | (schema, outcome) <- second, outcome /= AlreadyCurrent]

-- | Pin every registry row back to the identity it carried before the projections moved into
-- the @kioku@ schema. Written as three targeted updates keyed on the /current/ shape hash, so a
-- future family this test does not know about is left alone rather than silently swept along.
downgradeToPreRelocationIdentities :: (Store :> es) => Eff es ()
downgradeToPreRelocationIdentities =
  runTransaction . Tx.sql . encodeUtf8 . Text.concat $
    [ downgrade 4 "kioku-session-v4" "kioku-session-v5",
      downgrade 2 "kioku-memory-v2" "kioku-memory-v3",
      downgrade 2 "kioku-turn-v2" "kioku-turn-v3"
    ]
  where
    downgrade previousVersion previousHash currentHash =
      "UPDATE keiro.keiro_read_models SET version = "
        <> Text.pack (show (previousVersion :: Int))
        <> ", shape_hash = '"
        <> previousHash
        <> "' WHERE shape_hash = '"
        <> currentHash
        <> "';"

isRight :: Either e a -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False

-- * Harness

withApp :: (SessionId -> Eff AppEffects ()) -> Assertion
withApp use =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) \env -> do
      sid <- genSessionId
      result <- runAppIO env (startFixture sid >> use sid)
      case result of
        Left err -> assertFailure ("store error: " <> show err)
        Right () -> pure ()

startFixture ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  Eff es ()
startFixture sid = do
  now <- liftIO getCurrentTime
  result <-
    Session.startWithContext
      testContext
      StartSessionData
        { sessionId = sid,
          memorySpaceId = testSpace,
          actorPrincipal = testActorPrincipal,
          ownerPrincipal = Nothing,
          agentId = "test-agent",
          focus = "read-model reconciliation",
          scope = ScopeGlobal (Namespace "kioku-test"),
          subjectRef = Nothing,
          previousSessionId = Nothing,
          parentSessionId = Nothing,
          delegationDepth = 0,
          startedAt = now
        }
  case result of
    Left err -> liftIO (assertFailure ("Session.startWithContext testContext: " <> show err))
    Right _ -> pure ()
