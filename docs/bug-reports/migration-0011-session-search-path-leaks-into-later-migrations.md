---
type: Bug Report
title: Migration 0011's session search_path leaks into every migration applied after it
description: >-
  The 0.4.x payload of migration 0011 was the final of ten Kioku migrations that left the session
  search_path pinned to the kiroku schema; the corrected payload resets the host default before
  later components run.
generated:
  by: openai/gpt-5
  at: "2026-08-21T19:16:10Z"
bugId: BUG-1
status: fixed
severity: degraded
origin: mori://shinzui/rei
affects: mori://shinzui/kioku/packages/kioku-migrations
affectedVersion: "0.4.0.0"
fixedVersion: unreleased
resolution: >-
  Fixed on the default branch by correcting migration 0011 itself: its final statement now resets
  search_path before the transaction commits, so migration 0011 cannot reach an applied state
  while leaving pg-migrate's shared connection poisoned. The exact payload checksum changes from
  eee9cd252b32b563c50f8457596347fff1b2e4d3ea4dafe5b45043e991624192 to
  6c83d3f01f784d0d9395953d5bb1763b8eea6cd9439073df42f79775a85197a9. Databases that
  already applied the 0.4.0.0 or 0.4.1.0 payload must run the shipped, idempotent
  ledger-fixups/2026-08-19-rebaseline-0011-checksum.sql before the corrected up or verify;
  databases where 0011 is pending apply it normally. A composed Kiroku/Keiro/Kioku/host
  regression now gives the database a nonstandard host_app search path and proves an unqualified
  host migration succeeds after all 55 framework migrations.
observed: >-
  Applying a composed plan in which 0011 and a later component's migration are both pending fails
  on the first migration after 0011 with SQLSTATE 42P01, reporting that a table which exists in
  public does not exist. 0011 and every kioku migration apply; the consumer's do not.
expected: >-
  A migration changes only its own schema. kioku-migrations is embedded as one component of a
  consumer's composed pg-migrate plan, and kioku sorts before the consuming application in that
  plan, so a consumer's own migrations must resolve their own unqualified names exactly as they
  did before kioku's ran. Migration 0012 already meets this — it schema-qualifies rather than
  setting search_path — as does migration 0013.
reproduction:
  - Compose a pg-migrate plan whose components are ordered kioku then a consuming application, as an embedding host does.
  - Bring a database to kioku 0010 and leave at least one of the consuming application's own migrations pending, so that 0011 and that migration are pending in the same run.
  - Ensure the pending application migration references one of its own tables unqualified, for example ALTER TABLE some_read_model ADD COLUMN ...
  - Run the plan once. Migrations 0011 and 0012 apply.
  - The next migration fails with 42P01 naming the application's own table, even though the table exists in public and the database's search_path includes public.
workaround: >-
  Run the plan a second time. 0011 is then already applied and is skipped, so its SET never
  executes and the remaining migrations resolve normally -- verified against PostgreSQL 18.4.
  Setting ALTER DATABASE <db> SET search_path before the first run does not help, because 0011's
  session-level SET overrides the database default for the rest of that connection. A consumer
  already current on its own migrations, applying only framework rows, never meets this at all.
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-21T19:16:10Z"
    document_timestamp: "2026-08-21T19:16:10Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5
    effort: high
    context: >-
      Reviewed against repository commit a53d063da16640322b86ed0eccd61490d351df4c after reading
      pg-migrate 1.1.0.0's dedicated-connection runner, reproducing the 42P01 failure with the
      checked-in composed Kiroku/Keiro-0.14/Kioku/host test on PostgreSQL 17.10, and verifying the
      corrected 0011 plus exact-checksum re-baseline through all 24 migration tests.
verified:
  by: process:codex
  at: "2026-08-21T19:16:10Z"
---

# Migration 0011's session `search_path` leaks into every migration applied after it

## What is wrong

The payload shipped in 0.4.0.0 and 0.4.1.0 opened with

```sql
SET search_path TO kiroku, pg_catalog;
```

and never restored it. The corrected file retains that opening statement for its own unqualified
DDL and ends with `RESET search_path;`.

A bare `SET` is **session**-scoped, not transaction-scoped. Committing the migration transaction
therefore commits the setting too. `pg-migrate` runs a plan's migrations on one dedicated
connection, so the setting outlives `0011` and applies to every migration that executes after it
in the same run — including migrations belonging to components `0011` knows nothing about.

Migration `0012`, in the same release, does not have this problem: it schema-qualifies its
statements and sets no `search_path`. Feature migration `0013`, added later, does the same. Before
the correction neither repaired the session state inherited from `0011`, so `kiroku, pg_catalog`
remained active when the next component began.

`0011` is the final offender, not the only one. Migrations `0001`–`0005` and `0007`–`0011` all
contain the same bare `SET search_path TO kiroku, pg_catalog`; `0006`, `0012`, and `0013` do not.
The report centres on `0011` because it is the last such migration in the manifest and therefore
the one that must clear both its own setting and the identical value that `0010` may have left.

