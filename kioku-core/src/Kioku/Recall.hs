module Kioku.Recall
  ( RecallStrategy (..),
    RecallRequest (..),
    RecallHit (..),
    recall,
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
    getBySession,
    getByType,
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
import Kioku.Id (SessionId, idText)
import Kioku.Memory.Embedding (embedWithRetry)
import Kioku.Memory.ReadModel
  ( MemoriesByNamespaceQuery (..),
    MemoriesByScopeQuery (..),
    MemoriesBySessionQuery (..),
    MemoriesByTypeQuery (..),
    memoriesByNamespaceReadModel,
    memoriesByScopeReadModel,
    memoriesBySessionReadModel,
    memoriesByTypeReadModel,
  )
import Kioku.Prelude
import Kioku.Recall.Capability (VectorCapability (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)

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
  case capability of
    VectorAvailable ->
      recallWithVectorCapability now model req
    VectorExtensionUnavailable ->
      keywordOnly now req
    VectorColumnsUnavailable _ ->
      keywordOnly now req

recallWithVectorCapability ::
  (IOE :> es, Store :> es) =>
  UTCTime ->
  EmbeddingModel ->
  RecallRequest ->
  Eff es [RecallHit]
recallWithVectorCapability now model req =
  case req.strategy of
    Keyword -> keywordOnly now req
    Embedding -> embedThenRecall now model req
    Hybrid -> embedThenRecall now model req

embedThenRecall ::
  (IOE :> es, Store :> es) =>
  UTCTime ->
  EmbeddingModel ->
  RecallRequest ->
  Eff es [RecallHit]
embedThenRecall now model req = do
  embedded <- liftIO (embedWithRetry model 2 req.query)
  case embedded of
    Left _err ->
      keywordOnly now req
    Right queryVector -> do
      ftsRows <-
        if req.strategy == Embedding
          then pure []
          else selectFtsCandidates req
      vecRows <- selectVectorCandidates req queryVector
      pure (finishRecall now req ftsRows vecRows)

keywordOnly ::
  (Store :> es) =>
  UTCTime ->
  RecallRequest ->
  Eff es [RecallHit]
keywordOnly now req = do
  ftsRows <- selectFtsCandidates req
  pure (finishRecall now req ftsRows [])

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
           ORDER BY embedding <=> $1::vector, created_at DESC
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
