-- codd: in-txn

-- Migration: kioku-schema-hardening
-- Created: 2026-07-11-17-35-11 UTC
--
-- Four defects in the read-model schema, fixed together because they are all
-- constraint/index DDL on the same five scope-carrying tables:
--
--   1. The recursive supersession CTE (selectSupersessionChainStmt) joins on
--      `supersedes` and `superseded_by`, neither of which had an index, so every
--      recursion level was a sequential scan.
--   2. The session list/range/focus queries sort whole namespaces with no
--      supporting index.
--   3. The UNIQUE constraints on kioku_scenes and kioku_personas enforce nothing
--      for global-scope rows, because SQL treats NULLs as distinct: two global
--      personas for one namespace both satisfy UNIQUE (namespace, scope_kind,
--      scope_ref). PostgreSQL 15+ NULLS NOT DISTINCT closes that hole.
--   4. Nothing prevented a half-populated scope (scope_kind set, scope_ref NULL).
--      Such a row reads back as global (see Kioku.Api.Scope.scopeFromColumns) yet
--      matches no exact-scope query.
--
-- Everything below is idempotent: the repairs match nothing on a second pass, the
-- constraints are dropped before being added, and the indexes use IF NOT EXISTS.
SET search_path TO kiroku, pg_catalog;

-- Repair 1: normalise half-populated scope pairs to fully NULL, so the CHECK below
-- can be added to a non-empty database. This is not a behaviour change: such rows
-- already read back as global scopes.
UPDATE kioku_memories SET scope_kind = NULL, scope_ref = NULL
 WHERE (scope_kind IS NULL) <> (scope_ref IS NULL);
UPDATE kioku_sessions SET scope_kind = NULL, scope_ref = NULL
 WHERE (scope_kind IS NULL) <> (scope_ref IS NULL);
UPDATE kioku_scenes SET scope_kind = NULL, scope_ref = NULL
 WHERE (scope_kind IS NULL) <> (scope_ref IS NULL);
UPDATE kioku_personas SET scope_kind = NULL, scope_ref = NULL
 WHERE (scope_kind IS NULL) <> (scope_ref IS NULL);
UPDATE kioku_consolidation_decisions SET scope_kind = NULL, scope_ref = NULL
 WHERE (scope_kind IS NULL) <> (scope_ref IS NULL);

-- Repair 2: drop duplicate global-scope scenes/personas, keeping the newest row per
-- logical scope, so the NULLS NOT DISTINCT constraints below can be added. Only
-- NULL-scoped duplicates can exist -- the old constraints already blocked the rest.
DELETE FROM kioku_scenes doomed
 USING kioku_scenes keeper
 WHERE doomed.namespace = keeper.namespace
   AND doomed.scope_kind IS NOT DISTINCT FROM keeper.scope_kind
   AND doomed.scope_ref  IS NOT DISTINCT FROM keeper.scope_ref
   AND doomed.scene_key = keeper.scene_key
   AND (doomed.updated_at, doomed.scene_id) < (keeper.updated_at, keeper.scene_id);

DELETE FROM kioku_personas doomed
 USING kioku_personas keeper
 WHERE doomed.namespace = keeper.namespace
   AND doomed.scope_kind IS NOT DISTINCT FROM keeper.scope_kind
   AND doomed.scope_ref  IS NOT DISTINCT FROM keeper.scope_ref
   AND (doomed.updated_at, doomed.persona_id) < (keeper.updated_at, keeper.persona_id);

-- Scope uniqueness that also holds for global scopes. The upserts target the primary
-- keys (ON CONFLICT (scene_id) / (persona_id)), so replacing these constraints does
-- not disturb them.
ALTER TABLE kioku_scenes
  DROP CONSTRAINT IF EXISTS kioku_scenes_namespace_scope_kind_scope_ref_scene_key_key;
ALTER TABLE kioku_scenes
  DROP CONSTRAINT IF EXISTS kioku_scenes_scope_scene_key_unique;
ALTER TABLE kioku_scenes
  ADD CONSTRAINT kioku_scenes_scope_scene_key_unique
  UNIQUE NULLS NOT DISTINCT (namespace, scope_kind, scope_ref, scene_key);

ALTER TABLE kioku_personas
  DROP CONSTRAINT IF EXISTS kioku_personas_namespace_scope_kind_scope_ref_key;
ALTER TABLE kioku_personas
  DROP CONSTRAINT IF EXISTS kioku_personas_scope_unique;
ALTER TABLE kioku_personas
  ADD CONSTRAINT kioku_personas_scope_unique
  UNIQUE NULLS NOT DISTINCT (namespace, scope_kind, scope_ref);

-- A scope is either global (both columns NULL) or an entity scope (both set).
ALTER TABLE kioku_memories DROP CONSTRAINT IF EXISTS kioku_memories_scope_pair_check;
ALTER TABLE kioku_memories ADD CONSTRAINT kioku_memories_scope_pair_check
  CHECK ((scope_kind IS NULL) = (scope_ref IS NULL));

ALTER TABLE kioku_sessions DROP CONSTRAINT IF EXISTS kioku_sessions_scope_pair_check;
ALTER TABLE kioku_sessions ADD CONSTRAINT kioku_sessions_scope_pair_check
  CHECK ((scope_kind IS NULL) = (scope_ref IS NULL));

ALTER TABLE kioku_scenes DROP CONSTRAINT IF EXISTS kioku_scenes_scope_pair_check;
ALTER TABLE kioku_scenes ADD CONSTRAINT kioku_scenes_scope_pair_check
  CHECK ((scope_kind IS NULL) = (scope_ref IS NULL));

ALTER TABLE kioku_personas DROP CONSTRAINT IF EXISTS kioku_personas_scope_pair_check;
ALTER TABLE kioku_personas ADD CONSTRAINT kioku_personas_scope_pair_check
  CHECK ((scope_kind IS NULL) = (scope_ref IS NULL));

ALTER TABLE kioku_consolidation_decisions
  DROP CONSTRAINT IF EXISTS kioku_consolidation_decisions_scope_pair_check;
ALTER TABLE kioku_consolidation_decisions
  ADD CONSTRAINT kioku_consolidation_decisions_scope_pair_check
  CHECK ((scope_kind IS NULL) = (scope_ref IS NULL));

-- Indexes for the recursive supersession chain: its join arms are
-- `m.supersedes = c.memory_id OR m.superseded_by = c.memory_id`, and only the other
-- two arms hit the primary key.
CREATE INDEX IF NOT EXISTS kioku_memories_supersedes_idx
  ON kioku_memories (supersedes) WHERE supersedes IS NOT NULL;
CREATE INDEX IF NOT EXISTS kioku_memories_superseded_by_idx
  ON kioku_memories (superseded_by) WHERE superseded_by IS NOT NULL;

-- Indexes for the session list queries, which order by started_at within a namespace
-- (and, for the focus query, within a focus).
CREATE INDEX IF NOT EXISTS kioku_sessions_namespace_started_idx
  ON kioku_sessions (namespace, started_at DESC);
CREATE INDEX IF NOT EXISTS kioku_sessions_namespace_focus_idx
  ON kioku_sessions (namespace, focus, started_at DESC);

-- Pure write amplification: duplicates the index implied by
-- UNIQUE (session_id, turn_index) on the same table.
DROP INDEX IF EXISTS kioku_turns_session_idx;
