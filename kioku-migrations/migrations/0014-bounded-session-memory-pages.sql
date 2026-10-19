-- Additive keyset indexes; existing readers remain supported.
CREATE INDEX IF NOT EXISTS sessions_space_namespace_page_idx
  ON kioku.sessions (memory_space_id, namespace, started_at DESC, session_id ASC);
CREATE INDEX IF NOT EXISTS sessions_space_scope_page_idx
  ON kioku.sessions (memory_space_id, namespace, scope_kind, scope_ref, started_at DESC, session_id ASC);
CREATE INDEX IF NOT EXISTS sessions_space_subject_page_idx
  ON kioku.sessions (memory_space_id, namespace, subject_ref, started_at DESC, session_id ASC);
CREATE INDEX IF NOT EXISTS sessions_space_parent_page_idx
  ON kioku.sessions (memory_space_id, parent_session_id, started_at ASC, session_id ASC);
CREATE INDEX IF NOT EXISTS turns_space_session_page_idx
  ON kioku.turns (memory_space_id, session_id, turn_index ASC, turn_id ASC);
CREATE INDEX IF NOT EXISTS memories_space_namespace_page_idx
  ON kioku.memories (memory_space_id, namespace, priority ASC, created_at DESC, memory_id ASC);
CREATE INDEX IF NOT EXISTS memories_space_scope_page_idx
  ON kioku.memories (memory_space_id, namespace, scope_kind, scope_ref, priority ASC, created_at DESC, memory_id ASC);
CREATE INDEX IF NOT EXISTS memories_space_session_page_idx
  ON kioku.memories (memory_space_id, session_id, created_at DESC, memory_id ASC);
