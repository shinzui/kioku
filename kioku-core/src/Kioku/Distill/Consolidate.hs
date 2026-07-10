{-# LANGUAGE DataKinds #-}

-- | Pure shikumi program for deciding how an extracted atom affects active memory.
module Kioku.Distill.Consolidate
  ( ConsolidationAction (..),
    ConsolidationDecision (..),
    ConsolidateInput (..),
    ExistingMemory (..),
    consolidateSignature,
    consolidateProgram,
  )
where

import Kioku.Distill.Extract (ExtractedAtom)
import Kioku.Id (MemoryId, parseIdAnyPrefix)
import Kioku.Prelude
import Shikumi.Adapter (ToPrompt)
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable (..))
import Shikumi.Schema.Types (Field)
import Shikumi.Signature (Signature, mkSignature)

data ConsolidationAction
  = StoreAtom
  | UpdateAtom
  | MergeAtom
  | SkipAtom
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel)

data ExistingMemory = ExistingMemory
  { memoryId :: Field "existing memory identifier" Text,
    memoryType :: Field "existing memory type or category" Text,
    content :: Field "existing memory content" Text,
    priority :: Field "existing memory priority where lower is more important" Int,
    confidence :: Field "existing confidence label" Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data ConsolidateInput = ConsolidateInput
  { scopeLabel :: Field "human-readable memory scope label" Text,
    candidate :: ExtractedAtom,
    existing :: [ExistingMemory]
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data ConsolidationDecision = ConsolidationDecision
  { action :: ConsolidationAction,
    targetMemoryIds :: [Text],
    resultContent :: Maybe Text,
    rationale :: Field "one concise reason for the decision" Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

-- | An @UpdateAtom@ or @MergeAtom@ that names no parseable target is a decision
-- L1 can only degrade to a store; rejecting it here means the audit trail can
-- never record a merge that did not happen. @StoreAtom@ and @SkipAtom@ have a
-- safe canonical form — no targets — so stray ids are cleared rather than
-- rejected.
instance Validatable ConsolidationDecision where
  validate decision =
    case decision.action of
      StoreAtom -> Right decision {targetMemoryIds = []}
      SkipAtom -> Right decision {targetMemoryIds = []}
      UpdateAtom -> requireTargets decision
      MergeAtom -> requireTargets decision

requireTargets :: ConsolidationDecision -> Either Text ConsolidationDecision
requireTargets decision
  | null decision.targetMemoryIds =
      Left (actionLabel decision.action <> " requires at least one targetMemoryId")
  | otherwise = do
      _ <- traverse parseTarget decision.targetMemoryIds
      Right decision
  where
    parseTarget :: Text -> Either Text MemoryId
    parseTarget raw =
      case parseIdAnyPrefix raw of
        Left err -> Left ("targetMemoryIds contains an unparseable id " <> raw <> ": " <> err)
        Right mid -> Right mid

actionLabel :: ConsolidationAction -> Text
actionLabel = \case
  StoreAtom -> "StoreAtom"
  UpdateAtom -> "UpdateAtom"
  MergeAtom -> "MergeAtom"
  SkipAtom -> "SkipAtom"

consolidateSignature :: Signature ConsolidateInput ConsolidationDecision
consolidateSignature =
  mkSignature
    "Decide how one extracted memory atom should affect the active memories in \
    \the same scope. Choose StoreAtom when the candidate is durable and not \
    \already represented. Choose UpdateAtom when one existing memory should be \
    \rewritten with fresher or clearer content. Choose MergeAtom when multiple \
    \existing memories should collapse into one memory; put all affected ids in \
    \targetMemoryIds and put the winning merged content in resultContent. Choose \
    \SkipAtom when the candidate is transient, unsupported, redundant, or unsafe \
    \to store. For StoreAtom, leave targetMemoryIds empty and put the candidate \
    \content in resultContent. For SkipAtom, leave targetMemoryIds empty and \
    \resultContent absent."

consolidateProgram :: Program ConsolidateInput ConsolidationDecision
consolidateProgram = predict consolidateSignature
