module Kioku.Recall
  ( RecallStrategy (..),
    RecallRequest (..),
    RecallHit (..),
    RecallExecutionPlan (..),
    recall,
    planRecallExecution,
    fuseRecallCandidates,
    blendScore,
    rrfTerm,
    recencyDecay,
    priorityWeight,
    confidenceWeight,
    applyCharacterBudgets,
    getActiveInNamespace,
    getActiveByScope,
    getGlobal,
    getById,
    getBySession,
    getByType,

    -- * Test seams
    -- $testSeams
    selectFtsCandidates,
    selectVectorCandidates,
    vectorLiteral,
  )
where

import Baikai.Embedding (EmbeddingModel)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int32)
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (diffUTCTime)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.ReadModel (ConsistencyMode (..), ReadModelError, runQueryWith)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), scopeFromColumns, scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Api.Types (MemoryRecord (..), MemoryType, memoryTypeToText)
import Kioku.Id (MemoryId, SessionId, idText)
import Kioku.Memory.Embedding (embedWithRetry)
import Kioku.Memory.ReadModel
  ( MemoriesByNamespaceQuery (..),
    MemoriesByScopeQuery (..),
    MemoriesBySessionQuery (..),
    MemoriesByTypeQuery (..),
    MemoryByIdQuery (..),
    MemoryRow (..),
    memoriesByNamespaceReadModel,
    memoriesByScopeReadModel,
    memoriesBySessionReadModel,
    memoriesByTypeReadModel,
    memoryByIdReadModel,
  )
import Kioku.Prelude
import Kioku.Recall.Capability (VectorCapability (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)

-- $testSeams
-- Exported so the candidate SQL can be exercised directly against a real database
-- (@Kioku.RecallSqlSpec@) rather than only through 'recall', which would drag in an
-- embedding endpoint. They are not part of the intended public API.

data RecallStrategy = Keyword | Embedding | Hybrid
  deriving stock (Generic, Eq, Show)

data RecallRequest = RecallRequest
  { scope :: !MemoryScope,
    query :: !Text,
    strategy :: !RecallStrategy,
    maxResults :: !Int
  }
  deriving stock (Generic, Eq, Show)

data RecallHit = RecallHit
  { memory :: !MemoryRecord,
    score :: !Double,
    ftsRank :: !(Maybe Int),
    vecRank :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

data RecallExecutionPlan = RecallExecutionPlan
  { runFts :: !Bool,
    runVector :: !Bool,
    needsQueryEmbedding :: !Bool
  }
  deriving stock (Generic, Eq, Show)

data RecallCandidateQuery = RecallCandidateQuery
  { query :: !Text,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text),
    limit :: !Int32
  }
  deriving stock (Generic, Eq, Show)

data VectorCandidateQuery = VectorCandidateQuery
  { queryVector :: !Text,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text),
    limit :: !Int32
  }
  deriving stock (Generic, Eq, Show)

