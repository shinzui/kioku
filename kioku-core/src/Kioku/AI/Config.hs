-- | Host-selected settings. Values describe execution; they do not grant it.
module Kioku.AI.Config
  ( AIFeature (..),
    ExecutionMode (..),
    DistillationConfig (..),
    AIConfig (..),
    disabledAIConfig,
    featureName,
    parseFeature,
    distillationFeatures,
    embeddingFeatures,
    AIConfigurationError (..),
    AIExecutionError (..),
  )
where

import Baikai.Embedding (EmbeddingModel)
import Baikai.Interactive (InteractiveLaunchRequest, InteractiveProvider)
import Baikai.Model (Model)
import Baikai.Options (Options)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Kioku.Prelude hiding (Options)
import Shikumi.Error (ShikumiError)

data AIFeature
  = Extraction
  | Consolidation
  | Scene
  | Persona
  | MemoryEmbedding
  | QueryEmbedding
  | CandidateEmbedding
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data ExecutionMode = Disabled | API | Batch | Interactive
  deriving stock (Eq, Ord, Show)

data DistillationConfig
  = DistillationDisabled
  | CompletionConfig ExecutionMode Model Options
  | InteractiveConfig InteractiveProvider InteractiveLaunchRequest

data AIConfig = AIConfig
  { distillationDefault :: DistillationConfig,
    featureOverrides :: Map AIFeature DistillationConfig,
    embeddingSettings :: Map AIFeature EmbeddingModel
  }

disabledAIConfig :: AIConfig
disabledAIConfig = AIConfig DistillationDisabled Map.empty Map.empty

distillationFeatures, embeddingFeatures :: [AIFeature]
distillationFeatures = [Extraction, Consolidation, Scene, Persona]
embeddingFeatures = [MemoryEmbedding, QueryEmbedding, CandidateEmbedding]

featureName :: AIFeature -> Text
featureName = \case
  Extraction -> "extraction"
  Consolidation -> "consolidation"
  Scene -> "scene"
  Persona -> "persona"
  MemoryEmbedding -> "memory-embedding"
  QueryEmbedding -> "query-embedding"
  CandidateEmbedding -> "candidate-embedding"

parseFeature :: Text -> Either AIConfigurationError AIFeature
parseFeature name = case filter ((== name) . featureName) [minBound .. maxBound] of
  [feature] -> Right feature
  _ -> Left (InvalidAIConfiguration Nothing "unknown AI feature")

-- | Diagnostics contain remedies, never rendered provider settings or secrets.
data AIConfigurationError = InvalidAIConfiguration (Maybe AIFeature) Text
  deriving stock (Eq, Show)

data AIExecutionError
  = AIDisabled AIFeature
  | InteractiveUnavailable AIFeature
  | AIExecutionRefused AIFeature Text
  | AIProgramFailed ShikumiError
  | AIInteractiveFailed AIFeature Text
  deriving stock (Eq, Show)
