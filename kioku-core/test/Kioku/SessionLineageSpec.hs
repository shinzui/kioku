module Kioku.SessionLineageSpec (tests) where

import Control.Monad (void)
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..))
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Id (SessionId, genSessionId, idText)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Session qualified as Session
import Kioku.Session.Domain (StartSessionData (..))
import Kioku.Session.ReadModel (SessionRow (..))
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Session.Lineage"
    [ testCase "child sessions record parent id and delegation depth" testDelegationLineage
    ]

data LineageResult = LineageResult
  { children :: ![SessionRow],
    childChain :: ![SessionRow]
  }

testDelegationLineage :: IO ()
testDelegationLineage =
  withKiokuMigratedDatabase \connStr ->
    withStore (defaultConnectionSettings connStr) \st -> do
      tracer <- noopTracer
      parent <- genSessionId
      child1 <- genSessionId
      child2 <- genSessionId
      now <- getCurrentTime
      let env = AppEnv {store = st, tracer, metrics = Nothing}
          child2Started = addUTCTime 2 now
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

startFixture ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
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
