module Kioku.Memory.Embedding
  ( EmbeddingConfig (..),
    EmbedError (..),
    resolveEmbeddingConfig,
    toEmbeddingModel,
    embedWithRetry,
    sha256Hex,
    embeddingModelCompatible,
    embeddingModelsCompatible,
  )
where

import Baikai.Auth (ApiKeySource (..))
import Baikai.Embedding (EmbeddingModel (..), embedOne, emptyEmbeddingModel)
import Contravariant.Extras (contrazip2)
import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Crypto.Hash (Digest, SHA256)
import Crypto.Hash qualified as Hash
import Data.Functor.Contravariant ((>$<))
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Kioku.AI.Config
import Kioku.AI.Runtime (AIRuntime, runtimeEmbeddingModel)
import Kioku.Api.Access (MemorySpaceId, memorySpaceIdText)
import Kioku.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Numeric.Natural (Natural)

data EmbeddingConfig = EmbeddingConfig
  { baseUrl :: !Text,
    model :: !Text,
    dimensions :: !Int,
    apiKey :: !Text
  }
  deriving stock (Generic, Eq)

instance Show EmbeddingConfig where
  show _ = "EmbeddingConfig <redacted; use Baikai embedding settings>"

data EmbedError
  = EmbedTransport !Text
  | EmbedModelMismatch
  | EmbedEmpty
  deriving stock (Generic, Eq, Show)

resolveEmbeddingConfig :: AIRuntime -> AIFeature -> Either AIExecutionError EmbeddingModel
resolveEmbeddingConfig = runtimeEmbeddingModel

toEmbeddingModel :: EmbeddingConfig -> EmbeddingModel
toEmbeddingModel cfg =
  emptyEmbeddingModel
    { modelId = cfg.model,
      baseUrl = cfg.baseUrl,
      dimensions = Just (fromIntegral @Int @Natural cfg.dimensions),
      apiKey = Just (ApiKeyLiteral cfg.apiKey)
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

-- | Refuse mixing model-labelled vectors within an authorized memory space.
-- Call only after the vector capability probe succeeds.
embeddingModelCompatible :: (Store :> es) => MemorySpaceId -> EmbeddingModel -> Eff es Bool
embeddingModelCompatible space = embeddingModelsCompatible (Just space)

embeddingModelsCompatible :: (Store :> es) => Maybe MemorySpaceId -> EmbeddingModel -> Eff es Bool
embeddingModelsCompatible space model =
  runTransaction $
    Tx.statement (space, model.modelId) $
      preparable
        "SELECT NOT EXISTS (SELECT 1 FROM kioku.memories WHERE ($1::text IS NULL OR memory_space_id = $1) AND embedding IS NOT NULL AND (embedding_model IS DISTINCT FROM $2 OR dimensions IS DISTINCT FROM 1536))"
        (contrazip2 (fmap memorySpaceIdText >$< E.param (E.nullable E.text)) (E.param (E.nonNullable E.text)))
        (D.singleRow (D.column (D.nonNullable D.bool)))
