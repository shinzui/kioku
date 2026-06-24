module Kioku.Memory.Embedding.Worker
  ( backfillMissingEmbeddings,
  )
where

import Baikai.Embedding (EmbeddingModel (..))
import Control.Monad (foldM)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int32)
import Data.Text qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Kioku.Memory.Embedding (embedWithRetry, sha256Hex)
import Kioku.Prelude
import Kioku.Recall.Capability (VectorCapability (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)

data EmbeddingCandidate = EmbeddingCandidate
  { memoryId :: !Text,
    content :: !Text,
    contentHash :: !(Maybe Text),
    hasEmbedding :: !Bool
  }
  deriving stock (Generic, Eq, Show)

data EmbeddingUpdate = EmbeddingUpdate
  { memoryId :: !Text,
    embedding :: !(Vector Double),
    embeddingModel :: !Text,
    dimensions :: !Int,
    contentHash :: !Text
  }
  deriving stock (Generic, Eq, Show)

backfillMissingEmbeddings ::
  (IOE :> es, Store :> es) =>
  VectorCapability ->
  EmbeddingModel ->
  Int ->
  Eff es Int
backfillMissingEmbeddings VectorAvailable model dims = do
  candidates <- runTransaction (Tx.statement () selectEmbeddingCandidatesStmt)
  foldM embedCandidate 0 candidates
  where
    modelId = model.modelId

    embedCandidate count candidate
      | candidate.hasEmbedding && candidate.contentHash == Just contentHash =
          pure count
      | otherwise = do
          result <- liftIO (embedWithRetry model 3 candidate.content)
          case result of
            Left _err -> pure count
            Right embedding -> do
              runTransaction $
                Tx.statement
                  EmbeddingUpdate
                    { memoryId = candidate.memoryId,
                      embedding,
                      embeddingModel = modelId,
                      dimensions = dims,
                      contentHash
                    }
                  upsertEmbeddingStmt
              pure (count + 1)
      where
        contentHash = sha256Hex candidate.content
backfillMissingEmbeddings _ _ _ = pure 0

selectEmbeddingCandidatesStmt :: Statement () [EmbeddingCandidate]
selectEmbeddingCandidatesStmt =
  preparable
    """
    SELECT memory_id, content, content_hash, embedding IS NOT NULL AS has_embedding
    FROM kioku_memories
    WHERE status = 'active'
    ORDER BY created_at ASC
    """
    E.noParams
    (D.rowList embeddingCandidateDecoder)

embeddingCandidateDecoder :: D.Row EmbeddingCandidate
embeddingCandidateDecoder =
  EmbeddingCandidate
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.bool)

upsertEmbeddingStmt :: Statement EmbeddingUpdate ()
upsertEmbeddingStmt =
  preparable
    """
    UPDATE kioku_memories
    SET embedding = $2::vector,
        embedding_model = $3,
        dimensions = $4,
        content_hash = $5
    WHERE memory_id = $1
    """
    embeddingUpdateEncoder
    D.noResult

embeddingUpdateEncoder :: E.Params EmbeddingUpdate
embeddingUpdateEncoder =
  ((\update -> update.memoryId) >$< E.param (E.nonNullable E.text))
    <> ((\update -> vectorLiteral update.embedding) >$< E.param (E.nonNullable E.text))
    <> ((\update -> update.embeddingModel) >$< E.param (E.nonNullable E.text))
    <> ((\update -> fromIntegral @Int @Int32 update.dimensions) >$< E.param (E.nonNullable E.int4))
    <> ((\update -> update.contentHash) >$< E.param (E.nonNullable E.text))

vectorLiteral :: Vector Double -> Text
vectorLiteral values =
  "[" <> Text.intercalate "," (Text.pack . show <$> Vector.toList values) <> "]"
