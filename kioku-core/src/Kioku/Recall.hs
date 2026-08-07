-- | Running a recall request, and the unranked scope scans beside it.
--
-- A recall call names two things that used to be one. The __target__ says what to search — one
-- exact scope, or every scope in one namespace — and comes from the caller. The __memory space__
-- says whose memories those are, and comes from the 'MemoryAccessContext' that authorized the
-- call. Widening the first can never widen the second, which is the property the vocabulary in
-- "Kioku.Api.Recall" exists to make visible at every call site.
--
-- The old entry point is still here. 'legacyRecall' takes the pre-target 'RecallRequest', maps
-- its 'MemoryScope' through 'legacyRecallTarget', and returns exactly the rows it returns today;
-- it is deprecated so that an unmigrated caller finds out at compile time rather than by counting
-- rows. See @docs\/user\/recall.md@ for the migration table and the removal condition.
module Kioku.Recall
  ( -- * What to search for
    RecallTarget (..),
    RecallQuery (..),
    RecallStrategy (..),
    RecallLimit,
    mkRecallQuery,
    mkRecallLimit,
    recallLimitInt,
    defaultRecallLimit,
    maxRecallLimit,
    recallStrategyText,
    parseRecallStrategy,
    allRecallStrategies,
    recallTargetNamespace,
    recallTargetExactScope,
    recallTargetIsNamespaceWide,

    -- * Running it
    RecallError (..),
    RecallHit (..),
    RecallExecutionPlan (..),
    recall,

    -- * The pre-target API, kept for one release
    RecallRequest (..),
    legacyRecall,
    legacyRecallTarget,
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
    ResolvedRecall,
    resolveRecall,
    selectFtsCandidates,
    selectVectorCandidates,
    vectorLiteral,
    selectVectorCandidatesStmt,
    selectVectorCandidatesExactStmt,
    selectVectorCandidatesDiagnosed,
    VectorChannelOutcome (..),
    vectorChannelStarved,
    VectorCandidateQuery,
    vectorCandidateQuery,
    memoryRecordColumns,
    candidatePoolSize,
  )
where

