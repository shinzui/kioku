module Kioku.Memory.Embedding
  ( EmbeddingConfig (..),
    EmbedError (..),
    resolveEmbeddingConfig,
    toEmbeddingModel,
    embedWithRetry,
    sha256Hex,
  )
where

import Baikai.Auth (ApiKeySource (..))
import Baikai.Embedding (EmbeddingModel (..), embedOne)
import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Crypto.Hash (Digest, SHA256)
import Crypto.Hash qualified as Hash
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Kioku.Prelude
import Numeric.Natural (Natural)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

data EmbeddingConfig = EmbeddingConfig
  { baseUrl :: !Text,
    model :: !Text,
    dimensions :: !Int,
    apiKey :: !Text
  }
  deriving stock (Generic, Eq, Show)

data EmbedError
  = EmbedTransport !Text
  | EmbedEmpty
  deriving stock (Generic, Eq, Show)

resolveEmbeddingConfig :: IO EmbeddingConfig
resolveEmbeddingConfig = do
  baseUrl <- envText "KIOKU_EMBEDDING_BASE_URL" "https://api.openai.com"
  model <- envText "KIOKU_EMBEDDING_MODEL" "text-embedding-3-small"
  dimensions <- envInt "KIOKU_EMBEDDING_DIMENSIONS" 1536
  apiKey <- envTextFallback ["KIOKU_EMBEDDING_API_KEY", "OPENAI_API_KEY"] ""
  pure EmbeddingConfig {baseUrl, model, dimensions, apiKey}

toEmbeddingModel :: EmbeddingConfig -> EmbeddingModel
toEmbeddingModel cfg =
  EmbeddingModel
    { modelId = cfg.model,
      baseUrl = cfg.baseUrl,
      dimensions = Just (fromIntegral @Int @Natural cfg.dimensions),
      apiKey = ApiKeyLiteral cfg.apiKey
    }

embedWithRetry :: EmbeddingModel -> Int -> Text -> IO (Either EmbedError (Vector Double))
embedWithRetry model maxAttempts input = go 1
  where
    attempts = max 1 maxAttempts

    go attempt = do
      result <- try (embedOne model input)
      case result of
        Right vec
          | Vector.null vec -> pure (Left EmbedEmpty)
          | otherwise -> pure (Right vec)
        Left (err :: SomeException)
          | attempt >= attempts -> pure (Left (EmbedTransport (Text.pack (show err))))
          | otherwise -> do
              threadDelay (attemptDelayMicros attempt)
              go (attempt + 1)

sha256Hex :: Text -> Text
sha256Hex content =
  Text.pack (show (Hash.hash (TE.encodeUtf8 content) :: Digest SHA256))

attemptDelayMicros :: Int -> Int
attemptDelayMicros attempt = 200000 * (2 ^ max 0 (attempt - 1))

envText :: String -> Text -> IO Text
envText name fallback =
  maybe fallback Text.pack <$> lookupEnv name

envInt :: String -> Int -> IO Int
envInt name fallback = do
  found <- lookupEnv name
  pure $ fromMaybe fallback (found >>= readMaybe)

envTextFallback :: [String] -> Text -> IO Text
envTextFallback [] fallback = pure fallback
envTextFallback (name : rest) fallback = do
  found <- lookupEnv name
  case found of
    Just value -> pure (Text.pack value)
    Nothing -> envTextFallback rest fallback
