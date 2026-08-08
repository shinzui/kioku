-- | The recall target matrix, against a real database: three targets, three strategies, two
-- memory spaces holding identical rows under identical names.
--
-- == Why identical rows in two spaces
--
-- Every fixture row in @space_test@ has a twin in @space_other@ with the same namespace, the same
-- scope, and the same content. Nothing but the @memory_space_id@ predicate can tell them apart,
-- so a statement that lost that predicate — or that put it after a scope comparison it then got
-- wrong — returns six rows where it should return one, and every case here fails at once. A
-- fixture whose spaces differed in namespace or content would pass on the namespace filter alone
-- and prove nothing about the partition.
--
-- == Why the strategies are exercised at the channel level
--
-- @embedding@ and @hybrid@ recall embed the query through
-- 'Baikai.Embedding.EmbeddingModel', which is an HTTP endpoint; running them through
-- 'Kioku.Recall.recall' would need a live embedding service. The target predicate lives in the
-- channels, not above them, so the matrix drives 'Kioku.Recall.selectFtsCandidates' and
-- 'Kioku.Recall.selectVectorCandidates' directly and fuses their results with
-- 'Kioku.Recall.fuseRecallCandidates' for the hybrid row — which is exactly what recall does with
-- them. Fusion is pure and set-union-like, so it cannot introduce a row neither channel returned.
--
-- The keyword row is /also/ run through the public 'Kioku.Recall.recall', which needs no
-- embedding, so the whole entry point is proven for all three targets and not just the SQL under
-- it.
module Kioku.RecallTargetSpec (tests) where

import Data.Foldable (traverse_)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Time (UTCTime)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Kioku.Api.Access (MemoryAccessContext, MemorySpaceId, memorySpaceIdText)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (MemoryRecord (..))
import Kioku.App (AppEffects, runAppIO, withNoopAppEnv)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Recall
  ( RecallError,
    RecallHit (..),
    RecallLimit,
    RecallQuery (..),
    RecallStrategy (..),
    RecallTarget (..),
    ResolvedRecall,
    explainFtsCandidates,
    explainVectorExactCandidates,
    ftsCandidateSql,
    fuseRecallCandidates,
    mkRecallLimit,
    recall,
    resolveRecall,
    selectFtsCandidates,
    selectVectorCandidates,
    vectorCandidateSql,
    vectorLiteral,
  )
import Kioku.Recall.Capability (VectorCapability (..))
import Kioku.SpaceFixtures (otherContext, otherSpace, testContext, testSpace)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Recall.Target"
    [ testCase "every target and strategy returns its own rows, in its own space" testTargetMatrix,
      testCase "the public entry point answers all three targets" testRecallEntryPoint,
      testCase "each target's plan is bounded by the partition and its own scope clause" testBoundedPlans
    ]

-- * The matrix

-- | The nine target/strategy combinations, plus the same nine seen from the second space.
--
-- One fixture, one migrated cluster: seeding is the expensive part and the assertions are not.
testTargetMatrix :: IO ()
testTargetMatrix =
  withTargetFixture \runEff -> do
    result <- runEff do
      available <- vectorTypeIsReachable
      keyword <- traverse (channelIds Keyword) targetsUnderTest
      mirrored <- traverse (mirroredIds Keyword) targetsUnderTest
      embedding <- ifAvailable available (traverse (channelIds Embedding) targetsUnderTest)
      hybrid <- ifAvailable available (traverse (channelIds Hybrid) targetsUnderTest)
      pure (keyword, mirrored, embedding, hybrid)
    case result of
      Left err -> assertFailure ("store error: " <> show err)
      Right (keyword, mirrored, embedding, hybrid) -> do
        assertMatrix "keyword" testSpaceExpectations keyword
        assertMatrix "keyword, from the second space" otherSpaceExpectations mirrored
        case (embedding, hybrid) of
          (Just embeddingIds, Just hybridIds) -> do
            assertMatrix "embedding" testSpaceExpectations embeddingIds
            assertMatrix "hybrid" testSpaceExpectations hybridIds
          _ -> putStrLn skipMessage

-- | The rows each target must return in the space its context authorizes.
--
-- The exact global bucket is the row this whole initiative existed to make reachable: before the
-- statements were split it was refused, because the only rows the shared predicate could give it
-- were the namespace-wide ones.
testSpaceExpectations :: [(String, [Text])]
testSpaceExpectations =
  [ ("the exact global bucket, and nothing else in the namespace", ["t_global"]),
    ("exactly one entity scope", ["t_web"]),
    ("every scope in the namespace", ["t_api", "t_global", "t_web"])
  ]