import Baikai.Embedding (EmbeddingModel)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
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
import Kioku.Api.Access (MemoryAccessContext, MemorySpaceId, memoryContextSpace)
import Kioku.Api.Recall
  ( RecallLimit,
    RecallQuery (..),
    RecallStrategy (..),
    RecallTarget (..),
    allRecallStrategies,
    defaultRecallLimit,
    legacyRecallTarget,
    maxRecallLimit,
    mkRecallLimit,
    mkRecallQuery,
    parseRecallStrategy,
    recallLimitInt,
    recallStrategyText,
    recallTargetExactScope,
    recallTargetIsNamespaceWide,
    recallTargetNamespace,
  )
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..), scopeFromColumns, scopeKindText, scopeNamespaceText, scopeRefText)
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
import Kioku.Partition (memorySpaceParam)
import Kioku.Prelude
import Kioku.Recall.Capability (VectorCapability (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)

-- $testSeams
-- Exported so the candidate SQL can be exercised directly against a real database
-- (@Kioku.RecallSqlSpec@) rather than only through 'recall', which would drag in an
-- embedding endpoint. They are not part of the intended public API.
--
-- 'selectVectorCandidatesStmt', 'vectorCandidateQuery', 'memoryRecordColumns' and
-- 'candidatePoolSize' are exported for @Kioku.RecallHarness@, the recall-quality instrument. It
-- needs the statement itself (rather than 'selectVectorCandidates', which wraps it in its own
-- transaction) so that it can run it under a @SET LOCAL@, and it needs the projection and the
-- pool size so that its @EXPLAIN@ describes the query that actually runs. That last one is not a
-- nicety: the projection's row width sets the cost of the top-N sort the /exact/ plan needs, and
-- that cost is what the planner weighs against the HNSW scan — so an @EXPLAIN@ carrying a
-- different select list can silently choose a different plan and report a different answer.
-- Restating them in the harness rather than exporting them is how the harness got that wrong
-- once.

-- | The pre-'RecallTarget' recall request.
--
-- __Global scope means \"namespace-wide\" here.__ A 'ScopeGlobal' request returns every active
-- memory in the namespace, entity-scoped rows included — the scope filter simply vanishes. That
-- is the opposite of what 'getActiveByScope' does with the same value, and it is the ambiguity
-- 'RecallTarget' replaces. The behaviour is preserved exactly for one release; see
-- 'legacyRecall'.
--
-- __The memory space was never part of that asymmetry.__ It is an equality predicate on every
-- channel and it never widens, whatever the scope says.
data RecallRequest = RecallRequest
  { memorySpaceId :: !MemorySpaceId,
    -- | 'ScopeGlobal' searches the whole namespace; an entity scope matches exactly.
    scope :: !MemoryScope,
    query :: !Text,
    strategy :: !RecallStrategy,
    maxResults :: !Int
  }
  deriving stock (Generic, Eq, Show)
{-# DEPRECATED RecallRequest "Use RecallQuery and a RecallTarget. ScopeGlobal here means namespace-wide; the exact global bucket is ExactScope (ScopeGlobal ns)." #-}

-- | Why a recall call could not run at all, as distinct from running and matching nothing.
--
-- Keeping those apart is the whole point of returning an 'Either' here. A caller cannot tell
-- \"this could not be asked\" from \"there is nothing here\" if both arrive as an empty list, and
-- only one of them is worth acting on.
data RecallError
  = -- | A 'RecallRequest' named a memory space that is not the one its context authorizes:
    -- @RecallSpaceMismatch requested authorized@. Only 'legacyRecall' can produce this, because
    -- only the legacy request carries a space of its own.
    RecallSpaceMismatch !MemorySpaceId !MemorySpaceId
  | -- | The exact global bucket of a namespace was requested, and the candidate SQL cannot yet
    -- express it.
    --
    -- This is a deliberate refusal rather than a wrong answer. Both candidate statements spell
    -- the scope filter @(($4 IS NULL AND $5 IS NULL) OR (scope_kind = $4 AND scope_ref = $5))@,
    -- in which NULL scope columns mean /no scope filter at all/ — so the only rows an exact
    -- global request could produce through them are the namespace-wide ones, silently. Splitting
    -- those statements is
    -- @docs\/plans\/29-enforce-exact-and-namespace-wide-recall-in-postgresql.md@; until it lands,
    -- 'ExactScope' over a 'ScopeGlobal' is representable, round-trips on the wire, and refuses to
    -- execute. Use 'getGlobal' for an unranked exact global read in the meantime.
    RecallExactGlobalUnsupported !Namespace
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

-- | A recall request bound to the memory space that authorized it, with its target already
-- compiled to the scope columns the candidate SQL takes.
--
-- 'resolveRecall' is the only way to build one, which is what makes the binding trustworthy: the
-- space comes from a 'MemoryAccessContext' and the columns come from a 'RecallTarget', and
-- neither can be supplied independently of the other. Everything downstream of this type — both
-- candidate statements, the fusion, the budgets — sees a request that has already had its
-- authority and its breadth decided.
data ResolvedRecall = ResolvedRecall
  { memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text),
    query :: !Text,
    strategy :: !RecallStrategy,
    maxResults :: !Int
  }
  deriving stock (Generic, Eq, Show)

-- | Bind a request to one authorized memory space and compile its target to scope columns.
--
-- This is the single mapping from what a caller asked for to what the SQL is given, and it is
-- deliberately the only one:
--
-- @
-- 'NamespaceWide' ns                    -> namespace = ns, scope columns NULL (no scope filter)
-- 'ExactScope' ('ScopeEntity' ns k r)     -> namespace = ns, scope_kind = k, scope_ref = r
-- 'ExactScope' ('ScopeGlobal' ns)         -> refused; see 'RecallExactGlobalUnsupported'
-- @
--
-- The space is an argument rather than a field of the request, so no call site can widen a
-- target and a tenancy in the same edit.
resolveRecall :: MemorySpaceId -> RecallQuery -> Either RecallError ResolvedRecall
resolveRecall space request =
  case request.target of
    NamespaceWide (Namespace ns) -> Right (bind ns Nothing Nothing)
    ExactScope (ScopeEntity (Namespace ns) (ScopeKind kind) ref) ->
      Right (bind ns (Just kind) (Just ref))
    ExactScope (ScopeGlobal ns) -> Left (RecallExactGlobalUnsupported ns)
  where
    bind ns kind ref =
      ResolvedRecall
        { memorySpaceId = space,
          namespace = ns,
          scopeKind = kind,
          scopeRef = ref,
          query = request.query,
          strategy = request.strategy,
          maxResults = recallLimitInt request.maxResults
        }

data RecallCandidateQuery = RecallCandidateQuery
  { query :: !Text,
    memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text),
    limit :: !Int32
  }
  deriving stock (Generic, Eq, Show)

