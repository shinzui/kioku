-- codd: in-txn

-- Migration: kioku-base
-- Created: 2026-06-24-00-00-00 UTC
-- kioku read-model tables live in the kiroku schema.
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS kioku_memories (
  memory_id     text PRIMARY KEY,
  agent_id      text NOT NULL,
  session_id    text,
  namespace     text NOT NULL,
  scope_kind    text,
  scope_ref     text,
  memory_type   text NOT NULL,
  content       text NOT NULL,
  priority      integer NOT NULL DEFAULT 100,
  confidence    text NOT NULL DEFAULT 'medium',
  tags          jsonb NOT NULL DEFAULT '[]',
  status        text NOT NULL DEFAULT 'active',
  superseded_by text,
  supersedes    text,
  content_tsv   tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED,
  created_at    timestamptz NOT NULL,
  updated_at    timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS kioku_memories_status_idx ON kioku_memories (status);
CREATE INDEX IF NOT EXISTS kioku_memories_scope_idx
  ON kioku_memories (namespace, scope_kind, scope_ref) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS kioku_memories_type_idx ON kioku_memories (memory_type) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS kioku_memories_session_idx ON kioku_memories (session_id);
CREATE INDEX IF NOT EXISTS kioku_memories_tsv_idx ON kioku_memories USING gin (content_tsv);

CREATE TABLE IF NOT EXISTS kioku_sessions (
  session_id          text PRIMARY KEY,
  agent_id            text NOT NULL,
  focus               text NOT NULL,
  namespace           text NOT NULL,
  scope_kind          text,
  scope_ref           text,
  subject_ref         text,
  previous_session_id text,
  status              text NOT NULL DEFAULT 'running',
  started_at          timestamptz NOT NULL,
  completed_at        timestamptz,
  model_used          text,
  summary             text,
  error_message       text,
  created_at          timestamptz NOT NULL DEFAULT NOW(),
  updated_at          timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS kioku_sessions_status_idx ON kioku_sessions (status);
CREATE INDEX IF NOT EXISTS kioku_sessions_agent_idx ON kioku_sessions (agent_id);
CREATE INDEX IF NOT EXISTS kioku_sessions_scope_idx ON kioku_sessions (namespace, scope_kind, scope_ref);

CREATE TABLE IF NOT EXISTS kioku_turns (
  turn_id       text PRIMARY KEY,
  session_id    text NOT NULL,
  turn_index    integer NOT NULL,
  role          text NOT NULL,
  content       text NOT NULL,
  tool_summary  text,
  prompt_tokens integer,
  output_tokens integer,
  recorded_at   timestamptz NOT NULL,
  UNIQUE (session_id, turn_index)
);

CREATE INDEX IF NOT EXISTS kioku_turns_session_idx ON kioku_turns (session_id, turn_index);
