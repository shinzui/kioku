module Kioku.SessionLineageSpec (tests) where

import Control.Monad (void)
import Data.List (sort)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import Hasql.Transaction qualified as Tx
import Kioku.Api.Scope (MemoryScope (..), Namespace (..))
import Kioku.App (runAppIO, withNoopAppEnv)
import Kioku.Id (SessionId, genSessionId, idText)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Session qualified as Session
import Kioku.Session.Domain (StartSessionData (..))
import Kioku.Session.ReadModel (SessionRow (..))
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Test.Tasty (TestTree, localOption, mkTimeout, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Session.Lineage"
    [ testCase "child sessions record parent id and delegation depth" testDelegationLineage,
      testGroup
        "start rejects malformed lineage"
        [ testCase "a session that is its own predecessor" (assertInvalidLineage selfPrevious),
          testCase "a session that is its own parent" (assertInvalidLineage selfParent),
          testCase "a negative delegation depth" (assertInvalidLineage negativeDepth),
          testCase "a delegation depth past the cap" (assertInvalidLineage depthPastCap),
          testCase "a delegated session at depth 0" (assertInvalidLineage parentAtDepthZero),
          testCase "a root session at depth 1" (assertInvalidLineage rootAtDepthOne)
        ],
      -- A cycle cannot be built through the API any more, so this one manufactures corrupt
      -- data directly. Before the CTE carried a path array, getChain looped until the
      -- timeout fired; it now returns in milliseconds.
      localOption (mkTimeout 10_000_000) $
        testCase "getChain terminates on a cyclic chain" testChainTerminatesOnCycle
    ]

data LineageResult = LineageResult
  { children :: ![SessionRow],
    childChain :: ![SessionRow]
  }

testDelegationLineage :: IO ()
testDelegationLineage =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) \env -> do
      parent <- genSessionId
      child1 <- genSessionId
      child2 <- genSessionId
      now <- getCurrentTime
      let child2Started = addUTCTime 2 now
      result <-
        runAppIO env do
          startFixture parent "parent" Nothing Nothing 0 now
          startFixture child1 "child-1" Nothing (Just parent) 1 (addUTCTime 1 now)
          startFixture child2 "child-2" (Just child1) (Just parent) 1 child2Started
          children <- Session.getDelegationChildren parent >>= liftEither "getDelegationChildren"
          childChain <- Session.getChain child2 >>= liftEither "getChain"
          pure LineageResult {children, childChain}
      case result of
        Left storeErr -> assertFailure ("store error: " <> show storeErr)
        Right LineageResult {children, childChain} -> do
          assertEqual "parent has exactly the two direct delegation children" [idText child1, idText child2] (rowSessionId <$> children)
          assertEqual "children carry parentSessionId" [Just (idText parent), Just (idText parent)] (rowParentSessionId <$> children)
          assertEqual "children carry depth 1" [1, 1] (rowDelegationDepth <$> children)
          assertEqual "previous-session chain follows previousSessionId, not parentSessionId" [idText child1, idText child2] (rowSessionId <$> childChain)

-- | A malformed-lineage case, built from the session's own id (so the self-reference cases
-- can point a field at it) and an unrelated id (so the depth cases can name a parent
-- without tripping the self-parent rule first).
type LineageCase = SessionId -> SessionId -> UTCTime -> StartSessionData

baseStart :: LineageCase
baseStart sid _other startedAt =
  StartSessionData
    { sessionId = sid,
      agentId = "test-agent",
      focus = "delegation lineage",
      scope = ScopeGlobal (Namespace "kioku-test"),
      subjectRef = Nothing,
      previousSessionId = Nothing,
      parentSessionId = Nothing,
      delegationDepth = 0,
      startedAt
    }

selfPrevious, selfParent, negativeDepth, depthPastCap, parentAtDepthZero, rootAtDepthOne :: LineageCase
selfPrevious sid o t = (baseStart sid o t) {previousSessionId = Just sid}
selfParent sid o t = (baseStart sid o t) {parentSessionId = Just sid, delegationDepth = 1}
negativeDepth sid o t = (baseStart sid o t) {delegationDepth = -1}
depthPastCap sid o t = (baseStart sid o t) {parentSessionId = Just o, delegationDepth = 65}
parentAtDepthZero sid o t = (baseStart sid o t) {parentSessionId = Just o, delegationDepth = 0}
rootAtDepthOne sid o t = (baseStart sid o t) {delegationDepth = 1}

assertInvalidLineage :: LineageCase -> IO ()
assertInvalidLineage mkCommand =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) \env -> do
      sid <- genSessionId
      other <- genSessionId
      now <- getCurrentTime
      result <- runAppIO env (Session.start (mkCommand sid other now))
      case result of
        Left storeErr -> assertFailure ("store error: " <> show storeErr)
        Right (Left (Session.SessionInvalidLineage _)) -> pure ()
        Right other' ->
          assertFailure ("expected SessionInvalidLineage, got " <> show other')

startFixture ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  Text ->
  Maybe SessionId ->
  Maybe SessionId ->
  Int ->
  UTCTime ->
  Eff es ()
startFixture sid agent previous parent depth startedAt = do
  result <-
    Session.start
      StartSessionData
        { sessionId = sid,
          agentId = agent,
          focus = "delegation lineage",
          scope = ScopeGlobal (Namespace "kioku-test"),
          subjectRef = Nothing,
          previousSessionId = previous,
          parentSessionId = parent,
          delegationDepth = depth,
          startedAt
        }
  void (liftEither "Session.start" result)

-- | Insert two sessions that name each other as predecessor, bypassing 'Session.start'
-- (which now refuses to create a cycle), then walk the chain. The assertion is simply that
-- the query returns at all — and returns each session exactly once, rather than looping.
testChainTerminatesOnCycle :: IO ()
testChainTerminatesOnCycle =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) \env -> do
      a <- genSessionId
      b <- genSessionId
      result <-
        runAppIO env do
          insertCyclicPair a b
          Session.getChain a >>= liftEither "getChain"
      case result of
        Left storeErr -> assertFailure ("store error: " <> show storeErr)
        Right chain -> do
          assertEqual "the cyclic chain returns both sessions" 2 (length chain)
          assertEqual
            "each session appears exactly once"
            (sort [idText a, idText b])
            (sort (rowSessionId <$> chain))

insertCyclicPair ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  SessionId ->
  Eff es ()
insertCyclicPair a b =
  runTransaction . Tx.sql . encodeUtf8 $
    "INSERT INTO kioku_sessions (session_id, agent_id, focus, namespace, delegation_depth, status, started_at, previous_session_id) VALUES "
      <> "('"
      <> idText a
      <> "','t','f','kioku-test',0,'completed',NOW(),'"
      <> idText b
      <> "'),('"
      <> idText b
      <> "','t','f','kioku-test',0,'completed',NOW() - interval '1 second','"
      <> idText a
      <> "')"

liftEither :: (Show e, IOE :> es) => String -> Either e a -> Eff es a
liftEither label = \case
  Left err -> liftIO (assertFailure (label <> ": " <> show err))
  Right value -> pure value

rowSessionId :: SessionRow -> Text
rowSessionId row = row.sessionId

rowParentSessionId :: SessionRow -> Maybe Text
rowParentSessionId row = row.parentSessionId

rowDelegationDepth :: SessionRow -> Int
rowDelegationDepth row = row.delegationDepth
