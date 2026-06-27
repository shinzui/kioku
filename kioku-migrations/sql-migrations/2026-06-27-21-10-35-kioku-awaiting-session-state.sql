-- codd: in-txn

-- Migration: kioku-awaiting-session-state
-- Created: 2026-06-27-21-10-35 UTC
-- Adds park-and-resume columns to the session read model.
SET search_path TO kiroku, pg_catalog;

ALTER TABLE kioku_sessions ADD COLUMN IF NOT EXISTS awaiting_reason text;
ALTER TABLE kioku_sessions ADD COLUMN IF NOT EXISTS awaiting_correlation_key text;
ALTER TABLE kioku_sessions ADD COLUMN IF NOT EXISTS awaiting_deadline timestamptz;
ALTER TABLE kioku_sessions ADD COLUMN IF NOT EXISTS resume_input text;

CREATE INDEX IF NOT EXISTS kioku_sessions_awaiting_corr_idx
  ON kioku_sessions (namespace, awaiting_correlation_key)
  WHERE status = 'awaiting';
