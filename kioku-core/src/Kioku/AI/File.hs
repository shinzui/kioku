-- | Versioned AI files shared by command-line and embedding hosts.
module Kioku.AI.File (loadAIRuntime, parseAIConfig) where

import Baikai.Auth (ApiKeySource (..))
import Baikai.Embedding qualified as E
import Baikai.Interactive qualified as I
import Baikai.Model qualified as M
import Baikai.Options qualified as O
import Baikai.Provider.Claude.Api qualified as Claude
import Baikai.Provider.Claude.Cli qualified as ClaudeCli
import Baikai.Provider.Claude.Interactive qualified as ClaudeInteractive
import Baikai.Provider.OpenAI.Api qualified as OpenAI
import Baikai.Provider.OpenAI.Cli qualified as Codex
import Baikai.Provider.OpenAI.Interactive qualified as CodexInteractive
import Baikai.Provider.OpenAI.Responses qualified as Responses
import Baikai.Provider.Registry (newProviderRegistryFrom)
import Control.Applicative ((<|>))
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Kioku.AI.Config
import Kioku.AI.Runtime
import System.Environment (lookupEnv)

-- | Background workers never receive the foreground session capability.
loadAIRuntime :: Bool -> Maybe FilePath -> IO AIRuntime
loadAIRuntime foreground explicit = do
  environment <- lookupEnv "KIOKU_AI_CONFIG"
  case explicit <|> environment of
    Nothing -> pure disabledAIRuntime
    Just path -> do
      bytes <- BS.readFile path
      (cfg, permissions) <- either (const (ioError (userError "kioku: invalid AI configuration; check version, feature names, modes and required settings"))) pure (eitherDecodeStrict bytes >>= parseEither parseAIConfig)
      api <- if API `elem` permissions then Just <$> newProviderRegistryFrom [Claude.claudeMessagesProvider, OpenAI.openaiChatProvider, Responses.openaiResponsesProvider] else pure Nothing
      batch <- if Batch `elem` permissions then Just <$> newProviderRegistryFrom [ClaudeCli.claudeCliProvider ClaudeCli.defaultClaudeCliConfig, Codex.codexCliProvider Codex.defaultCodexCliConfig] else pure Nothing
      let launcher feature request = case Map.findWithDefault cfg.distillationDefault feature cfg.featureOverrides of
            InteractiveConfig I.InteractiveClaude _ -> either (const (Left (AIInteractiveFailed feature "Baikai refused interactive safety settings"))) Right <$> ClaudeInteractive.launchClaudeInteractive ClaudeInteractive.defaultClaudeInteractiveConfig request
            InteractiveConfig I.InteractiveCodex _ -> either (const (Left (AIInteractiveFailed feature "Baikai refused interactive safety settings"))) Right <$> CodexInteractive.launchCodexInteractive CodexInteractive.defaultCodexInteractiveConfig request
            _ -> pure (Left (AIExecutionRefused feature "interactive mode was not selected"))
          caps =
            noHostCapabilities
              { apiRegistry = api,
                batchRegistry = batch,
                allowInteractive = Interactive `elem` permissions,
                launchInteractive = if foreground && Interactive `elem` permissions then Just launcher else Nothing,
                allowEmbeddingAPI = API `elem` permissions
              }
      newAIRuntime caps cfg >>= either (ioError . userError . show) pure

parseAIConfig :: Value -> Parser (AIConfig, [ExecutionMode])
parseAIConfig = withObject "AI configuration" $ \o -> do
  strictKeys ["version", "permissions", "distillation", "features", "embeddings"] o
  version <- o .: "version"
  unless (version == (1 :: Int)) (fail "unsupported AI configuration version")
  permissions <- o .:? "permissions" .!= [] >>= traverse mode
  defaults <- maybe (pure DistillationDisabled) distillation =<< o .:? "distillation"
  overrides <- o .:? "features" .!= KM.empty >>= featureMap distillation
  embeddings <- o .:? "embeddings" .!= KM.empty >>= featureMap embedding
  pure (AIConfig defaults overrides embeddings, permissions)

featureMap :: (Value -> Parser a) -> Object -> Parser (Map.Map AIFeature a)
featureMap parseValue o = Map.fromList <$> traverse one (KM.toList o)
  where
    one (key, value) = (,) <$> either (const (fail "unknown feature")) pure (parseFeature (Key.toText key)) <*> parseValue value

mode :: Text -> Parser ExecutionMode
mode = \case
  "disabled" -> pure Disabled
  "api" -> pure API
  "batch" -> pure Batch
  "interactive" -> pure Interactive
  _ -> fail "invalid execution mode"

distillation :: Value -> Parser DistillationConfig
distillation = withObject "distillation" $ \o -> do
  selected <- o .: "mode" >>= mode
  case selected of
    Disabled -> strictKeys ["mode"] o >> pure DistillationDisabled
    Interactive -> do
      strictKeys ["mode", "provider", "model", "workingDir", "effort"] o
      provider <-
        o .: "provider" >>= \case
          "claude" -> pure I.InteractiveClaude
          "codex" -> pure I.InteractiveCodex
          (_ :: Text) -> fail "unknown interactive provider"
      model <- o .: "model"
      working <- o .: "workingDir"
      effort <- o .:? "effort"
      let safety = case provider of
            I.InteractiveClaude -> I.ClaudeAllowedTools ["Read", "Write"]
            I.InteractiveCodex -> I.CodexSandbox I.CodexWorkspaceWrite I.CodexApprovalOnRequest
      pure (InteractiveConfig provider ((I.interactiveLaunchRequest "") {I.modelId = Just model, I.workingDir = Just working, I.safety = safety, I.effort = effort}))
    _ -> do
      strictKeys ["mode", "api", "model", "provider", "baseUrl", "options"] o
      api <- o .: "api"
      modelId <- o .: "model"
      baseUrl <- o .: "baseUrl"
      provider <- o .: "provider"
      options <- maybe (pure O.emptyOptions) parseOptions =<< o .:? "options"
      pure (CompletionConfig selected ((M.mkModel api modelId baseUrl) {M.provider = provider}) options)

parseOptions :: Value -> Parser O.Options
parseOptions = withObject "Baikai options" $ \o -> do
  strictKeys ["apiKeyEnv", "maxTokens", "temperature", "timeoutMs", "thinking"] o
  key <- fmap ApiKeyEnv <$> o .:? "apiKeyEnv"
  maxTokens <- o .:? "maxTokens"
  temperature <- o .:? "temperature"
  timeout <- o .:? "timeoutMs"
  thinking <- o .:? "thinking"
  pure O.emptyOptions {O.apiKey = key, O.maxTokens = maxTokens, O.temperature = temperature, O.timeoutMs = timeout, O.thinking = thinking}

embedding :: Value -> Parser E.EmbeddingModel
embedding = withObject "embedding" $ \o -> do
  strictKeys ["mode", "model", "baseUrl", "dimensions", "apiKeyEnv"] o
  selected <- o .: "mode" >>= mode
  unless (selected == API) (fail "embeddings require independently authorized API mode")
  model <- o .: "model"
  baseUrl <- o .: "baseUrl"
  dimensions <- o .: "dimensions"
  key <- fmap ApiKeyEnv <$> o .:? "apiKeyEnv"
  pure E.emptyEmbeddingModel {E.modelId = model, E.baseUrl = baseUrl, E.dimensions = Just dimensions, E.apiKey = key}

strictKeys :: [Text] -> Object -> Parser ()
strictKeys allowed o = unless (all ((`elem` allowed) . Key.toText) (KM.keys o)) (fail "unknown configuration field")
