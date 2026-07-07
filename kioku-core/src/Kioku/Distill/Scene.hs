{-# LANGUAGE DataKinds #-}

-- | Pure shikumi program for rendering L2 scene blocks from L1 memory atoms.
module Kioku.Distill.Scene
  ( SceneInput (..),
    SceneOutput (..),
    sceneSignature,
    sceneProgram,
  )
where

import Kioku.Prelude
import Shikumi.Adapter (ToPrompt)
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Schema.Types (Field)
import Shikumi.Signature (Signature, mkSignature)

data SceneInput = SceneInput
  { scopeLabel :: Field "human label of the scope" Text,
    atoms :: Field "the active memory atoms in this scope, newline-joined" Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data SceneOutput = SceneOutput
  { title :: Field "a short scene title, e.g. 'Testing & CI practices'" Text,
    bodyMd :: Field "a markdown scene block summarizing the atoms as a narrative" Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

sceneSignature :: Signature SceneInput SceneOutput
sceneSignature =
  mkSignature
    "Summarize a set of related agent memory atoms for one scope into a single \
    \readable markdown scene block. The title should name the dominant topic or \
    \workflow. The body should synthesize the atoms into a short narrative with \
    \a few bullet points or brief paragraphs. Preserve concrete preferences, \
    \constraints, and project facts; do not invent details not present in the atoms."

sceneProgram :: Program SceneInput SceneOutput
sceneProgram = predict sceneSignature
