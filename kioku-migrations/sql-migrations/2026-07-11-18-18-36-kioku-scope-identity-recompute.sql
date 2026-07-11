-- codd: in-txn

-- Migration: kioku-scope-identity-recompute
-- Created: 2026-07-11-18-18-36 UTC
--
-- Scene and persona primary keys are derived from the scope. The old derivation joined
-- namespace/kind/ref with '/' and no escaping, so two genuinely different scopes could
-- produce one id:
--
--   ScopeGlobal (Namespace 'a/b/c')                 -> 'a/b/c'
--   ScopeEntity (Namespace 'a') (ScopeKind 'b') 'c' -> 'a/b/c'
--
-- Both then wrote the same row, and since the upserts do not update the scope columns on
-- conflict, the second scope's body landed on a row still attributed to the first.
--
-- Kioku.Distill.ScopeIdentity now percent-escapes each component before joining. This
-- migration brings persisted ids in line with it. Components containing none of '%', '/' or
-- ':' escape to themselves, so almost every database has nothing to rewrite -- the WHERE
-- clauses below match only the ambiguous rows.
--
-- A row that had absorbed a second scope's content keeps the id derived from its *stored*
-- scope columns, i.e. it stays with the first writer. The second scope's scene or persona
-- simply regenerates under its own, now-distinct id on the next distillation timer: scenes
-- and personas are caches of kioku_memories, not records of truth.
--
-- Re-running recomputes the same values, so this is idempotent.
SET search_path TO kiroku, pg_catalog;

CREATE OR REPLACE FUNCTION pg_temp.kioku_escape_scope_component(component text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  -- '%' first, or the encoding is not injective.
  SELECT replace(replace(replace(component, '%', '%25'), '/', '%2F'), ':', '%3A')
$$;

-- The COALESCE collapses the kind/ref segment for global rows. The scope-pair CHECK added by
-- the schema-hardening migration guarantees kind and ref are NULL together, so there is no
-- half-populated case to worry about.
CREATE OR REPLACE FUNCTION pg_temp.kioku_scope_identity(namespace text, scope_kind text, scope_ref text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT pg_temp.kioku_escape_scope_component(namespace)
      || COALESCE(
           '/' || pg_temp.kioku_escape_scope_component(scope_kind)
               || '/' || pg_temp.kioku_escape_scope_component(scope_ref),
           ''
         )
$$;

UPDATE kioku_scenes
   SET scene_id = 'kioku_scene:'
               || pg_temp.kioku_scope_identity(namespace, scope_kind, scope_ref)
               || ':'
               || pg_temp.kioku_escape_scope_component(scene_key)
 WHERE namespace ~ '[%/:]'
    OR scope_kind ~ '[%/:]'
    OR scope_ref ~ '[%/:]'
    OR scene_key ~ '[%/:]';

UPDATE kioku_personas
   SET persona_id = 'kioku_persona:'
                 || pg_temp.kioku_scope_identity(namespace, scope_kind, scope_ref)
 WHERE namespace ~ '[%/:]'
    OR scope_kind ~ '[%/:]'
    OR scope_ref ~ '[%/:]';