data FusedCandidate = FusedCandidate
  { memory :: !MemoryRecord,
    ftsRank :: !(Maybe Int),
    vecRank :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

recall ::
  (IOE :> es, Store :> es) =>
  EmbeddingModel ->
  VectorCapability ->
  RecallRequest ->
  Eff es [RecallHit]
recall model capability req = do
  now <- liftIO getCurrentTime
  executeRecallPlan now model req (planRecallExecution capability req.strategy)

planRecallExecution :: VectorCapability -> RecallStrategy -> RecallExecutionPlan
planRecallExecution capability strategy =
  case capability of
    VectorAvailable ->
      case strategy of
        Keyword -> RecallExecutionPlan {runFts = True, runVector = False, needsQueryEmbedding = False}
        Embedding -> RecallExecutionPlan {runFts = False, runVector = True, needsQueryEmbedding = True}
        Hybrid -> RecallExecutionPlan {runFts = True, runVector = True, needsQueryEmbedding = True}
    VectorExtensionUnavailable ->
      keywordExecutionPlan
    VectorColumnsUnavailable _ ->
      keywordExecutionPlan

keywordExecutionPlan :: RecallExecutionPlan
keywordExecutionPlan =
  RecallExecutionPlan {runFts = True, runVector = False, needsQueryEmbedding = False}

executeRecallPlan ::
  (IOE :> es, Store :> es) =>
  UTCTime ->
  EmbeddingModel ->
  RecallRequest ->
  RecallExecutionPlan ->
  Eff es [RecallHit]
executeRecallPlan now model req execution
  | execution.needsQueryEmbedding =
      embedThenRecall now model req execution
  | otherwise = do
      ftsRows <- selectIf execution.runFts (selectFtsCandidates req)
      pure (finishRecall now req ftsRows [])

embedThenRecall ::
  (IOE :> es, Store :> es) =>
  UTCTime ->
  EmbeddingModel ->
  RecallRequest ->
  RecallExecutionPlan ->
  Eff es [RecallHit]
embedThenRecall now model req execution = do
  embedded <- liftIO (embedWithRetry model 2 req.query)
  case embedded of
    Left _err ->
      keywordOnly now req
    Right queryVector -> do
      ftsRows <- selectIf execution.runFts (selectFtsCandidates req)
      vecRows <- selectIf execution.runVector (selectVectorCandidates req queryVector)
      pure (finishRecall now req ftsRows vecRows)

keywordOnly ::
  (Store :> es) =>
  UTCTime ->
  RecallRequest ->
  Eff es [RecallHit]
keywordOnly now req = do
  ftsRows <- selectFtsCandidates req
  pure (finishRecall now req ftsRows [])

selectIf :: (Applicative f) => Bool -> f [a] -> f [a]
selectIf True action = action
selectIf False _ = pure []

finishRecall :: UTCTime -> RecallRequest -> [MemoryRecord] -> [MemoryRecord] -> [RecallHit]
finishRecall now req ftsRows vecRows =
  applyCharacterBudgets perMemoryCharacterBudget totalCharacterBudget $
    take (max 0 req.maxResults) $
      fuseRecallCandidates now ftsRows vecRows

selectFtsCandidates ::
  (Store :> es) =>
  RecallRequest ->
  Eff es [MemoryRecord]
selectFtsCandidates req =
  runTransaction $
    Tx.statement
      (candidateQuery req)
      selectFtsCandidatesStmt

selectVectorCandidates ::
  (Store :> es) =>
  RecallRequest ->
  Vector Double ->
  Eff es [MemoryRecord]
selectVectorCandidates req queryVector =
  runTransaction $
    Tx.statement
      (vectorCandidateQuery req queryVector)
      selectVectorCandidatesStmt

candidateQuery :: RecallRequest -> RecallCandidateQuery
candidateQuery req =
  RecallCandidateQuery
    { query = req.query,
      namespace = scopeNamespaceText req.scope,
      scopeKind = scopeKindText req.scope,
      scopeRef = scopeRefText req.scope,
      limit = candidatePoolSize
    }

vectorCandidateQuery :: RecallRequest -> Vector Double -> VectorCandidateQuery
vectorCandidateQuery req queryVector =
  VectorCandidateQuery
    { queryVector = vectorLiteral queryVector,
      namespace = scopeNamespaceText req.scope,
      scopeKind = scopeKindText req.scope,
      scopeRef = scopeRefText req.scope,
      limit = candidatePoolSize
    }

fuseRecallCandidates :: UTCTime -> [MemoryRecord] -> [MemoryRecord] -> [RecallHit]
fuseRecallCandidates now ftsRows vecRows =
  List.sortOn (Down . (\hit -> hit.score)) $
    toHit <$> Map.elems fused
  where
    fused =
      foldRanked (\rank row -> upsertFts row rank) Map.empty ftsRows
        & \m -> foldRanked (\rank row -> upsertVec row rank) m vecRows

    toHit candidate =
      RecallHit
        { memory = candidate.memory,
          score = blendScore now candidate.memory candidate.ftsRank candidate.vecRank,
          ftsRank = candidate.ftsRank,
          vecRank = candidate.vecRank
        }

foldRanked :: (Int -> MemoryRecord -> Map Text FusedCandidate -> Map Text FusedCandidate) -> Map Text FusedCandidate -> [MemoryRecord] -> Map Text FusedCandidate
foldRanked f initial rows =
  foldl
    (\acc (rank, row) -> f rank row acc)
    initial
    (zip [1 ..] rows)

upsertFts :: MemoryRecord -> Int -> Map Text FusedCandidate -> Map Text FusedCandidate
upsertFts row rank =
  Map.alter (Just . addRank) row.memoryId
  where
    addRank :: Maybe FusedCandidate -> FusedCandidate
    addRank Nothing =
      FusedCandidate {memory = row, ftsRank = Just rank, vecRank = Nothing}
    addRank (Just existing) =
      FusedCandidate
        { memory = existing.memory,
          ftsRank = existing.ftsRank <|> Just rank,
          vecRank = existing.vecRank
        }

upsertVec :: MemoryRecord -> Int -> Map Text FusedCandidate -> Map Text FusedCandidate
upsertVec row rank =
  Map.alter (Just . addRank) row.memoryId
  where
    addRank :: Maybe FusedCandidate -> FusedCandidate
    addRank Nothing =
      FusedCandidate {memory = row, ftsRank = Nothing, vecRank = Just rank}
    addRank (Just existing) =
      FusedCandidate
        { memory = existing.memory,
          ftsRank = existing.ftsRank,
          vecRank = existing.vecRank <|> Just rank
        }

blendScore :: UTCTime -> MemoryRecord -> Maybe Int -> Maybe Int -> Double
blendScore now memory ftsRank vecRank =
  maybe 0 rrfTerm ftsRank
    + maybe 0 rrfTerm vecRank
    + recencyWeight * recencyDecay now memory.createdAt
    + prioritySignalWeight * priorityWeight memory.priority
    + confidenceSignalWeight * confidenceWeight memory.confidence

rrfTerm :: Int -> Double
rrfTerm rank =
  1 / (rrfK + fromIntegral rank)

recencyDecay :: UTCTime -> UTCTime -> Double
recencyDecay now createdAt =
  exp (negate (log 2) * ageDays / recencyHalfLifeDays)
  where
    ageDays = max 0 (realToFrac (diffUTCTime now createdAt) / secondsPerDay)

priorityWeight :: Int -> Double
priorityWeight priority
  | priority <= alwaysInjectPriority = 1
  | otherwise = clamp01 (1 - (fromIntegral priority / priorityMax))

confidenceWeight :: Text -> Double
confidenceWeight = \case
  "high" -> 1
  "medium" -> 0.6
  "low" -> 0.3
  _ -> 0.3

applyCharacterBudgets :: Int -> Int -> [RecallHit] -> [RecallHit]
applyCharacterBudgets perMemoryCap totalCap =
  go 0 []
  where
    go _ acc [] = reverse acc
    go used acc (hit : rest)
      | totalCap <= 0 = reverse acc
      | used + Text.length truncated.memory.content > totalCap = reverse acc
      | otherwise = go (used + Text.length truncated.memory.content) (truncated : acc) rest
      where
        truncated = truncateHit perMemoryCap hit

truncateHit :: Int -> RecallHit -> RecallHit
truncateHit cap hit =
  RecallHit
    { memory = truncateMemory cap hit.memory,
      score = hit.score,
      ftsRank = hit.ftsRank,
      vecRank = hit.vecRank
    }

truncateMemory :: Int -> MemoryRecord -> MemoryRecord
truncateMemory cap row =
  MemoryRecord
    { memoryId = row.memoryId,
      agentId = row.agentId,
      sessionId = row.sessionId,
      scope = row.scope,
      memoryType = row.memoryType,
      content = truncateText cap row.content,
      priority = row.priority,
      confidence = row.confidence,
      tags = row.tags,
      status = row.status,
      createdAt = row.createdAt
    }

truncateText :: Int -> Text -> Text
truncateText cap content
  | cap <= 0 = ""
  | Text.length content <= cap = content
  | cap <= Text.length ellipsis = Text.take cap ellipsis
  | otherwise = Text.take (cap - Text.length ellipsis) content <> ellipsis

clamp01 :: Double -> Double
clamp01 = max 0 . min 1

selectFtsCandidatesStmt :: Statement RecallCandidateQuery [MemoryRecord]
selectFtsCandidatesStmt =
  preparable
    ( "SELECT "
        <> memoryRecordColumns
        <> """
            FROM kiroku.kioku_memories
           WHERE status = 'active'
             AND namespace = $2
             AND (($3 IS NULL AND $4 IS NULL) OR (scope_kind = $3 AND scope_ref = $4))
             AND content_tsv @@ websearch_to_tsquery('english', $1)
           ORDER BY ts_rank(content_tsv, websearch_to_tsquery('english', $1)) DESC, created_at DESC
           LIMIT $5
           """
    )
    recallCandidateQueryEncoder
    (D.rowList memoryRecordDecoder)

-- | Vector candidates, ordered by cosine distance and nothing else.
--
-- The @ORDER BY@ is deliberately a single expression. An HNSW index can only produce the
-- distance pathkey, so a second sort key (this query used to carry @created_at DESC@) leaves
-- the planner to make up the difference: on PostgreSQL 13+ it bolts an @Incremental Sort@ on
-- top of the index scan, and where incremental sort is unavailable or disabled it abandons
-- the index entirely for a sequential scan plus a full sort. Ordering by distance alone makes
-- the index scan unconditional. Nothing is lost: the statement does not return the distance,
-- so a caller could not re-break ties anyway, and exact ties between 1536-dimension float
-- vectors essentially do not occur.
--
-- Recall that this is a *post-filtered* ANN scan: the namespace, scope and status predicates
-- are applied to rows the index has already chosen by distance. See 'candidatePoolSize' for
-- what that costs.
selectVectorCandidatesStmt :: Statement VectorCandidateQuery [MemoryRecord]
selectVectorCandidatesStmt =
  preparable
    ( "SELECT "
        <> memoryRecordColumns
        <> """
            FROM kiroku.kioku_memories
           WHERE status = 'active'
             AND namespace = $2
             AND (($3 IS NULL AND $4 IS NULL) OR (scope_kind = $3 AND scope_ref = $4))
             AND embedding IS NOT NULL
           ORDER BY embedding <=> $1::vector
           LIMIT $5
           """
    )
    vectorCandidateQueryEncoder
    (D.rowList memoryRecordDecoder)

recallCandidateQueryEncoder :: E.Params RecallCandidateQuery
recallCandidateQueryEncoder =
  ((\q -> q.query) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\q -> q.scopeRef) >$< E.param (E.nullable E.text))
    <> ((\q -> q.limit) >$< E.param (E.nonNullable E.int4))

