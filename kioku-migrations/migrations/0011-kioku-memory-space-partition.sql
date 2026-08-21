-- Migration: kioku-memory-space-partition
-- Created: 2026-08-06-15-10-00 UTC
--
-- Every kioku read-model row becomes attributable to exactly one memory space.
--
-- A memory space is the outer isolation boundary: two tenants who must never see each
-- other's data are separated by memory space, whereas two hosts sharing a database are
-- merely separated by namespace. Until this migration the read models had no such column,
-- so a query could only ever see every space at once. See
-- docs/adr/namespace-is-not-a-security-boundary.md.
--
-- The column is added in the only safe order: nullable, deterministic backfill, validation,
-- then NOT NULL, then the constraints and indexes that put the partition first. A row whose
-- space were NULL would have to be interpreted by every query, and the only two available
-- interpretations -- "invisible" and "visible everywhere" -- are both wrong. Absence of a
-- partition must never read as unrestricted access, so every pre-existing row is backfilled
-- into the single explicit space `kioku_legacy`. See
-- docs/adr/legacy-data-lands-in-one-explicit-space.md.
--
-- Turns and L1 watermarks derive their space from their parent session rather than being
-- assumed legacy, because that derivation is the rule that must hold forever; the fallback
-- for a turn whose session row is missing is the legacy space, and the validation block
-- below fails the whole migration if any turn or watermark ends up disagreeing with a
-- session that does exist.
--
-- Every statement is idempotent: the columns and indexes use IF NOT EXISTS, the constraints
-- are dropped before being re-added, and the backfill matches only rows that are still NULL.
SET search_path TO kiroku, pg_catalog;

-- Step 1: the column, nullable, on every table that holds partitioned data.

ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS memory_space_id text;
ALTER TABLE kioku_sessions ADD COLUMN IF NOT EXISTS memory_space_id text;
ALTER TABLE kioku_turns ADD COLUMN IF NOT EXISTS memory_space_id text;
ALTER TABLE kioku_l1_watermarks ADD COLUMN IF NOT EXISTS memory_space_id text;
ALTER TABLE kioku_consolidation_decisions ADD COLUMN IF NOT EXISTS memory_space_id text;
ALTER TABLE kioku_scenes ADD COLUMN IF NOT EXISTS memory_space_id text;
ALTER TABLE kioku_personas ADD COLUMN IF NOT EXISTS memory_space_id text;

-- Step 2: the deterministic backfill.
--
-- Roots first. Every row that exists at this point predates memory spaces, so it belongs to
-- the legacy space by definition -- there is no other space it could have been written in.

UPDATE kioku_memories SET memory_space_id = 'kioku_legacy' WHERE memory_space_id IS NULL;
UPDATE kioku_sessions SET memory_space_id = 'kioku_legacy' WHERE memory_space_id IS NULL;
UPDATE kioku_consolidation_decisions SET memory_space_id = 'kioku_legacy' WHERE memory_space_id IS NULL;
UPDATE kioku_scenes SET memory_space_id = 'kioku_legacy' WHERE memory_space_id IS NULL;
UPDATE kioku_personas SET memory_space_id = 'kioku_legacy' WHERE memory_space_id IS NULL;

-- Derived rows inherit from the session they belong to. `kioku_turns.session_id` has no
-- foreign key, so an orphan turn is possible in principle; it falls back to the legacy
-- space, which is where its session would have been had it survived.

UPDATE kioku_turns t
   SET memory_space_id =
         COALESCE(
           (SELECT s.memory_space_id FROM kioku_sessions s WHERE s.session_id = t.session_id),
           'kioku_legacy')
 WHERE t.memory_space_id IS NULL;

UPDATE kioku_l1_watermarks w
   SET memory_space_id =
         COALESCE(
           (SELECT s.memory_space_id FROM kioku_sessions s WHERE s.session_id = w.session_id),
           'kioku_legacy')
 WHERE w.memory_space_id IS NULL;

-- Step 3: validation, before anything irreversible.
--
-- Abort rather than write a partition nobody can trust. The first check is the one that
-- matters on a fresh upgrade (nothing may be left unattributed); the second and third are
-- the derivation rule, which is vacuous today but is the invariant every later write must
-- preserve, and stating it here is what makes a future violation loud.
DO $$
DECLARE
  unattributed bigint;
  drifted bigint;
