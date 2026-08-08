-- | An instrument for measuring the quality of kioku's vector recall against a corpus whose
-- true answer is known /by construction/, in Haskell, without asking Postgres anything.
--
-- == Why this exists
--
-- Recall's vector channel can silently return nothing. The HNSW index covers the embedding
-- column alone (its only predicate is @embedding IS NOT NULL@), so it picks its candidates by
-- distance and the namespace, scope, and @status = 'active'@ predicates are applied /afterwards/,
-- to rows the index has already chosen. When the rows outside the caller's scope are nearer the
-- query than the in-scope answers, the index can spend its whole budget on rows the filter then
-- discards. That is /filtered-ANN starvation/, and because 'Kioku.Recall.fuseRecallCandidates'
-- blends the two channels by rank, an empty vector channel simply contributes no ranks: the
-- score degrades smoothly into pure keyword scoring, with no error and no warning. Nothing in a
-- 'Kioku.Api.Types.MemoryRecord' or a @RecallHit@ says "the semantic half came back empty".
--
-- This module builds the corpus that provokes that, and measures what actually came back.
--
-- == The geometry, and why it is the point
--
-- The query sits on axis 0. A seeded vector at angle @t@ (radians) is @cos t * e0 + sin t * e1@,
-- so its cosine distance to the query is exactly @1 - cos t@ — a pure, monotonically increasing
-- function of one knob on @[0, pi]@. The harness therefore knows the true ranking of every
-- seeded row /without querying the database/, which is what makes recall@k a measurement rather
-- than a tautology. The obvious alternative — run an exact scan and compare the approximate
-- result to it — would measure the ANN path against the planner's /other/ choice, and the
-- planner's choice between those two plans is precisely the thing under suspicion.
--
-- (The existing 'Kioku.RecallSqlSpec.unitVector' cannot express this: orthogonal basis vectors
-- sit at cosine distance exactly 0 or exactly 1, and starvation needs a graded scale.)
--
-- == Two traps that produce confidently-wrong numbers rather than errors
--
-- 1. __Rows inserted inside an open transaction never get an HNSW index scan__, not even with
--    @enable_seqscan = off@ and a fresh @ANALYZE@. Every seeding statement here is its own
--    committed transaction ('runTransaction' commits). Do not "optimise" 'seedCorpus' by
--    wrapping the whole corpus in one transaction — the rows would be invisible to the index
--    and every number downstream would be fiction.
-- 2. __An @EXPLAIN@ that restates the query is not measuring the query.__ This module used to
--    keep its own copy of the vector SQL, and the copy was wrong twice — once by selecting one
--    column instead of thirteen, once by omitting the memory-space predicate — each time
--    reporting a plan no live query could produce. There is no copy now:
--    'Kioku.Recall.explainVectorAnnCandidates' explains the shipping statement itself, from the
--    same SQL text and the same parameters.
--
-- See docs/plans/18-build-a-recall-quality-harness-that-reproduces-filtered-ann-starvation.md
-- and docs/plans/29-enforce-exact-and-namespace-wide-recall-in-postgresql.md.
module Kioku.RecallHarness
  ( -- * Geometry
    vectorAtAngle,
    queryVector,
    cosineDistanceAtAngle,
    embeddingDimensions,

    -- * Seeding
    CorpusConfig (..),
    defaultStarvationCorpus,
    exactEntityStarvationCorpus,
    inScopeScopeFor,
    SeededCorpus (..),
    seedCorpus,

    -- * Measurement
    RecallQuality (..),
    measureRecallQuality,
    measureRecallQualityWith,
    explainVectorQuery,
    explainVectorQueryWith,
    describeRecallQuality,
    usedHnswIndex,
    planAgreesWithQuery,
    runDdl,
  )
where

import Data.Char (isDigit)
import Data.Foldable (traverse_)
import Data.List (isInfixOf, sortOn)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Effectful (Eff, (:>))
import Hasql.Transaction qualified as Tx
import Kioku.Api.Access (memorySpaceIdText)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (MemoryRecord (..))
import Kioku.Recall
  ( RecallLimit,
    RecallQuery (..),
    RecallStrategy (..),
    RecallTarget (..),
    ResolvedRecall,
    VectorCandidateSql,
    VectorChannelOutcome (..),
    explainVectorAnnCandidates,
    mkRecallLimit,
    resolveRecall,
    runVectorAnnCandidates,
    selectVectorCandidatesDiagnosed,
    vectorCandidateSql,
  )
