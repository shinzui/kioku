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
    selectVectorCandidatesDiagnosed,
    VectorChannelOutcome (..),
    vectorChannelStarved,
    FtsCandidateSql,
    ftsCandidateSql,
    explainFtsCandidates,
    VectorCandidateSql,
    vectorCandidateSql,
    runVectorAnnCandidates,
    explainVectorAnnCandidates,
    explainVectorExactCandidates,
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
-- (@Kioku.RecallSqlSpec@, @Kioku.RecallTargetSpec@) rather than only through 'recall', which
-- would drag in an embedding endpoint. They are not part of the intended public API.
--
-- 'vectorCandidateSql', 'runVectorAnnCandidates' and 'explainVectorAnnCandidates' are exported
-- for @Kioku.RecallHarness@, the recall-quality instrument. It needs the approximate pass on its
-- own — 'selectVectorCandidates' runs the fallback too, and wraps both in its own transaction —
-- so that it can run it under a @SET LOCAL@ and measure the approximate pass in isolation. And
-- it needs an @EXPLAIN@ of /that/ statement, which is why 'explainVectorAnnCandidates' lives
-- here beside the statement it describes rather than in the harness.
--
-- __The harness used to restate the SQL and it went wrong twice.__ An @EXPLAIN@ whose SQL differs
-- from the shipping statement in any way the planner cares about can choose a different plan and
-- report a different answer, silently and flatteringly. Once the copy selected @memory_id@ alone:
-- the narrow row made the top-N sort look cheap, the planner took the exact plan, and the
-- @EXPLAIN@ reported fifty happy rows while the real query took the HNSW plan and returned zero.
-- Once it omitted the @memory_space_id@ predicate, which is the leading column of every
-- partition-first index, and reported an access path no live query can produce. There is now no
-- copy to drift: the @EXPLAIN@ is built from the same SQL text and the same parameters as the
-- statement it explains.

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
-- Every 'RecallTarget' is now executable, so the only way to reach this channel is the legacy
-- request's own memory space disagreeing with the context that authorized it. The channel stays
-- on 'recall' rather than collapsing to a total function: removing it is a public signature
-- change for every call site, which belongs with the consumer migration in
-- @docs\/plans\/30-migrate-recall-consumers-to-explicit-targets.md@ rather than here.
data RecallError
  = -- | A 'RecallRequest' named a memory space that is not the one its context authorizes:
    -- @RecallSpaceMismatch requested authorized@. Only 'legacyRecall' can produce this, because
    -- only the legacy request carries a space of its own.
    RecallSpaceMismatch !MemorySpaceId !MemorySpaceId
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

-- | Which rows inside one namespace a resolved target admits.
--
-- Three targets, three predicates, and — this is the whole point — no value that means two of
-- them. The representation this replaces spelled all three with a nullable @scope_kind@ and
-- @scope_ref@ pair, in which NULL meant /omit the scope filter/; the exact global bucket, whose
-- rows are exactly the ones whose scope columns /are/ NULL, therefore had no way to say so and
-- was refused rather than answered wrongly. See
-- @docs\/adr\/each-recall-target-gets-its-own-statement.md@.
data ScopeBound
  = -- | Only the rows recorded with no entity scope: @scope_kind IS NULL AND scope_ref IS NULL@.
    GlobalBucketOnly
  | -- | Only the rows carrying exactly this kind and ref: @scope_kind = $4 AND scope_ref = $5@.
    EntityScopeOnly !Text !Text
  | -- | Every scope in the namespace: no scope comparison at all. The memory-space and namespace
    -- predicates still apply, which is why this widens breadth without widening tenancy.
    EveryScopeInNamespace
  deriving stock (Generic, Eq, Show)

-- | A recall request bound to the memory space that authorized it, with its target already
-- compiled to the scope predicate the candidate SQL will carry.
--
-- 'resolveRecall' is the only way to build one, which is what makes the binding trustworthy: the
-- space comes from a 'MemoryAccessContext' and the bound comes from a 'RecallTarget', and neither
-- can be supplied independently of the other. Everything downstream of this type — all three
-- candidate statement families, the fusion, the budgets — sees a request that has already had its
-- authority and its breadth decided.
data ResolvedRecall = ResolvedRecall
  { memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    scopeBound :: !ScopeBound,
    query :: !Text,
    strategy :: !RecallStrategy,
    maxResults :: !Int
  }
  deriving stock (Generic, Eq, Show)