data VectorCandidateQuery = VectorCandidateQuery
  { queryVector :: !Text,
    memorySpaceId :: !MemorySpaceId,
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

-- | Run a recall request: plan, optionally embed the query, select candidates from each
-- active channel, fuse by reciprocal rank, score, and trim.
--
-- The memory space searched is 'Kioku.Api.Access.memoryContextSpace' of the context, and nothing
-- in the request can change it. That is why the context is passed here rather than a bare space:
-- a target that widens from one scope to a whole namespace is a retrieval choice, and it must be
-- impossible for that choice to also select whose memories are searched.
--
-- The context is not asked for a second permission. A 'MemoryAccessContext' exists only for
-- permissions 'Kioku.Api.Access.authorizeMemoryAccess' already checked against this space, which
-- is the same reason the read functions below take only a space — see "Kioku.Memory".
recall ::
  (IOE :> es, Store :> es) =>
  EmbeddingModel ->
  VectorCapability ->
  MemoryAccessContext ->
  RecallQuery ->
  Eff es (Either RecallError [RecallHit])
recall model capability context request =
  case resolveRecall (memoryContextSpace context) request of
    Left err -> pure (Left err)
    Right resolved -> Right <$> runResolvedRecall model capability resolved

{-# DEPRECATED legacyRecall "Use recall with a RecallQuery. ScopeGlobal in a RecallRequest means namespace-wide, which is legacyRecallTarget's mapping; the exact global bucket is ExactScope (ScopeGlobal ns)." #-}

-- | Run a pre-'RecallTarget' 'RecallRequest' and return exactly what it returns today.
--
-- The scope is mapped through 'legacyRecallTarget', so a global scope stays namespace-wide. The
-- request's own @memorySpaceId@ must be the one the context authorizes; a request naming another
-- space is refused with 'RecallSpaceMismatch' rather than quietly retargeted, for the same reason
-- the deprecated write wrappers in "Kioku.Memory" refuse rather than rewrite.
--
-- Two edges of @maxResults@ are handled here rather than by 'mkRecallLimit', because this
-- function's contract is "what you get today":
--
-- * a zero or negative limit returns no hits, which is what @take (max 0 n)@ did;
-- * a limit above 'maxRecallLimit' is clamped to it, which is unobservable — each channel
--   contributes at most 50 candidates, so a fused result set holds at most 100 distinct
--   memories and a larger @take@ never had anything more to take.
legacyRecall ::
  (IOE :> es, Store :> es) =>
  EmbeddingModel ->
  VectorCapability ->
  MemoryAccessContext ->
  RecallRequest ->
  Eff es (Either RecallError [RecallHit])
legacyRecall model capability context req
  | req.memorySpaceId /= authorized =
      pure (Left (RecallSpaceMismatch req.memorySpaceId authorized))
  | req.maxResults <= 0 = pure (Right [])
  | otherwise =
      recall
        model
        capability
        context
        RecallQuery
          { target = legacyRecallTarget req.scope,
            query = req.query,
            strategy = req.strategy,
            maxResults = legacyRecallLimit req.maxResults
          }
  where
    authorized = memoryContextSpace context

-- | Total by construction: 'legacyRecall' reaches this only with @requested >= 1@, so the
-- 'defaultRecallLimit' fallback is unreachable and exists to keep the function total rather than
-- to define behaviour.
legacyRecallLimit :: Int -> RecallLimit
legacyRecallLimit requested =
  either (const defaultRecallLimit) id (mkRecallLimit (max 1 (min maxRecallLimit requested)))

runResolvedRecall ::
  (IOE :> es, Store :> es) =>
  EmbeddingModel ->
  VectorCapability ->
  ResolvedRecall ->
  Eff es [RecallHit]
runResolvedRecall model capability resolved = do
  now <- liftIO getCurrentTime
  executeRecallPlan now model resolved (planRecallExecution capability resolved.strategy)

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
    -- A dimension mismatch is a configuration error, not a missing feature, but recall's
    -- response is the same: the vector channel cannot work, so degrade to keyword rather
    -- than fail. The worker is where it is reported loudly.
    VectorDimensionMismatch {} ->
      keywordExecutionPlan

keywordExecutionPlan :: RecallExecutionPlan
keywordExecutionPlan =
  RecallExecutionPlan {runFts = True, runVector = False, needsQueryEmbedding = False}

executeRecallPlan ::
  (IOE :> es, Store :> es) =>
  UTCTime ->
  EmbeddingModel ->
  ResolvedRecall ->
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
  ResolvedRecall ->
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
  ResolvedRecall ->
  Eff es [RecallHit]
keywordOnly now req = do
  ftsRows <- selectFtsCandidates req
  pure (finishRecall now req ftsRows [])

selectIf :: (Applicative f) => Bool -> f [a] -> f [a]
selectIf True action = action
selectIf False _ = pure []

finishRecall :: UTCTime -> ResolvedRecall -> [MemoryRecord] -> [MemoryRecord] -> [RecallHit]
finishRecall now req ftsRows vecRows =
  applyCharacterBudgets perMemoryCharacterBudget totalCharacterBudget $
    take req.maxResults $
      fuseRecallCandidates now ftsRows vecRows

selectFtsCandidates ::
  (Store :> es) =>
  ResolvedRecall ->
  Eff es [MemoryRecord]
selectFtsCandidates req =
  runTransaction $
    Tx.statement
      (candidateQuery req)
      selectFtsCandidatesStmt

-- | What the vector channel did, so that a degraded semantic half stops being invisible.
--
-- This exists because of how the defect it describes survived. 'fuseRecallCandidates' blends the
-- two channels by rank, so a vector channel that returns nothing contributes no ranks and the
-- score decays smoothly into pure keyword scoring: no error, no warning, and nothing in a
-- 'RecallHit' recording that the semantic half of a "hybrid" search came back empty. A caller
-- looking at plausible keyword results had no way to know.
data VectorChannelOutcome = VectorChannelOutcome
  { -- | Rows the approximate (HNSW) pass returned.
    annRows :: !Int,
    -- | Whether the exact pass ran because the approximate one came back short of the pool.
    exactFallbackFired :: !Bool,
    -- | Rows finally handed to the fusion.
    rowsReturned :: !Int
  }
  deriving stock (Generic, Eq, Show)

-- | Did the approximate pass miss rows that were really there?
--
-- True exactly when the exact fallback found more than the ANN pass did — that is, when the ANN
-- scan starved and the fallback rescued it. A host that wants a metric or a log line for the
-- health of its semantic channel should count these.
vectorChannelStarved :: VectorChannelOutcome -> Bool
vectorChannelStarved outcome =
  outcome.exactFallbackFired && outcome.rowsReturned > outcome.annRows

selectVectorCandidates ::
  (Store :> es) =>
  ResolvedRecall ->
  Vector Double ->
  Eff es [MemoryRecord]
selectVectorCandidates req queryVector =
  snd <$> selectVectorCandidatesDiagnosed req queryVector

-- | The vector channel, with a report of what it did. See 'VectorChannelOutcome'.
--
-- == Why there are two passes
--
-- The HNSW index is /post-filtered/: it picks candidates by distance alone, and the namespace,
-- scope, and @status@ predicates are applied afterwards, to rows it has already chosen. When the
-- memories nearest the query sit outside the caller's scope — a small scope inside a large
-- namespace, which is the normal shape of kioku data — the index spends its whole budget on rows
-- the filter then discards and the channel returns __nothing__.
--
-- So: run the approximate pass, and if it comes back short of the pool, run an exact pass that
-- cannot starve. The trigger is "short of the pool" rather than "empty" because a partial
-- starvation is a starvation too, and because the exact pass is cheap in precisely the case that
-- makes it fire spuriously — a scope holding fewer than 'candidatePoolSize' embedded memories,
-- where scanning all of them costs nothing.
--
-- == Why the exact pass rather than pgvector's own remedy
--
-- pgvector 0.8's @hnsw.iterative_scan@ is designed for exactly this, and it was measured across
-- five freshly built indexes on a 20000-row starving corpus. It returned the right answer 2 times
-- in 5 (@relaxed_order@) and 4 times in 5 (@strict_order@). HNSW construction is randomized, so
-- whether the iterative scan reaches the in-scope rows within its budget depends on the graph it
-- happened to get. A remedy that works 40% of the time is not a remedy — and, worse, it passes
-- any single test run. The exact pass returned the right answer 5 times in 5, needs no minimum
-- pgvector version, and cannot starve by construction.
--
-- == The cost, honestly
--
-- The exact pass scans every embedded row in the caller's scope: about 7ms per 2000 rows on the
-- measurement machine, growing linearly. That cost is paid only when the approximate pass came
-- back short, and it is bounded by the size of the scope the caller asked about — which is the
-- set they wanted searched anyway. On a large scope with no selective filter the approximate pass
-- fills the pool and the fallback never fires, so the common path is unchanged.
selectVectorCandidatesDiagnosed ::
  (Store :> es) =>
  ResolvedRecall ->
  Vector Double ->
  Eff es (VectorChannelOutcome, [MemoryRecord])
selectVectorCandidatesDiagnosed req queryVector =
  runTransaction do
    -- The HNSW scan visits at most @hnsw.ef_search@ candidates, and the default (40) is below the
    -- pool size (50) — so even with nothing for the filter to discard, the pool never fills and
    -- the channel silently under-delivers by 20%. Measured: 40 rows returned for a LIMIT of 50 on
    -- a 2000-row corpus with no out-of-scope rows at all.
    --
    -- (The comment that used to live at 'candidatePoolSize' claimed pgvector searches with
    -- @ef = max(ef_search, LIMIT)@ so the pool fills at the default. On pgvector 0.8.2 it does
    -- not. That claim was inherited, plausible, and false.)
    --
    -- Raising it to exactly the pool size fills the pool at no measurable cost (0.149ms vs
    -- 0.138ms) and does not move the planner off the HNSW path. Raising it far higher — the
    -- remedy a previous plan prescribed — /does/ move the planner, onto an ANN scan that then
    -- starves, which is how this defect was originally mis-diagnosed.
    Tx.sql efSearchSetting
    annRows <- Tx.statement query selectVectorCandidatesStmt
    if length annRows >= fromIntegral candidatePoolSize
      then
        pure
          ( VectorChannelOutcome
              { annRows = length annRows,
                exactFallbackFired = False,
                rowsReturned = length annRows
              },
            annRows
          )
      else do
        exactRows <- Tx.statement query selectVectorCandidatesExactStmt
        pure
          ( VectorChannelOutcome
              { annRows = length annRows,
                exactFallbackFired = True,
                rowsReturned = length exactRows
              },
            exactRows
          )
  where
    query = vectorCandidateQuery req queryVector

-- | @SET LOCAL@, so it lives exactly as long as the transaction the query runs in and cannot
-- leak into the rest of the connection.
efSearchSetting :: ByteString
efSearchSetting =
  TE.encodeUtf8 ("SET LOCAL hnsw.ef_search = " <> Text.pack (show candidatePoolSize))

candidateQuery :: ResolvedRecall -> RecallCandidateQuery
candidateQuery req =
  RecallCandidateQuery
    { query = req.query,
      memorySpaceId = req.memorySpaceId,
      namespace = req.namespace,
      scopeKind = req.scopeKind,
      scopeRef = req.scopeRef,
      limit = candidatePoolSize
    }

vectorCandidateQuery :: ResolvedRecall -> Vector Double -> VectorCandidateQuery
vectorCandidateQuery req queryVector =
  VectorCandidateQuery
    { queryVector = vectorLiteral queryVector,
      memorySpaceId = req.memorySpaceId,
      namespace = req.namespace,
      scopeKind = req.scopeKind,
      scopeRef = req.scopeRef,
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

-- | Full-text candidates.
--
-- The scope predicate @(($3 IS NULL AND $4 IS NULL) OR (scope_kind = $3 AND scope_ref = $4))@
-- is why recall searches namespace-wide for a global scope; scoped reads are exact-scope. For
-- a global scope both parameters are NULL, the first disjunct is always true, and the filter
-- vanishes. 'Kioku.Memory.ReadModel.selectActiveByScopeStmt' requires the columns to be NULL
-- instead. The @ORDER BY@ here is free to carry a recency tiebreak: a GIN index provides no
-- ordering, so there is no pathkey to preserve.
selectFtsCandidatesStmt :: Statement RecallCandidateQuery [MemoryRecord]
selectFtsCandidatesStmt =
  preparable
    ( "SELECT "
        <> memoryRecordColumns
        <> """
            FROM kiroku.kioku_memories
           WHERE status = 'active'
             AND memory_space_id = $2
             AND namespace = $3
             AND (($4 IS NULL AND $5 IS NULL) OR (scope_kind = $4 AND scope_ref = $5))
             AND content_tsv @@ websearch_to_tsquery('english', $1)
           ORDER BY ts_rank(content_tsv, websearch_to_tsquery('english', $1)) DESC, created_at DESC
           LIMIT $6
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
--
-- The scope predicate is the same one 'selectFtsCandidatesStmt' carries: recall searches
-- namespace-wide for a global scope; scoped reads are exact-scope.
selectVectorCandidatesStmt :: Statement VectorCandidateQuery [MemoryRecord]
selectVectorCandidatesStmt =
  preparable
    ( "SELECT "
        <> memoryRecordColumns
        <> """
            FROM kiroku.kioku_memories
           WHERE status = 'active'
             AND memory_space_id = $2
             AND namespace = $3
             AND (($4 IS NULL AND $5 IS NULL) OR (scope_kind = $4 AND scope_ref = $5))
             AND embedding IS NOT NULL
           ORDER BY embedding <=> $1::vector
           LIMIT $6
           """
    )
    vectorCandidateQueryEncoder
    (D.rowList memoryRecordDecoder)

-- | The exact vector scan: every embedded row in the caller's scope, ranked by distance, top-N.
-- It cannot starve, because the filter is applied /before/ the ranking rather than after it.
--
-- The @OFFSET 0@ is the whole mechanism and must not be "tidied away". It is an optimisation
-- fence: it stops Postgres from pulling the subquery up into the outer query, which in turn stops
-- the outer @ORDER BY embedding <=> …@ from reaching the HNSW index. Without it the planner
-- flattens the two levels back into 'selectVectorCandidatesStmt' and we are measuring — and
-- shipping — the very query we are trying to avoid.
--
-- A @MATERIALIZED@ CTE would also fence it, and was rejected: materialising forces every in-scope
-- row's 1536-dimension embedding into memory (about 6KB each, so ~120MB for a 20000-row scope),
-- whereas the fence streams and the top-N sort holds only 50 rows.
--
-- The predicates are identical to 'selectVectorCandidatesStmt''s, including @embedding IS NOT
-- NULL@ — here it is a correctness filter rather than an index-matching one, but it must stay
-- either way, since a NULL embedding has no distance to anything.
selectVectorCandidatesExactStmt :: Statement VectorCandidateQuery [MemoryRecord]
selectVectorCandidatesExactStmt =
  preparable
    ( "SELECT "
        <> memoryRecordColumns
        <> """
            FROM (SELECT *
                    FROM kiroku.kioku_memories
                   WHERE status = 'active'
                     AND memory_space_id = $2
                     AND namespace = $3
                     AND (($4 IS NULL AND $5 IS NULL) OR (scope_kind = $4 AND scope_ref = $5))
                     AND embedding IS NOT NULL
                  OFFSET 0) AS scoped
           ORDER BY embedding <=> $1::vector
           LIMIT $6
           """
    )
    vectorCandidateQueryEncoder
    (D.rowList memoryRecordDecoder)

recallCandidateQueryEncoder :: E.Params RecallCandidateQuery
recallCandidateQueryEncoder =
  ((\q -> q.query) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.memorySpaceId) >$< memorySpaceParam)
    <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\q -> q.scopeRef) >$< E.param (E.nullable E.text))
    <> ((\q -> q.limit) >$< E.param (E.nonNullable E.int4))

vectorCandidateQueryEncoder :: E.Params VectorCandidateQuery
vectorCandidateQueryEncoder =
  ((\q -> q.queryVector) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.memorySpaceId) >$< memorySpaceParam)
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
-- == Filtered-ANN starvation, and how it is handled
--
-- The HNSW index is /post-filtered/: it covers the embedding column alone, so it picks its
-- candidates by distance and the namespace, scope and @status@ predicates are applied afterwards,
-- to rows it has already chosen. When the memories nearest the query sit outside the caller's
-- scope — a small scope inside a large namespace, which is the normal shape of kioku data — the
-- scan spends its entire budget on rows the filter then discards and the vector channel returns
-- __nothing__. Measured: 2000 in-scope memories and 2000 nearer ones in another namespace, at
-- default settings, returned zero rows every time.
--
-- 'selectVectorCandidatesDiagnosed' handles this by running an exact pass whenever the
-- approximate pass comes back short of this pool. Read its Haddock for the mechanism; the summary
-- is that the approximate pass is fast and can starve, the exact pass cannot starve and costs a
-- scan of the caller's scope, and the second only runs when the first came back short.
--
-- == Two claims that used to live here and are false
--
-- This comment previously asserted that pgvector searches with @ef = max(ef_search, LIMIT)@, so
-- that this pool fills at the default @hnsw.ef_search@ of 40. __It does not.__ On pgvector 0.8.2,
-- a corpus of 2000 in-scope rows with /nothing/ out of scope — nothing for the filter to discard
-- at all — returned 40 rows against this LIMIT of 50. The vector channel was silently
-- under-delivering by 20% in the healthy case. 'selectVectorCandidatesDiagnosed' now sets
-- @hnsw.ef_search@ to exactly this pool size, which fills it at no measurable cost.
--
-- It also warned against raising @hnsw.ef_search@ at all, on the evidence that
-- @SET hnsw.ef_search = 200@ flipped the planner onto an HNSW scan that starved. That evidence
-- was real but the conclusion was too broad: at 200 the planner does flip, and at 50 (this pool
-- size) it does not, while the pool fills. The distinction is measured, not argued.
--
-- == What is still not fixed
--
-- pgvector 0.8's @hnsw.iterative_scan@ is the vendor's own remedy for starvation and it was
-- rejected on evidence, not on principle: across five freshly built indexes on a 20000-row
-- starving corpus it returned the right answer 2 times in 5 (@relaxed_order@) and 4 times in 5
-- (@strict_order@). HNSW construction is randomized, so it is a lottery. Do not reach for it
-- again without a sample size — a single passing run says nothing.
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

-- | Active memories carrying __exactly__ this scope.
--
-- Recall searches namespace-wide for a global scope; scoped reads are exact-scope. So
-- 'ScopeGlobal' here means "the rows recorded with no entity scope", /not/ "everything in the
-- namespace" — a memory under @mori:repo:web@ is returned by 'recall' with scope @mori@ but
-- not by this. For the read-side equivalent of recall's breadth, use 'getActiveInNamespace'.
getActiveByScope ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  MemoryScope ->
  Eff es (Either ReadModelError [MemoryRecord])
getActiveByScope space scope =
  runQueryWith
    Nothing
    Eventual
    memoriesByScopeReadModel
    MemoriesByScopeQuery
      { memorySpaceId = space,
        namespace = scopeNamespaceText scope,
        scopeKind = scopeKindText scope,
        scopeRef = scopeRefText scope
      }

-- | Every active memory in the namespace, whatever its scope. This is the read-side
-- equivalent of what 'recall' does with a global scope — inside one memory space.
getActiveInNamespace ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  Namespace ->
  Eff es (Either ReadModelError [MemoryRecord])
getActiveInNamespace space (Namespace ns) =
  runQueryWith
    Nothing
    Eventual
    memoriesByNamespaceReadModel
    MemoriesByNamespaceQuery {memorySpaceId = space, namespace = ns}

-- | The global bucket of a namespace: rows recorded with no entity scope. Not the same as a
-- 'recall' scoped to the namespace, which also returns entity-scoped rows.
getGlobal ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  Namespace ->
  Eff es (Either ReadModelError [MemoryRecord])
getGlobal space ns =
  getActiveByScope space (ScopeGlobal ns)

getById ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  MemoryId ->
  Eff es (Either ReadModelError (Maybe MemoryRecord))
getById space mid =
  fmap (fmap (fmap memoryRowToRecord)) $
    runQueryWith
      Nothing
      Eventual
      memoryByIdReadModel
      MemoryByIdQuery {memorySpaceId = space, memoryId = idText mid}

getBySession ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  SessionId ->
  Eff es (Either ReadModelError [MemoryRecord])
getBySession space sid =
  runQueryWith
    Nothing
    Eventual
    memoriesBySessionReadModel
    MemoriesBySessionQuery {memorySpaceId = space, sessionId = idText sid}

getByType ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  Namespace ->
  MemoryType ->
  Eff es (Either ReadModelError [MemoryRecord])
getByType space (Namespace ns) mt =
  runQueryWith
    Nothing
    Eventual
    memoriesByTypeReadModel
    MemoriesByTypeQuery {memorySpaceId = space, namespace = ns, memoryType = memoryTypeToText mt}

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
