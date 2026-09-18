---
id: 45
slug: harden-kioku-migrations-to-the-postgresql-patterns
title: "Harden Kioku migrations to the PostgreSQL patterns"
kind: exec-plan
created_at: 2026-09-18T18:42:34Z
intention: "intention_01m2twr1ddexergqvtn2bqztbv"
master_plan: "docs/masterplans/8-adopt-keiro-0-17-comprehensively.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-18T18:42:34Z
---

# Harden Kioku migrations to the PostgreSQL patterns

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Turn Kioku's PostgreSQL conventions into executable gates. Historical migrations remain
byte-for-byte immutable, while every future migration must schema-qualify owned objects,
must not change `search_path`, must appear in the manifest and lockfile, and must compose
after Kiroku and Keiro under a hostile session. Fresh, upgraded, and rerun databases must
converge on the same Kioku schema. The result follows
`mori://shinzui/postgresql-jitsurei/docs/migrations-schema-qualify-migration-objects` and
the migration guidance in `mori://shinzui/keiro-runtime-patterns` without rewriting the
legacy history those standards were introduced to protect.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Ratchet new migrations; never normalize old SQL in place.
  Rationale: Migrations 0001 through 0011 contain historical unqualified objects and
    `SET search_path`, but their checksums are durable database facts. ADR-10 explicitly
    makes future explicit qualification the remedy.
  Date: 2026-09-18
- Decision: Test the complete service plan, not the Kioku component in isolation.
  Rationale: Schema and session leakage occurs at component boundaries. The supported plan
    is Kiroku, then Keiro, then Kioku, and only that sequence proves ownership isolation.
  Date: 2026-09-18


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This plan starts after
`docs/plans/42-align-kioku-with-the-released-keiro-0-17-dependency-cohort.md`, because it
adopts the released 0.17 test fixture. It may develop in parallel with
`docs/plans/44-establish-a-validated-projection-catalog-and-runtime-assembly.md`; when that
plan is complete, consume its catalog registration boundary in integration fixtures rather
than creating another registration list.

`kioku-migrations/src/Kioku/Migrations/Internal/Definition.hs` embeds the manifest and
constructs the Kioku component; `Kioku.Migrations.kiokuMigrationPlan` composes it after
Kiroku and Keiro. `kioku-migrations/migrations/manifest` names thirteen SQL files and
`migrations.lock` records durable hashes. `kioku-migrations/test/Main.hs` already exercises
fresh apply, a Codd-era upgrade, migration reruns, a hostile host `search_path`, registry
layout compatibility, and the projection relocation. Its manifest test calls
`checkMigrationManifest`, but there is no explicit lockfile or forward-only SQL policy gate.

The early migrations predate current schema rules and use unqualified names or
`SET search_path`. Migration 0012 relocates application projections into `kioku`; 0013
adds the partition-aware full-text index. Their bytes are released and immutable. The correct
strategy is to record that baseline and apply stricter checks only to files added after 0013.

Keiro 0.17 publishes `Keiro.Test.Postgres.withMigratedSuiteWith`, which creates a cached
Kiroku+Keiro template and accepts extra migration components. Use the released API from
`mori://shinzui/keiro/packages/keiro-test-support` instead of maintaining a second framework
fixture where it fits; keep `withBareDatabase` for layout and history tests that intentionally
start before framework migrations.

[ADR-10](../adr/projections-live-in-the-kioku-schema.md) requires explicit schema ownership,
no `search_path` dependence, immutable applied history, and migration-time reconciliation.
[ADR-9](../adr/each-recall-target-gets-its-own-statement.md) requires the nine recall access
paths to remain separate. No new ADR is needed unless expected-schema policy changes what
Kioku considers its public database contract.


## Plan of Work

Milestone 1 strengthens integrity. Add tests beside `testManifestIntegrity` that parse and
verify `kioku-migrations/migrations.lock`, compare it with the embedded manifest, reject
missing/extra/duplicate entries, and assert the thirteen released hashes. Use pg-migrate's
lockfile API when exported; otherwise add a small read-only parser in test code that follows
the documented format. Do not regenerate the lockfile unless a new migration is added.