-- | The same three targets, run under the context that authorizes the /other/ space. Identical
-- targets, identical rows, different partition — so this is what fails if a statement ever
-- resolves its space from anywhere but the context.
otherSpaceExpectations :: [(String, [Text])]
otherSpaceExpectations =
  [ ("the exact global bucket, and nothing else in the namespace", ["o_global"]),
    ("exactly one entity scope", ["o_web"]),
    ("every scope in the namespace", ["o_api", "o_global", "o_web"])
  ]

assertMatrix :: String -> [(String, [Text])] -> [[Text]] -> IO ()
assertMatrix label expectations actual =
  traverse_ assertRow (zip3 [0 :: Int ..] expectations actual)
  where
    assertRow (index, (what, expected), got) = do
      assertEqual (label <> ": " <> what) expected got
      assertBool
        ( label
            <> ": target "
            <> show index
            <> " returned a row from another memory space: "
            <> show got
        )
        (not (any (`elem` foreignIdsFor expected) got))

    -- Whichever space the expectations belong to, the other space's ids are the ones that must
    -- never appear.
    foreignIdsFor expected
      | any ("t_" `Text.isPrefixOf`) expected = otherSpaceIds
      | otherwise = testSpaceIds

-- | The three targets, in the order the expectation tables list them.
targetsUnderTest :: [RecallTarget]
targetsUnderTest =
  [ ExactScope (ScopeGlobal fixtureNamespace),
    ExactScope (ScopeEntity fixtureNamespace repoKind "web"),
    NamespaceWide fixtureNamespace
  ]

-- | Run one strategy's channels for one target, in the test space, and return the ids it found.
channelIds :: (Store :> es) => RecallStrategy -> RecallTarget -> Eff es [Text]
channelIds = channelIdsIn testSpace

-- | The same, in the second space.
mirroredIds :: (Store :> es) => RecallStrategy -> RecallTarget -> Eff es [Text]
mirroredIds = channelIdsIn otherSpace

channelIdsIn :: (Store :> es) => MemorySpaceId -> RecallStrategy -> RecallTarget -> Eff es [Text]
channelIdsIn space strategy target = do
  let resolved = request space target strategy
  case strategy of
    Keyword -> sortedIds <$> selectFtsCandidates resolved
    Embedding -> sortedIds <$> selectVectorCandidates resolved fixtureQueryVector
    Hybrid -> do
      ftsRows <- selectFtsCandidates resolved
      vecRows <- selectVectorCandidates resolved fixtureQueryVector
      -- The instant is irrelevant here: it only feeds the recency term of the blended score, and
      -- this case asserts which rows came back rather than in what order.
      pure (sort (fmap hitId (fuseRecallCandidates fixtureInstant ftsRows vecRows)))
  where
    hitId hit = hit.memory.memoryId

-- * The public entry point

-- | The same three targets through 'Kioku.Recall.recall' itself, keyword-only so that no
-- embedding endpoint is involved.
--
-- 'VectorExtensionUnavailable' makes the keyword plan a guarantee rather than a hope, which is
-- what lets the embedding model be 'undefined': the execution plan never asks for it.
testRecallEntryPoint :: IO ()
testRecallEntryPoint =
  withTargetFixture \runEff -> do
    result <- runEff do
      authorized <- traverse (runKeywordRecall testContext) targetsUnderTest
      -- The same three targets under a context that authorizes the other space. Identical
      -- requests, identical rows, different partition: nothing in a RecallQuery can choose it.
      mirrored <- traverse (runKeywordRecall otherContext) targetsUnderTest
      pure (authorized, mirrored)
    case result of
      Left err -> assertFailure ("store error: " <> show err)
      Right (authorized, mirrored) -> do
        assertMatrix "recall" testSpaceExpectations (fmap expectHits authorized)
        assertMatrix "recall, in the second space" otherSpaceExpectations (fmap expectHits mirrored)
  where
    expectHits =
      either (\err -> error ("recall refused: " <> show err)) id

runKeywordRecall ::
  (Store :> es, IOE :> es) =>
  MemoryAccessContext ->
  RecallTarget ->
  Eff es (Either RecallError [Text])
runKeywordRecall context target =
  fmap (sort . fmap (\hit -> hit.memory.memoryId))
    <$> recall
      undefinedModel
      VectorExtensionUnavailable
      context
      RecallQuery
        { target,
          query = fixtureContent,
          strategy = Keyword,
          maxResults = limitOf 10
        }

-- | The keyword channel never embeds, and 'VectorExtensionUnavailable' makes that a guarantee.
undefinedModel :: a
undefinedModel = error "the keyword channel must not embed"

-- * Plan evidence

