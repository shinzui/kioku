-- codd: in-txn

-- Migration: kioku-embedding-schema-heal
-- Created: 2026-07-11-17-45-43 UTC
--
-- A catch-up for 2026-06-24-01-00-00-kioku-memory-embeddings.sql, which is one-shot in the
-- worst way: it adds the embedding columns only if `CREATE EXTENSION vector` succeeds, but
-- codd records it applied either way. A database whose server had no pgvector at that
-- moment is therefore degraded *permanently* -- installing pgvector later changes nothing,
-- because the migration that would have used it will never run again. (This repository's
-- own dev database was in exactly that state.) This migration re-attempts the DDL, so any
-- database that gains the extension before its next `just migrate` heals itself.
--
-- It also fixes a bug in the original that only shows up when pgvector is installed in
-- `public`, which is where operators usually put it. There, `CREATE EXTENSION IF NOT EXISTS`
-- is a no-op, the `pg_extension` probe passes -- and then the *unqualified* `vector(1536)`
-- fails with `42704: type "vector" does not exist`, because migrations run with
-- `search_path = kiroku, pg_catalog`. The original migration aborts rather than degrading.
-- Below, the type and the operator class are schema-qualified with wherever the extension
-- actually lives, so the DDL succeeds under either layout.
--
-- Every statement is IF NOT EXISTS, so this is a no-op on a healthy database and on one
-- that is still missing pgvector.
SET search_path TO kiroku, pg_catalog;

DO $$
DECLARE
  vector_schema text;
BEGIN
  BEGIN
    -- With this migration's search_path, a fresh install lands in `kiroku`, which is also
    -- the schema the application's connections search -- so the type and the `<=>` operator
    -- resolve unqualified at query time.
    CREATE EXTENSION IF NOT EXISTS vector;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'pgvector extension is unavailable (%: %); leaving kioku memory embedding columns absent and recall keyword-only', SQLSTATE, SQLERRM;
  END;

  SELECT n.nspname
    INTO vector_schema
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
   WHERE e.extname = 'vector';

  IF vector_schema IS NULL THEN
    RETURN;
  END IF;

  EXECUTE format(
    'ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS embedding %I.vector(1536)',
    vector_schema
  );
  ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS embedding_model text;
  ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS dimensions integer;
  ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS content_hash text;

  EXECUTE format(
    'CREATE INDEX IF NOT EXISTS kioku_memories_embedding_hnsw ON kioku_memories USING hnsw (embedding %I.vector_cosine_ops) WHERE embedding IS NOT NULL',
    vector_schema
  );
  CREATE INDEX IF NOT EXISTS kioku_memories_content_hash_idx ON kioku_memories (content_hash);

  -- The columns are correct in any schema, but naming the type is not: the application
  -- connects with `search_path = kiroku, pg_catalog` (Kiroku.Store.Connection's `schema`
  -- plus an empty `extraSearchPath`), and recall casts with a bare `$1::vector`. If the
  -- extension lives anywhere else, that cast cannot resolve and the vector path stays
  -- unusable no matter how healthy the schema looks.
  IF vector_schema <> 'kiroku' THEN
    RAISE WARNING 'pgvector is installed in schema %, not kiroku. The embedding columns exist, but kioku connects with search_path = kiroku, pg_catalog and cannot name the vector type, so recall will degrade to keyword-only. Fix by adding % to the store''s extraSearchPath, or by moving the extension: ALTER EXTENSION vector SET SCHEMA kiroku;', vector_schema, vector_schema;
  END IF;
END $$;
