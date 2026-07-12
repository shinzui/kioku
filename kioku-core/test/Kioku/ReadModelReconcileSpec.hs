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
-- 'reconcileReadModelRegistry' is the repair, and this spec walks the whole arc: a healthy
-- query, a downgraded registry row, the resulting outage, the reconcile, and the query
-- working again.
module Kioku.ReadModelReconcileSpec (tests) where

import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Time (getCurrentTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import Hasql.Transaction qualified as Tx
import Keiro.ReadModel (ReadModelError (..))
import Kioku.Api.Scope (MemoryScope (..), Namespace (..))
import Kioku.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Kioku.Id (SessionId, genSessionId)
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
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "ReadModel.Reconcile"
    [ testCase "a stale registry row fails every query closed, then reconciles" testStaleThenReconcile,
      testCase "reconciliation is idempotent" testIdempotent
    ]

-- | The whole arc. Each step is asserted, including the outage itself — without that
-- assertion the test could pass against a build where the guard never fires at all.
testStaleThenReconcile :: Assertion
testStaleThenReconcile =
  withApp \sid -> do
    -- A first query registers the session models at the identity the code declares.
    healthy <- Session.getById sid
    liftIO $ assertBool "a fresh database serves session queries" (isRight healthy)

    downgradeSessionByIdTo 2 "kioku-session-v2"

    stale <- Session.getById sid
    liftIO case stale of
      Left (ReadModelStaleSchema name expectedVersion foundVersion expectedHash foundHash) -> do
        assertEqual "the stale model" "kioku-session-by-id" name
        assertEqual "expected version" 3 expectedVersion
        assertEqual "found version" 2 foundVersion
        assertEqual "expected hash" "kioku-session-v3" expectedHash
        assertEqual "found hash" "kioku-session-v2" foundHash
      other ->
        assertFailure
          ("expected the query to fail closed on the stale row, got " <> show (() <$ other))

    outcomes <- reconcileReadModelRegistry
    liftIO do
      assertEqual
        "the downgraded row was bumped back"
        (Just Reconciled)
        (outcomeFor "kioku-session-by-id" outcomes)
      -- Reconciliation must cover every model the code declares, not just the ones this
      -- test happened to query. The rest have no registry row at all — only
      -- kioku-session-by-id was ever queried — so they are inserted rather than repaired.
      assertEqual
        "every declared model was accounted for"
        (map (.readModelName) kiokuReadModelSchemas)
        (map ((.readModelName) . fst) outcomes)
      assertEqual
        "the models that were never queried got fresh rows"
        []
        [ schema.readModelName
        | (schema, outcome) <- outcomes,
          schema.readModelName /= "kioku-session-by-id",
          outcome /= Registered
        ]

    repaired <- Session.getById sid
    liftIO $ assertBool "the query works again" (isRight repaired)

-- | A second pass must write nothing. If it reported 'Reconciled' again, the reconciler
-- would be rewriting @last_built_at@ on every @just migrate@ — and, worse, would be lying
-- about what it changed.
testIdempotent :: Assertion
testIdempotent =
  withApp \sid -> do
    void (Session.getById sid)
    _ <- reconcileReadModelRegistry
    second <- reconcileReadModelRegistry
    liftIO $
      assertEqual
        "every model is already current on the second pass"
        []
        [schema.readModelName | (schema, outcome) <- second, outcome /= AlreadyCurrent]

-- | Pin the registry row back to an older identity, exactly as a database that missed the
-- v3 bump would have it. The name is unqualified so it resolves through the store's
-- @search_path@, precisely as keiro's own registry statements do.
downgradeSessionByIdTo :: (Store :> es) => Int -> Text -> Eff es ()
downgradeSessionByIdTo version shapeHash =
  runTransaction . Tx.sql . encodeUtf8 $
    "UPDATE keiro.keiro_read_models SET version = "
      <> Text.pack (show version)
      <> ", shape_hash = '"
      <> shapeHash
      <> "' WHERE name = 'kioku-session-by-id'"

outcomeFor :: Text -> [(ReadModelSchema, ReconcileOutcome)] -> Maybe ReconcileOutcome
outcomeFor name outcomes =
  lookup name [(schema.readModelName, outcome) | (schema, outcome) <- outcomes]

isRight :: Either e a -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False

-- * Harness

withApp :: (SessionId -> Eff AppEffects ()) -> Assertion
withApp use =
  withKiokuMigratedDatabase \connStr ->
    withStore (defaultConnectionSettings connStr) \st -> do
      tracer <- noopTracer
      sid <- genSessionId
      let env = AppEnv {store = st, tracer, metrics = Nothing}
      result <- runAppIO env (startFixture sid >> use sid)
      case result of
        Left err -> assertFailure ("store error: " <> show err)
        Right () -> pure ()

startFixture ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  Eff es ()
startFixture sid = do
  now <- liftIO getCurrentTime
  result <-
    Session.start
      StartSessionData
        { sessionId = sid,
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
    Left err -> liftIO (assertFailure ("Session.start: " <> show err))
    Right _ -> pure ()