BEGIN
  SELECT (SELECT count(*) FROM kioku_memories WHERE memory_space_id IS NULL)
       + (SELECT count(*) FROM kioku_sessions WHERE memory_space_id IS NULL)
       + (SELECT count(*) FROM kioku_turns WHERE memory_space_id IS NULL)
       + (SELECT count(*) FROM kioku_l1_watermarks WHERE memory_space_id IS NULL)
       + (SELECT count(*) FROM kioku_consolidation_decisions WHERE memory_space_id IS NULL)
       + (SELECT count(*) FROM kioku_scenes WHERE memory_space_id IS NULL)
       + (SELECT count(*) FROM kioku_personas WHERE memory_space_id IS NULL)
    INTO unattributed;

  IF unattributed > 0 THEN
    RAISE EXCEPTION
      'kioku memory-space backfill left % row(s) with no memory space; refusing to continue',
      unattributed;
  END IF;

  SELECT (SELECT count(*)
            FROM kioku_turns t
            JOIN kioku_sessions s ON s.session_id = t.session_id
           WHERE t.memory_space_id IS DISTINCT FROM s.memory_space_id)
       + (SELECT count(*)
            FROM kioku_l1_watermarks w
            JOIN kioku_sessions s ON s.session_id = w.session_id
           WHERE w.memory_space_id IS DISTINCT FROM s.memory_space_id)
    INTO drifted;

  IF drifted > 0 THEN
    RAISE EXCEPTION
      'kioku memory-space backfill left % derived row(s) in a different space from their session',
      drifted;
  END IF;
END $$;

-- Step 4: make the column mandatory. An empty string is rejected too: it is not a space,
-- and allowing it would give "no space" a second spelling.

ALTER TABLE kioku_memories ALTER COLUMN memory_space_id SET NOT NULL;
ALTER TABLE kioku_sessions ALTER COLUMN memory_space_id SET NOT NULL;
ALTER TABLE kioku_turns ALTER COLUMN memory_space_id SET NOT NULL;
ALTER TABLE kioku_l1_watermarks ALTER COLUMN memory_space_id SET NOT NULL;
ALTER TABLE kioku_consolidation_decisions ALTER COLUMN memory_space_id SET NOT NULL;
ALTER TABLE kioku_scenes ALTER COLUMN memory_space_id SET NOT NULL;
ALTER TABLE kioku_personas ALTER COLUMN memory_space_id SET NOT NULL;

ALTER TABLE kioku_memories DROP CONSTRAINT IF EXISTS kioku_memories_space_present_check;
ALTER TABLE kioku_memories ADD CONSTRAINT kioku_memories_space_present_check
  CHECK (memory_space_id <> '');
ALTER TABLE kioku_sessions DROP CONSTRAINT IF EXISTS kioku_sessions_space_present_check;
ALTER TABLE kioku_sessions ADD CONSTRAINT kioku_sessions_space_present_check
  CHECK (memory_space_id <> '');
ALTER TABLE kioku_turns DROP CONSTRAINT IF EXISTS kioku_turns_space_present_check;
ALTER TABLE kioku_turns ADD CONSTRAINT kioku_turns_space_present_check
  CHECK (memory_space_id <> '');
ALTER TABLE kioku_l1_watermarks DROP CONSTRAINT IF EXISTS kioku_l1_watermarks_space_present_check;
ALTER TABLE kioku_l1_watermarks ADD CONSTRAINT kioku_l1_watermarks_space_present_check
  CHECK (memory_space_id <> '');
ALTER TABLE kioku_consolidation_decisions DROP CONSTRAINT IF EXISTS kioku_consolidation_decisions_space_present_check;
ALTER TABLE kioku_consolidation_decisions ADD CONSTRAINT kioku_consolidation_decisions_space_present_check
  CHECK (memory_space_id <> '');
ALTER TABLE kioku_scenes DROP CONSTRAINT IF EXISTS kioku_scenes_space_present_check;
ALTER TABLE kioku_scenes ADD CONSTRAINT kioku_scenes_space_present_check
  CHECK (memory_space_id <> '');
ALTER TABLE kioku_personas DROP CONSTRAINT IF EXISTS kioku_personas_space_present_check;
ALTER TABLE kioku_personas ADD CONSTRAINT kioku_personas_space_present_check
  CHECK (memory_space_id <> '');

-- Step 5: identities that were derived from a scope must now be derived from a space and a
-- scope together.
--
-- Scene and persona primary keys are computed from the namespace and scope alone
-- (Kioku.Distill.ScopeIdentity). Two memory spaces are allowed to use identical namespaces
-- and scopes -- that is the whole point of the partition -- so those ids collide across
-- spaces, and with a single-column primary key one space's scene would silently overwrite
-- another's through the upsert's ON CONFLICT clause.
--
-- The fix is a composite primary key rather than a new id derivation. Re-deriving the ids
-- would rewrite every scene and persona row and every plaintext mirror filename for a
-- cosmetic gain; the composite key makes the collision impossible while leaving already
-- persisted ids exactly as they are.

