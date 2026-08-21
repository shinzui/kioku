-- Ledger re-baseline for the corrected payload of Kioku migration 0011 (BUG-1).
--
-- kioku-migrations 0.4.0.0 and 0.4.1.0 shipped a payload whose plain
-- `SET search_path TO kiroku, pg_catalog` survived transaction commit on the
-- connection pg-migrate reuses for a composed plan. A later host component on
-- that connection could therefore fail to resolve its own unqualified tables.
-- The corrected 0011 explicitly resets the session value before committing.
--
-- pg-migrate verifies the exact SHA-256 of every applied payload. Correcting
-- 0011 therefore changes its checksum, and a database that already applied the
-- withdrawn payload will report MigrationChecksumMismatch until its stored
-- checksum is re-baselined. This script performs that one re-baseline and
-- nothing else.
--
-- WHEN TO RUN: after taking a verified backup, once per long-lived database
-- that ALREADY APPLIED kioku/0011 under kioku-migrations 0.4.0.0 or 0.4.1.0,
-- BEFORE the first `up` or `verify` using the corrected package. A database
-- where 0011 is still pending does not need this script; it applies the
-- corrected payload normally. Fresh and ephemeral databases do not need it.
--
-- WHY NO SCHEMA MIGRATION FOLLOWS: the withdrawn and corrected payloads have
-- identical durable schema and data effects. The only withdrawn effect was a
-- connection-local search_path value, and that ceased to exist when the old
-- runner connection closed.
--
-- SAFETY: the UPDATE matches only the applied kioku/0011 row carrying the exact
-- withdrawn checksum. It is idempotent: a second run, a pending migration, an
-- already-corrected row, or any other checksum changes zero rows. This narrow
-- correction is not permission to bypass any other checksum mismatch.
--
-- LEDGER LOCATION: pg-migrate's default ledger schema is `pgmigrate`. If the
-- host configured a different schema through LedgerConfig, change the schema
-- name in the to_regclass call below and nowhere else.

BEGIN;

DO $$
DECLARE
  ledger_table regclass;
  withdrawn_checksum bytea :=
    decode('eee9cd252b32b563c50f8457596347fff1b2e4d3ea4dafe5b45043e991624192', 'hex');
  corrected_checksum bytea :=
    decode('6c83d3f01f784d0d9395953d5bb1763b8eea6cd9439073df42f79775a85197a9', 'hex');
  rebaselined integer;
BEGIN
  ledger_table := to_regclass('pgmigrate.migrations');

  IF ledger_table IS NULL THEN
    RAISE EXCEPTION
      'Could not find pgmigrate.migrations; edit this script if LedgerConfig uses a different schema';
  END IF;

  EXECUTE format(
    'UPDATE %s SET checksum = $1
       WHERE component = ''kioku''
         AND migration = ''0011-kioku-memory-space-partition''
         AND status = ''applied''
         AND checksum = $2',
    ledger_table
  )
  USING corrected_checksum, withdrawn_checksum;

  GET DIAGNOSTICS rebaselined = ROW_COUNT;

  IF rebaselined = 0 THEN
    RAISE NOTICE
      'no applied kioku/0011 row carried the withdrawn checksum; nothing to re-baseline';
  ELSIF rebaselined = 1 THEN
    RAISE NOTICE 're-baselined the applied kioku/0011 checksum';
  ELSE
    RAISE EXCEPTION 're-baselined % kioku/0011 rows; expected at most one', rebaselined;
  END IF;
END $$;

-- Sanity check: kioku/0011 must now carry the corrected checksum, or be absent
-- because this database has not reached 0011 yet. Expect one row with ok =
-- true, or zero rows.
--   SELECT encode(checksum, 'hex') =
--          '6c83d3f01f784d0d9395953d5bb1763b8eea6cd9439073df42f79775a85197a9' AS ok
--   FROM pgmigrate.migrations
--   WHERE component = 'kioku'
--     AND migration = '0011-kioku-memory-space-partition';

COMMIT;
