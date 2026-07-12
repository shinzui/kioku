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
