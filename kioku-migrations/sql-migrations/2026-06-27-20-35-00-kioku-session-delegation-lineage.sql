-- codd: in-txn

SET search_path TO kiroku, pg_catalog;

ALTER TABLE kioku_sessions
  ADD COLUMN IF NOT EXISTS parent_session_id text,
  ADD COLUMN IF NOT EXISTS delegation_depth integer NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS kioku_sessions_parent_session_idx
  ON kioku_sessions (parent_session_id, started_at)
  WHERE parent_session_id IS NOT NULL;
