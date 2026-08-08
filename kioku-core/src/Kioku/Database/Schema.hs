-- | Where Kioku's own relations live, spelled once.
--
-- Kioku shares the host application's Kiroku event store but owns its projections, and since
-- migration @0012-relocate-projections-to-kioku-schema.sql@ those projections live in a
-- dedicated @kioku@ PostgreSQL schema rather than beside the event tables in @kiroku@. See
-- @docs\/adr\/projections-live-in-the-kioku-schema.md@.
--
-- Every statement Kioku issues names its relation through one of the constants below instead
-- of relying on @search_path@. That is deliberate. The Kiroku connection puts its own primary
-- schema first and then whatever @extraSearchPath@ entries the host configured, on a pool the
-- host shares — so an unqualified @memories@ would resolve to whichever relation the host's
-- settings happened to reach first. Naming the schema in the SQL makes ownership a property of
-- the query rather than of the connection.
--
-- 'Keiro.Connection.qualifyTable' produces the double-quoted @\"kioku\".\"memories\"@ form, so
-- these values are safe to concatenate into static SQL. They are trusted constants and nothing
-- user-supplied reaches them; every value a caller provides still travels as a parameter.
--
-- This module stays in @other-modules@: the physical layout is Kioku's business, not a public
-- API its consumers should be able to depend on.
module Kioku.Database.Schema
  ( kiokuSchema,
    memoriesTable,
    sessionsTable,
    turnsTable,
    l1WatermarksTable,
    consolidationDecisionsTable,
    scenesTable,
    personasTable,
    memoriesRelation,
    sessionsRelation,
    turnsRelation,
  )
where

import Data.Text (Text)
import Keiro.Connection (qualifyTable)

-- | The PostgreSQL schema every Kioku-owned relation lives in.
--
-- Not to be confused with a Keiro read-model schema identity (a logical name, version, and
-- shape hash) or with a Kioku memory space (a @memory_space_id@ column value). Moving the
-- tables into one schema changes neither; see
-- @docs\/adr\/the-partition-is-a-column-not-a-schema.md@.
kiokuSchema :: Text
kiokuSchema = "kioku"

-- | The unqualified names Keiro's 'Keiro.ReadModel.ReadModel' metadata records, which it keeps
-- separate from the schema. Exported so a read-model declaration and the SQL it runs cannot
-- drift apart: both are built from these.
memoriesRelation, sessionsRelation, turnsRelation :: Text
memoriesRelation = "memories"
sessionsRelation = "sessions"
turnsRelation = "turns"

l1WatermarksRelation, consolidationDecisionsRelation, scenesRelation, personasRelation :: Text
l1WatermarksRelation = "l1_watermarks"
consolidationDecisionsRelation = "consolidation_decisions"
scenesRelation = "scenes"
personasRelation = "personas"

-- | The memory projection: one row per memory, with its full-text vector and its optional
-- embedding.
memoriesTable :: Text
memoriesTable = qualifyTable kiokuSchema memoriesRelation

-- | The session projection, including continuation and awaiting state.
sessionsTable :: Text
sessionsTable = qualifyTable kiokuSchema sessionsRelation

-- | The ordered turns of a session.
turnsTable :: Text
turnsTable = qualifyTable kiokuSchema turnsRelation

-- | L1 distillation's idempotency watermarks.
l1WatermarksTable :: Text
l1WatermarksTable = qualifyTable kiokuSchema l1WatermarksRelation

-- | L2 consolidation's decision audit trail.
consolidationDecisionsTable :: Text
consolidationDecisionsTable = qualifyTable kiokuSchema consolidationDecisionsRelation

-- | L3 scene projections.
scenesTable :: Text
scenesTable = qualifyTable kiokuSchema scenesRelation

-- | L3 persona projections.
personasTable :: Text
personasTable = qualifyTable kiokuSchema personasRelation
