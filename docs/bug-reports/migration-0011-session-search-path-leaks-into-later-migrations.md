---
type: Bug Report
title: Migration 0011's session search_path leaks into every migration applied after it
description: >-
  Migration 0011 is the final of ten released Kioku migrations that set the session search_path
  and never restore it, so later components on the same connection resolve unqualified names
  against the kiroku schema instead of their own.
generated:
  by: openai/gpt-5
  at: "2026-08-19T21:39:40Z"
bugId: BUG-1
status: confirmed
severity: degraded
origin: mori://shinzui/rei
affects: mori://shinzui/kioku/packages/kioku-migrations
affectedVersion: "0.4.0.0"
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
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-19T21:39:40Z"
    document_timestamp: "2026-08-19T21:39:40Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5
    effort: high
    context: >-
      Confirmed at repository commit c6032c5926d94b13894dc35589b409376c135f04 by reading
      pg-migrate 1.1.0.0's dedicated-connection runner and reproducing the 42P01 failure with a
      composed Kioku-plus-host plan on PostgreSQL 17.10. The same plan succeeded when a
      transactional RESET search_path migration was inserted before the host component.
verified:
  by: process:codex
  at: "2026-08-19T21:39:40Z"
---

# Migration 0011's session `search_path` leaks into every migration applied after it

## What is wrong

`kioku-migrations/migrations/0011-kioku-memory-space-partition.sql:28` opens with

```sql
SET search_path TO kiroku, pg_catalog;
```

and never restores it.

A bare `SET` is **session**-scoped, not transaction-scoped. Committing the migration transaction
therefore commits the setting too. `pg-migrate` runs a plan's migrations on one dedicated
connection, so the setting outlives `0011` and applies to every migration that executes after it
in the same run — including migrations belonging to components `0011` knows nothing about.

Migration `0012`, in the same release, does not have this problem: it schema-qualifies its
statements and sets no `search_path`. It also does not repair the session state it inherits from
`0011`, so `kiroku, pg_catalog` remains active when the next component begins.

`0011` is the final offender, not the only one. Migrations `0001`–`0005` and `0007`–`0011` all
contain the same bare `SET search_path TO kiroku, pg_catalog`; `0006` and `0012` do not. The report
centres on `0011` because it is the last such migration in the current manifest and therefore the
one whose value reaches a host component when the full released plan is pending.

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

The owning repository reproduced the defect at commit
`c6032c5926d94b13894dc35589b409376c135f04` with `kioku-migrations` 0.4.1.0,
`pg-migrate` 1.1.0.0, and PostgreSQL 17.10. The ephemeral database contained
`public.host_table`, and the composed plan was `kiroku, keiro, kioku, host`; the host component's
only migration ran `ALTER TABLE host_table ADD COLUMN leaked boolean`. The plan failed after both
Kioku migrations `0011` and `0012` committed:

```text
Left (DatabaseSessionFailed (ScriptSessionError
  "ALTER TABLE host_table ADD COLUMN leaked boolean;"
  (ServerError "42P01" "relation \"host_table\" does not exist" ...)))
```

Inserting a transactional `RESET search_path` migration between the Kioku and host components
made the otherwise identical plan complete, including the unqualified host `ALTER TABLE`. This
also demonstrates that the repair can be forward-only.

## Fix direction

Append migration `0013` containing `RESET search_path;`. It runs after every released Kioku
migration, restores the database/role default on the runner's existing connection when its
transaction commits, and preserves every released migration checksum. A composed-plan regression
test must set a nonstandard database default, run a later host migration with an unqualified table
name, and prove the host migration sees that default after Kioku completes.

Future migrations must either schema-qualify their relations or use
`SET LOCAL search_path TO ...`, whose value disappears at the end of that migration's transaction.
Do not edit migrations `0001`–`0011`: changing any released payload changes its durable checksum.

The general rule for an embedded migration component is: **a component must leave session state
ready for the next component, whose SQL it cannot know.**

## Note for the fix

`0011` is already released in 0.4.0.0 and 0.4.1.0, and the earlier offenders shipped in every
release, so correcting any historical payload would change its checksum. `shinzui/kiroku`'s BUG-1
is the precedent for a historical checksum repair, but this defect does not need one: every
historical migration applies correctly, and a new final migration can restore the session before
control passes to another component.

## Related

- `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-1` — the same class of defect in a sibling
  component: a migration relying on the `search_path` an earlier migration happened to leave
  behind, where this one is a migration *leaving* one behind. Together they suggest the component
  family would benefit from a shared rule about `search_path` in migrations.
