# Codd cohort upgrade SQL

These are the reviewed, idempotent SQL artifacts used before importing Kioku's pinned Codd cohort
into pg-migrate. Run them in this order against a quiescent, backed-up database:

1. `realign-kiroku-migration-timestamps.sql`
2. `realign-keiro-migration-timestamps.sql`
3. `relocate-keiro-tables-to-keiro-schema.sql`

The first file is byte-identical to Kiroku commit
`876fb66f60508441970211c56de0bfb234ccb3f6`; the other two are byte-identical to Keiro commit
`0a1b5d64eae1dbb97fe40ed5b911a596b80ff638`. Their SHA-256 fingerprints are:

```text
7b0a2852d3e778dc13f1b3b87e77c3e05c74d45900341448d9b2ff4c0c35e19f  realign-kiroku-migration-timestamps.sql
d820add419b5dddfbea2649bf1af4a9a5678c1811c5faaff82383c42afd6bfb4  realign-keiro-migration-timestamps.sql
9323e94a7a135c34cd85c71f656ac6b82632e91b90f227b5a7686309627fe24b  relocate-keiro-tables-to-keiro-schema.sql
```

The Kioku migration rehearsal executes these same files. See
`docs/user/upgrading-to-pg-migrate.md` for the complete backup, import, forward-migration, and
verification procedure.

## Deprecated: scheduled for removal

This directory and everything that reads it are **deprecated as of kioku 0.2.0.0**. They exist
only as a one-time bridge for databases whose schema evolution predates the pg-migrate cutover
(kioku ExecPlan 20). A database created by `kioku-migrate up` has never needed any of it.

**The removal gate.** Removal is blocked on the last codd-era downstream database crossing over.
As of 2026-07-30 that is Shikigami, which still declares `codd >=0.1.8 && <0.2` and `codd-extras`,
still Git-pins `hasql-migration` and `codd-project`, and still pins Kioku at the pre-pg-migrate
commit `8bcfc282484dd59b0a0b25530cca4f3ad9034ce1`. Its crossing is tracked by Shikigami's
`docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md`.

Before removing, confirm no live database still has a `codd.sql_migrations` table. A migration
ledger is forward-only — there is no unapply — so deleting the bridge early strands such a
database with no supported route across.

**Remove these together, in one commit:**

- this directory, `kioku-migrations/codd-upgrade/`, and its `extra-doc-files` /
  `extra-source-files` entries
- `kioku-migrations/src/Kioku/Migrations/History/Codd.hs`
- the `import` subcommand and its options parser in `kioku-migrate/app/Main.hs`
- the `pg-migrate-import-codd` dependency from `kioku-migrations.cabal` (library *and*
  test-suite stanzas) and from `kioku-migrate.cabal`
- `testCoddCohortImport` in `kioku-migrations/test/Main.hs`, with its fixture
  `kioku-migrations/test/fixtures/pre-cutover-schema.sql` and the `coddV5Ledger` and
  `coddSnapshotStatement` helpers
- the `.claude/skills/cohort-migrate` skill, which is built entirely on this bridge
