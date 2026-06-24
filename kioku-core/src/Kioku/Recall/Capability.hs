module Kioku.Recall.Capability
  ( VectorCapability (..),
    detectVectorCapability,
  )
where

import Effectful (Eff, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Kioku.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)

data VectorCapability
  = VectorAvailable
  | VectorExtensionUnavailable
  | VectorColumnsUnavailable ![Text]
  deriving stock (Generic, Eq, Show)

data CapabilityProbe = CapabilityProbe
  { hasVectorExtension :: !Bool,
    hasEmbedding :: !Bool,
    hasEmbeddingModel :: !Bool,
    hasDimensions :: !Bool,
    hasContentHash :: !Bool
  }
  deriving stock (Generic, Eq, Show)

detectVectorCapability ::
  (Store :> es) =>
  Eff es VectorCapability
detectVectorCapability = classifyProbe <$> runTransaction (Tx.statement () detectVectorCapabilityStmt)

classifyProbe :: CapabilityProbe -> VectorCapability
classifyProbe probe
  | not probe.hasVectorExtension = VectorExtensionUnavailable
  | null missing = VectorAvailable
  | otherwise = VectorColumnsUnavailable missing
  where
    missing =
      missingIf (not probe.hasEmbedding) "embedding"
        <> missingIf (not probe.hasEmbeddingModel) "embedding_model"
        <> missingIf (not probe.hasDimensions) "dimensions"
        <> missingIf (not probe.hasContentHash) "content_hash"

missingIf :: Bool -> Text -> [Text]
missingIf True columnName = [columnName]
missingIf False _ = []

detectVectorCapabilityStmt :: Statement () CapabilityProbe
detectVectorCapabilityStmt =
  preparable
    """
    SELECT
      EXISTS (
        SELECT 1
        FROM pg_extension
        WHERE extname = 'vector'
      ) AS has_vector_extension,
      EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'kiroku' AND table_name = 'kioku_memories' AND column_name = 'embedding'
      ) AS has_embedding,
      EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'kiroku' AND table_name = 'kioku_memories' AND column_name = 'embedding_model'
      ) AS has_embedding_model,
      EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'kiroku' AND table_name = 'kioku_memories' AND column_name = 'dimensions'
      ) AS has_dimensions,
      EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'kiroku' AND table_name = 'kioku_memories' AND column_name = 'content_hash'
      ) AS has_content_hash
    """
    E.noParams
    ( D.singleRow $
        CapabilityProbe
          <$> D.column (D.nonNullable D.bool)
          <*> D.column (D.nonNullable D.bool)
          <*> D.column (D.nonNullable D.bool)
          <*> D.column (D.nonNullable D.bool)
          <*> D.column (D.nonNullable D.bool)
    )