-- | What the three bounds compile to, read back out of PostgreSQL rather than asserted about the
-- Haskell.
--
-- Two properties, and they are the two the split exists for:
--
-- 1. __Every plan is bounded by the partition.__ @memory_space_id@ appears in every plan, on
--    every channel, for every target. A statement that lost it would still pass every row-level
--    case above in a single-space fixture; this is what makes losing it loud.
-- 2. __The three bounds are three plans.__ The exact global bucket's plan names
--    @scope_kind IS NULL@, the exact entity's names an equality on @scope_kind@, and the
--    namespace-wide plan names neither. Before the split all three produced one plan with one
--    parameterised predicate, and no artifact anywhere could tell a reviewer which meaning had
--    been asked for.
--
-- @enable_seqscan = off@ is set for the same reason the corpus is small: the fixture holds six
-- rows, so an unconstrained planner would sequentially scan whatever it was asked and the plan
-- would say nothing about which access paths are /available/. Turning the sequential scan off
-- asks the question this case actually means — can this query be answered through a
-- partition-leading index? — and the answer is asserted below.
testBoundedPlans :: IO ()
testBoundedPlans =
  withTargetFixture \runEff -> do
    result <- runEff do
      available <- vectorTypeIsReachable
      keywordPlans <- traverse (planFor explainFtsCandidates . ftsPlan) targetsUnderTest
      vectorPlans <-
        ifAvailable
          available
          (traverse (planFor explainVectorExactCandidates . vectorPlan) targetsUnderTest)
      pure (keywordPlans, vectorPlans)
    case result of
      Left err -> assertFailure ("store error: " <> show err)
      Right (keywordPlans, vectorPlans) -> do
        assertPlans "keyword" keywordPlans
        case vectorPlans of
          Just plans -> assertPlans "vector (exact pass)" plans
          Nothing -> putStrLn skipMessage
  where
    ftsPlan target = ftsCandidateSql (request testSpace target Keyword)
    vectorPlan target =
      vectorCandidateSql (request testSpace target Embedding) fixtureQueryVector

    planFor explain compiled =
      Text.unlines
        <$> runTransaction do
          Tx.sql "SET LOCAL enable_seqscan = off"
          explain compiled

assertPlans :: String -> [Text] -> IO ()
assertPlans label plans =
  case plans of
    [globalPlan, entityPlan, widePlan] -> do
      traverse_ (assertPartitionBound label) plans
      assertBool
        (label <> ": the exact global plan does not test scope_kind for NULL\n" <> Text.unpack globalPlan)
        ("scope_kind IS NULL" `Text.isInfixOf` globalPlan)
      assertBool
        (label <> ": the exact entity plan does not compare scope_kind\n" <> Text.unpack entityPlan)
        ("scope_kind = " `Text.isInfixOf` entityPlan)
      assertBool
        ( label
            <> ": the namespace-wide plan constrains a scope, so it is not namespace-wide\n"
            <> Text.unpack widePlan
        )
        (not ("scope_kind" `Text.isInfixOf` widePlan))
      assertBool
        ( label
            <> ": the exact global and namespace-wide targets produced the same plan, which is \
               \the ambiguity this split removes\n"
            <> Text.unpack globalPlan
        )
        (globalPlan /= widePlan)
      -- "Partition-leading" is not a claim about which index was named; it is a claim about the
      -- shape of the access path, so it is asserted against the index condition itself.
      assertBool
        ( label
            <> ": a bound cannot be answered through an index whose condition leads with the \
               \memory space\n"
            <> Text.unpack (Text.unlines plans)
        )
        (all (Text.isInfixOf "Index Cond: ((memory_space_id") plans)
    other -> assertFailure (label <> ": expected three plans, got " <> show (length other))

assertPartitionBound :: String -> Text -> IO ()
assertPartitionBound label plan =
  assertBool
    (label <> ": a plan does not mention memory_space_id at all\n" <> Text.unpack plan)
    ("memory_space_id" `Text.isInfixOf` plan)

-- * Fixture

fixtureNamespace :: Namespace
fixtureNamespace = Namespace "mori"

repoKind :: ScopeKind
repoKind = ScopeKind "repo"

-- | Identical in both spaces and under every scope, so content can never be what separates the
-- rows a target returns.
fixtureContent :: Text
fixtureContent = "the deployment pipeline runs on nix flakes"

fixtureInstant :: UTCTime
fixtureInstant = read "2026-08-07 00:00:00 UTC"

testSpaceIds, otherSpaceIds :: [Text]
testSpaceIds = ["t_global", "t_web", "t_api"]
otherSpaceIds = ["o_global", "o_web", "o_api"]

