{-# LANGUAGE DataKinds #-}

module Kioku.Distill.L1
  ( FindMergeCandidates (..),
    L1Error (..),
    L1Outcome (..),
    L1RunMode (..),
    L1Summary (..),
    distillSessionL1,
    recallCandidates,
    scopedScanCandidates,
  )
where

import Baikai.Embedding (EmbeddingModel)
import Control.Monad (foldM)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Either (lefts)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int32)
import Data.KindID.V7 qualified as KindID
import Data.List (nub)
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUIDv5
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.ReadModel (ReadModelError)
import Kioku.Api.Access
  ( MemoryAccessContext,
    MemoryPermission (..),
    MemorySpaceId,
    memoryContextAllows,
    memoryContextRecordedActor,
    memoryContextSpace,
  )
import Kioku.Api.Scope (MemoryScope, scopeFromColumns, scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Api.Types (Confidence (..), MemoryRecord (..), MemoryType (..), confidenceFromText, memoryTypeFromText)
import Kioku.Database.Schema (consolidationDecisionsTable, l1WatermarksTable)
import Kioku.Distill.Consolidate
  ( ConsolidateInput (..),
    ConsolidationAction (..),
    ConsolidationDecision (..),
    ExistingMemory (..),
  )
import Kioku.Distill.Extract (ExtractInput (..), ExtractOutput (..), ExtractedAtom (..))
import Kioku.Distill.Runtime (DistillRuntime, runConsolidation, runExtraction)
import Kioku.Id (MemoryId, SessionId, idText, parseIdLenient)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Memory.ReadModel (MemoryRow (..))
import Kioku.Partition (memorySpaceParam)
import Kioku.Prelude
import Kioku.Recall qualified as Recall
import Kioku.Recall.Capability (VectorCapability)
import Kioku.Session qualified as Session
import Kioku.Session.ReadModel (SessionRow (..), TurnRow (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Shikumi.Schema.Types (field, unField)

-- | How a pass finds memories that a newly extracted atom might merge into.
--
-- The authorizing context is an argument rather than something the finder closes over, so a
-- finder value can be built once at startup and still be used by passes running in different
-- memory spaces. It is the whole context rather than a bare 'MemorySpaceId' because
-- 'Kioku.Recall.recall' takes one: a finder that searches must be handed the decision that
-- authorized the pass, so that widening what it searches can never widen whose memories it
-- reaches.
-- The error channel is 'L1Error' rather than 'ReadModelError' because a finder that runs recall
-- can fail in a way a read model cannot — see 'L1RecallRefused'. Flattening such a refusal into
-- an empty candidate list would tell the consolidator there is nothing to merge into, which is
-- the "a denial became an empty result" mistake 'Kioku.Api.Access' exists to prevent.
newtype FindMergeCandidates es = FindMergeCandidates
  { runFindMergeCandidates ::
      MemoryAccessContext -> MemoryScope -> Text -> Eff es (Either L1Error [MemoryRecord])
  }

data L1Error
  = L1SessionReadFailed !ReadModelError
  | L1SessionNotFound !SessionId
  | L1TurnReadFailed !ReadModelError
  | L1MemoryReadFailed !ReadModelError
  | L1ExtractionFailed !Text
  | L1ConsolidationFailed !Text
  | L1MemoryWriteFailed !Memory.MemoryWriteError
  | -- | the context does not authorize distillation in this space
    L1NotPermitted !MemoryPermission
  | -- | the merge-candidate finder asked recall for something it would not run
    L1RecallRefused !Recall.RecallError
  deriving stock (Generic, Show)

data L1Summary = L1Summary
  { extracted :: !Int,
    stored :: !Int,
    merged :: !Int,
    skipped :: !Int
  }
  deriving stock (Generic, Eq, Show)

-- | Whether a pass may skip itself when the per-session watermark shows no new
-- turns since the last fully successful pass. Timer fires use
-- 'RespectWatermark' (the debounce); @kioku distill --force@ uses
-- 'IgnoreWatermark'.
data L1RunMode
  = RespectWatermark
  | IgnoreWatermark
  deriving stock (Generic, Eq, Show)

data L1Outcome
  = L1Distilled !L1Summary
  | L1SkippedUpToDate
  deriving stock (Generic, Eq, Show)

-- | What the pass actually did with an atom, as opposed to what the
-- consolidator asked for. A merge whose targets all turned out to be missing
-- degrades to a store; a merge whose only target is the atom's own prior copy
-- degrades to a skip. The audit row records this, not the LLM's claim.
data AppliedAction
  = ActionStored
  | ActionUpdated
  | ActionMerged
  | ActionSkipped
  deriving stock (Generic, Eq, Show)

data AppliedDecision = AppliedDecision
  { appliedAction :: !AppliedAction,
    winnerId :: !(Maybe MemoryId),
    appliedTargets :: ![MemoryId],
    appliedNote :: !(Maybe Text)
  }

data WatermarkRow = WatermarkRow
  { memorySpaceId :: !MemorySpaceId,
    sessionId :: !Text,
    lastTurnIndex :: !Int32,
    distilledAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data AuditRow = AuditRow
  { memorySpaceId :: !MemorySpaceId,
    decisionId :: !Text,
    sessionId :: !Text,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text),
    candidateContent :: !Text,
    decision :: !Text,
    targetIds :: ![Text],
    resultMemoryId :: !(Maybe Text),
    rationale :: !(Maybe Text),
    decidedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

-- | Run one L1 distillation pass. Under 'RespectWatermark' a session whose
-- highest turn index is already covered by a previous fully successful pass is
-- skipped before any LLM call, which is what makes keiro's at-least-once timer
-- re-fires cheap. The watermark advances only when the whole fold succeeds, so
-- a failed pass is retried in full.
--
-- The pass writes memories, so it needs a 'MemoryAccessContext' — the one for the memory space
-- the session belongs to. It demands 'MemoryDistill' before anything else, so an unauthorized
-- pass fails before it spends a single LLM token rather than after, at the first write.
distillSessionL1 ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  L1RunMode ->
  DistillRuntime ->
  FindMergeCandidates es ->
  SessionId ->
  Eff es (Either L1Error L1Outcome)
distillSessionL1 context mode rt finder sid
  | not (memoryContextAllows MemoryDistill context) =
      pure (Left (L1NotPermitted MemoryDistill))
  | otherwise = do
      sessionResult <- Session.getById space sid
      case sessionResult of
        Left err -> pure (Left (L1SessionReadFailed err))
        Right Nothing -> pure (Left (L1SessionNotFound sid))
        Right (Just session) -> do
          turnsResult <- Session.getTurns space sid
          case turnsResult of
            Left err -> pure (Left (L1TurnReadFailed err))
            Right turns -> do
              let maxTurnIndex = maximum (0 : fmap (.turnIndex) turns)
              upToDate <- watermarkCovers mode space sid maxTurnIndex
              if upToDate
                then pure (Right L1SkippedUpToDate)
                else do
                  inputResult <- buildExtractInput space sid session turns
                  case inputResult of
                    Left err -> pure (Left err)
                    Right input -> do
                      extractedResult <- liftIO (runExtraction rt input)
                      case extractedResult of
                        Left err -> pure (Left (L1ExtractionFailed (Text.pack (show err))))
                        Right output -> do
                          foldResult <-
                            foldM
                              (stepAtom maxTurnIndex session)
                              (Right emptySummary {extracted = length output.atoms})
                              output.atoms
                          case foldResult of
                            Left err -> pure (Left err)
                            Right summary -> do
                              writeWatermark space sid maxTurnIndex
                              pure (Right (L1Distilled summary))
  where
    space = memoryContextSpace context

    stepAtom _ _ (Left err) _ = pure (Left err)
    stepAtom maxTurnIndex session (Right summary) atom =
      applyAtom context rt finder sid session maxTurnIndex summary atom

watermarkCovers ::
  (Store :> es) =>
  L1RunMode ->
  MemorySpaceId ->
  SessionId ->
  Int ->
  Eff es Bool
watermarkCovers IgnoreWatermark _ _ _ = pure False
watermarkCovers RespectWatermark space sid maxTurnIndex = do
  stored <- readWatermark space sid
  pure (maybe False (>= maxTurnIndex) stored)

readWatermark ::
  (Store :> es) =>
  MemorySpaceId ->
  SessionId ->
  Eff es (Maybe Int)
readWatermark space sid =
  runTransaction $
    fmap fromIntegral <$> Tx.statement (WatermarkKey space (idText sid)) selectWatermarkStmt

writeWatermark ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  SessionId ->
  Int ->
  Eff es ()
writeWatermark space sid maxTurnIndex = do
  now <- liftIO getCurrentTime
  runTransaction $
    Tx.statement
      WatermarkRow
        { memorySpaceId = space,
          sessionId = idText sid,
          lastTurnIndex = fromIntegral maxTurnIndex,
          distilledAt = now
        }
      upsertWatermarkStmt

data WatermarkKey = WatermarkKey !MemorySpaceId !Text

scopedScanCandidates ::
  (IOE :> es, Store :> es) =>
  Int ->
  FindMergeCandidates es
scopedScanCandidates limit =
  FindMergeCandidates \context scope _query ->
    bimap L1MemoryReadFailed (take (max 0 limit))
      <$> Recall.getActiveByScope (memoryContextSpace context) scope

-- | Merge candidates from ranked hybrid recall over the atom's own text.
--
-- The target is @'Recall.ExactScope' scope@, the same population 'scopedScanCandidates' draws
-- from. The two finders differ in how they /rank/ and bound that population — one by hybrid
-- relevance to the atom, the other by a priority-ordered scan — and a finder that also changed
-- which memories exist would not be a substitutable alternative to the other.
--
-- It was not always so. Until recall targets were explicit this line read
-- @'Recall.legacyRecallTarget' scope@, which maps a global scope to /namespace-wide/, so a
-- session scoped @mori@ drew candidates from @mori:repo:web@ as well — and could merge an atom
-- into that memory, rewriting content that feeds a scene the session has nothing to do with.
-- Nobody chose that; it is what @ScopeGlobal@ meaning two things looked like from inside one
-- module. See @docs\/plans\/30-migrate-recall-consumers-to-explicit-targets.md@ for the decision
-- and what it costs: a globally-scoped session now stores where it used to merge across scopes.
recallCandidates ::
  (IOE :> es, Store :> es) =>
  EmbeddingModel ->
  VectorCapability ->
  Int ->
  FindMergeCandidates es
recallCandidates model capability limit =
  FindMergeCandidates \context scope query ->
    -- A limit of zero or less asks for no candidates, which is what the pre-'RecallLimit'
    -- @take (max 0 limit)@ produced. Anything above the bound is clamped rather than refused:
    -- a fused result set holds at most 100 memories, so it was never reachable anyway.
    case Recall.mkRecallLimit (min Recall.maxRecallLimit limit) of
      Left _ -> pure (Right [])
      Right maxResults -> do
        hits <-
          Recall.recall
            model
            capability
            context
            Recall.RecallQuery
              { target = Recall.ExactScope scope,
                query,
                strategy = Recall.Hybrid,
                maxResults
              }
        pure (bimap L1RecallRefused (fmap (.memory)) hits)

buildExtractInput ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  SessionId ->
  SessionRow ->
  [TurnRow] ->
  Eff es (Either L1Error ExtractInput)
buildExtractInput space sid session turns = do
  memoryTextResult <-
    if null turns
      then fallbackMemoryText space sid (sessionScope session)
      else pure (Right (renderTurns turns))
  pure do
    memoryText <- memoryTextResult
    Right
      ExtractInput
        { focus = field session.focus,
          scopeLabel = field (renderScope (sessionScope session)),
          conversation = field memoryText
        }

fallbackMemoryText ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  SessionId ->
  MemoryScope ->
  Eff es (Either L1Error Text)
fallbackMemoryText space sid scope = do
  bySession <- Recall.getBySession space sid
  case bySession of
    Left err -> pure (Left (L1MemoryReadFailed err))
    Right rows
      | not (null rows) -> pure (Right (renderMemories rows))
      | otherwise -> do
          byScope <- Recall.getActiveByScope space scope
          pure $
            case byScope of
              Left err -> Left (L1MemoryReadFailed err)
              Right scopeRows -> Right (renderMemories scopeRows)

applyAtom ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  DistillRuntime ->
  FindMergeCandidates es ->
  SessionId ->
  SessionRow ->
  Int ->
  L1Summary ->
  ExtractedAtom ->
  Eff es (Either L1Error L1Summary)
applyAtom context rt finder sid session maxTurnIndex summary atom = do
  candidatesResult <-
    finder.runFindMergeCandidates
      context
      (sessionScope session)
      (unField atom.content)
  case candidatesResult of
    Left err -> pure (Left err)
    Right candidates -> do
      decisionResult <-
        liftIO $
          runConsolidation
            rt
            ConsolidateInput
              { scopeLabel = field (renderScope (sessionScope session)),
                candidate = atom,
                existing = existingMemory <$> candidates
              }
      case decisionResult of
        Left err -> pure (Left (L1ConsolidationFailed (Text.pack (show err))))
        Right decision -> do
          appliedResult <- applyDecision context sid session atom decision
          case appliedResult of
            Left err -> pure (Left err)
            Right applied -> do
              writeAudit (memoryContextSpace context) sid session atom maxTurnIndex decision applied
              pure (Right (addAppliedDecision summary applied))

-- | Apply a consolidation decision, writing nothing until the whole plan for
-- the atom is known to be executable. The winner id is a deterministic function
-- of the session and the atom content, so every write here is idempotent under
-- keiro's at-least-once timer contract.
applyDecision ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  SessionId ->
  SessionRow ->
  ExtractedAtom ->
  ConsolidationDecision ->
  Eff es (Either L1Error AppliedDecision)
applyDecision context sid session atom decision =
  case decision.action of
    SkipAtom -> pure (Right (appliedSkip Nothing))
    StoreAtom -> storeWinner Nothing Nothing
    UpdateAtom -> mergeInto ActionUpdated
    MergeAtom -> mergeInto ActionMerged
  where
    winner = l1AtomMemoryId sid (unField atom.content)

    appliedSkip note =
      AppliedDecision
        { appliedAction = ActionSkipped,
          winnerId = Nothing,
          appliedTargets = [],
          appliedNote = note
        }

    storeWinner note supersedes =
      fmap
        ( \mid ->
            AppliedDecision
              { appliedAction = ActionStored,
                winnerId = Just mid,
                appliedTargets = [],
                appliedNote = note
              }
        )
        <$> recordAtom context sid session atom decision winner supersedes

    mergeInto action = do
      let requested = nub (parsedTargetIds decision)
          nonSelf = filter (/= winner) requested
          degradeNote
            | null requested = "no usable merge targets supplied; stored the candidate"
            | otherwise = "targets missing; degraded to store"
      if not (null requested) && null nonSelf
        then pure (Right (appliedSkip (Just selfTargetNote)))
        else do
          winnerRow <- Memory.getMemoryRowById (memoryContextSpace context) winner
          case winnerRow of
            Left err -> pure (Left (L1MemoryReadFailed err))
            Right (Just row)
              | row.status /= "active" ->
                  pure (Right (appliedSkip (Just (retiredWinnerNote row.status))))
            _ -> do
              resolved <- resolveExistingTargets (memoryContextSpace context) nonSelf
              case resolved of
                Left err -> pure (Left err)
                Right [] -> storeWinner (Just degradeNote) Nothing
                Right targets@(firstTarget : _) -> do
                  winnerResult <- recordAtom context sid session atom decision winner (Just firstTarget)
                  case winnerResult of
                    Left err -> pure (Left err)
                    Right stored -> do
                      mergeResults <-
                        traverse
                          (\target -> requireMemoryWrite =<< Memory.mergeWithContext context target stored)
                          targets
                      pure $
                        case lefts mergeResults of
                          err : _ -> Left err
                          [] ->
                            Right
                              AppliedDecision
                                { appliedAction = action,
                                  winnerId = Just stored,
                                  appliedTargets = targets,
                                  appliedNote = Nothing
                                }

-- | Drop target ids that name no row in the read model. A hallucinated but
-- syntactically valid TypeID would otherwise fail @Memory.merge@ with
-- 'Memory.MemoryNotFound' /after/ the winner had already been recorded,
-- wedging the timer and leaking one memory per retry.
resolveExistingTargets ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  [MemoryId] ->
  Eff es (Either L1Error [MemoryId])
resolveExistingTargets space =
  foldM step (Right [])
  where
    step (Left err) _ = pure (Left err)
    step (Right acc) mid = do
      row <- Memory.getMemoryRowById space mid
      pure $
        case row of
          Left err -> Left (L1MemoryReadFailed err)
          Right Nothing -> Right acc
          Right (Just _) -> Right (acc <> [mid])

selfTargetNote :: Text
selfTargetNote =
  "merge target is the atom's own prior copy; already represented"

retiredWinnerNote :: Text -> Text
retiredWinnerNote status =
  "this atom was already distilled and is now " <> status <> "; already represented"

-- | The distilled memory belongs to the space the pass was authorized for, and is attributed to
-- that context's principal — the thing that ran the distillation, not the agent whose session
-- produced the evidence. @agentId@ still carries that agent, unchanged, as the organizing label
-- it always was.
recordAtom ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  SessionId ->
  SessionRow ->
  ExtractedAtom ->
  ConsolidationDecision ->
  MemoryId ->
  Maybe MemoryId ->
  Eff es (Either L1Error MemoryId)
recordAtom context sid session atom decision memoryId supersedes = do
  now <- liftIO getCurrentTime
  requireMemoryWrite
    =<< Memory.recordWithContext
      context
      RecordMemoryData
        { memoryId,
          memorySpaceId = memoryContextSpace context,
          actorPrincipal = memoryContextRecordedActor context,
          ownerPrincipal = Nothing,
          agentId = session.agentId,
          sessionId = Just sid,
          scope = sessionScope session,
          memoryType = atomMemoryType atom,
          content = resolvedContent atom decision,
          priority = unField atom.priority,
          confidence = atomConfidence atom,
          tags = Set.fromList ["distilled", "l1"],
          supersedes,
          recordedAt = now
        }

requireMemoryWrite :: (Applicative f) => Either Memory.MemoryWriteError MemoryId -> f (Either L1Error MemoryId)
requireMemoryWrite = \case
  Left err -> pure (Left (L1MemoryWriteFailed err))
  Right mid -> pure (Right mid)

-- | The audit key is a deterministic function of the session, the pass's
-- maximum turn index, and the atom content, so @ON CONFLICT (decision_id) DO
-- NOTHING@ collapses re-fires of the same pass into one row while a later pass
-- over new turns still writes its own.
writeAudit ::
  (IOE :> es, Store :> es) =>
  MemorySpaceId ->
  SessionId ->
  SessionRow ->
  ExtractedAtom ->
  Int ->
  ConsolidationDecision ->
  AppliedDecision ->
  Eff es ()
writeAudit space sid session atom maxTurnIndex decision applied = do
  now <- liftIO getCurrentTime
  runTransaction $
    Tx.statement
      AuditRow
        { memorySpaceId = space,
          decisionId = l1AuditKey sid maxTurnIndex (unField atom.content),
          sessionId = idText sid,
          namespace = scopeNamespaceText (sessionScope session),
          scopeKind = scopeKindText (sessionScope session),
          scopeRef = scopeRefText (sessionScope session),
          candidateContent = unField atom.content,
          decision = appliedActionText applied.appliedAction,
          targetIds = idText <$> applied.appliedTargets,
          resultMemoryId = idText <$> applied.winnerId,
          rationale = Just (auditRationale decision applied),
          decidedAt = now
        }
      insertAuditStmt

auditRationale :: ConsolidationDecision -> AppliedDecision -> Text
auditRationale decision applied =
  unField decision.rationale <> maybe "" (\note -> " [" <> note <> "]") applied.appliedNote

-- | UUIDv5 namespace for every deterministic L1 identity (atom memory ids and
-- consolidation audit keys).
l1AtomNamespace :: UUID
l1AtomNamespace =
  fromMaybe UUID.nil $
    UUID.fromString "6b696f6b-752d-6c31-8000-61746f6d6964"

l1Uuid5 :: Text -> UUID
l1Uuid5 =
  UUIDv5.generateNamed l1AtomNamespace . BS.unpack . TE.encodeUtf8

-- | The memory id an extracted atom always maps to. Keyed on the /candidate/
-- content rather than the consolidator's rewritten @resultContent@, so the id
-- stays stable across retries whose rewrites differ.
l1AtomMemoryId :: SessionId -> Text -> MemoryId
l1AtomMemoryId sid content =
  KindID.decorateKindID (l1Uuid5 (idText sid <> ":" <> content))

l1AuditKey :: SessionId -> Int -> Text -> Text
l1AuditKey sid maxTurnIndex content =
  "kioku_consolidation_decision:"
    <> UUID.toText
      (l1Uuid5 ("audit:" <> idText sid <> ":" <> Text.pack (show maxTurnIndex) <> ":" <> content))

existingMemory :: MemoryRecord -> ExistingMemory
existingMemory row =
  ExistingMemory
    { memoryId = field row.memoryId,
      memoryType = field row.memoryType,
      content = field row.content,
      priority = field row.priority,
      confidence = field row.confidence
    }

parsedTargetIds :: ConsolidationDecision -> [MemoryId]
parsedTargetIds decision =
  mapMaybe parseTargetId decision.targetMemoryIds

parseTargetId :: Text -> Maybe MemoryId
parseTargetId =
  either (const Nothing) Just . parseIdLenient

resolvedContent :: ExtractedAtom -> ConsolidationDecision -> Text
resolvedContent atom decision =
  fromMaybe (unField atom.content) decision.resultContent

atomMemoryType :: ExtractedAtom -> MemoryType
atomMemoryType atom =
  fromMaybe MemoryFact $
    memoryTypeFromText (Text.toLower (unField atom.atomType))

atomConfidence :: ExtractedAtom -> Confidence
atomConfidence atom =
  fromMaybe MediumConfidence $
    confidenceFromText (Text.toLower (unField atom.confidence))

sessionScope :: SessionRow -> MemoryScope
sessionScope session =
  scopeFromColumns session.namespace session.scopeKind session.scopeRef

renderScope :: MemoryScope -> Text
renderScope scope =
  Text.intercalate "/" $
    scopeNamespaceText scope : catMaybes [scopeKindText scope, scopeRefText scope]

renderTurns :: [TurnRow] -> Text
renderTurns =
  Text.intercalate "\n" . fmap renderTurn

renderTurn :: TurnRow -> Text
renderTurn turn =
  Text.pack (show turn.turnIndex)
    <> ". "
    <> turn.role
    <> ": "
    <> turn.content
    <> maybe "" ("\n   tools: " <>) turn.toolSummary

renderMemories :: [MemoryRecord] -> Text
renderMemories =
  Text.intercalate "\n" . fmap renderMemory

renderMemory :: MemoryRecord -> Text
renderMemory row =
  "- " <> row.memoryType <> ": " <> row.content

addAppliedDecision :: L1Summary -> AppliedDecision -> L1Summary
addAppliedDecision summary applied =
  case applied.appliedAction of
    ActionStored -> summary {stored = summary.stored + 1}
    ActionUpdated -> summary {merged = summary.merged + 1}
    ActionMerged -> summary {merged = summary.merged + 1}
    ActionSkipped -> summary {skipped = summary.skipped + 1}

appliedActionText :: AppliedAction -> Text
appliedActionText = \case
  ActionStored -> "store"
  ActionUpdated -> "update"
  ActionMerged -> "merge"
  ActionSkipped -> "skip"

emptySummary :: L1Summary
emptySummary = L1Summary {extracted = 0, stored = 0, merged = 0, skipped = 0}

encodeTargetIds :: [Text] -> Text
encodeTargetIds =
  TE.decodeUtf8 . BL.toStrict . Aeson.encode

selectWatermarkStmt :: Statement WatermarkKey (Maybe Int32)
selectWatermarkStmt =
  preparable
    ( """
      SELECT last_turn_index
      FROM
      """
        <> " "
        <> l1WatermarksTable
        <> " "
        <> """
           WHERE memory_space_id = $1
             AND session_id = $2
           """
    )
    ( ((\(WatermarkKey space _) -> space) >$< memorySpaceParam)
        <> ((\(WatermarkKey _ sessionId) -> sessionId) >$< E.param (E.nonNullable E.text))
    )
    (D.rowMaybe (D.column (D.nonNullable D.int4)))

-- | @GREATEST@ keeps the watermark monotonic: a slow pass over turns 1-3 that
-- lands after a fast pass over turns 1-5 must not rewind it.
upsertWatermarkStmt :: Statement WatermarkRow ()
upsertWatermarkStmt =
  preparable
    ( "INSERT INTO "
        <> l1WatermarksTable
        <> " AS watermark\n"
        <> """
             (memory_space_id, session_id, last_turn_index, distilled_at)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT (session_id) DO UPDATE
             SET last_turn_index =
                   GREATEST(watermark.last_turn_index, EXCLUDED.last_turn_index),
                 distilled_at = EXCLUDED.distilled_at
           """
    )
    watermarkRowEncoder
    D.noResult

watermarkRowEncoder :: E.Params WatermarkRow
watermarkRowEncoder =
  ((\row -> row.memorySpaceId) >$< memorySpaceParam)
    <> ((\row -> row.sessionId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.lastTurnIndex) >$< E.param (E.nonNullable E.int4))
    <> ((\row -> row.distilledAt) >$< E.param (E.nonNullable E.timestamptz))

insertAuditStmt :: Statement AuditRow ()
insertAuditStmt =
  preparable
    ( "INSERT INTO "
        <> consolidationDecisionsTable
        <> "\n"
        <> """
             (memory_space_id, decision_id, session_id, namespace, scope_kind, scope_ref,
              candidate_content, decision, target_ids, result_memory_id, rationale, decided_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10, $11, $12)
           ON CONFLICT (decision_id) DO NOTHING
           """
    )
    auditRowEncoder
    D.noResult

auditRowEncoder :: E.Params AuditRow
auditRowEncoder =
  ((\row -> row.memorySpaceId) >$< memorySpaceParam)
    <> ((\row -> row.decisionId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.sessionId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\row -> row.scopeRef) >$< E.param (E.nullable E.text))
    <> ((\row -> row.candidateContent) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.decision) >$< E.param (E.nonNullable E.text))
    <> ((encodeTargetIds . \row -> row.targetIds) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.resultMemoryId) >$< E.param (E.nullable E.text))
    <> ((\row -> row.rationale) >$< E.param (E.nullable E.text))
    <> ((\row -> row.decidedAt) >$< E.param (E.nonNullable E.timestamptz))