import Kioku.SpaceFixtures (testSpace)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Text.Read (readMaybe)

-- * Geometry

-- | The width of @kioku.memories.embedding@, which is @vector(1536)@. A seeded vector must
-- match it exactly or the @::vector@ cast fails.
embeddingDimensions :: Int
embeddingDimensions = 1536

-- | @cos t * e0 + sin t * e1@ — a unit vector at angle @t@ from the query axis, in the plane
-- spanned by the first two coordinates. Every other coordinate is zero.
vectorAtAngle :: Double -> Vector Double
vectorAtAngle t =
  Vector.generate embeddingDimensions \j ->
    case j of
      0 -> cos t
      1 -> sin t
      _ -> 0

-- | The query the whole harness measures against: the vector at angle zero, i.e. @e0@.
queryVector :: Vector Double
queryVector = vectorAtAngle 0

-- | The cosine distance from 'queryVector' to 'vectorAtAngle', in closed form.
--
-- Both vectors are unit length, so cosine distance is @1 - cos(angle between them)@, and the
-- angle between @e0@ and @vectorAtAngle t@ is @t@. This is the ground truth: it is computed
-- here, in Haskell, and never read back from the database, which is the thing under test.
cosineDistanceAtAngle :: Double -> Double
cosineDistanceAtAngle t = 1 - cos t

-- * Seeding

-- | The knobs that make a corpus starve.
--
-- Starvation needs the filter to /correlate with distance/: the rows the query's bound throws
-- away must be the ones the index reaches for first. So the decoys sit /nearer/ the query than
-- any in-scope row, in a scope the target excludes.
data CorpusConfig = CorpusConfig
  { -- | Memories inside the target's bound. These are the true answers.
    inScopeCount :: !Int,
    -- | Memories outside it, which the query must never return.
    decoyCount :: !Int,
    -- | The angular band (radians) the in-scope rows are spread evenly across.
    inScopeAngles :: !(Double, Double),
    -- | The angular band the decoys occupy. Make it strictly nearer the query than
    -- 'inScopeAngles' — that is, smaller angles — or nothing starves.
    decoyAngles :: !(Double, Double),
    -- | The target the measurement aims at the corpus, which decides both the statement family
    -- under test and the scope the in-scope rows are seeded with ('inScopeScopeFor').
    target :: !RecallTarget,
    -- | The scope the decoys carry. The target must exclude it, or the \"decoys\" are answers
    -- and nothing is being measured.
    decoyScope :: !MemoryScope
  }
  deriving stock (Eq, Show)

-- | The scope the in-scope rows carry, given the target aimed at them.
--
-- An exact target admits exactly one scope, so there is no choice. A namespace-wide target
-- admits every scope in its namespace; the global bucket is the simplest of them and is what the
-- corpus uses.
inScopeScopeFor :: RecallTarget -> MemoryScope
inScopeScopeFor = \case
  ExactScope scope -> scope
  NamespaceWide ns -> ScopeGlobal ns

-- | The probe the previous initiative recorded as "1648 rows removed by filter, zero returned":
-- in-scope memories in one namespace, nearer decoys in another.
--
-- Every decoy is strictly nearer the query than every in-scope row. In cosine distance the
-- decoys span roughly 0.001 to 0.12 and the in-scope rows roughly 0.30 to 0.64, so the index,
-- descending towards the query, meets all 2000 decoys before the first true answer.
--
-- __@inScopeCount@ was 2000 until the memory-space partition landed, and 2000 stopped
-- starving.__ Not because anything about the ANN scan changed, but because the partition-first
-- rebuild of @kioku_memories_scope_idx@ — now @kioku_memories_space_scope_idx@, leading with
-- @memory_space_id@ — made the planner prefer an ordinary index scan of the in-scope rows plus
-- a top-N sort over the HNSW scan entirely. Measured: at 2000 in-scope rows the exact plan cost
-- 213.97 and won; dropping that one index restored the HNSW plan and the starvation with it,
-- while dropping the other two new partition-first indexes changed nothing.
--
-- The sort's cost grows with the in-scope row count and the HNSW scan's does not, so the fix is
-- the one this file's starvation case asks for: a harsher corpus, not a relaxed assertion. 4000
-- is the first power-of-two step at which the planner goes back to HNSW; it was measured
-- starving at 4000, 8000, 16000 and 32000, and it is the smallest of those.
defaultStarvationCorpus :: CorpusConfig
defaultStarvationCorpus =
  CorpusConfig
    { inScopeCount = 4000,
      decoyCount = 2000,
      inScopeAngles = (0.8, 1.2),
      decoyAngles = (0.05, 0.5),
      target = NamespaceWide targetNamespace,
      decoyScope = ScopeGlobal decoyNamespace
    }

