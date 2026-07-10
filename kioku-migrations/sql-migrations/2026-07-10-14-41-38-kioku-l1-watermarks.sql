-- codd: in-txn

-- Migration: kioku-l1-watermarks
-- Created: 2026-07-10-14-41-38 UTC
-- Per-session L1 distillation watermark: the highest turn index covered by a
-- fully successful pass. Read to skip re-extraction on timer re-fires; written
-- only after a pass completes without error.
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS kioku_l1_watermarks (
  session_id text PRIMARY KEY,
  last_turn_index integer NOT NULL DEFAULT 0,
  distilled_at timestamptz NOT NULL DEFAULT NOW()
);
