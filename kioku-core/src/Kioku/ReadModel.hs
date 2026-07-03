-- | The schema identities of every Kioku read model registered in the
-- @keiro_read_models@ registry.
--
-- Kioku evolves its projections with /additive/ migrations: new columns are
-- added and backfill with sensible defaults, so existing rows remain correct
-- for the newer read-model version without a full offline rebuild. When such a
-- migration ships, the code-declared 'Keiro.ReadModel.version' /
-- 'Keiro.ReadModel.shapeHash' advance, but any pre-existing
-- @keiro_read_models@ row stays pinned at the old identity —
-- 'Keiro.ReadModel.registerReadModel' only inserts, it never bumps an existing
-- row. Every subsequent query then fails closed with
-- 'Keiro.ReadModel.ReadModelStaleSchema'.
--
-- 'kiokuReadModelSchemas' lets a migration runner reconcile those stale rows to
-- the current identity. Because Kioku guarantees its read-model migrations leave
-- the table data correct for the current version, advancing the registry guard
-- is safe here without a rebuild. A consumer that introduces a /non-additive/
-- reshape must instead rewrite the projected data in its migration before
-- reconciling.
module Kioku.ReadModel
  ( ReadModelSchema (..),
    kiokuReadModelSchemas,
  )
where

import Keiro.ReadModel (ReadModel (..))
import Kioku.Memory.ReadModel
  ( memoriesByNamespaceReadModel,
    memoriesByNamespaceRowsReadModel,
    memoriesByScopeReadModel,
    memoriesByScopeRowsReadModel,
    memoriesBySessionReadModel,
    memoriesBySessionRowsReadModel,
    memoriesByTypeReadModel,
    memoriesByTypeRowsReadModel,
    memoryByIdReadModel,
    memorySupersessionChainReadModel,
  )
import Kioku.Prelude
import Kioku.Session.ReadModel
  ( awaitingSessionsByCorrelationKeyReadModel,
    sessionByIdReadModel,
    sessionChainReadModel,
    sessionDelegationChildrenReadModel,
    sessionsByFocusReadModel,
    sessionsByNamespaceReadModel,
    sessionsByScopeReadModel,
    sessionsByStartedRangeReadModel,
    turnsBySessionReadModel,
  )

-- | The registry identity of a read model: its logical name plus the schema
-- 'version' and 'shapeHash' the current code expects.
data ReadModelSchema = ReadModelSchema
  { readModelName :: !Text,
    readModelVersion :: !Int,
    readModelShapeHash :: !Text
  }
  deriving stock (Eq, Show)

schemaOf :: ReadModel q r -> ReadModelSchema
schemaOf rm = ReadModelSchema rm.name rm.version rm.shapeHash

-- | Every Kioku read model paired with the schema identity the current code
-- expects. Ordered session models first, then memory models.
kiokuReadModelSchemas :: [ReadModelSchema]
kiokuReadModelSchemas =
  [ schemaOf sessionByIdReadModel,
    schemaOf sessionsByNamespaceReadModel,
    schemaOf sessionsByScopeReadModel,
    schemaOf sessionsByFocusReadModel,
    schemaOf sessionsByStartedRangeReadModel,
    schemaOf sessionChainReadModel,
    schemaOf sessionDelegationChildrenReadModel,
    schemaOf awaitingSessionsByCorrelationKeyReadModel,
    schemaOf turnsBySessionReadModel,
    schemaOf memoryByIdReadModel,
    schemaOf memoriesByNamespaceReadModel,
    schemaOf memoriesByNamespaceRowsReadModel,
    schemaOf memoriesByScopeReadModel,
    schemaOf memoriesByScopeRowsReadModel,
    schemaOf memoriesBySessionReadModel,
    schemaOf memoriesBySessionRowsReadModel,
    schemaOf memoriesByTypeReadModel,
    schemaOf memoriesByTypeRowsReadModel,
    schemaOf memorySupersessionChainReadModel
  ]