Milestone 2 adds a forward ratchet. Add a test helper that treats 0001–0013 as the frozen
legacy allowlist and applies policy checks to every later manifest entry: owned tables,
indexes, constraints, functions, and types must be schema-qualified; SQL must not issue
`SET [LOCAL] search_path`; and `public` must not be an application-object default. Prefer
the official lint helper from the migration pattern project if one exists at implementation
time; locate it with Mori first. The test should print the filename and rule on failure.

Milestone 3 adopts the shared fixture. Add `keiro-test-support ^>=0.17.0.0` to the
appropriate test or `test-support` stanza. Rework `withKiokuMigratedDatabase` to create the
released Kiroku+Keiro template and apply Kioku's component as the extra component, while
preserving the current callback contract for `kioku-core` and `kioku-cli` tests. Keep bare
ephemeral PostgreSQL for tests that assemble old physical layouts.

Milestone 4 proves schema convergence. Add a deterministic expected-schema assertion for
Kioku-owned objects (normalized catalog query or checked-in schema snapshot) that excludes
owners, OIDs, timestamps, and extension-installation variability. Compare fresh apply with
the supported Codd upgrade path. Run the complete plan after setting a hostile host schema
as default, append a host migration, and verify the host object lands in its schema. Apply or
verify the plan twice and require no pending migration or checksum issue.

Milestone 5 updates `docs/user/library-api.md` and `docs/user/getting-started.md` with the
ratcheted authoring flow: use `just new-migration`, qualify every object, update manifest and
lockfile through pg-migrate tooling, run migration tests, and never edit a released payload.


## Concrete Steps

Run from the repository root:

```sh
cabal test kioku-migrations:kioku-migrations-test
cabal test kioku-core:kioku-test --test-options='--pattern Schema'
cabal test kioku-cli:kioku-cli-test
```

The migration suite must report passing groups for manifest/lock integrity,
schema-qualification policy, fresh apply, Codd upgrade, session isolation, and schema
convergence. Then run:

```sh
cabal test all
git diff -- kioku-migrations/migrations/0001-*.sql kioku-migrations/migrations/0002-*.sql kioku-migrations/migrations/0003-*.sql kioku-migrations/migrations/0004-*.sql kioku-migrations/migrations/0005-*.sql kioku-migrations/migrations/0006-*.sql kioku-migrations/migrations/0007-*.sql kioku-migrations/migrations/0008-*.sql kioku-migrations/migrations/0009-*.sql kioku-migrations/migrations/0010-*.sql kioku-migrations/migrations/0011-*.sql kioku-migrations/migrations/0012-*.sql kioku-migrations/migrations/0013-*.sql
```

The final diff must be empty. If the implementation adds no Kioku migration—and none is
expected for Keiro 0.17—the manifest, lockfile, and composed count remain unchanged.


## Validation and Acceptance

Acceptance requires all thirteen historical SHA-256 values to remain unchanged and the
complete plan to contain 56 migrations: Kiroku 11, Keiro 32, Kioku 13. A deliberately
unqualified future migration fixture and a fixture that sets `search_path` must fail the
policy test with their filenames; the frozen legacy files must not be rewritten or silently
ignored by checksum verification.

A fresh database and a supported imported-history database must expose the same normalized
Kioku relations, columns, constraints, and indexes. Running the plan twice must be a no-op.
A following host component must resolve its own unqualified table in the host schema, proving
Kioku leaked no session state.


## Idempotence and Recovery

Ephemeral database tests are repeatable and destroy only their own temporary clusters.
Never point them at `DATABASE_URL` or a long-lived database. If expected schema differs,
inspect the catalog diff and migration history; update the snapshot only when an intentional
new migration explains every change. Do not repair a mismatch by editing the pg-migrate ledger.


## Interfaces and Dependencies

Use `Kioku.Migrations.kiokuMigrations` as the application component and
`Kioku.Migrations.kiokuMigrationPlan` as the complete public plan. Reuse
`Keiro.Test.Postgres.withMigratedSuiteWith` from `keiro-test-support ^>=0.17.0.0` for
framework-aware fixtures and retain `Kioku.Migrations.TestSupport.withBareDatabase` for
historical layout tests. The public `withKiokuMigratedDatabase :: (Text -> IO a) -> IO a`
shape remains stable so core and CLI tests require no fixture rewrite.