ALTER TABLE kioku_scenes DROP CONSTRAINT IF EXISTS kioku_scenes_pkey;
ALTER TABLE kioku_scenes ADD CONSTRAINT kioku_scenes_pkey
  PRIMARY KEY (memory_space_id, scene_id);

ALTER TABLE kioku_personas DROP CONSTRAINT IF EXISTS kioku_personas_pkey;
ALTER TABLE kioku_personas ADD CONSTRAINT kioku_personas_pkey
  PRIMARY KEY (memory_space_id, persona_id);

-- Scope uniqueness is now per space. NULLS NOT DISTINCT is preserved from the
-- schema-hardening migration: without it two global-scope rows in one space would both
-- satisfy the constraint, because SQL considers NULLs distinct.

ALTER TABLE kioku_scenes DROP CONSTRAINT IF EXISTS kioku_scenes_scope_scene_key_unique;
ALTER TABLE kioku_scenes ADD CONSTRAINT kioku_scenes_scope_scene_key_unique
  UNIQUE NULLS NOT DISTINCT (memory_space_id, namespace, scope_kind, scope_ref, scene_key);

ALTER TABLE kioku_personas DROP CONSTRAINT IF EXISTS kioku_personas_scope_unique;
ALTER TABLE kioku_personas ADD CONSTRAINT kioku_personas_scope_unique
  UNIQUE NULLS NOT DISTINCT (memory_space_id, namespace, scope_kind, scope_ref);

-- Step 6: lookup indexes, partition first.
--
-- Every index whose leading columns were a namespace or a scope is rebuilt with the memory
-- space in front of them, because every such query now carries a space predicate and the
-- space is the most selective column available. Indexes led by a globally unique id
-- (memory_id, session_id, parent_session_id, supersedes, superseded_by, content_hash) are
-- deliberately left alone: an id is already selective enough that prefixing it with the
-- space would buy nothing and cost a write on every insert. The space predicate is still in
-- those statements -- it is a filter there, not an access path.

DROP INDEX IF EXISTS kioku_memories_scope_idx;
CREATE INDEX IF NOT EXISTS kioku_memories_space_scope_idx
  ON kioku_memories (memory_space_id, namespace, scope_kind, scope_ref) WHERE status = 'active';

-- The old type index covered `memory_type` alone, while the query it exists for filters on
-- namespace and type together. Rebuilding it partition-first also fixes that.
DROP INDEX IF EXISTS kioku_memories_type_idx;
CREATE INDEX IF NOT EXISTS kioku_memories_space_type_idx
  ON kioku_memories (memory_space_id, namespace, memory_type) WHERE status = 'active';

CREATE INDEX IF NOT EXISTS kioku_memories_space_namespace_idx
  ON kioku_memories (memory_space_id, namespace, priority, created_at DESC) WHERE status = 'active';

DROP INDEX IF EXISTS kioku_sessions_scope_idx;
CREATE INDEX IF NOT EXISTS kioku_sessions_space_scope_idx
  ON kioku_sessions (memory_space_id, namespace, scope_kind, scope_ref);

DROP INDEX IF EXISTS kioku_sessions_namespace_started_idx;
CREATE INDEX IF NOT EXISTS kioku_sessions_space_namespace_started_idx
  ON kioku_sessions (memory_space_id, namespace, started_at DESC);

DROP INDEX IF EXISTS kioku_sessions_namespace_focus_idx;
CREATE INDEX IF NOT EXISTS kioku_sessions_space_namespace_focus_idx
  ON kioku_sessions (memory_space_id, namespace, focus, started_at DESC);

DROP INDEX IF EXISTS kioku_sessions_awaiting_corr_idx;
CREATE INDEX IF NOT EXISTS kioku_sessions_space_awaiting_corr_idx
  ON kioku_sessions (memory_space_id, namespace, awaiting_correlation_key)
  WHERE status = 'awaiting';

DROP INDEX IF EXISTS kioku_consolidation_scope_idx;
CREATE INDEX IF NOT EXISTS kioku_consolidation_space_scope_idx
  ON kioku_consolidation_decisions (memory_space_id, namespace, scope_kind, scope_ref);

-- The scene scope index is now a strict prefix of the unique constraint's index, exactly as
-- kioku_turns_session_idx was of UNIQUE (session_id, turn_index) before the schema-hardening
-- migration dropped it. Keeping it would be pure write amplification.
DROP INDEX IF EXISTS kioku_scenes_scope_idx;

-- pg-migrate reuses one connection for the complete composed plan, so the plain SET at the
-- start of this migration would survive transaction commit. Migration 0010 may already have
-- supplied the same leaked value, which is why changing only this migration's opening SET to
-- SET LOCAL would not restore the host configuration. Reset the session value explicitly so
-- migration 0012 and every later component inherit the configured database or role default.
RESET search_path;