vectorCandidateQueryEncoder :: E.Params VectorCandidateQuery
vectorCandidateQueryEncoder =
  ((\q -> q.queryVector) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\q -> q.scopeRef) >$< E.param (E.nullable E.text))
    <> ((\q -> q.limit) >$< E.param (E.nonNullable E.int4))

memoryRecordColumns :: Text
memoryRecordColumns =
  "memory_id, agent_id, session_id, namespace, scope_kind, scope_ref, memory_type, content, priority, confidence, tags::text, status, created_at "

memoryRecordDecoder :: D.Row MemoryRecord
memoryRecordDecoder =
  makeMemoryRecord
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> (fromIntegral @Int32 @Int <$> D.column (D.nonNullable D.int4))
    <*> D.column (D.nonNullable D.text)
    <*> (decodeTags <$> D.column (D.nonNullable D.text))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)

makeMemoryRecord ::
  Text ->
  Text ->
  Maybe Text ->
  Text ->
  Maybe Text ->
  Maybe Text ->
  Text ->
  Text ->
  Int ->
  Text ->
  Set.Set Text ->
  Text ->
  UTCTime ->
  MemoryRecord
makeMemoryRecord memoryId agentId sessionId namespace scopeKind scopeRef memoryType content priority confidence tags status createdAt =
  MemoryRecord
    { memoryId,
      agentId,
      sessionId,
      scope = scopeFromColumns namespace scopeKind scopeRef,
      memoryType,
      content,
      priority,
      confidence,
      tags,
      status,
      createdAt
    }

