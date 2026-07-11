-- | Database-level tests for the recall candidate SQL: the scope predicate, the status
-- filter, the full-text query parser, and the vector round-trip. These go through
-- 'selectFtsCandidates' / 'selectVectorCandidates' rather than 'recall', so no embedding
-- endpoint is involved and the SQL under test is exercised exactly as it ships.
module Kioku.RecallSqlSpec (tests) where

import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (MemoryRecord (..))
import Kioku.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Recall (RecallRequest (..), RecallStrategy (..), selectFtsCandidates, selectVectorCandidates, vectorLiteral)
import Kioku.Recall.Capability (VectorCapability (..), detectVectorCapability)
import Kioku.RecallHarness
  ( CorpusConfig (..),
    SeededCorpus (..),
    cosineDistanceAtAngle,
    defaultStarvationCorpus,
    queryVector,
    seedCorpus,
  )
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Recall.Sql"
    [ testCase "a global scope searches the whole namespace; an entity scope is exact" testScopePredicate,
      testCase "archived memories are never candidates" testStatusFilter,
      testGroup
        "websearch_to_tsquery survives whatever the user typed"
        [ testCase "an empty query" (assertQueryDoesNotThrow ""),
          testCase "unbalanced quotes and bare operators" (assertQueryDoesNotThrow "\"unbalanced OR AND"),
          testCase "punctuation only" (assertQueryDoesNotThrow "-- ; ()")
        ],
      testCase "a vector round-trip ranks the nearest embedding first" testVectorRoundTrip,
      testCase "capability detection reads the column's real width" testDimensionDetection,
      testCase "the harness seeds the geometry it claims" testHarnessGeometry
    ]

-- | The instrument's own test, and the one that everything downstream rests on.
--
-- 'Kioku.RecallHarness' claims that a row seeded at angle @t@ sits at cosine distance
-- @1 - cos t@ from the query, and it uses that claim to know the true ranking of the corpus
-- /without asking the database/ — which is what makes recall@k a measurement rather than a
-- tautology. If the claim is false, every number the harness reports is fiction, so it is
-- checked directly here against the distances Postgres actually computes.
--
-- The second assertion is the one that makes starvation possible at all: every decoy must be
-- strictly nearer the query than every in-scope row, because starvation requires the filter to
-- correlate with distance. A corpus where that does not hold cannot starve, and a test built on
-- it would pass for the wrong reason.
testHarnessGeometry :: IO ()
testHarnessGeometry =
  withRecallFixture \runEff -> do
    result <- runEff do
      available <- vectorTypeIsReachable
      if not available
        then pure Nothing
        else do
          corpus <- seedCorpus smallCorpus
          measured <- actualDistances
          pure (Just (corpus, measured))
    case result of
      Left err -> assertFailure ("store error: " <> show err)
      Right Nothing ->
        putStrLn "  [skipped] no reachable pgvector on this cluster; re-enter the dev shell to exercise the recall harness"
      Right (Just (corpus, measured)) -> do
        assertEqual
          "every seeded row came back"
          (smallCorpus.inScopeCount + smallCorpus.decoyCount)
          (length measured)

        -- 1. Postgres agrees with the closed form the ground truth is built on.
        let predicted memoryId
              | Just t <- lookup memoryId (seedAngles smallCorpus) = cosineDistanceAtAngle t
              | otherwise = error ("unseeded memory id came back: " <> Text.unpack memoryId)
            worstError =
              maximum [abs (d - predicted memoryId) | (memoryId, d) <- measured]
        assertBool
          ( "Postgres disagrees with the harness's closed-form distance by "
              <> show worstError
              <> "; the ground truth cannot be trusted"
          )
          -- pgvector stores each component as a 4-byte float, so agreement is to float
          -- precision, not double.
          (worstError < 1e-5)

        -- 2. Every decoy really is nearer than every in-scope row, or nothing can starve.
        let distancesFor prefix =
              [d | (memoryId, d) <- measured, prefix `Text.isPrefixOf` memoryId]
            decoyDistances = distancesFor "m_decoy_"
            inScopeDistances = distancesFor "m_in_"
        assertBool
          ( "the decoys are not strictly nearer than the in-scope rows: farthest decoy "
              <> show (maximum decoyDistances)
              <> " vs nearest in-scope "
              <> show (minimum inScopeDistances)
              <> " — this corpus cannot starve"
          )
          (maximum decoyDistances < minimum inScopeDistances)

        -- 3. The ground-truth ordering is what it says it is: nearest first.
        let truthDistances =
              [d | memoryId <- corpus.trueNearestInScope, Just d <- [lookup memoryId measured]]
        assertEqual
          "the ground truth names every in-scope row"
          smallCorpus.inScopeCount
          (length truthDistances)
        assertBool
          "the ground truth is not ordered nearest-first"
          (and (zipWith (<=) truthDistances (drop 1 truthDistances)))