-- | Three scopes in one namespace: the global bucket and two entity scopes under the same kind.
fixtureScopes :: [(Text, Text, MemoryScope)]
fixtureScopes =
  [ ("t_global", "o_global", ScopeGlobal fixtureNamespace),
    ("t_web", "o_web", ScopeEntity fixtureNamespace repoKind "web"),
    ("t_api", "o_api", ScopeEntity fixtureNamespace repoKind "api")
  ]

-- | The query vector the embedding and hybrid rows search with. It is one of the seeded vectors,
-- so the nearest row is exact — but every seeded row is within the pool, and the matrix asserts
-- which rows came back rather than their order.
fixtureQueryVector :: Vector Double
fixtureQueryVector = basisVector 0

request :: MemorySpaceId -> RecallTarget -> RecallStrategy -> ResolvedRecall
request space target strategy =
  resolveRecall
    space
    RecallQuery {target, query = fixtureContent, strategy, maxResults = limitOf 10}

limitOf :: Int -> RecallLimit
limitOf = either (error . Text.unpack) id . mkRecallLimit

sortedIds :: [MemoryRecord] -> [Text]
sortedIds = sort . fmap (\row -> row.memoryId)

ifAvailable :: (Applicative f) => Bool -> f a -> f (Maybe a)
ifAvailable False _ = pure Nothing
ifAvailable True action = Just <$> action

-- | A silent skip is indistinguishable from a pass, so the vector rows say so out loud.
skipMessage :: String
skipMessage =
  "  [skipped] no reachable pgvector on this cluster; re-enter the dev shell to exercise the \
  \vector rows of the target matrix"

-- | Six rows: three scopes, twice, one set per memory space. Each carries a distinct embedding so
-- the vector channel has something to rank, and identical content so the keyword channel matches
-- all six.
seedFixture :: (Store :> es) => Bool -> Eff es ()
seedFixture withEmbeddings = do
  runTransaction . Tx.sql . encodeUtf8 $
    "INSERT INTO kioku.memories \
    \(memory_space_id, memory_id, agent_id, namespace, scope_kind, scope_ref, memory_type, content, status, created_at, updated_at) VALUES "
      <> Text.intercalate ", " (concatMap rowsFor fixtureScopes)
  if withEmbeddings
    then traverse_ setEmbedding (zip [0 ..] (testSpaceIds <> otherSpaceIds))
    else pure ()
  where
    rowsFor (testId, otherId, scope) =
      [row testSpace testId scope, row otherSpace otherId scope]

    row space memoryId scope =
      "('"
        <> memorySpaceIdText space
        <> "', '"
        <> memoryId
        <> "', 'agent', '"
        <> namespaceOf scope
        <> "', "
        <> sqlText (kindOf scope)
        <> ", "
        <> sqlText (refOf scope)
        <> ", 'fact', '"
        <> fixtureContent
        <> "', 'active', now(), now())"

    namespaceOf = \case
      ScopeGlobal (Namespace ns) -> ns
      ScopeEntity (Namespace ns) _ _ -> ns
    kindOf = \case
      ScopeGlobal _ -> Nothing
      ScopeEntity _ (ScopeKind kind) _ -> Just kind
    refOf = \case
      ScopeGlobal _ -> Nothing
      ScopeEntity _ _ ref -> Just ref

    sqlText = maybe "NULL" (\value -> "'" <> value <> "'")

setEmbedding :: (Store :> es) => (Int, Text) -> Eff es ()
setEmbedding (i, memoryId) =
  runTransaction . Tx.sql . encodeUtf8 $
    "UPDATE kioku.memories SET embedding = '"
      <> vectorLiteral (basisVector i)
      <> "'::vector WHERE memory_id = '"
      <> memoryId
      <> "'"

-- | A 1536-dimension basis vector. Distinct basis vectors are cosine-orthogonal, so the ranking
-- among them is unambiguous and none of them is ever equidistant from the query.
basisVector :: Int -> Vector Double
basisVector i = Vector.generate 1536 (\j -> if j == i then 1 else 0)

-- | Whether /this connection/ can name the @vector@ type, which is what the @$1::vector@ cast in
-- the vector statements needs.
vectorTypeIsReachable :: (Store :> es) => Eff es Bool
vectorTypeIsReachable =
  runTransaction (Tx.statement () stmt)
  where
    stmt :: Statement () Bool
    stmt =
      preparable
        "SELECT to_regtype('vector') IS NOT NULL"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.bool)))

-- | A migrated throwaway database, seeded once, handed to the case as a runner.
withTargetFixture :: ((forall a. Eff AppEffects a -> IO (Either StoreError a)) -> IO ()) -> IO ()
withTargetFixture use =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) \env -> do
      seeded <- runAppIO env do
        available <- vectorTypeIsReachable
        seedFixture available
      case seeded of
        Left err -> assertFailure ("seeding failed: " <> show err)
        Right () -> use (runAppIO env)
