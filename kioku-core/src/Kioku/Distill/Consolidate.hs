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
import Kioku.Prelude
import Shikumi.Adapter (ToPrompt)
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema)
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
