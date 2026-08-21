-- Migration: partition-aware-fts-index
-- Created: 2026-08-21 UTC
--
-- Every full-text recall statement constrains an active row by memory space and namespace
-- before matching content_tsv. btree_gin supplies GIN operator classes for the two text
-- columns, so one partial index can enforce that complete candidate boundary instead of
-- enumerating matches from unrelated tenants through the historical content-only GIN.
--
-- This is an optional access-path improvement. Some managed PostgreSQL roles cannot install
-- extensions, so the extension attempt is isolated in a PL/pgSQL subtransaction. The old
-- content-only GIN is dropped only after the replacement is visible in the catalog; otherwise
-- it remains as the correctness-preserving fallback.

DO $$
DECLARE
  btree_gin_available boolean := false;
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS btree_gin;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE
        'btree_gin extension is unavailable (%: %); retaining kioku_memories_tsv_idx',
        SQLSTATE,
        SQLERRM;
  END;

  SELECT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_extension
    WHERE extname = 'btree_gin'
  ) INTO btree_gin_available;

  IF btree_gin_available THEN
    CREATE INDEX IF NOT EXISTS kioku_memories_space_namespace_tsv_idx
      ON kioku.memories USING gin (memory_space_id, namespace, content_tsv)
      WHERE status = 'active';

    IF to_regclass('kioku.kioku_memories_space_namespace_tsv_idx') IS NOT NULL THEN
      DROP INDEX IF EXISTS kioku.kioku_memories_tsv_idx;
    END IF;
  ELSE
    RAISE NOTICE
      'btree_gin is not installed; retaining kioku_memories_tsv_idx as the full-text fallback';
  END IF;
END $$;
