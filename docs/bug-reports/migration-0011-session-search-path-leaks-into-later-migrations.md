---
type: Bug Report
title: Migration 0011's session search_path leaks into every migration applied after it
description: >-
  Migration 0011 opens with a bare SET search_path TO kiroku, pg_catalog and never restores it,
  so every migration a consumer applies after it on the same connection resolves unqualified
  names against the kiroku schema instead of its own.
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-19T00:00:00Z"
bugId: BUG-1
status: reported
severity: degraded
origin: mori://shinzui/rei
affects: mori://shinzui/kioku/packages/kioku-migrations
affectedVersion: "0.4.0.0"
lastWorkingVersion: "0.3.0.0"
observed: >-
  Applying a composed plan in which 0011 and a later component's migration are both pending fails
  on the first migration after 0011 with SQLSTATE 42P01, reporting that a table which exists in
  public does not exist. 0011 and every kioku migration apply; the consumer's do not.
expected: >-
  A migration changes only its own schema. kioku-migrations is embedded as one component of a
  consumer's composed pg-migrate plan, and kioku sorts before the consuming application in that
  plan, so a consumer's own migrations must resolve their own unqualified names exactly as they
  did before kioku's ran. Migration 0012 already meets this — it schema-qualifies rather than
  setting search_path.
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
---

# Migration 0011's session `search_path` leaks into every migration applied after it

## What is wrong

`kioku-migrations/migrations/0011-kioku-memory-space-partition.sql:28` opens with

```sql
SET search_path TO kiroku, pg_catalog;
```

and never restores it.

A bare `SET` is **session**-scoped, not transaction-scoped. `pg-migrate` runs a plan's migrations
on one connection, so the setting outlives `0011` and applies to every migration that executes
after it in the same run — including migrations belonging to components `0011` knows nothing
about.

Migration `0012`, in the same release, does not have this problem: it schema-qualifies its
statements and sets no `search_path`.

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

## Suggested fix

Either, and both are one line:

- `SET LOCAL search_path TO kiroku, pg_catalog;` — pg-migrate's transactional mode scopes it to
  the migration, which is what `0011` appears to intend; or
- drop the `SET` and schema-qualify `0011`'s statements, as `0012` already does.

The general rule worth adopting for an embedded migration component: **a migration must not
change the meaning of an unqualified name for migrations it knows nothing about.** A grep for a
bare `SET search_path` across `kioku-migrations/migrations/` would confirm whether `0011` is the
only instance.

## Note for the fix

`0011` is already released in 0.4.0.0 and 0.4.1.0, so correcting its payload changes its
checksum. `shinzui/kiroku`'s BUG-1 is the precedent for that situation and its resolution
describes the shape — a ledger re-baseline fixup plus a forward migration — but the cases differ
in one way that may make this one cheaper: kiroku's withdrawn payload failed at DDL parse time,
whereas `0011` applies correctly and only mis-configures the session. A forward-only fix that
leaves `0011`'s bytes alone may therefore be available.

## Related

- `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-1` — the same class of defect in a sibling
  component: a migration relying on the `search_path` an earlier migration happened to leave
  behind, where this one is a migration *leaving* one behind. Together they suggest the component
  family would benefit from a shared rule about `search_path` in migrations.