-- | Bind a request to one authorized memory space and compile its target to a scope bound.
--
-- This is the single mapping from what a caller asked for to what the SQL is given, and it is
-- deliberately the only one:
--
-- @
-- 'ExactScope' ('ScopeGlobal' ns)       -> namespace = ns, 'GlobalBucketOnly'
-- 'ExactScope' ('ScopeEntity' ns k r)   -> namespace = ns, 'EntityScopeOnly' k r
-- 'NamespaceWide' ns                  -> namespace = ns, 'EveryScopeInNamespace'
-- @
--
-- It is total. Every target has a predicate, the limit was validated into a 'RecallLimit' before
-- the request was built, and the space is an argument rather than a field of the request — so no
-- call site can widen a target and a tenancy in the same edit, and none of the three meanings can
-- fail to be expressible.
resolveRecall :: MemorySpaceId -> RecallQuery -> ResolvedRecall
resolveRecall space request =
  case request.target of
    ExactScope (ScopeGlobal (Namespace ns)) -> bind ns GlobalBucketOnly
    ExactScope (ScopeEntity (Namespace ns) (ScopeKind kind) ref) ->
      bind ns (EntityScopeOnly kind ref)
    NamespaceWide (Namespace ns) -> bind ns EveryScopeInNamespace
  where
    bind ns bound =
      ResolvedRecall
        { memorySpaceId = space,
          namespace = ns,
          scopeBound = bound,
          query = request.query,
          strategy = request.strategy,
          maxResults = recallLimitInt request.maxResults
        }

-- | The parameters a candidate query takes when its scope predicate needs none of its own:
-- @$1@ the match text, @$2@ the memory space, @$3@ the namespace, @$4@ the row limit.
--
-- Both bounds that use this record — 'GlobalBucketOnly' and 'EveryScopeInNamespace' — carry no
-- scope /values/, and that is precisely why they must not share a statement: they differ by the
-- SQL they compile to, not by a parameter, so which one ran is visible in the statement's name
-- and in its query plan rather than hidden in a NULL.
data BoundedCandidateParams = BoundedCandidateParams
  { match :: !Text,
    memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    limit :: !Int32
  }
  deriving stock (Generic, Eq, Show)

-- | 'BoundedCandidateParams' plus the two scope comparisons an entity bound makes: @$4@ the
-- scope kind and @$5@ the scope ref, which moves the row limit to @$6@. Both are non-nullable,
-- so this record cannot express \"no scope filter\" even by accident.
data EntityCandidateParams = EntityCandidateParams
  { match :: !Text,
    memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    scopeKind :: !Text,
    scopeRef :: !Text,
    limit :: !Int32
  }
  deriving stock (Generic, Eq, Show)

-- | A full-text candidate query, already committed to one of the three statement families.
data FtsCandidateSql
  = FtsInGlobalBucket !BoundedCandidateParams
  | FtsInEntityScope !EntityCandidateParams
  | FtsAcrossNamespace !BoundedCandidateParams
  deriving stock (Generic, Eq, Show)

-- | A vector candidate query, already committed to one of the three statement families. The same
-- value drives the approximate pass, the exact fallback, and the @EXPLAIN@ of the approximate
-- pass, so those three can never describe different queries.
data VectorCandidateSql
  = VectorInGlobalBucket !BoundedCandidateParams
  | VectorInEntityScope !EntityCandidateParams
  | VectorAcrossNamespace !BoundedCandidateParams
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
  Right <$> runResolvedRecall model capability (resolveRecall (memoryContextSpace context) request)

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
  runTransaction (runFtsCandidates (ftsCandidateSql req))

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
    annRows <- runVectorAnnCandidates candidates
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
        exactRows <- runVectorExactCandidates candidates
        pure
          ( VectorChannelOutcome
              { annRows = length annRows,
                exactFallbackFired = True,
                rowsReturned = length exactRows
              },
            exactRows
          )
  where
    candidates = vectorCandidateSql req queryVector