decodeTags :: Text -> Set.Set Text
decodeTags =
  fromMaybe Set.empty . Aeson.decode . BL.fromStrict . TE.encodeUtf8

vectorLiteral :: Vector Double -> Text
vectorLiteral values =
  "[" <> Text.intercalate "," (Text.pack . show <$> Vector.toList values) <> "]"

-- | How many candidates each channel contributes to the RRF fusion.
--
-- Do not "fix" the vector channel by raising @hnsw.ef_search@ to cover this pool. That was
-- tried, on the theory that the 40 default sits below this 50 and so could never fill it, and
-- measurement refuted it twice over. First, pgvector already searches with
-- @ef = max(ef_search, LIMIT)@, so the pool fills at the default. Second, raising it is
-- actively harmful: with 1536-dimension vectors, 2000 rows in the target namespace and 2000
-- nearer rows in another, @SET hnsw.ef_search = 200@ flipped the planner from an exact plan
-- (bitmap scan on the scope index, top-N sort, 50 correct rows) onto an HNSW scan that spent
-- its whole budget on rows the namespace filter then discarded — 1648 removed, __zero__
-- returned. The default kept the exact plan.
--
-- The underlying hazard is real and predates this code: the HNSW scan is post-filtered, so a
-- selective predicate that correlates with distance can starve the pool. pgvector 0.8's
-- @hnsw.iterative_scan@ is the intended remedy, but it is not a drop-in — @relaxed_order@
-- returned zero rows on the same probe — and it would pin a minimum pgvector version. It
-- needs its own investigation rather than a hopeful @SET@.
candidatePoolSize :: Int32
candidatePoolSize = 50