-- | The same starvation, aimed at an /exact entity scope/ rather than a whole namespace.
--
-- This is the shape the filtered-ANN work was really about: a small scope inside a large
-- namespace, where the nearest rows belong to a sibling scope. Both scopes live in the same
-- namespace here, so the memory-space and namespace predicates match every row in the table and
-- only the scope comparison separates the answers from the decoys — which is the narrowest the
-- exact-entity statement family can be pushed.
--
-- It exists because the split into three statement families means the fallback is now dispatched
-- per family: a regression that dropped the @OFFSET 0@ fence from the exact family alone would
-- leave the namespace-wide case above passing.
exactEntityStarvationCorpus :: CorpusConfig
exactEntityStarvationCorpus =
  defaultStarvationCorpus
    { target = ExactScope (ScopeEntity targetNamespace repoKind "in-scope"),
      decoyScope = ScopeEntity targetNamespace repoKind "decoy"
    }

repoKind :: ScopeKind
repoKind = ScopeKind "repo"

-- | What was seeded, including the ground truth.
data SeededCorpus = SeededCorpus
  { config :: !CorpusConfig,
    -- | The in-scope memory ids ordered by true cosine distance, nearest first. Computed from
    -- the seed angles, never read back from the database.
    trueNearestInScope :: ![Text]
  }
  deriving stock (Eq, Show)

-- | The namespace the query asks for.
targetNamespace :: Namespace
targetNamespace = Namespace "harness_target"

-- | The namespace the default corpus's decoys live in. The query must never return one of these.
decoyNamespace :: Namespace
decoyNamespace = Namespace "harness_decoy"

-- | Spread @n@ points evenly across @[lo, hi]@, inclusive at both ends.
anglesAcross :: Int -> (Double, Double) -> [Double]
anglesAcross n (lo, hi)
  | n <= 0 = []
  | n == 1 = [lo]
  | otherwise =
      [ lo + (hi - lo) * fromIntegral i / fromIntegral (n - 1)
      | i <- [0 .. n - 1]
      ]

-- | Seed the corpus and return its ground truth.
--
-- Rows are inserted in committed batches (see the module header's trap 1: rows in an open
-- transaction get no index scan), and the table is @ANALYZE@d afterwards, because without
-- statistics the planner uses defaults and the plan it picks is not the plan production would
-- pick — which, for this harness, is the entire subject.
seedCorpus :: (Store :> es) => CorpusConfig -> Eff es SeededCorpus
seedCorpus cfg = do
  let inScope =
        [ (inScopeId i, inScopeScopeFor cfg.target, t)
        | (i, t) <- zip [0 :: Int ..] (anglesAcross cfg.inScopeCount cfg.inScopeAngles)
        ]
      decoys =
        [ (decoyId i, cfg.decoyScope, t)
        | (i, t) <- zip [0 :: Int ..] (anglesAcross cfg.decoyCount cfg.decoyAngles)
        ]
  traverse_ insertBatch (chunksOf seedBatchSize (inScope <> decoys))
  runTransaction (Tx.sql "ANALYZE kioku.memories")
  pure
    SeededCorpus
      { config = cfg,
        -- Distance is @1 - cos t@, which increases monotonically with @t@ on @[0, pi]@, so
        -- ordering by angle *is* ordering by distance. 'anglesAcross' already emits ascending
        -- angles; sorting explicitly keeps that from being a silent assumption.
        trueNearestInScope =
          fmap (\(memoryId, _, _) -> memoryId) (sortOn (\(_, _, t) -> t) inScope)
      }
  where
    inScopeId i = "m_in_" <> Text.pack (show i)
    decoyId i = "m_decoy_" <> Text.pack (show i)

-- | Rows per @INSERT@. Each batch is its own committed transaction.
seedBatchSize :: Int
seedBatchSize = 500