-- | @SET LOCAL@, so it lives exactly as long as the transaction the query runs in and cannot
-- leak into the rest of the connection.
efSearchSetting :: ByteString
efSearchSetting =
  TE.encodeUtf8 ("SET LOCAL hnsw.ef_search = " <> Text.pack (show candidatePoolSize))

-- | Compile a resolved request into a full-text candidate query. The match text is the caller's
-- query, which @websearch_to_tsquery@ reads twice: once to filter and once to rank.
ftsCandidateSql :: ResolvedRecall -> FtsCandidateSql
ftsCandidateSql req =
  case req.scopeBound of
    GlobalBucketOnly -> FtsInGlobalBucket (boundedParams req req.query)
    EntityScopeOnly kind ref -> FtsInEntityScope (entityParams req req.query kind ref)
    EveryScopeInNamespace -> FtsAcrossNamespace (boundedParams req req.query)

-- | Compile a resolved request and an embedded query into a vector candidate query. The match
-- text is the vector literal the @$1::vector@ cast reads.
vectorCandidateSql :: ResolvedRecall -> Vector Double -> VectorCandidateSql
vectorCandidateSql req queryVector =
  case req.scopeBound of
    GlobalBucketOnly -> VectorInGlobalBucket (boundedParams req literal)
    EntityScopeOnly kind ref -> VectorInEntityScope (entityParams req literal kind ref)
    EveryScopeInNamespace -> VectorAcrossNamespace (boundedParams req literal)
  where
    literal = vectorLiteral queryVector

boundedParams :: ResolvedRecall -> Text -> BoundedCandidateParams
boundedParams req match =
  BoundedCandidateParams
    { match,
      memorySpaceId = req.memorySpaceId,
      namespace = req.namespace,
      limit = candidatePoolSize
    }

