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
-- 'reconcileReadModelRegistry' repairs those rows to the identity the compiled
-- code expects, deriving every name, version, and shape hash from
-- 'kiokuReadModelSchemas' — the same 'ReadModel' values the queries use, so the
-- registry can never disagree with the code. The @kioku-migrate@ executable runs
-- it immediately after applying migrations, which is why a read-model version
-- bump needs no hand-written registry SQL. A host that applies migrations as a
-- library (by running @Kioku.Migrations.kiokuMigrationPlan@ through pg-migrate)
-- must call it itself; see @docs\/user\/library-api.md@.
--
-- Because Kioku guarantees its read-model migrations leave the table data correct
-- for the current version, advancing the registry guard is safe here without a
-- rebuild. A consumer that introduces a /non-additive/ reshape must instead
-- rewrite the projected data in its migration before reconciling.
module Kioku.ReadModel
  ( ReadModelSchema (..),
    kiokuReadModelSchemas,
    ReconcileOutcome (..),
    reconcileReadModelRegistry,
  )
where

import Effectful (Eff, (:>))
import Keiro.ReadModel (ReadModel (..))
import Keiro.ReadModel.Schema qualified as Schema
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
import Kiroku.Store.Effect (Store)

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

-- | What reconciliation did to one read model's registry row.
data ReconcileOutcome
  = -- | No row existed; one was inserted at the current identity.
    Registered
  | -- | The row disagreed with the code and was bumped to the current identity.
    Reconciled
  | -- | The row already matched the code. Left untouched, status and all.
    AlreadyCurrent
  deriving stock (Eq, Show)

-- | Bring every row of keiro's @keiro_read_models@ registry up to the schema
-- identity the compiled code expects, and report what changed.
--
-- Idempotent: a second run reports 'AlreadyCurrent' for every model and writes
-- nothing. It is built on keiro's own registry statements, which are compiled
-- into whichever keiro version Kioku links against — so it finds the registry
-- table wherever that version puts it, and survives keiro's schema relocation
-- without change.
reconcileReadModelRegistry ::
  (Store :> es) => Eff es [(ReadModelSchema, ReconcileOutcome)]
reconcileReadModelRegistry =
  forM kiokuReadModelSchemas \schema -> do
    existing <- Schema.lookupReadModel schema.readModelName
    outcome <- case existing of
      Nothing ->
        Registered
          <$ Schema.registerReadModel
            schema.readModelName
            schema.readModelVersion
            schema.readModelShapeHash
      Just metadata
        | metadata.version == schema.readModelVersion
            && metadata.shapeHash == schema.readModelShapeHash ->
            pure AlreadyCurrent
        | otherwise ->
            Reconciled
              <$ Schema.markLive
                schema.readModelName
                schema.readModelVersion
                schema.readModelShapeHash
    pure (schema, outcome)
