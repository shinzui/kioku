-- codd: in-txn

-- Migration: kioku-distillation
-- Created: 2026-06-24-02-00-00 UTC
-- Adds distillation pyramid read models and consolidation audit rows.
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS kioku_scenes (
  scene_id text PRIMARY KEY,
  namespace text NOT NULL,
  scope_kind text,
  scope_ref text,
  scene_key text NOT NULL,
  title text NOT NULL,
  body_md text NOT NULL,
  atom_ids jsonb NOT NULL DEFAULT '[]',
  source_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (namespace, scope_kind, scope_ref, scene_key)
);

CREATE INDEX IF NOT EXISTS kioku_scenes_scope_idx
  ON kioku_scenes (namespace, scope_kind, scope_ref);

CREATE TABLE IF NOT EXISTS kioku_personas (
  persona_id text PRIMARY KEY,
  namespace text NOT NULL,
  scope_kind text,
  scope_ref text,
  body_md text NOT NULL,
  scene_count integer NOT NULL DEFAULT 0,
  source_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (namespace, scope_kind, scope_ref)
);

CREATE TABLE IF NOT EXISTS kioku_consolidation_decisions (
  decision_id text PRIMARY KEY,
  session_id text,
  namespace text NOT NULL,
  scope_kind text,
  scope_ref text,
  candidate_content text NOT NULL,
  decision text NOT NULL CHECK (decision IN ('store', 'update', 'merge', 'skip')),
  target_ids jsonb NOT NULL DEFAULT '[]',
  result_memory_id text,
  rationale text,
  decided_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS kioku_consolidation_session_idx
  ON kioku_consolidation_decisions (session_id);

CREATE INDEX IF NOT EXISTS kioku_consolidation_scope_idx
  ON kioku_consolidation_decisions (namespace, scope_kind, scope_ref);
