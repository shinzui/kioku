{-# LANGUAGE DataKinds #-}

-- | Pure shikumi program for rendering L3 persona profiles from L2 scenes.
module Kioku.Distill.Persona
  ( PersonaInput (..),
    PersonaOutput (..),
    personaSignature,
    personaProgram,
  )
where

import Kioku.Prelude
import Shikumi.Adapter (ToPrompt)
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema)
import Shikumi.Schema.Types (Field)
import Shikumi.Signature (Signature, mkSignature)

data PersonaInput = PersonaInput
  { scopeLabel :: Field "human label of the scope" Text,
    scenes :: Field "the scene blocks for this scope, newline-joined" Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newtype PersonaOutput = PersonaOutput
  { bodyMd :: Field "a single distilled persona/profile markdown for this scope" Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

personaSignature :: Signature PersonaInput PersonaOutput
personaSignature =
  mkSignature
    "Distill all scene blocks for one scope into a single concise persona or \
    \profile. Describe who the agent is working with in this scope, their \
    \stable preferences, constraints, project facts, and durable patterns \
    \learned across scenes. Produce one markdown document. Preserve only details \
    \grounded in the scene text; do not invent biographical facts or private data."

personaProgram :: Program PersonaInput PersonaOutput
personaProgram = predict personaSignature