## Why it reaches consumers

Kioku is embedded. A host composes kioku's migrations as one component of its own plan, and
kioku sorts **before** the host's own migrations. So the leak lands on exactly the migrations a
host owns and kioku cannot see.

Observed in `shinzui/rei`, whose plan is ordered `pgmq, kiroku, keiro, kioku, rei`. Applying the
Keiro 0.13 cohort ran all nineteen pending framework migrations, then failed on the first pending
Rei migration:

```text
up: error: DatabaseSessionFailed (ScriptSessionError
  "…ALTER TABLE entity_properties ADD COLUMN IF NOT EXISTS value_topic TEXT;…"
  (ServerError "42P01" "relation \"entity_properties\" does not exist" …))
```

`entity_properties` exists, in `public`, and the database's own `search_path` is
`public, message_store, reporting`. Only the runner's session disagreed.

## Scope

The leak fires only when `0011` **actually executes** in the same run as a later unqualified
migration, which is why it is graded `degraded` rather than `unusable`. Three paths are exposed:

- **restore-a-backup-then-upgrade**, which is the supported way to build a working database in
  hosts whose predecessor history was imported rather than replayed;
- **a host landing its own new migration in the same window as this cohort**;
- **a fresh database built in one pass**, where every migration runs in one session.

A host already current on its own migrations, applying only framework rows, is unaffected.

The version history is broader than the original report stated. Release tags `v0.1.0.0`,
`v0.2.0.0`, and `v0.3.0.0` all end at migration `0010`, which has the same session-level `SET`.
Releases `v0.4.0.0` and `v0.4.1.0` add `0011`, then `0012`, without restoring the setting. There
is therefore no released last-working version of the pg-migrate component; `0.4.0.0` remains the
affected version against which this particular failure was observed.

## Validation

The owning repository now carries the reproducer in `kioku-migrations/test/Main.hs`. The
ephemeral database sets its configured default to `host_app, pg_catalog`, creates
`host_app.host_table`, and applies `kiroku -> keiro -> kioku -> host` with
`keiro-migrations` 0.14.0.0. The host component's only migration runs an unqualified
`ALTER TABLE host_table`. With the withdrawn `0011` body, all other migration cases passed and
this case alone failed:

```text
Left (DatabaseSessionFailed (ScriptSessionError
  "ALTER TABLE host_table ADD COLUMN migrated boolean NOT NULL DEFAULT true;"
  (ServerError "42P01" "relation \"host_table\" does not exist" ...)))
```

After migration `0011` itself gained its final `RESET search_path;`, the focused case passed and
the complete suite reported all 24 cases passing. The final composed framework plan contains 55
rows: 11 Kiroku, 31 Keiro, and 13 Kioku. A separate regression models an applied 0.4.x database by
replacing only `kioku/0011`'s ledger checksum with the withdrawn digest; strict verification then
reports `MigrationChecksumMismatch`, the shipped re-baseline restores verification without DDL,
and a second run changes nothing.

## Resolution

Migration `0011` now cleans up the session state before its own transaction commits. The opening
plain `SET` remains because the migration's historical DDL is unqualified, but the file ends with
an explanatory comment and `RESET search_path;`. Changing the opening statement to `SET LOCAL`
would not suffice: when `0011` begins, `0010` may already have left the same session value, and
commit would reveal it again. The final plain reset restores the configured database or role
default for `0012`, `0013`, and every later host component.

This deliberately corrects a released payload. The withdrawn exact-byte SHA-256 is
`eee9cd252b32b563c50f8457596347fff1b2e4d3ea4dafe5b45043e991624192`; the corrected digest is
`6c83d3f01f784d0d9395953d5bb1763b8eea6cd9439073df42f79775a85197a9`. A database that already
applied `0011` under 0.4.0.0 or 0.4.1.0 must run
`kioku-migrations/ledger-fixups/2026-08-19-rebaseline-0011-checksum.sql` once before the corrected
`up` or `verify`. The script matches only the applied Kioku row with the withdrawn checksum and is
an informative no-op otherwise. A database where `0011` is pending applies the corrected bytes
normally, and a Codd-era database has no `0011` row before its first corrected `up`.

No schema-convergence migration is necessary: the old and corrected bodies have identical durable
schema and data effects, and the old session value disappeared when its runner connection closed.
No cleanup migration was added. A component must leave session state ready for the next component,
whose SQL it cannot know; future migrations must name relations explicitly or contain and clean up
any session setting inside their own execution boundary.

## Related

- `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-1` — the same class of defect in a sibling
  component: a migration relying on the `search_path` an earlier migration happened to leave
  behind, where this one is a migration *leaving* one behind. Together they suggest the component
  family would benefit from a shared rule about `search_path` in migrations.
