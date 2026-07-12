-- codd: in-txn

-- Migration: kioku-memory-embeddings
-- Created: 2026-06-24-01-00-00 UTC
-- Adds optional pgvector-backed embedding columns for hybrid recall.
SET search_path TO kiroku, pg_catalog;

DO $$
DECLARE
  vector_available boolean := false;
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS vector;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'pgvector extension is unavailable (%: %); skipping kioku memory embedding columns and ANN index', SQLSTATE, SQLERRM;
  END;

  SELECT EXISTS (
    SELECT 1
    FROM pg_extension
    WHERE extname = 'vector'
  ) INTO vector_available;

  IF vector_available THEN
    EXECUTE 'ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS embedding vector(1536)';
    ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS embedding_model text;
    ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS dimensions integer;
    ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS content_hash text;

    EXECUTE 'CREATE INDEX IF NOT EXISTS kioku_memories_embedding_hnsw ON kioku_memories USING hnsw (embedding vector_cosine_ops) WHERE embedding IS NOT NULL';
    CREATE INDEX IF NOT EXISTS kioku_memories_content_hash_idx ON kioku_memories (content_hash);
  END IF;
END $$;
