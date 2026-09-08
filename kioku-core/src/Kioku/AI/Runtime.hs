{-# LANGUAGE DataKinds #-}

-- | Immutable dispatch through capabilities supplied by the embedding host.
module Kioku.AI.Runtime
  ( AIRuntime,
    HostCapabilities (..),
    noHostCapabilities,
    newAIRuntime,
    disabledAIRuntime,
    featureConfiguration,
    executionAvailability,
    runAIProgram,
    runtimeEmbeddingModel,
    interactiveLauncher,
  )
where

import Baikai.Api (Api (..), normaliseApi)
import Baikai.Embedding qualified as Embedding
import Baikai.Interactive (InteractiveLaunchRequest, InteractiveLaunchResult)
import Baikai.Interactive qualified
import Baikai.Model qualified as Model
import Baikai.Options qualified as Options
import Baikai.Provider.Registry qualified as Registry
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text qualified as Text
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Dispatch.Dynamic (interpose)
import Effectful.Error.Static (runErrorNoCallStack)
import Kioku.AI.Config
import Kioku.Prelude
import Shikumi.Error (ShikumiError)
import Shikumi.LLM qualified as LLM
import Shikumi.Program (Program, runProgram)
import Shikumi.Routing (routeLLM, runRouting)

-- | Registries grant separate API and batch capabilities. The callback grants a
-- fresh interactive session; presence of a terminal or executable grants none.
data HostCapabilities = HostCapabilities
  { apiRegistry :: Maybe Registry.ProviderRegistry,
    batchRegistry :: Maybe Registry.ProviderRegistry,
    allowInteractive :: Bool,
    launchInteractive :: Maybe (AIFeature -> InteractiveLaunchRequest -> IO (Either AIExecutionError InteractiveLaunchResult)),
    allowEmbeddingAPI :: Bool
  }

noHostCapabilities :: HostCapabilities
noHostCapabilities = HostCapabilities Nothing Nothing False Nothing False

data AIRuntime = AIRuntime AIConfig HostCapabilities (Map.Map AIFeature Registry.ProviderRegistry)

disabledAIRuntime :: AIRuntime
disabledAIRuntime = AIRuntime disabledAIConfig noHostCapabilities Map.empty

featureConfiguration :: AIRuntime -> AIFeature -> DistillationConfig
featureConfiguration (AIRuntime cfg _ _) feature
  | feature `elem` distillationFeatures = Map.findWithDefault cfg.distillationDefault feature cfg.featureOverrides
  | otherwise = DistillationDisabled

runtimeEmbeddingModel :: AIRuntime -> AIFeature -> Either AIExecutionError Embedding.EmbeddingModel
runtimeEmbeddingModel (AIRuntime cfg _ _) feature = maybe (Left (AIDisabled feature)) Right (Map.lookup feature cfg.embeddingSettings)

interactiveLauncher :: AIRuntime -> Maybe (AIFeature -> InteractiveLaunchRequest -> IO (Either AIExecutionError InteractiveLaunchResult))
interactiveLauncher (AIRuntime _ caps _) = caps.launchInteractive

executionAvailability :: AIRuntime -> AIFeature -> Either AIExecutionError ()
executionAvailability rt feature
  | feature `elem` embeddingFeatures = () <$ runtimeEmbeddingModel rt feature
  | otherwise = case featureConfiguration rt feature of
      DistillationDisabled -> Left (AIDisabled feature)
      InteractiveConfig {} -> maybe (Left (InteractiveUnavailable feature)) (const (Right ())) (interactiveLauncher rt)
      CompletionConfig {} -> Right ()

-- | Validate without reading credentials or invoking handlers. Snapshot selected
-- handlers into private registries so later host registration cannot widen them.
newAIRuntime :: HostCapabilities -> AIConfig -> IO (Either AIConfigurationError AIRuntime)
newAIRuntime caps cfg = case validateShape of
  Left err -> pure (Left err)
  Right () -> do
    selected <- traverse validateFeature distillationFeatures
    pure $ AIRuntime cfg caps . Map.fromList . catMaybes <$> sequence selected
  where
    invalid f = Left . InvalidAIConfiguration (Just f)
    validateShape = do
      forM_ (Map.keys cfg.featureOverrides) $ \f ->
        unless (f `elem` distillationFeatures) (invalid f "embedding features require embedding settings")
      forM_ (Map.toList cfg.embeddingSettings) $ \(f, model) -> do
        unless (f `elem` embeddingFeatures) (invalid f "distillation features require distillation settings")
        unless caps.allowEmbeddingAPI (invalid f "host has not granted embedding API execution")
        when (Text.null (Text.strip model.modelId)) (invalid f "select an embedding model")
        unless (model.dimensions == Just 1536) (invalid f "stored vectors require 1536 dimensions; migrate and re-embed before changing models")
      case Map.elems cfg.embeddingSettings of
        [] -> Right ()
        model : rest ->
          unless
            (all (\other -> other.modelId == model.modelId && other.baseUrl == model.baseUrl) rest)
            (Left (InvalidAIConfiguration Nothing "memory, query and candidate embeddings must use the same model and endpoint"))
    validateFeature f = case featureConfiguration (AIRuntime cfg caps Map.empty) f of
      DistillationDisabled -> pure (Right Nothing)
      InteractiveConfig _ request -> pure $ do
        unless caps.allowInteractive (invalid f "host has not granted interactive execution")
        when (maybe True (Text.null . Text.strip) request.modelId) (invalid f "select an interactive model")
        Right Nothing
      CompletionConfig mode model _ -> do
        let registry = case mode of API -> caps.apiRegistry; Batch -> caps.batchRegistry; _ -> Nothing
            tag = normaliseApi model.api
            tagAllowed = case tag of
              AnthropicMessagesCli -> mode == Batch
              OpenAICompletionsCli -> mode == Batch
              Custom _ -> mode == API || mode == Batch
              _ -> mode == API
        if Text.null (Text.strip (Model.modelId model))
          then pure (invalid f "select a completion model")
          else
            if not tagAllowed
              then pure (invalid f "model transport does not match execution mode")
              else case registry of
                Nothing -> pure (invalid f "host has not granted this completion mode")
                Just reg ->
                  Registry.lookupApiProviderWith reg tag >>= \case
                    Nothing -> pure (invalid f "register the selected transport in the host registry")
                    Just handler -> do
                      snapshot <- Registry.newProviderRegistryFrom [handler]
                      pure (Right (Just (f, snapshot)))

-- | Force both model and options at the final LLM boundary. A Program's nested
-- routing choices cannot escape the selected feature capability.
runAIProgram :: AIRuntime -> AIFeature -> Program i o -> i -> IO (Either AIExecutionError o)
runAIProgram rt@(AIRuntime _ _ registries) feature prog input = case executionAvailability rt feature of
  Left err -> pure (Left err)
  Right () -> case (featureConfiguration rt feature, Map.lookup feature registries) of
    (CompletionConfig _ model selected, Just reg) -> do
      result <-
        runEff
          . runErrorNoCallStack @ShikumiError
          . runConcurrent
          . runRouting model
          . LLM.runLLMResilient (LLM.defaultLLMConfig reg)
          . interpose
            ( \_ -> \case
                LLM.Complete _ ctx opts -> LLM.complete model ctx (wireOptions selected opts)
                LLM.Stream _ ctx opts -> LLM.stream model ctx (wireOptions selected opts)
            )
          . routeLLM
          $ runProgram prog input
      pure (either (Left . AIProgramFailed) Right result)
    _ -> pure (Left (AIExecutionRefused feature "interactive execution requires a typed signature result handoff"))
  where
    wireOptions selected rendered =
      selected
        { Options.responseFormat = rendered.responseFormat,
          Options.metadata = Map.union rendered.metadata selected.metadata
        }
