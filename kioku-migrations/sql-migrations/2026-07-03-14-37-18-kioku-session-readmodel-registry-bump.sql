-- codd: in-txn

-- Migration: kioku-session-readmodel-registry-bump
-- Created: 2026-07-03-14-37-18 UTC
--
-- The session read model reshaped v1 -> v2 (delegation lineage) -> v3 (awaiting
-- park/resume) through the two preceding, purely additive column migrations.
-- Those ALTER TABLE migrations left the underlying kioku_sessions data correct
-- for v3, but they did not touch the keiro_read_models registry. Because
-- registerReadModel only inserts a row (never bumps an existing one), any
-- database that registered a session read model before this upgrade stays
-- pinned at its old version, and every session query then fails closed with
-- ReadModelStaleSchema. Reconcile those rows to the current v3 identity.
--
-- keiro_read_models canonically lives in the kiroku schema (created by the
-- keiro framework bootstrap). Some long-lived development databases still hold
-- it in public; keep public on the search_path so the unqualified name resolves
-- there too. Idempotent: the guard skips rows already at v3.
SET search_path TO kiroku, public, pg_catalog;

UPDATE keiro_read_models
SET version = 3,
    shape_hash = 'kioku-session-v3',
    status = 'live',
    last_built_at = now(),
    updated_at = now()
WHERE name IN (
    'kioku-session-by-id',
    'kioku-sessions-by-namespace',
    'kioku-sessions-by-scope',
    'kioku-sessions-by-focus',
    'kioku-sessions-by-started-range',
    'kioku-session-chain',
    'kioku-session-delegation-children',
    'kioku-sessions-awaiting-by-correlation-key'
  )
  AND (version <> 3 OR shape_hash <> 'kioku-session-v3');
