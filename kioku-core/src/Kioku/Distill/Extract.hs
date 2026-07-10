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

import Data.Text qualified as Text
import Kioku.Prelude
import Shikumi.Adapter (ToPrompt)
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable (..))
import Shikumi.Schema.Types (Field, field, unField)
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

atomTypes :: [Text]
atomTypes = ["fact", "pattern", "preference", "constraint", "instruction"]

confidences :: [Text]
confidences = ["high", "medium", "low"]

-- | Normalize what has a safe canonical form; reject what does not.
--
-- An unclamped negative priority is the dangerous case: @priority@ flows
-- straight into @RecordMemoryData@ and from there into every
-- @ORDER BY priority ASC@ read, so a hallucinated @-1000000@ would dominate
-- every candidate and injection query in the scope forever. Unknown enum values
-- were previously coerced to defaults inside L1, silently relabelling a memory;
-- rejecting them surfaces as a shikumi 'Shikumi.Error.ValidationFailure', i.e. a
-- failed extraction, i.e. a retryable timer fire.
instance Validatable ExtractOutput where
  validate output = ExtractOutput <$> traverse validateAtom output.atoms

validateAtom :: ExtractedAtom -> Either Text ExtractedAtom
validateAtom atom = do
  content <- nonEmpty "atom content" (Text.strip (unField atom.content))
  atomType <- oneOf "atomType" atomTypes (normalize (unField atom.atomType))
  confidence <- oneOf "confidence" confidences (normalize (unField atom.confidence))
  pure
    ExtractedAtom
      { atomType = field atomType,
        content = field content,
        priority = field (clamp 0 100 (unField atom.priority)),
        confidence = field confidence
      }
  where
    normalize = Text.toLower . Text.strip

nonEmpty :: Text -> Text -> Either Text Text
nonEmpty label value
  | Text.null value = Left (label <> " must be non-empty")
  | otherwise = Right value

oneOf :: Text -> [Text] -> Text -> Either Text Text
oneOf label allowed value
  | value `elem` allowed = Right value
  | otherwise =
      Left (label <> " must be one of " <> Text.intercalate " | " allowed <> "; got: " <> value)

clamp :: Int -> Int -> Int -> Int
clamp lo hi = max lo . min hi

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