-- | Small enough to be quick, large enough that both bands are populated. The starvation case
-- uses 'defaultStarvationCorpus'; this one only has to prove the geometry.
smallCorpus :: CorpusConfig
smallCorpus = defaultStarvationCorpus {inScopeCount = 20, decoyCount = 20}

-- | The angles the harness seeded, recomputed here from the same config, so the assertion
-- compares Postgres against the /closed form/ rather than against the harness's own vectors.
seedAngles :: CorpusConfig -> [(Text, Double)]
seedAngles cfg =
  [ ("m_in_" <> Text.pack (show i), t)
  | (i, t) <- zip [0 :: Int ..] (evenly cfg.inScopeCount cfg.inScopeAngles)
  ]
    <> [ ("m_decoy_" <> Text.pack (show i), t)
       | (i, t) <- zip [0 :: Int ..] (evenly cfg.decoyCount cfg.decoyAngles)
       ]
  where
    evenly n (lo, hi)
      | n <= 0 = []
      | n == 1 = [lo]
      | otherwise = [lo + (hi - lo) * fromIntegral i / fromIntegral (n - 1) | i <- [0 .. n - 1]]

-- | Every seeded row's true cosine distance to the query, as Postgres computes it. The harness
-- must never do this — its whole value is knowing the answer without asking — but the test that
-- validates the harness must.
actualDistances :: (Store :> es) => Eff es [(Text, Double)]
actualDistances =
  runTransaction (Tx.statement (vectorLiteral queryVector) stmt)
  where
    stmt :: Statement Text [(Text, Double)]
    stmt =
      preparable
        "SELECT memory_id, (embedding <=> $1::vector)::float8 \
        \  FROM kiroku.kioku_memories \
        \ WHERE embedding IS NOT NULL \
        \ ORDER BY 2"
        (E.param (E.nonNullable E.text))
        ( D.rowList
            ( (,)
                <$> D.column (D.nonNullable D.text)
                <*> D.column (D.nonNullable D.float8)
            )
        )

-- | The migrated schema declares @embedding vector(1536)@, so a process configured for 512
-- is misconfigured and every embedding write it attempts would fail on the @::vector@ cast.
-- Detection reports it once, at startup, instead of once per event forever.
testDimensionDetection :: IO ()
testDimensionDetection =
  withRecallFixture \runEff -> do
    result <- runEff do
      available <- vectorTypeIsReachable
      if not available
        then pure Nothing
        else do
          mismatched <- detectVectorCapability 512
          matched <- detectVectorCapability 1536
          pure (Just (mismatched, matched))
    case result of
      Left err -> assertFailure ("store error: " <> show err)
      Right Nothing ->
        putStrLn "  [skipped] no reachable pgvector on this cluster; re-enter the dev shell to exercise dimension detection"
      Right (Just (mismatched, matched)) -> do
        assertEqual "a 512-dimension config against a vector(1536) column is a mismatch" (VectorDimensionMismatch 512 1536) mismatched
        assertEqual "the configured width matching the column is simply available" VectorAvailable matched

