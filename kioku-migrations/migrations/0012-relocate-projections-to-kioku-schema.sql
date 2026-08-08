-- Migration: relocate-projections-to-kioku-schema
-- Created: 2026-08-07-18-20-00 UTC
--
-- Kioku's seven projection tables move out of Kiroku's schema and into their own.
--
-- Kioku deliberately shares the host application's Kiroku event store: that sharing is the
-- integration boundary, and this migration does not touch it. What it does change is where the
-- relations *Kioku* owns live. Until now they sat in `kiroku` alongside the event store's own
-- tables, distinguished only by a `kioku_` name prefix that nothing in the catalog enforces, so
-- a host that already ran Kiroku found another product's projections inside its event store's
-- namespace. After this migration every Kioku-owned relation is in the `kioku` schema, and the
-- prefix is dropped because the schema now supplies the namespace it used to stand in for. See
-- docs/adr/projections-live-in-the-kioku-schema.md.
--
--   kiroku.kioku_memories                 -> kioku.memories
--   kiroku.kioku_sessions                 -> kioku.sessions
--   kiroku.kioku_turns                    -> kioku.turns
--   kiroku.kioku_l1_watermarks            -> kioku.l1_watermarks
--   kiroku.kioku_consolidation_decisions  -> kioku.consolidation_decisions
--   kiroku.kioku_scenes                   -> kioku.scenes
--   kiroku.kioku_personas                 -> kioku.personas
--
-- This is a metadata operation, not a copy. `ALTER TABLE ... SET SCHEMA` and
-- `ALTER TABLE ... RENAME TO` both keep the table's object identity, so its rows, indexes,
-- constraints, owner, and table grants come along untouched and nothing is rebuilt. Index and
-- constraint names are deliberately *not* renamed: they travel by identity, and renaming them
-- would churn the catalog for no gain. None of the seven tables has a sequence, trigger, or
-- foreign key needing separate movement.
--
-- The `vector` extension is not moved and must not be. A PostgreSQL extension is a
-- database-wide object the host may share, so `ALTER EXTENSION` is out of scope here. The
-- memory table keeps its `vector` column and its HNSW index by identity, and the runtime's
-- `to_regtype('vector')` probe keeps resolving against the connection's search path exactly as
-- 0009-kioku-embedding-schema-heal.sql arranged.
--
-- Exactly two catalog states are accepted, and every other state aborts before a single table
-- moves. A partial or colliding layout is never repaired heuristically, because there is no way
-- to tell an interrupted upgrade apart from a host relation that happens to share a target name,
-- and guessing wrong would mean moving somebody else's table or writing into it. The migration
-- is transactional, so a refusal leaves the catalog exactly as it was found.
--
--   1. all seven sources present as ordinary tables, no target name occupied -> move them
--   2. no source name occupied at all, all seven targets present as ordinary tables -> no-op
--
-- The occupancy test uses `to_regclass`, which resolves any relation: a view, materialized view,
-- foreign table, sequence, or index sitting on a target name blocks the move, because all of
-- them share PostgreSQL's relation namespace and any one of them would make the rename fail.

CREATE SCHEMA IF NOT EXISTS kioku;

COMMENT ON SCHEMA kioku IS
  'Kioku-owned read-model projections. Managed by pg-migrate component kioku.';

DO $$
DECLARE
  source_names CONSTANT text[] := ARRAY[
    'kioku_memories',
    'kioku_sessions',
    'kioku_turns',
    'kioku_l1_watermarks',
    'kioku_consolidation_decisions',
    'kioku_scenes',
    'kioku_personas'
  ];
  target_names CONSTANT text[] := ARRAY[
    'memories',
    'sessions',
    'turns',
    'l1_watermarks',
    'consolidation_decisions',
    'scenes',
    'personas'
  ];
  expected CONSTANT integer := array_length(source_names, 1);
  slot integer;
  source_relation regclass;
  target_relation regclass;
  relation_kind "char";
  present_sources integer := 0;
  ordinary_sources integer := 0;
  present_targets integer := 0;
  ordinary_targets integer := 0;
BEGIN
  -- Pass one counts. Nothing is altered until the whole layout has been classified, so a
  -- collision on the seventh table cannot be discovered after the first six have moved.
  FOR slot IN 1 .. expected LOOP
    source_relation := to_regclass('kiroku.' || quote_ident(source_names[slot]));
    target_relation := to_regclass('kioku.' || quote_ident(target_names[slot]));

    IF source_relation IS NOT NULL THEN
      present_sources := present_sources + 1;
      SELECT c.relkind INTO relation_kind
        FROM pg_catalog.pg_class c
       WHERE c.oid = source_relation;
      IF relation_kind = 'r' THEN
        ordinary_sources := ordinary_sources + 1;
      END IF;
    END IF;

    IF target_relation IS NOT NULL THEN
      present_targets := present_targets + 1;
      SELECT c.relkind INTO relation_kind
        FROM pg_catalog.pg_class c
       WHERE c.oid = target_relation;
      IF relation_kind = 'r' THEN
        ordinary_targets := ordinary_targets + 1;
      END IF;
    END IF;
  END LOOP;

  IF present_sources = expected AND ordinary_sources = expected AND present_targets = 0 THEN
    FOR slot IN 1 .. expected LOOP
      EXECUTE format('ALTER TABLE kiroku.%I SET SCHEMA kioku', source_names[slot]);
      EXECUTE format('ALTER TABLE kioku.%I RENAME TO %I', source_names[slot], target_names[slot]);
    END LOOP;
  ELSIF present_sources = 0 AND present_targets = expected AND ordinary_targets = expected THEN
    -- Already relocated. Re-running the body is a no-op by construction, not by accident.
    NULL;
  ELSE
    RAISE EXCEPTION
      'refusing to relocate Kioku projections: expected either % ordinary kiroku.kioku_* tables '
      'with no kioku.* target relation, or no kiroku.kioku_* relation with % ordinary kioku.* '
      'tables; found % source relation(s) of which % ordinary, and % target relation(s) of '
      'which % ordinary',
      expected, expected, present_sources, ordinary_sources, present_targets, ordinary_targets;
  END IF;
END $$;
