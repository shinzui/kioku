{-# LANGUAGE DataKinds #-}

-- | Pure shikumi program for extracting L1 memory atoms from recent session text.
module Kioku.Distill.Extract
  ( ExtractInput (..),
    ExtractedAtom (..),
    ExtractOutput (..),
    extractSignature,
    extractProgram,
  )
where

import Kioku.Prelude
import Shikumi.Adapter (ToPrompt)
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema)
import Shikumi.Schema.Types (Field)
import Shikumi.Signature (Signature, mkSignature)

data ExtractInput = ExtractInput
  { focus :: Field "the session focus, task, or topic" Text,
    scopeLabel :: Field "human-readable memory scope label" Text,
    conversation :: Field "recent turns, notes, or recorded memory evidence" Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data ExtractedAtom = ExtractedAtom
  { atomType :: Field "one of: fact | pattern | preference | constraint | instruction" Text,
    content :: Field "one concise durable memory sentence" Text,
    priority :: Field "0=always inject; 100=default; larger=lower priority" Int,
    confidence :: Field "one of: high | medium | low" Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newtype ExtractOutput = ExtractOutput
  { atoms :: [ExtractedAtom]
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

extractSignature :: Signature ExtractInput ExtractOutput
extractSignature =
  mkSignature
    "Extract durable L1 memory atoms from the provided session text. Include only \
    \information that is useful after this session: stable user preferences, \
    \project facts, recurring patterns, constraints, and explicit instructions. \
    \Ignore transient chatter, one-off status updates, secrets, and unsupported \
    \guesses. Keep each atom as one concise sentence, choose an atomType from the \
    \allowed set, set priority lower for more important memories, and set \
    \confidence to high, medium, or low. Return an empty atoms list when there is \
    \nothing durable to retain."

extractProgram :: Program ExtractInput ExtractOutput
extractProgram = predict extractSignature