entityParams :: ResolvedRecall -> Text -> Text -> Text -> EntityCandidateParams
entityParams req match scopeKind scopeRef =
  EntityCandidateParams
    { match,
      memorySpaceId = req.memorySpaceId,
      namespace = req.namespace,
      scopeKind,
      scopeRef,
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

-- * The three statement families

-- $
-- Every candidate statement is one of nine: three channels (full text, the approximate vector
-- pass, the exact vector pass) times three bounds ('GlobalBucketOnly', 'EntityScopeOnly',
-- 'EveryScopeInNamespace'). They are generated from one SQL template per channel and one scope
-- clause per bound, so the three bounds can only ever differ in the scope clause — the memory
-- space, the namespace and the @status@ filter are written once and cannot drift apart between
-- families.
--
-- The nine exist instead of three parameterised statements because the widening is the security
-- property. A single statement with a nullable scope pair has to spell the predicate
-- @(($4 IS NULL AND $5 IS NULL) OR (scope_kind = $4 AND scope_ref = $5))@, in which passing NULL
-- silently drops the scope filter — so a caller that meant \"the global bucket\" and a caller
-- that meant \"the whole namespace\" issue the identical query with the identical parameters, and
-- neither a reviewer nor a query plan can tell them apart. Splitting them puts the difference in
-- the statement name and in the @Index Cond@.

-- | How a bound is spelled in SQL, and which positional parameter the row limit therefore lands
-- on. An entity bound consumes @$4@ and @$5@ for its comparisons, which pushes its limit to @$6@.
data ScopeClause = ScopeClause
  { predicate :: !Text,
    limitParam :: !Text
  }

globalBucketClause, entityScopeClause, namespaceWideClause :: ScopeClause
globalBucketClause = ScopeClause "AND scope_kind IS NULL AND scope_ref IS NULL" "$4"
entityScopeClause = ScopeClause "AND scope_kind = $4 AND scope_ref = $5" "$6"
namespaceWideClause = ScopeClause "" "$4"

-- | The predicates every candidate query carries before its scope clause: one authorized memory
-- space, one namespace, active rows only. @$1@ is the match text, @$2@ the space, @$3@ the
-- namespace.
--
-- The memory space is first and mandatory in all nine statements. Namespace-wide means every
-- scope in one space, never every space — see
-- @docs\/adr\/namespace-is-not-a-security-boundary.md@.
partitionPredicates :: Text
partitionPredicates =
  "WHERE status = 'active' AND memory_space_id = $2 AND namespace = $3 "

-- | Full-text candidates.
--
-- The @ORDER BY@ is free to carry a recency tiebreak: a GIN index provides no ordering, so
-- there is no pathkey to preserve.
ftsCandidateQuerySql :: ScopeClause -> Text
ftsCandidateQuerySql scope =
  "SELECT "
    <> memoryRecordColumns
    <> "FROM kiroku.kioku_memories "
    <> partitionPredicates
    <> scope.predicate
    <> " AND content_tsv @@ websearch_to_tsquery('english', $1) "
    <> "ORDER BY ts_rank(content_tsv, websearch_to_tsquery('english', $1)) DESC, created_at DESC "
    <> "LIMIT "
    <> scope.limitParam

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
-- Recall that this is a *post-filtered* ANN scan: the space, namespace, scope and status
-- predicates are applied to rows the index has already chosen by distance. See
-- 'candidatePoolSize' for what that costs and 'selectVectorCandidatesDiagnosed' for the pass
-- that rescues it.
vectorAnnCandidateQuerySql :: ScopeClause -> Text
vectorAnnCandidateQuerySql scope =
  "SELECT "
    <> memoryRecordColumns
    <> "FROM kiroku.kioku_memories "
    <> partitionPredicates
    <> scope.predicate
    <> " AND embedding IS NOT NULL "
    <> "ORDER BY embedding <=> $1::vector "
    <> "LIMIT "
    <> scope.limitParam

-- | The exact vector scan: every embedded row inside the bound, ranked by distance, top-N.
-- It cannot starve, because the filter is applied /before/ the ranking rather than after it.
--
-- The @OFFSET 0@ is the whole mechanism and must not be "tidied away". It is an optimisation
-- fence: it stops Postgres from pulling the subquery up into the outer query, which in turn stops
-- the outer @ORDER BY embedding <=> …@ from reaching the HNSW index. Without it the planner
-- flattens the two levels back into 'vectorAnnCandidateQuerySql' and we are measuring — and
-- shipping — the very query we are trying to avoid.
--
-- A @MATERIALIZED@ CTE would also fence it, and was rejected: materialising forces every in-bound
-- row's 1536-dimension embedding into memory (about 6KB each, so ~120MB for a 20000-row scope),
-- whereas the fence streams and the top-N sort holds only 50 rows.
--
-- The predicates are identical to the approximate pass's, including @embedding IS NOT NULL@ —
-- here it is a correctness filter rather than an index-matching one, but it must stay either way,
-- since a NULL embedding has no distance to anything.
vectorExactCandidateQuerySql :: ScopeClause -> Text
vectorExactCandidateQuerySql scope =
  "SELECT "
    <> memoryRecordColumns
    <> "FROM (SELECT * FROM kiroku.kioku_memories "
    <> partitionPredicates
    <> scope.predicate
    <> " AND embedding IS NOT NULL OFFSET 0) AS scoped "
    <> "ORDER BY embedding <=> $1::vector "
    <> "LIMIT "
    <> scope.limitParam

-- | Run the full-text channel against whichever family the target chose.
--
-- The @case@ is total over 'FtsCandidateSql', so a fourth bound cannot be added without deciding
-- what SQL it compiles to.
runFtsCandidates :: FtsCandidateSql -> Tx.Transaction [MemoryRecord]
runFtsCandidates = \case
  FtsInGlobalBucket params -> Tx.statement params (boundedRows ftsCandidateQuerySql globalBucketClause)
  FtsInEntityScope params -> Tx.statement params (entityRows ftsCandidateQuerySql)
  FtsAcrossNamespace params -> Tx.statement params (boundedRows ftsCandidateQuerySql namespaceWideClause)

-- | Run the approximate vector pass against whichever family the target chose.
runVectorAnnCandidates :: VectorCandidateSql -> Tx.Transaction [MemoryRecord]
runVectorAnnCandidates = \case
  VectorInGlobalBucket params -> Tx.statement params (boundedRows vectorAnnCandidateQuerySql globalBucketClause)
  VectorInEntityScope params -> Tx.statement params (entityRows vectorAnnCandidateQuerySql)
  VectorAcrossNamespace params -> Tx.statement params (boundedRows vectorAnnCandidateQuerySql namespaceWideClause)

-- | Run the exact vector pass against whichever family the target chose.
runVectorExactCandidates :: VectorCandidateSql -> Tx.Transaction [MemoryRecord]
runVectorExactCandidates = \case
  VectorInGlobalBucket params -> Tx.statement params (boundedRows vectorExactCandidateQuerySql globalBucketClause)
  VectorInEntityScope params -> Tx.statement params (entityRows vectorExactCandidateQuerySql)
  VectorAcrossNamespace params -> Tx.statement params (boundedRows vectorExactCandidateQuerySql namespaceWideClause)

-- | @EXPLAIN (ANALYZE, BUFFERS)@ over the full-text channel, built from the same SQL text and
-- given the same parameters as 'runFtsCandidates'.
explainFtsCandidates :: FtsCandidateSql -> Tx.Transaction [Text]
explainFtsCandidates = \case
  FtsInGlobalBucket params -> Tx.statement params (boundedPlan ftsCandidateQuerySql globalBucketClause)
  FtsInEntityScope params -> Tx.statement params (entityPlan ftsCandidateQuerySql)
  FtsAcrossNamespace params -> Tx.statement params (boundedPlan ftsCandidateQuerySql namespaceWideClause)

-- | @EXPLAIN (ANALYZE, BUFFERS)@ over the approximate vector pass, built from the same SQL text
-- and given the same parameters as 'runVectorAnnCandidates'. See the test-seam note at the top of
-- this module for why these live here rather than in the harness that uses them.
explainVectorAnnCandidates :: VectorCandidateSql -> Tx.Transaction [Text]
explainVectorAnnCandidates = explainVector vectorAnnCandidateQuerySql

-- | @EXPLAIN (ANALYZE, BUFFERS)@ over the exact vector pass — the one whose access path is a
-- scan of the bound rather than of the embedding index, and therefore the one where a
-- partition-leading index earns its keep.
explainVectorExactCandidates :: VectorCandidateSql -> Tx.Transaction [Text]
explainVectorExactCandidates = explainVector vectorExactCandidateQuerySql

explainVector :: (ScopeClause -> Text) -> VectorCandidateSql -> Tx.Transaction [Text]
explainVector sqlFor = \case
  VectorInGlobalBucket params -> Tx.statement params (boundedPlan sqlFor globalBucketClause)
  VectorInEntityScope params -> Tx.statement params (entityPlan sqlFor)
  VectorAcrossNamespace params -> Tx.statement params (boundedPlan sqlFor namespaceWideClause)

boundedPlan :: (ScopeClause -> Text) -> ScopeClause -> Statement BoundedCandidateParams [Text]
boundedPlan sqlFor scope =
  preparable (explained (sqlFor scope)) boundedCandidateEncoder planDecoder

entityPlan :: (ScopeClause -> Text) -> Statement EntityCandidateParams [Text]
entityPlan sqlFor =
  preparable (explained (sqlFor entityScopeClause)) entityCandidateEncoder planDecoder

explained :: Text -> Text
explained sql = "EXPLAIN (ANALYZE, BUFFERS) " <> sql

planDecoder :: D.Result [Text]
planDecoder = D.rowList (D.column (D.nonNullable D.text))

boundedRows :: (ScopeClause -> Text) -> ScopeClause -> Statement BoundedCandidateParams [MemoryRecord]
boundedRows sqlFor scope =
  preparable (sqlFor scope) boundedCandidateEncoder (D.rowList memoryRecordDecoder)

entityRows :: (ScopeClause -> Text) -> Statement EntityCandidateParams [MemoryRecord]
entityRows sqlFor =
  preparable (sqlFor entityScopeClause) entityCandidateEncoder (D.rowList memoryRecordDecoder)

boundedCandidateEncoder :: E.Params BoundedCandidateParams
boundedCandidateEncoder =
  ((\q -> q.match) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.memorySpaceId) >$< memorySpaceParam)
    <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.limit) >$< E.param (E.nonNullable E.int4))

entityCandidateEncoder :: E.Params EntityCandidateParams
entityCandidateEncoder =
  ((\q -> q.match) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.memorySpaceId) >$< memorySpaceParam)
    <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.scopeKind) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.scopeRef) >$< E.param (E.nonNullable E.text))
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
