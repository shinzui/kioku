module Kioku.Api.Types
  ( MemoryType (..),
    memoryTypeToText,
    memoryTypeFromText,
    Confidence (..),
    confidenceToText,
    confidenceFromText,
    MemoryStatus (..),
    memoryStatusToText,
    memoryStatusFromText,
    MemoryRecord (..),
  )
where

import Data.Set (Set)
import Kioku.Api.Scope (MemoryScope)
import Kioku.Prelude

data MemoryType
  = MemoryFact
  | MemoryPattern
  | MemoryPreference
  | MemoryConstraint
  | MemoryInstruction
  deriving stock (Generic, Eq, Show, Enum, Bounded)

memoryTypeToText :: MemoryType -> Text
memoryTypeToText = \case
  MemoryFact -> "fact"
  MemoryPattern -> "pattern"
  MemoryPreference -> "preference"
  MemoryConstraint -> "constraint"
  MemoryInstruction -> "instruction"

memoryTypeFromText :: Text -> Maybe MemoryType
memoryTypeFromText = \case
  "fact" -> Just MemoryFact
  "pattern" -> Just MemoryPattern
  "preference" -> Just MemoryPreference
  "constraint" -> Just MemoryConstraint
  "instruction" -> Just MemoryInstruction
  _ -> Nothing

data Confidence
  = HighConfidence
  | MediumConfidence
  | LowConfidence
  deriving stock (Generic, Eq, Show, Enum, Bounded)

confidenceToText :: Confidence -> Text
confidenceToText = \case
  HighConfidence -> "high"
  MediumConfidence -> "medium"
  LowConfidence -> "low"

confidenceFromText :: Text -> Maybe Confidence
confidenceFromText = \case
  "high" -> Just HighConfidence
  "medium" -> Just MediumConfidence
  "low" -> Just LowConfidence
  _ -> Nothing

data MemoryStatus
  = MemoryActive
  | MemorySuperseded
  | MemoryMergedStatus
  | MemoryArchived
  deriving stock (Generic, Eq, Show, Enum, Bounded)

memoryStatusToText :: MemoryStatus -> Text
memoryStatusToText = \case
  MemoryActive -> "active"
  MemorySuperseded -> "superseded"
  MemoryMergedStatus -> "merged"
  MemoryArchived -> "archived"

memoryStatusFromText :: Text -> Maybe MemoryStatus
memoryStatusFromText = \case
  "active" -> Just MemoryActive
  "superseded" -> Just MemorySuperseded
  "merged" -> Just MemoryMergedStatus
  "archived" -> Just MemoryArchived
  _ -> Nothing

data MemoryRecord = MemoryRecord
  { memoryId :: !Text,
    agentId :: !Text,
    sessionId :: !(Maybe Text),
    scope :: !MemoryScope,
    memoryType :: !Text,
    content :: !Text,
    priority :: !Int,
    confidence :: !Text,
    tags :: !(Set Text),
    status :: !Text,
    createdAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
