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
-- 2. __A partial index needs its predicate restated in the query__, or the planner cannot prove
--    the index applies and falls back to a sequential scan. The @embedding IS NOT NULL@ in
--    'explainVectorStmt' is load-bearing, not decoration.
--
-- See docs/plans/18-build-a-recall-quality-harness-that-reproduces-filtered-ann-starvation.md.
module Kioku.RecallHarness
  ( -- * Geometry
    vectorAtAngle,
    queryVector,
    cosineDistanceAtAngle,
    embeddingDimensions,

    -- * Seeding
    CorpusConfig (..),
    defaultStarvationCorpus,
    SeededCorpus (..),
    seedCorpus,

    -- * Measurement
    RecallQuality (..),
    measureRecallQuality,
    explainVectorQuery,
    describeRecallQuality,
    usedHnswIndex,
    planAgreesWithQuery,
  )
where

import Data.Char (isDigit)
import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int32)
import Data.List (isInfixOf, sortOn)
import Data.Set qualified as Set
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
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Api.Types (MemoryRecord (..))
import Kioku.Recall (RecallRequest (..), RecallStrategy (..), selectVectorCandidates)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Text.Read (readMaybe)

-- * Geometry

-- | The width of @kioku_memories.embedding@, which is @vector(1536)@. A seeded vector must
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
-- Starvation needs the filter to /correlate with distance/: the rows the scope filter throws
-- away must be the ones the index reaches for first. So the decoys live in a different
-- namespace and sit /nearer/ the query than any in-scope row.
data CorpusConfig = CorpusConfig
  { -- | Memories in the namespace and scope the query asks for. These are the true answers.
    inScopeCount :: !Int,
    -- | Memories in a /different/ namespace, which the query must never return.
    decoyCount :: !Int,
    -- | The angular band (radians) the in-scope rows are spread evenly across.
    inScopeAngles :: !(Double, Double),
    -- | The angular band the decoys occupy. Make it strictly nearer the query than
    -- 'inScopeAngles' — that is, smaller angles — or nothing starves.
    decoyAngles :: !(Double, Double)
  }
  deriving stock (Eq, Show)

-- | The probe the previous initiative recorded as "1648 rows removed by filter, zero returned":
-- 2000 in-scope memories, 2000 nearer decoys in another namespace.
--
-- Every decoy is strictly nearer the query than every in-scope row. In cosine distance the
-- decoys span roughly 0.001 to 0.12 and the in-scope rows roughly 0.30 to 0.64, so the index,
-- descending towards the query, meets all 2000 decoys before the first true answer.
defaultStarvationCorpus :: CorpusConfig
defaultStarvationCorpus =
  CorpusConfig
    { inScopeCount = 2000,
      decoyCount = 2000,
      inScopeAngles = (0.8, 1.2),
      decoyAngles = (0.05, 0.5)
    }

-- | What was seeded, including the ground truth.
data SeededCorpus = SeededCorpus
  { config :: !CorpusConfig,
    -- | The scope the query asks for. Its namespace holds only the in-scope rows.
    targetScope :: !MemoryScope,
    -- | The in-scope memory ids ordered by true cosine distance, nearest first. Computed from
    -- the seed angles, never read back from the database.
    trueNearestInScope :: ![Text]
  }
  deriving stock (Eq, Show)

-- | The namespace the query asks for. Only in-scope rows live here.
targetNamespace :: Text
targetNamespace = "harness_target"