-- | Recall's scope predicate is @(($3 IS NULL AND $4 IS NULL) OR (scope_kind = $3 AND
-- scope_ref = $4))@: for a global scope both parameters are NULL, the first disjunct is
-- always true, and the query searches the entire namespace -- entity-scoped rows included.
-- That is deliberate and is *not* what the scoped read-model queries do with the same
-- 'MemoryScope' value. See docs/user/recall.md.
testScopePredicate :: IO ()
testScopePredicate =
  withRecallFixture \runEff -> do
    result <- runEff do
      seedMemories
        [ ("m_global", ns1Global, "the deployment pipeline runs on nix flakes", "active"),
          ("m_entity", ns1Entity, "the deployment pipeline runs on nix flakes", "active"),
          ("m_other_ns", ns2Global, "the deployment pipeline runs on nix flakes", "active")
        ]
      wide <- selectFtsCandidates (request ns1Global "deployment pipeline")
      exact <- selectFtsCandidates (request ns1Entity "deployment pipeline")
      pure (memoryIds wide, memoryIds exact)
    case result of
      Left err -> assertFailure ("store error: " <> show err)
      Right (wide, exact) -> do
        assertEqual
          "a global scope recalls every active row in the namespace, entity-scoped rows included"
          ["m_entity", "m_global"]
          wide
        assertEqual
          "an entity scope recalls only rows carrying exactly that scope"
          ["m_entity"]
          exact
        assertBool
          "no query ever crosses a namespace boundary"
          ("m_other_ns" `notElem` (wide <> exact))

testStatusFilter :: IO ()
testStatusFilter =
  withRecallFixture \runEff -> do
    result <- runEff do
      seedMemories
        [ ("m_active", ns1Global, "the deployment pipeline runs on nix flakes", "active"),
          ("m_archived", ns1Global, "the deployment pipeline runs on nix flakes", "archived")
        ]
      memoryIds <$> selectFtsCandidates (request ns1Global "deployment pipeline")
    case result of
      Left err -> assertFailure ("store error: " <> show err)
      Right ids -> assertEqual "an archived memory matching the query is not a candidate" ["m_active"] ids

-- | @websearch_to_tsquery@ is total by design -- it never raises on malformed input, unlike
-- @to_tsquery@. This pins that, because recall passes user text straight into it.
assertQueryDoesNotThrow :: Text -> IO ()
assertQueryDoesNotThrow query =
  withRecallFixture \runEff -> do
    result <- runEff do
      seedMemories [("m_active", ns1Global, "the deployment pipeline runs on nix flakes", "active")]
      selectFtsCandidates (request ns1Global query)
    case result of
      Left err -> assertFailure ("recall raised on query " <> show query <> ": " <> show err)
      Right _ -> pure ()

-- | Writes a real @vector(1536)@ through 'vectorLiteral' and reads it back through the
-- shipping ORDER BY, so the text encoding and the @::vector@ cast are both exercised.
-- Skipped where the cluster has no reachable pgvector, which stays a supported degradation.
testVectorRoundTrip :: IO ()
testVectorRoundTrip =
  withRecallFixture \runEff -> do
    result <- runEff do
      available <- vectorTypeIsReachable
      if not available
        then pure Nothing
        else do
          seedMemories
            [ ("m_near", ns1Global, "orbital mechanics", "active"),
              ("m_far", ns1Global, "orbital mechanics", "active")
            ]
          setEmbedding "m_near" (unitVector 0)
          setEmbedding "m_far" (unitVector 1)
          Just . memoryIdsInOrder <$> selectVectorCandidates (request ns1Global "orbital") (unitVector 0)
    case result of
      Left err -> assertFailure ("store error: " <> show err)
      Right Nothing ->
        -- A silent skip is indistinguishable from a pass, so say so out loud. ephemeral-pg
        -- takes its binaries from PATH: a shell entered before pgvector was added to
        -- nix/haskell.nix still spins up clusters without it.
        putStrLn "  [skipped] no reachable pgvector on this cluster; re-enter the dev shell to exercise the vector path"
      Right (Just ids) ->
        assertEqual
          "the embedding nearest the query vector ranks first"
          ["m_near", "m_far"]
          ids