insertBatch :: (Store :> es) => [(Text, MemoryScope, Double)] -> Eff es ()
insertBatch [] = pure ()
insertBatch rows =
  runTransaction . Tx.sql . encodeUtf8 $
    "INSERT INTO kioku.memories \
    \(memory_space_id, memory_id, agent_id, namespace, scope_kind, scope_ref, memory_type, content, status, created_at, updated_at, embedding) VALUES "
      <> Text.intercalate ", " (row <$> rows)
  where
    row (memoryId, scope, t) =
      "('"
        <> memorySpaceIdText testSpace
        <> "', '"
        <> memoryId
        <> "', 'agent', '"
        <> namespaceTextOf scope
        <> "', "
        <> sqlText (kindTextOf scope)
        <> ", "
        <> sqlText (refTextOf scope)
        <> ", 'fact', 'seeded corpus row "
        <> memoryId
        <> "', 'active', now(), now(), "
        <> sparseVectorSql t
        <> ")"

namespaceTextOf :: MemoryScope -> Text
namespaceTextOf = \case
  ScopeGlobal (Namespace ns) -> ns
  ScopeEntity (Namespace ns) _ _ -> ns

kindTextOf :: MemoryScope -> Maybe Text
kindTextOf = \case
  ScopeGlobal _ -> Nothing
  ScopeEntity _ (ScopeKind kind) _ -> Just kind

refTextOf :: MemoryScope -> Maybe Text
refTextOf = \case
  ScopeGlobal _ -> Nothing
  ScopeEntity _ _ ref -> Just ref

sqlText :: Maybe Text -> Text
sqlText = maybe "NULL" (\value -> "'" <> value <> "'")

-- | The seeded vector, built as SQL rather than as a 1536-element text literal.
--
-- 'Kioku.Recall.vectorLiteral' would render all 1536 components, of which 1534 are zero: about
-- 6KB per row, so around 25MB of SQL text for the default corpus and far more for the sweep.
-- Only the first two coordinates are non-zero, so the zeros are appended by Postgres with
-- @repeat@ instead. The two significant components are still computed in Haskell — the ground
-- truth stays Haskell's — and the M1 instrument case asserts that the distances Postgres
-- actually computes for these rows match @1 - cos t@, which is what makes the shortcut safe
-- rather than merely clever.
sparseVectorSql :: Double -> Text
sparseVectorSql t =
  "('["
    <> showDouble (cos t)
    <> ","
    <> showDouble (sin t)
    <> "' || repeat(',0', "
    <> Text.pack (show (embeddingDimensions - 2))
    <> ") || ']')::vector"

showDouble :: Double -> Text
showDouble = Text.pack . show

chunksOf :: Int -> [a] -> [[a]]
chunksOf n xs
  | n <= 0 = [xs]
  | otherwise = case splitAt n xs of
      (chunk, []) -> [chunk | not (null chunk)]
      (chunk, rest) -> chunk : chunksOf n rest

-- * Measurement