-- | The namespace the decoys live in. The query must never return one of these.
decoyNamespace :: Text
decoyNamespace = "harness_decoy"

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
        [ (inScopeId i, targetNamespace, t)
        | (i, t) <- zip [0 :: Int ..] (anglesAcross cfg.inScopeCount cfg.inScopeAngles)
        ]
      decoys =
        [ (decoyId i, decoyNamespace, t)
        | (i, t) <- zip [0 :: Int ..] (anglesAcross cfg.decoyCount cfg.decoyAngles)
        ]
  traverse_ insertBatch (chunksOf seedBatchSize (inScope <> decoys))
  runTransaction (Tx.sql "ANALYZE kioku_memories")
  pure
    SeededCorpus
      { config = cfg,
        targetScope = ScopeGlobal (Namespace targetNamespace),
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

insertBatch :: (Store :> es) => [(Text, Text, Double)] -> Eff es ()
insertBatch [] = pure ()
insertBatch rows =
  runTransaction . Tx.sql . encodeUtf8 $
    "INSERT INTO kioku_memories \
    \(memory_id, agent_id, namespace, scope_kind, scope_ref, memory_type, content, status, created_at, updated_at, embedding) VALUES "
      <> Text.intercalate ", " (row <$> rows)
  where
    row (memoryId, namespace, t) =
      "('"
        <> memoryId
        <> "', 'agent', '"
        <> namespace
        <> "', NULL, NULL, 'fact', 'seeded corpus row "
        <> memoryId
        <> "', 'active', now(), now(), "
        <> sparseVectorSql t
        <> ")"

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
planAgreesWithQuery :: RecallQuality -> Bool
planAgreesWithQuery q = maybe False (== q.rowsReturned) q.planTopRows

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
  rows <- selectVectorCandidates (vectorRequest corpus) queryVector
  plan <- explainVectorQuery corpus
  let returned = (\row -> row.memoryId) <$> rows
      returnedSet = Set.fromList returned
      truth = take k corpus.trueNearestInScope
      found = length (filter (`Set.member` returnedSet) truth)
  pure
    RecallQuality
      { rowsReturned = length rows,
        recallAtK =
          if null truth
            then 0
            else fromIntegral found / fromIntegral (length truth),
        k,
        decoysReturned = length (filter ("m_decoy_" `Text.isPrefixOf`) returned),
        planText = plan,
        planTopRows = planActualTopRows plan
      }

-- | The request the vector channel is driven with. The query /text/ is irrelevant — the vector
-- statement never reads it — but 'RecallRequest' requires one.
vectorRequest :: SeededCorpus -> RecallRequest
vectorRequest corpus =
  RecallRequest
    { scope = corpus.targetScope,
      query = "seeded corpus row",
      strategy = Embedding,
      maxResults = 10
    }

-- | @EXPLAIN (ANALYZE, BUFFERS)@ for the vector candidate query, run with the same five
-- parameters recall passes, so Postgres plans it the way it plans the real one.
explainVectorQuery :: (Store :> es) => SeededCorpus -> Eff es Text
explainVectorQuery corpus =
  Text.unlines
    <$> runTransaction
      ( Tx.statement
          ( Text.pack (show (Vector.toList queryVector)),
            scopeNamespaceText corpus.targetScope,
            scopeKindText corpus.targetScope,
            scopeRefText corpus.targetScope,
            explainPoolSize
          )
          explainVectorStmt
      )

-- | 'Kioku.Recall.candidatePoolSize' is not exported, so it is restated here. If the two ever
-- disagree the EXPLAIN describes a query nobody runs — but note that 'rowsReturned' and
-- 'recallAtK' are measured through the real 'selectVectorCandidates' and so use the real pool
-- size regardless. Only the plan text depends on this copy.
explainPoolSize :: Int32
explainPoolSize = 50

-- | The projection from 'Kioku.Recall.selectVectorCandidatesStmt', which does not export it.
-- It is restated here because the row width it implies changes which plan Postgres picks — see
-- 'explainVectorStmt'. If the two ever drift apart the captured plan stops describing the query
-- under test, and the EXPLAIN becomes a confidently-wrong measurement rather than an error.
-- 'planAgreesWithQuery' is the guard against exactly that.
memoryRecordColumns :: Text
memoryRecordColumns =
  "memory_id, agent_id, session_id, namespace, scope_kind, scope_ref, memory_type, content, priority, confidence, tags::text, status, created_at "

-- | Everything here is copied verbatim from 'Kioku.Recall.selectVectorCandidatesStmt' — the
-- select list, the predicates, the @ORDER BY@, and the @LIMIT@ — and every part of it earns
-- its place.
--
-- @embedding IS NOT NULL@ is not decoration: the HNSW index is partial on exactly that
-- predicate, and without it restated here the planner cannot prove the index applies and falls
-- back to a sequential scan — which would look like "the index is broken" and be entirely an
-- artifact of the measurement.
--
-- __The select list is load-bearing too, which is not obvious and was learned the hard way.__
-- An earlier version of this function selected @memory_id@ alone, on the theory that Postgres
-- chooses the plan from the @WHERE@, the @ORDER BY@ and the @LIMIT@, and that the projection
-- could not turn an HNSW scan into anything else. That is false. The projection sets the row
-- width, the width sets the cost of the top-N sort that the /exact/ plan needs, and that cost
-- is exactly what the planner weighs against the HNSW scan. On the 2000-in-scope, 2000-decoy
-- corpus the narrow projection made the sort look cheap, the planner took the exact plan, and
-- the EXPLAIN reported 50 happy rows — while the real query, with its 13 real columns, took
-- the HNSW plan and returned zero. The instrument was describing a query nobody runs.
explainVectorStmt :: Statement (Text, Text, Maybe Text, Maybe Text, Int32) [Text]
explainVectorStmt =
  preparable
    ( "EXPLAIN (ANALYZE, BUFFERS) SELECT "
        <> memoryRecordColumns
        <> " FROM kiroku.kioku_memories \
           \ WHERE status = 'active' \
           \   AND namespace = $2 \
           \   AND (($3 IS NULL AND $4 IS NULL) OR (scope_kind = $3 AND scope_ref = $4)) \
           \   AND embedding IS NOT NULL \
           \ ORDER BY embedding <=> $1::vector \
           \ LIMIT $5"
    )
    encoder
    (D.rowList (D.column (D.nonNullable D.text)))
  where
    encoder =
      ((\(v, _, _, _, _) -> v) >$< E.param (E.nonNullable E.text))
        <> ((\(_, n, _, _, _) -> n) >$< E.param (E.nonNullable E.text))
        <> ((\(_, _, sk, _, _) -> sk) >$< E.param (E.nullable E.text))
        <> ((\(_, _, _, sr, _) -> sr) >$< E.param (E.nullable E.text))
        <> ((\(_, _, _, _, l) -> l) >$< E.param (E.nonNullable E.int4))

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
-- exact plan over @kioku_memories_scope_idx@. Which one Postgres picked is the load-bearing
-- observation: the previous initiative found it returning 50 correct rows on the exact plan and
-- zero on the HNSW one, and a measurement that does not record the plan has not measured the
-- thing that matters.
usedHnswIndex :: RecallQuality -> Bool
usedHnswIndex q = "kioku_memories_embedding_hnsw" `isInfixOf` Text.unpack q.planText
