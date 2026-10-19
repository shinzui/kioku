-- Active recency ignores priority. The namespace page index is priority-first
-- and therefore requires sorting the whole matching population for this query.
-- This additive index builds in the migration transaction (not CONCURRENTLY):
-- reads continue, but writers wait for the build/transaction to finish.
CREATE INDEX IF NOT EXISTS memories_space_active_recency_idx
  ON kioku.memories (memory_space_id, namespace, created_at DESC, memory_id ASC)
  WHERE status = 'active';