rrfK :: Double
rrfK = 60

recencyWeight :: Double
recencyWeight = 0.10

prioritySignalWeight :: Double
prioritySignalWeight = 0.15

confidenceSignalWeight :: Double
confidenceSignalWeight = 0.05

recencyHalfLifeDays :: Double
recencyHalfLifeDays = 30

secondsPerDay :: Double
secondsPerDay = 86400

priorityMax :: Double
priorityMax = 100

alwaysInjectPriority :: Int
alwaysInjectPriority = 0

perMemoryCharacterBudget :: Int
perMemoryCharacterBudget = 2000

totalCharacterBudget :: Int
totalCharacterBudget = 12000

ellipsis :: Text
ellipsis = "..."

getActiveByScope ::
  (IOE :> es, Store :> es) =>
  MemoryScope ->
  Eff es (Either ReadModelError [MemoryRecord])
getActiveByScope scope =
  runQueryWith
    Nothing
    Eventual
    memoriesByScopeReadModel
    (MemoriesByScopeQuery (scopeNamespaceText scope) (scopeKindText scope) (scopeRefText scope))

getActiveInNamespace ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  Eff es (Either ReadModelError [MemoryRecord])
getActiveInNamespace (Namespace ns) =
  runQueryWith Nothing Eventual memoriesByNamespaceReadModel (MemoriesByNamespaceQuery ns)

getGlobal ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  Eff es (Either ReadModelError [MemoryRecord])
getGlobal ns =
  getActiveByScope (ScopeGlobal ns)

getById ::
  (IOE :> es, Store :> es) =>
  MemoryId ->
  Eff es (Either ReadModelError (Maybe MemoryRecord))
getById mid =
  fmap (fmap (fmap memoryRowToRecord)) $
    runQueryWith Nothing Eventual memoryByIdReadModel (MemoryByIdQuery (idText mid))

getBySession ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  Eff es (Either ReadModelError [MemoryRecord])
getBySession sid =
  runQueryWith Nothing Eventual memoriesBySessionReadModel (MemoriesBySessionQuery (idText sid))

getByType ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  MemoryType ->
  Eff es (Either ReadModelError [MemoryRecord])
getByType (Namespace ns) mt =
  runQueryWith Nothing Eventual memoriesByTypeReadModel (MemoriesByTypeQuery ns (memoryTypeToText mt))

memoryRowToRecord :: MemoryRow -> MemoryRecord
memoryRowToRecord row =
  MemoryRecord
    { memoryId = row.memoryId,
      agentId = row.agentId,
      sessionId = row.sessionId,
      scope = scopeFromColumns row.namespace row.scopeKind row.scopeRef,
      memoryType = row.memoryType,
      content = row.content,
      priority = row.priority,
      confidence = row.confidence,
      tags = row.tags,
      status = row.status,
      createdAt = row.createdAt
    }
