module Kioku.Recall.Capability
  ( VectorCapability (..),
    detectVectorCapability,
    classifyProbe,
    CapabilityProbe (..),
  )
where

import Data.Int (Int32)
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
  | -- | @KIOKU_EMBEDDING_DIMENSIONS@ disagrees with the declared width of the
    -- @kioku_memories.embedding@ column: configured first, actual second. Every embedding
    -- write would fail on the @::vector@ cast, one event at a time, forever.
    VectorDimensionMismatch !Int !Int
  deriving stock (Generic, Eq, Show)

data CapabilityProbe = CapabilityProbe
  { hasVectorType :: !Bool,
    hasEmbedding :: !Bool,
    hasEmbeddingModel :: !Bool,
    hasDimensions :: !Bool,
    hasContentHash :: !Bool,
    embeddingTypmod :: !(Maybe Int32)
  }
  deriving stock (Generic, Eq, Show)

-- | Probe what the vector path can actually do, given the dimension count the process is
-- configured with (@EmbeddingConfig.dimensions@).
detectVectorCapability ::
  (Store :> es) =>
  Int ->
  Eff es VectorCapability
detectVectorCapability configuredDimensions =
  classifyProbe configuredDimensions <$> runTransaction (Tx.statement () detectVectorCapabilityStmt)

classifyProbe :: Int -> CapabilityProbe -> VectorCapability
classifyProbe configuredDimensions probe
  | not probe.hasVectorType = VectorExtensionUnavailable
  | not (null missing) = VectorColumnsUnavailable missing
  | Just actual <- declaredDimensions,
    actual /= configuredDimensions =
      VectorDimensionMismatch configuredDimensions actual
  | otherwise = VectorAvailable
  where
    missing =
      missingIf (not probe.hasEmbedding) "embedding"
        <> missingIf (not probe.hasEmbeddingModel) "embedding_model"
        <> missingIf (not probe.hasDimensions) "dimensions"
        <> missingIf (not probe.hasContentHash) "content_hash"

    -- For pgvector, a column's atttypmod *is* its declared dimension count. A column
    -- declared without one reports -1, which constrains nothing, so there is nothing to
    -- disagree with.
    declaredDimensions =
      case probe.embeddingTypmod of
        Just typmod | typmod > 0 -> Just (fromIntegral typmod)
        _ -> Nothing

missingIf :: Bool -> Text -> [Text]
missingIf True columnName = [columnName]
missingIf False _ = []

-- | The extension check asks @to_regtype@, not @pg_extension@, and the difference matters.
-- @pg_extension@ answers "is pgvector installed /somewhere/ in this database" — but recall
-- casts with a bare @$1::vector@, and the store connects with
-- @search_path = kiroku, pg_catalog@. An extension installed into @public@ (the usual
-- operator default) satisfies @pg_extension@ and still cannot be named, so every vector
-- query would fail with @42704@ while capability detection reported everything healthy.
-- @to_regtype@ resolves against the live @search_path@, which is exactly the question the
-- query asks.
detectVectorCapabilityStmt :: Statement () CapabilityProbe
detectVectorCapabilityStmt =
  preparable
    """
    SELECT
      to_regtype('vector') IS NOT NULL AS has_vector_type,
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
      ) AS has_content_hash,
      (
        SELECT a.atttypmod
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'kiroku'
          AND c.relname = 'kioku_memories'
          AND a.attname = 'embedding'
          AND NOT a.attisdropped
      ) AS embedding_typmod
    """
    E.noParams
    ( D.singleRow $
        CapabilityProbe
          <$> D.column (D.nonNullable D.bool)
          <*> D.column (D.nonNullable D.bool)
          <*> D.column (D.nonNullable D.bool)
          <*> D.column (D.nonNullable D.bool)
          <*> D.column (D.nonNullable D.bool)
          <*> D.column (D.nullable D.int4)
    )