-- | What the vector channel actually did.
data RecallQuality = RecallQuality
  { -- | How many candidates the vector channel produced. The pool is 50
    -- ('Kioku.Recall.candidatePoolSize'), so a healthy selective scope returns 50.
    rowsReturned :: !Int,
    -- | Of the @k@ truly nearest in-scope memories, what fraction came back. 1.0 is perfect;
    -- 0.0 means the search found none of them.
    recallAtK :: !Double,
    k :: !Int,
    -- | How many of the returned rows were decoys. Must always be zero: the scope filter is a
    -- correctness boundary, and a non-zero value here means something far worse than starvation.
    decoysReturned :: !Int,
    -- | Rows the approximate (HNSW) pass returned, before any exact fallback.
    annRows :: !Int,
    -- | Whether the exact fallback ran because the approximate pass came back short.
    exactFallbackFired :: !Bool,
    -- | @EXPLAIN (ANALYZE, BUFFERS)@ for the query as it is actually issued. Carried so a
    -- failing case can print the cause rather than just @expected: True, got: False@.
    planText :: !Text,
    -- | The row count the captured plan's top node actually produced. If this disagrees with
    -- 'rowsReturned', the EXPLAIN is describing a query nobody runs — see 'planAgreesWithQuery'.
    planTopRows :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

-- | Does the captured plan describe the query that was actually measured?
--
-- This is the instrument's self-check, and it exists because the instrument got this wrong
-- once. An @EXPLAIN@ whose SQL differs from the real statement in any way the planner cares
-- about — notably the width of the select list, which sets the cost of the top-N sort the
-- /exact/ plan needs — can choose a different plan and report a different result. The failure
-- mode is silent and flattering: the EXPLAIN says "50 rows, all good" while the real query
-- returns zero.
--
-- So: the plan's top node must have produced the same number of rows the query returned. If it
-- did not, every conclusion drawn from 'planText' is void, and a case built on it must fail
-- loudly rather than report a comfortable number.
--
-- The comparison is against 'annRows', not 'rowsReturned', because 'planText' captures the
-- /approximate/ statement, and the channel may then run an exact fallback whose rows the ANN plan
-- naturally does not account for. Comparing against the final count would make this check fail
-- precisely when the fallback is doing its job — which would be a false alarm, and a false alarm
-- that fires every time is a check nobody keeps.
planAgreesWithQuery :: RecallQuality -> Bool
planAgreesWithQuery q = maybe False (== q.annRows) q.planTopRows

-- | Pull @rows=N@ out of the @(actual time=… rows=N loops=1)@ segment of the plan's first line,
-- which is its top node. Returns 'Nothing' if the plan has no @actual@ section, which would
-- mean the EXPLAIN ran without @ANALYZE@ and is not a measurement at all.
planActualTopRows :: Text -> Maybe Int
planActualTopRows plan = do
  firstLine <- case Text.lines plan of
    l : _ -> Just l
    [] -> Nothing
  actual <- afterToken "actual" firstLine
  rows <- afterToken "rows=" actual
  readMaybe (Text.unpack (Text.takeWhile isDigit rows))
  where
    afterToken token haystack =
      case Text.breakOn token haystack of
        (_, rest)
          | Text.null rest -> Nothing
          | otherwise -> Just (Text.drop (Text.length token) rest)

-- | Run the vector channel against a seeded corpus and score what it returned.
--
-- This drives 'Kioku.Recall.selectVectorCandidates' — the exported test seam — rather than a
-- copy of the SQL, so when the statement changes the harness measures the /new/ one and cannot
-- silently keep testing a query that no longer runs in production.
measureRecallQuality :: (Store :> es) => SeededCorpus -> Int -> Eff es RecallQuality
measureRecallQuality corpus k = do
  (outcome, rows) <- selectVectorCandidatesDiagnosed (vectorRequest corpus) queryVector
  -- Both passes and the plan below run against the same statement family, because they are all
  -- compiled from the corpus's own target.
  plan <- explainVectorQuery corpus
  pure (scoreRecallQuality corpus k rows plan outcome.annRows outcome.exactFallbackFired)

-- | 'measureRecallQuality', but with @SET LOCAL@ settings applied to the transaction the vector
-- statement runs in — the seam the bake-off in
-- docs/plans/19-fix-filtered-ann-starvation-in-vector-recall.md needs.
--
-- Two details make this a real measurement rather than a plausible one.
--
-- First, the settings and the query must share a transaction. @SET LOCAL@ lasts exactly as long
-- as the surrounding transaction, so issuing it in one @runTransaction@ and the query in another
-- is a no-op that silently measures the baseline while claiming to measure the candidate — and
-- reports a confident number either way. Both go in the single transaction below.
--
-- Second, the query is the shipping approximate pass itself, not a copy: both it and the
-- @EXPLAIN@ are driven from the one 'Kioku.Recall.VectorCandidateSql' the corpus's target
-- compiles to, and the @EXPLAIN@ runs under the same settings in its own transaction.
-- 'planAgreesWithQuery' still guards the pair.
measureRecallQualityWith ::
  (Store :> es) =>
  -- | @SET LOCAL@ statements, e.g. @["SET LOCAL hnsw.iterative_scan = 'strict_order'"]@.
  [Text] ->
  SeededCorpus ->
  Int ->
  Eff es RecallQuality
measureRecallQualityWith settings corpus k = do
  rows <- runTransaction do
    traverse_ (Tx.sql . encodeUtf8) settings
    runVectorAnnCandidates (vectorCandidates corpus)
  plan <- explainVectorQueryWith settings corpus
  -- This drives the raw ANN statement, with no fallback, so the ANN pass *is* the whole channel.
  pure (scoreRecallQuality corpus k rows plan (length rows) False)

scoreRecallQuality :: SeededCorpus -> Int -> [MemoryRecord] -> Text -> Int -> Bool -> RecallQuality
scoreRecallQuality corpus k rows plan annPassRows fallbackFired =
  RecallQuality
    { rowsReturned = length rows,
      recallAtK =
        if null truth
          then 0
          else fromIntegral found / fromIntegral (length truth),
      k,
      decoysReturned = length (filter ("m_decoy_" `Text.isPrefixOf`) returned),
      annRows = annPassRows,
      exactFallbackFired = fallbackFired,
      planText = plan,
      planTopRows = planActualTopRows plan
    }
  where
    returned = (\row -> row.memoryId) <$> rows
    returnedSet = Set.fromList returned
    truth = take k corpus.trueNearestInScope
    found = length (filter (`Set.member` returnedSet) truth)

-- | The request the vector channel is driven with. The query /text/ is irrelevant — the vector
-- statement never reads it — but a 'RecallQuery' requires one.
--
-- It goes through 'resolveRecall' rather than being assembled by hand, so the harness measures
-- the same target-to-statement mapping recall itself uses, whichever of the three families the
-- corpus's target selects.
vectorRequest :: SeededCorpus -> ResolvedRecall
vectorRequest corpus =
  resolveRecall
    testSpace
    RecallQuery
      { target = corpus.config.target,
        query = "seeded corpus row",
        strategy = Embedding,
        maxResults = expectValidLimit 10
      }

-- | The compiled vector query the measurement, the plan capture, and recall itself all share.
vectorCandidates :: SeededCorpus -> VectorCandidateSql
vectorCandidates corpus = vectorCandidateSql (vectorRequest corpus) queryVector

expectValidLimit :: Int -> RecallLimit
expectValidLimit = either (error . Text.unpack) id . mkRecallLimit

-- | @EXPLAIN (ANALYZE, BUFFERS)@ for the vector candidate query, over exactly the statement and
-- parameters recall issues, so Postgres plans it the way it plans the real one.
explainVectorQuery :: (Store :> es) => SeededCorpus -> Eff es Text
explainVectorQuery = explainVectorQueryWith []

-- | 'explainVectorQuery' with @SET LOCAL@ settings applied to the same transaction. They must
-- share a transaction: @SET LOCAL@ lasts exactly as long as the surrounding one, so a setting
-- issued separately would silently EXPLAIN the baseline while claiming to EXPLAIN the candidate.
explainVectorQueryWith :: (Store :> es) => [Text] -> SeededCorpus -> Eff es Text
explainVectorQueryWith settings corpus =
  Text.unlines <$> runTransaction do
    traverse_ (Tx.sql . encodeUtf8) settings
    explainVectorAnnCandidates (vectorCandidates corpus)

-- | A failure message that reads as a diagnosis rather than an assertion.
--
-- The whole purpose of this harness is to convert an invisible failure into a legible one, so a
-- case that fails with @expected: True, got: False@ has not delivered it. The most telling line
-- in the plan is @Rows Removed by Filter@ — starvation, made visible.
describeRecallQuality :: RecallQuality -> String
describeRecallQuality q =
  Text.unpack . Text.unlines $
    [ "the vector channel returned "
        <> Text.pack (show q.rowsReturned)
        <> " candidates, recall@"
        <> Text.pack (show q.k)
        <> " = "
        <> Text.pack (show q.recallAtK)
        <> (if q.decoysReturned > 0 then " (!! " <> Text.pack (show q.decoysReturned) <> " out-of-scope decoys leaked)" else ""),
      "plan: "
        <> (if usedHnswIndex q then "HNSW (approximate)" else "exact")
        <> ( if planAgreesWithQuery q
               then ""
               else
                 " -- !! the captured plan produced "
                   <> Text.pack (show q.planTopRows)
                   <> " rows but the query returned "
                   <> Text.pack (show q.rowsReturned)
                   <> "; the EXPLAIN is describing a different query and cannot be trusted"
           ),
      q.planText
    ]

-- | Whether a captured plan used the HNSW index — the approximate path — as opposed to the
-- exact plan over @kioku_memories_space_scope_idx@. Which one Postgres picked is the load-bearing
-- observation: the previous initiative found it returning 50 correct rows on the exact plan and
-- zero on the HNSW one, and a measurement that does not record the plan has not measured the
-- thing that matters.
usedHnswIndex :: RecallQuality -> Bool
usedHnswIndex q = "kioku_memories_embedding_hnsw" `isInfixOf` Text.unpack q.planText

-- | Run arbitrary DDL against the seeded corpus and re-@ANALYZE@ — the seam the bake-off needs
-- to prototype an /index/ candidate without shipping a migration for it. Each statement is its
-- own committed transaction, because a rebuilt index that the planner cannot see is the same
-- confidently-wrong measurement as an uncommitted row.
runDdl :: (Store :> es) => [Text] -> Eff es ()
runDdl statements = do
  traverse_ (runTransaction . Tx.sql . encodeUtf8) statements
  runTransaction (Tx.sql "ANALYZE kioku.memories")