-- * Fixture

ns1Global, ns1Entity, ns2Global :: MemoryScope
ns1Global = ScopeGlobal (Namespace "ns1")
ns1Entity = ScopeEntity (Namespace "ns1") (ScopeKind "repo") "web"
ns2Global = ScopeGlobal (Namespace "ns2")

request :: MemoryScope -> Text -> RecallRequest
request scope query =
  RecallRequest {scope, query, strategy = Keyword, maxResults = 10}

memoryIds :: [MemoryRecord] -> [Text]
memoryIds = sort . fmap (\row -> row.memoryId)

memoryIdsInOrder :: [MemoryRecord] -> [Text]
memoryIdsInOrder = fmap (\row -> row.memoryId)

-- | A 1536-dimension basis vector. Two distinct basis vectors are cosine-orthogonal
-- (distance 1) while a vector is at distance 0 from itself, so ranking is unambiguous.
unitVector :: Int -> Vector Double
unitVector i =
  Vector.generate 1536 (\j -> if j == i then 1 else 0)

seedMemories ::
  (Store :> es) =>
  [(Text, MemoryScope, Text, Text)] ->
  Eff es ()
seedMemories rows =
  runTransaction . Tx.sql . encodeUtf8 $
    "INSERT INTO kioku_memories (memory_id, agent_id, namespace, scope_kind, scope_ref, memory_type, content, status, created_at, updated_at) VALUES "
      <> Text.intercalate ", " (row <$> rows)
  where
    row (memoryId, scope, content, status) =
      "('"
        <> memoryId
        <> "', 'agent', '"
        <> namespaceOf scope
        <> "', "
        <> sqlText (kindOf scope)
        <> ", "
        <> sqlText (refOf scope)
        <> ", 'fact', '"
        <> content
        <> "', '"
        <> status
        <> "', now(), now())"

    namespaceOf = \case
      ScopeGlobal (Namespace ns) -> ns
      ScopeEntity (Namespace ns) _ _ -> ns
    kindOf = \case
      ScopeGlobal _ -> Nothing
      ScopeEntity _ (ScopeKind k) _ -> Just k
    refOf = \case
      ScopeGlobal _ -> Nothing
      ScopeEntity _ _ r -> Just r

    sqlText Nothing = "NULL"
    sqlText (Just value) = "'" <> value <> "'"

setEmbedding :: (Store :> es) => Text -> Vector Double -> Eff es ()
setEmbedding memoryId embedding =
  runTransaction . Tx.sql . encodeUtf8 $
    "UPDATE kioku_memories SET embedding = '"
      <> vectorLiteral embedding
      <> "'::vector WHERE memory_id = '"
      <> memoryId
      <> "'"

-- | The question that actually matters is not "is the extension installed somewhere" but
-- "can this connection name the type" -- which is what recall's @$1::vector@ cast needs, and
-- what @to_regtype@ answers against the live search_path.
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

-- | A migrated throwaway database plus a store, handed to the case as a runner. Each case
-- gets its own cluster, so the seeds cannot collide.
withRecallFixture :: ((forall a. Eff AppEffects a -> IO (Either StoreError a)) -> IO ()) -> IO ()
withRecallFixture use =
  withKiokuMigratedDatabase \connStr ->
    withStore (defaultConnectionSettings connStr) \st -> do
      tracer <- noopTracer
      let env = AppEnv {store = st, tracer, metrics = Nothing}
      use (runAppIO env)
