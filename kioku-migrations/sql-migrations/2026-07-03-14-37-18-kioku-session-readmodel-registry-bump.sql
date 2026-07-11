-- codd: in-txn

-- Migration: kioku-session-readmodel-registry-bump
-- Created: 2026-07-03-14-37-18 UTC
-- Body rewritten 2026-07-11: locate keiro_read_models dynamically. See
-- docs/plans/14-align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations.md
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
-- keiro_read_models lives in a different schema depending on the keiro cohort:
-- in `kiroku` on the pinned cohort (keiro's bootstrap runs under
-- `SET search_path TO kiroku`), in a dedicated `keiro` schema after keiro's
-- schema relocation, and in `public` on some long-lived development databases.
-- Hard-coding a search_path here would make this file fail with undefined_table
-- on every fresh database built against a relocated keiro -- keiro's bootstrap
-- sorts before this file on every cohort, so there is no later migration that
-- could rescue it. Resolve the table dynamically instead, so this file is
-- correct on all three layouts and survives the pin bump.
--
-- A missing table means keiro's bootstrap did not run, i.e. a genuinely broken
-- database: fail loudly rather than silently reconciling nothing.
-- Idempotent: the guard skips rows already at v3.
DO $do$
DECLARE
  registry regclass;
BEGIN
  registry := COALESCE(
    to_regclass('keiro.keiro_read_models'),
    to_regclass('kiroku.keiro_read_models'),
    to_regclass('public.keiro_read_models'));

  IF registry IS NULL THEN
    RAISE EXCEPTION 'keiro_read_models not found in the keiro, kiroku, or public schemas';
  END IF;

  EXECUTE format($sql$
    UPDATE %s
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
      AND (version <> 3 OR shape_hash <> 'kioku-session-v3')
  $sql$, registry);
END
$do$;
