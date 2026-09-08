---
title: "One-time Codd migration-history import"
type: Capability
description: "Cross an existing Codd-managed database onto pg-migrate without replaying any DDL, by importing the pinned 30-migration cohort into the pg-migrate ledger behind a required reason and acknowledgement, then applying only what is genuinely forward."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-19
provider: mori://shinzui/kioku
status: deprecated
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-migrations
  - kioku-migrate
interface:
  - Kioku.Migrations.History.Codd
replacedBy:
  - CAP-13
requires:
  - CAP-13
evidence:
  - kind: test
    resource: kioku-migrations/test/Main.hs
    proves: "The pinned Codd history maps 30 known plan targets, the pre-cutover cohort imports 30 rows and applies only the forward migrations, a missing default ledger table is rejected, and the import restores strict verification and is idempotent."
  - kind: guide
    resource: docs/user/upgrading-to-pg-migrate.md
    proves: "The backup-first, zero-replay cutover runbook this command exists to serve."
  - kind: guide
    resource: docs/user/cli-reference.md
    proves: "The import command's flags, including the separate source database, the cooperating advisory lock key, and the required reason and confirmation."
---

# One-time Codd migration-history import

Kioku's schema used to be managed by Codd. `kioku-migrate import` is the bridge that moved
an existing data-bearing database onto
[the pg-migrate component (CAP-13)](embedded-migration-component.md) without replaying a
single DDL statement: it reads the Codd ledger, maps the pinned 30-migration cohort onto
the corresponding pg-migrate plan targets, writes the ledger rows, and leaves only the
genuinely forward migrations to apply.

It is deliberately hard to run by accident. `--reason` is required, and although the parser
accepts an omitted `--confirm`, the evidence validator refuses to import without that
acknowledgement. The source database defaults to the target but can be named separately,
the cooperating Codd advisory lock key defaults to `7739843257482693991`, and
`--strict-source` additionally rejects unrelated entries in a ledger that
application-owned migrations share.

## Shape

```bash
cabal run kioku-migrate -- import \
  --database-url "$DATABASE_URL" \
  --source-database-url "$OLD_DATABASE_URL" \
  --reason 'verified Codd-to-pg-migrate cohort cutover' \
  --confirm
```

## Limits

- **Deprecated since 0.2.0.0**, and scheduled for removal once the last Codd-era database
  has crossed over. A database that never used Codd should ignore it entirely and adopt
  [CAP-13](embedded-migration-component.md) directly.
- It maps exactly the pinned 30-migration cohort. A database at any other Codd state is
  not a supported input.
- It is a one-time cutover, not an ongoing compatibility layer: after it runs, pg-migrate
  owns the history and the Codd ledger is no longer consulted.
- Read the backup-first runbook before running it. This command rewrites migration history.
