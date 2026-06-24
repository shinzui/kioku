{-# LANGUAGE DataKinds #-}

module Kioku.Distill.L1
  ( FindMergeCandidates (..),
    L1Error (..),
    L1Summary (..),
    distillSessionL1,
    recallCandidates,
    scopedScanCandidates,
  )
where

import Baikai.Embedding (EmbeddingModel)
import Control.Monad (foldM)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Either (lefts)
import Data.Functor.Contravariant ((>$<))
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.ReadModel (ReadModelError)
import Kioku.Api.Scope (MemoryScope, scopeFromColumns, scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Api.Types (Confidence (..), MemoryRecord (..), MemoryType (..), confidenceFromText, memoryTypeFromText)
import Kioku.Distill.Consolidate
  ( ConsolidateInput (..),
    ConsolidationAction (..),
    ConsolidationDecision (..),
    ExistingMemory (..),
    consolidateProgram,
  )
import Kioku.Distill.Extract (ExtractInput (..), ExtractOutput (..), ExtractedAtom (..), extractProgram)
import Kioku.Distill.Runtime (DistillRuntime, runDistillProgram)
import Kioku.Id (MemoryId, SessionId, genMemoryId, idText, parseIdAnyPrefix)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Prelude
import Kioku.Recall qualified as Recall
import Kioku.Recall.Capability (VectorCapability)
import Kioku.Session qualified as Session
import Kioku.Session.ReadModel (SessionRow (..), TurnRow (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Shikumi.Schema.Types (field, unField)

newtype FindMergeCandidates es = FindMergeCandidates
  { runFindMergeCandidates :: MemoryScope -> Text -> Eff es [MemoryRecord]
  }

data L1Error
  = L1SessionReadFailed !ReadModelError
  | L1SessionNotFound !SessionId
  | L1TurnReadFailed !ReadModelError
  | L1MemoryReadFailed !ReadModelError
  | L1MemoryWriteFailed !Memory.MemoryWriteError
  deriving stock (Generic, Show)

data L1Summary = L1Summary
  { extracted :: !Int,
    stored :: !Int,
    merged :: !Int,
    skipped :: !Int
  }
  deriving stock (Generic, Eq, Show)

data AppliedDecision
  = AppliedStored !(Maybe MemoryId)
  | AppliedMerged !(Maybe MemoryId)
  | AppliedSkipped

data AuditRow = AuditRow
  { decisionId :: !Text,
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

distillSessionL1 ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  DistillRuntime ->
  FindMergeCandidates es ->
  SessionId ->
  Eff es (Either L1Error L1Summary)
distillSessionL1 rt finder sid = do
  sessionResult <- Session.getById sid
  case sessionResult of
    Left err -> pure (Left (L1SessionReadFailed err))
    Right Nothing -> pure (Left (L1SessionNotFound sid))
    Right (Just session) -> do
      inputResult <- buildExtractInput sid session
      case inputResult of
        Left err -> pure (Left err)
        Right input -> do
          extractedResult <- liftIO (runDistillProgram rt extractProgram input)
          case extractedResult of
            Left _err -> pure (Right emptySummary)
            Right output ->
              foldM
                (stepAtom rt finder sid session)
                (Right emptySummary {extracted = length output.atoms})
                output.atoms
  where
    stepAtom _ _ _ _ (Left err) _ = pure (Left err)
    stepAtom stepRt stepFinder stepSid stepSession (Right summary) atom =
      applyAtom stepRt stepFinder stepSid stepSession summary atom

scopedScanCandidates ::
  (IOE :> es, Store :> es) =>
  Int ->
  FindMergeCandidates es
scopedScanCandidates limit =
  FindMergeCandidates \scope _query -> do
    result <- Recall.getActiveByScope scope
    pure $
      case result of
        Left _err -> []
        Right rows -> take (max 0 limit) rows

recallCandidates ::
  (IOE :> es, Store :> es) =>
  EmbeddingModel ->
  VectorCapability ->
  Int ->
  FindMergeCandidates es
recallCandidates model capability limit =
  FindMergeCandidates \scope query -> do
    hits <-
      Recall.recall
        model
        capability
        Recall.RecallRequest
          { scope,
            query,
            strategy = Recall.Hybrid,
            maxResults = max 0 limit
          }
    pure (fmap (.memory) hits)

buildExtractInput ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  SessionRow ->
  Eff es (Either L1Error ExtractInput)
buildExtractInput sid session = do
  turnsResult <- Session.getTurns sid
  case turnsResult of
    Left err -> pure (Left (L1TurnReadFailed err))
    Right turns -> do
      memoryTextResult <-
        if null turns
          then fallbackMemoryText sid (sessionScope session)
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
  SessionId ->
  MemoryScope ->
  Eff es (Either L1Error Text)
fallbackMemoryText sid scope = do
  bySession <- Recall.getBySession sid
  case bySession of
    Left err -> pure (Left (L1MemoryReadFailed err))
    Right rows
      | not (null rows) -> pure (Right (renderMemories rows))
      | otherwise -> do
          byScope <- Recall.getActiveByScope scope
          pure $
            case byScope of
              Left err -> Left (L1MemoryReadFailed err)
              Right scopeRows -> Right (renderMemories scopeRows)

applyAtom ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  DistillRuntime ->
  FindMergeCandidates es ->
  SessionId ->
  SessionRow ->
  L1Summary ->
  ExtractedAtom ->
  Eff es (Either L1Error L1Summary)
applyAtom rt finder sid session summary atom = do
  candidates <- finder.runFindMergeCandidates (sessionScope session) (unField atom.content)
  decisionResult <-
    liftIO $
      runDistillProgram
        rt
        consolidateProgram
        ConsolidateInput
          { scopeLabel = field (renderScope (sessionScope session)),
            candidate = atom,
            existing = existingMemory <$> candidates
          }
  let decision =
        case decisionResult of
          Left _err -> fallbackStoreDecision atom
          Right d -> d
  appliedResult <- applyDecision sid session atom decision
  case appliedResult of
    Left err -> pure (Left err)
    Right applied -> do
      writeAudit sid session atom decision applied
      pure (Right (addAppliedDecision summary applied))

applyDecision ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  SessionRow ->
  ExtractedAtom ->
  ConsolidationDecision ->
  Eff es (Either L1Error AppliedDecision)
applyDecision sid session atom decision =
  case decision.action of
    StoreAtom -> do
      fmap (AppliedStored . Just) <$> recordAtom sid session atom decision Nothing
    UpdateAtom -> do
      case parsedTargetIds decision of
        [] -> do
          fmap (AppliedStored . Just) <$> recordAtom sid session atom decision Nothing
        target : _ -> do
          winnerResult <- recordAtom sid session atom decision (Just target)
          case winnerResult of
            Left err -> pure (Left err)
            Right winner -> do
              merged <- requireMemoryWrite =<< Memory.merge target winner
              pure $
                case merged of
                  Left err -> Left err
                  Right _ -> Right (AppliedMerged (Just winner))
    MergeAtom -> do
      case parsedTargetIds decision of
        [] -> do
          fmap (AppliedStored . Just) <$> recordAtom sid session atom decision Nothing
        targetIds@(firstTarget : _) -> do
          winnerResult <- recordAtom sid session atom decision (Just firstTarget)
          case winnerResult of
            Left err -> pure (Left err)
            Right winner -> do
              mergeResults <- traverse (\target -> requireMemoryWrite =<< Memory.merge target winner) targetIds
              pure $
                case lefts mergeResults of
                  err : _ -> Left err
                  [] -> Right (AppliedMerged (Just winner))
    SkipAtom ->
      pure (Right AppliedSkipped)

recordAtom ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  SessionRow ->
  ExtractedAtom ->
  ConsolidationDecision ->
  Maybe MemoryId ->
  Eff es (Either L1Error MemoryId)
recordAtom sid session atom decision supersedes = do
  memoryId <- genMemoryId
  now <- liftIO getCurrentTime
  requireMemoryWrite
    =<< Memory.record
      RecordMemoryData
        { memoryId,
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

writeAudit ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  SessionRow ->
  ExtractedAtom ->
  ConsolidationDecision ->
  AppliedDecision ->
  Eff es ()
writeAudit sid session atom decision applied = do
  auditKey <- ("kioku_consolidation_decision:" <>) . idText <$> genMemoryId
  now <- liftIO getCurrentTime
  runTransaction $
    Tx.statement
      AuditRow
        { decisionId = auditKey,
          sessionId = idText sid,
          namespace = scopeNamespaceText (sessionScope session),
          scopeKind = scopeKindText (sessionScope session),
          scopeRef = scopeRefText (sessionScope session),
          candidateContent = unField atom.content,
          decision = actionText decision.action,
          targetIds = decision.targetMemoryIds,
          resultMemoryId = appliedResultId applied,
          rationale = Just (unField decision.rationale),
          decidedAt = now
        }
      insertAuditStmt

existingMemory :: MemoryRecord -> ExistingMemory
existingMemory row =
  ExistingMemory
    { memoryId = field row.memoryId,
      memoryType = field row.memoryType,
      content = field row.content,
      priority = field row.priority,
      confidence = field row.confidence
    }

fallbackStoreDecision :: ExtractedAtom -> ConsolidationDecision
fallbackStoreDecision atom =
  ConsolidationDecision
    { action = StoreAtom,
      targetMemoryIds = [],
      resultContent = Just (unField atom.content),
      rationale = field "consolidation failed; storing candidate atom conservatively"
    }

parsedTargetIds :: ConsolidationDecision -> [MemoryId]
parsedTargetIds decision =
  mapMaybe parseTargetId decision.targetMemoryIds

parseTargetId :: Text -> Maybe MemoryId
parseTargetId =
  either (const Nothing) Just . parseIdAnyPrefix

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
addAppliedDecision summary = \case
  AppliedStored _ ->
    summary {stored = summary.stored + 1}
  AppliedMerged _ ->
    summary {merged = summary.merged + 1}
  AppliedSkipped ->
    summary {skipped = summary.skipped + 1}

appliedResultId :: AppliedDecision -> Maybe Text
appliedResultId = \case
  AppliedStored mid -> idText <$> mid
  AppliedMerged mid -> idText <$> mid
  AppliedSkipped -> Nothing

actionText :: ConsolidationAction -> Text
actionText = \case
  StoreAtom -> "store"
  UpdateAtom -> "update"
  MergeAtom -> "merge"
  SkipAtom -> "skip"

emptySummary :: L1Summary
emptySummary = L1Summary {extracted = 0, stored = 0, merged = 0, skipped = 0}

encodeTargetIds :: [Text] -> Text
encodeTargetIds =
  TE.decodeUtf8 . BL.toStrict . Aeson.encode

insertAuditStmt :: Statement AuditRow ()
insertAuditStmt =
  preparable
    """
    INSERT INTO kioku_consolidation_decisions
      (decision_id, session_id, namespace, scope_kind, scope_ref, candidate_content,
       decision, target_ids, result_memory_id, rationale, decided_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, $10, $11)
    ON CONFLICT (decision_id) DO NOTHING
    """
    auditRowEncoder
    D.noResult

auditRowEncoder :: E.Params AuditRow
auditRowEncoder =
  ((\row -> row.decisionId) >$< E.param (E.nonNullable E.text))
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
