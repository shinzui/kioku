# Upgrading an existing Codd database to pg-migrate

This runbook moves a data-bearing database created by the pre-cutover kioku cohort onto
pg-migrate without replaying any of its 30 historical migrations. The source profile is exact:
kiroku 6, keiro 14, and kioku 10. Five migrations added after those pins are not imported; the
normal `up` step applies them once after the history import.

Stop every application, worker, and migration process that can write to the database. The importer
takes pg-migrate's target advisory lock and a cooperating Codd-source lock, but old Codd processes
do not honor that source lock. Quiescence is therefore an operator requirement, not something the
tool can guarantee.

Take a backup before doing anything else:

```bash
export DATABASE_URL='postgresql://user@host/database'
pg_dump --format=custom --file=before-kioku-pg-migrate.dump "$DATABASE_URL"
```

Restoring this backup is the only rollback. pg-migrate is forward-only; deleting ledger rows is not
a supported rollback.

## 1. Realign Kiroku's Codd filenames

Run the idempotent ledger-only script shipped with `kioku-migrations`:

```bash
psql "$DATABASE_URL" --set=ON_ERROR_STOP=1 \
  --file=kioku-migrations/codd-upgrade/realign-kiroku-migration-timestamps.sql
```

It renames the six sentinel filenames recorded by kioku's old Kiroku pin to the real-UTC names used
as import evidence. It does not execute schema DDL.

## 2. Realign Keiro's Codd filenames

Run Keiro's idempotent ledger-only fixup:

```bash
psql "$DATABASE_URL" --set=ON_ERROR_STOP=1 \
  --file=kioku-migrations/codd-upgrade/realign-keiro-migration-timestamps.sql
```

The script's `migration_timestamp` assignment retains the old timestamp for the renamed rows. That
does not affect import identity: the adapter derives `codd:<filename>` from the filename and records
the timestamp only as audit detail.

## 3. Relocate Keiro's framework tables

Move the eleven `keiro_*` tables from `kiroku` into Keiro's dedicated schema:

```bash
psql "$DATABASE_URL" --set=ON_ERROR_STOP=1 \
  --file=kioku-migrations/codd-upgrade/relocate-keiro-tables-to-keiro-schema.sql
```

This is an idempotent, transactional series of `ALTER TABLE ... SET SCHEMA` operations. PostgreSQL
moves indexes and constraints with their tables; rows are not copied. The import command validates
the relocated tables, indexes, recovery columns, workflow backfill, and generation-aware primary key
before accepting Keiro's state-equivalent history.

## 4. Import the 30 historical rows

Use the migrate executable built from the reviewed kioku revision:

```bash
DATABASE_URL="$DATABASE_URL" cabal run kioku-migrate -- import \
  --reason 'verified Codd-to-pg-migrate cohort cutover' \
  --confirm
```

Do not pass `--strict-source` when the database has application-owned Codd migrations in the same
ledger; lenient selection ignores those unrelated rows. Use `--strict-source` only when these 30
cohort rows are expected to be the entire Codd ledger.

The command writes 30 `status='applied'` rows and their import audit records without executing the
mapped SQL. Six Kiroku and nine Kioku mappings are checked against preserved SHA-256 payloads. The
14 rewritten Keiro mappings and Kioku 0006 require successful read-only state validators.

Running the same import again is safe: matching audit evidence reports `already imported`. Changed
evidence fails with a history-import conflict instead of overwriting the first audit.

## 5. Apply the five post-pin migrations and verify

```bash
DATABASE_URL="$DATABASE_URL" cabal run kioku-migrate -- up
DATABASE_URL="$DATABASE_URL" cabal run kioku-migrate -- verify
DATABASE_URL="$DATABASE_URL" cabal run kioku-migrate -- status
```

`up` reports the 30 imported migrations as already applied and applies only Kiroku 0007/0008 and
Keiro 0015/0016/0017. The final status is 35 applied migrations with no pending, unknown, or
verification issues:

```text
kiroku  8
keiro  17
kioku  10
```

Keep the backup until the application and workers have restarted successfully and their normal
read/write paths have been checked.
