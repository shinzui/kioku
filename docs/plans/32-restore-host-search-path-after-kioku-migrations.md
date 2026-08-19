---
id: 32
slug: restore-host-search-path-after-kioku-migrations
title: "Restore host search path after Kioku migrations"
kind: exec-plan
created_at: 2026-08-19T21:59:29Z
intention: "intention_01m0e0jgvzem4s6jb4xwwgcy5y"
---

# Restore host search path after Kioku migrations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kioku is embedded as one component of a host application's PostgreSQL migration plan. Today, a
fresh install or cohort upgrade can apply all of Kioku's migrations successfully and then fail on
the host's first migration: historical Kioku migrations leave the connection's `search_path` set
to `kiroku, pg_catalog`, so an unqualified host table that exists in the host's configured schema
appears not to exist. The confirmed report is
[BUG-1](../bug-reports/migration-0011-session-search-path-leaks-into-later-migrations.md).

After this change, Kioku's final migration restores PostgreSQL's configured default search path
before the next component runs. A host can apply `kiroku -> keiro -> kioku -> host` in one run,
and a later host migration such as `ALTER TABLE host_table ...` resolves `host_table` exactly as
it did when the migration connection opened. This is observable in a new ephemeral-database test
whose database default is `host_app, pg_catalog`: the current tree fails with SQLSTATE `42P01`,
while the completed tree applies all 54 migrations (Kiroku 11, Keiro 30, Kioku 13) plus the host
migration in one run. Existing released checksums remain unchanged, and no application-facing
Haskell API changes.


## Progress

- [ ] Add a composed-plan regression that gives the database a nonstandard default
      `search_path`, runs Kioku before a host component, and captures the current `42P01` failure.
- [ ] Append migration `0013-restore-host-search-path.sql` without changing migrations
      `0001` through `0012`, then make the composed-plan regression pass.
- [ ] Update migration-count assertions and the Codd cutover rehearsal for the 54-row plan.
- [ ] Close BUG-1 as fixed on the default branch, update current user documentation and
      changelogs, regenerate the bug-report index/log, and validate the OKF bundle.
- [ ] Run focused and repository-wide validation, perform the ADR distillation pass, and record
      the results in this plan.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Treat BUG-1 as a valid component-isolation defect, but not as a regression introduced
  by migration `0011`.
  Rationale: The owning repository reproduced the exact `42P01` failure on PostgreSQL 17.10.
  Release tags `v0.1.0.0` through `v0.3.0.0` end at migration `0010`, which contains the same
  session-level `SET`; `v0.4.0.0` and `v0.4.1.0` add `0011` as the final such migration and `0012`
  does not restore the setting. There is no released last-working pg-migrate component.
  Date: 2026-08-19

- Decision: Repair the session with a new final migration containing `RESET search_path;`.
  Rationale: A plain `SET` inside a committed transaction persists on the connection, while
  `RESET` restores the database, role, or connection-startup default when its own transaction
  commits. A proof run inserted exactly that migration between Kioku and a host component and
  made the otherwise identical failing plan succeed.
  Date: 2026-08-19

- Decision: Do not edit migrations `0001` through `0012`, and do not re-baseline their ledger
  checksums.
  Rationale: All historical DDL applies correctly. The defect is only the session state handed to
  the next component, so an append-only repair is sufficient and preserves pg-migrate's durable
  exact-byte history contract.
  Date: 2026-08-19

- Decision: Test behavior at the component boundary instead of adding a text-only ban on
  `SET search_path`.
  Rationale: A full-chain test catches any future Kioku migration that leaks session state after
  `0013`, regardless of spelling, and proves the host-visible effect. Historical files must keep
  their bare `SET` bytes, so a blanket source grep would either fail forever or require a brittle
  allowlist without proving runtime isolation.
  Date: 2026-08-19

- Decision: Use a nonstandard database default (`host_app, pg_catalog`) in the regression rather
  than relying on PostgreSQL's usual `public` fallback.
  Rationale: This proves the fix restores host configuration rather than merely hard-coding a
  path that happens to work for the reproducer.
  Date: 2026-08-19

- Decision: Do not create a new ADR during plan creation.
  Rationale: [ADR-10](../adr/projections-live-in-the-kioku-schema.md) already establishes both
  explicit schema qualification and forward-only treatment of released migrations. The fix
  enforces those existing constraints at a component boundary rather than introducing a new
  architecture. The implementation must still perform the required ADR distillation pass at
  completion.
  Date: 2026-08-19


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

PostgreSQL's `search_path` is the ordered list of schemas used to resolve an unqualified name such
as `host_table`. `SET search_path TO kiroku, pg_catalog` changes that list for the current database
session, which means the value remains on that connection after the transaction commits. `SET
LOCAL` would last only until the current transaction ends. `RESET search_path` restores the
configuration value with which the session was initialized, including a database-level or
role-level default.

`pg-migrate` executes a validated `MigrationPlan`, which is an ordered composition of library- and
application-owned `MigrationComponent` values. The dependency at
`mori://shinzui/pg-migrate/packages/pg-migrate` version 1.1.0.0 acquires one dedicated Hasql
connection, holds one advisory lock for the complete plan, and executes each ordinary SQL file in
its own transaction on that same connection. The public contract is recorded at
`mori://shinzui/pg-migrate/docs/public-api`. Therefore transaction rollback protects a failed SQL
migration, but a successful plain `SET` becomes session state observed by later migrations. The
current bound in `kioku-migrations/kioku-migrations.cabal` is already `pg-migrate ^>=1.1.0.0`; no
dependency change is needed.

`kioku-migrations/migrations/manifest` is the authoritative order of Kioku-owned SQL files.
`kioku-migrations/src/Kioku/Migrations/Internal/Definition.hs` embeds those exact bytes and exports
the `kioku` component through `Kioku.Migrations.kiokuMigrations`. The first ten files were shipped
as the initial pg-migrate component. Migrations `0001` through `0005` and `0007` through `0011`
each contain `SET search_path TO kiroku, pg_catalog`; `0006` and `0012` do not. Migration `0012`
fully qualifies its DDL but inherits the value left by `0011`, so the runner reaches the next
component with `kiroku, pg_catalog` still active. These files are released exact-byte history and
must not be edited.

`kioku-migrations/test/Main.hs` owns database-backed migration tests. Its
`testFreshDatabase`, `testKirokuOnlyAdoption`, and `testCoddCohortImport` paths already exercise
the real embedded plan against ephemeral PostgreSQL. The file also has helpers for acquiring a
raw connection and for running Hasql sessions. `kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs`
deliberately hands callers a connection string after pg-migrate releases its migration connection;
that is useful for catalog assertions but cannot reveal leaked runner state. The new regression
must therefore compose an application-owned host component into the same plan, so the host SQL is
executed on the leaking connection itself.

The test suite in `kioku-migrations/kioku-migrations.cabal` currently imports the public Kiroku
component but not the public Keiro component or `Data.Set`. To assemble
`kiroku -> keiro -> kioku -> host` using only supported APIs, its direct test dependencies need
`keiro-migrations ^>=0.13.0.0` and `containers >=0.6 && <0.8`. The host SQL bytes can be produced
with the already available `Data.Text.Encoding.encodeUtf8`, so no new `bytestring` test dependency
is necessary.

Adding one Kioku migration changes current plan totals from 53 to 54. The exact assertions at
`kioku-migrations/test/Main.hs` in the Kiroku-adoption and Codd-import tests must move to 54;
`expectedForwardMigrationIds` must gain `kioku/0013-restore-host-search-path`; and the repeated
run must observe 54 `AlreadyApplied` results. `forwardMigrationEffectCountStatement` remains six
because it intentionally counts durable schema/catalog effects and `RESET search_path` has none.
Current counts also appear in `docs/user/getting-started.md` and
`docs/user/upgrading-to-the-kioku-schema.md`. The Codd cutover guide at
`docs/user/upgrading-to-pg-migrate.md` must describe the actual 24-row forward suffix: five Kiroku
rows (`0007` through `0011`), sixteen Keiro rows (`0015` through `0030`), and three Kioku rows
(`0011` through `0013`), ending at 54 total. Historical release sections in changelogs remain
historical and are not rewritten; new facts go under an `Unreleased` heading.

The relevant local architecture decision is
[ADR-10](../adr/projections-live-in-the-kioku-schema.md). It says Kioku-owned runtime SQL names
relations explicitly rather than relying on host connection search paths, and it explicitly
rejects rewriting migrations `0001` through `0011` because released migrations are immutable
history. No other local ADR governs this narrower session-cleanup defect.


## Plan of Work

### Milestone 1: prove and repair the composed-plan boundary

First extend `kioku-migrations/kioku-migrations.cabal` with the two direct test dependencies
described above. In `kioku-migrations/test/Main.hs`, add a group for migration-session isolation
and a test named along the lines of “restores the host search path before later components.” The
test starts with `withBareDatabase`, creates schema `host_app` and table
`host_app.host_table`, and changes that ephemeral database's default `search_path` to
`host_app, pg_catalog`. Obtain a safely quoted database identifier with a Hasql statement that
selects `quote_ident(current_database())`, issue `ALTER DATABASE <quoted-name> SET search_path TO
host_app, pg_catalog`, release the setup connection, and let pg-migrate acquire a new connection so
the new default is active.

Build four components with supported public APIs: Kiroku's exported component, Keiro's exported
component, `Kioku.Migrations.kiokuMigrations`, and a test-only `host` component. Create the host
component with `migrationComponentFromEmbeddedSql`, make it depend on component name `kioku`, and
give it one transactional SQL migration containing an unqualified statement such as `ALTER TABLE
host_table ADD COLUMN migrated boolean NOT NULL DEFAULT true;`. Compose the four components in
that order with `migrationPlan` and call `runMigrationPlan defaultRunOptions` using the ephemeral
database connection string. Assert the report is successful, its last result is the host
migration with `AppliedNow`, and a qualified catalog query sees the new column. This assertion is
the host-visible contract; merely querying `current_setting('search_path')` on a later fresh
connection would not test the runner session.

Before adding the fix migration, run this focused test once and record the negative proof in this
plan's Surprises & Discoveries section. It must fail with `DatabaseSessionFailed`, SQLSTATE
`42P01`, and `relation "host_table" does not exist`. Do not commit that red state. Then run
`just new-migration restore-host-search-path`. The recipe must create
`kioku-migrations/migrations/0013-restore-host-search-path.sql` and append it to the manifest.
Replace the scaffold body with explanatory comments and the single executable statement `RESET
search_path;`. Explain in the SQL comments that plain `SET` in historical transactional migrations
survives commit, pg-migrate deliberately reuses one connection, and the reset restores the
database/role default for later components. Do not use `SET LOCAL` here: a local reset would vanish
at commit and leave the leaked session value active. Do not modify `kioku-migrations/migrations.lock`,
which records the pre-cutover Codd evidence rather than forward migrations.

Update `testKirokuOnlyAdoption`, `testCoddCohortImport`, and `expectedForwardMigrationIds` for the
new plan row while preserving the six-effect catalog assertion. The milestone is complete when
the same composed-plan regression that failed before now succeeds, the manifest integrity test
passes, the Codd rehearsal imports 30 historical rows then applies the 24-row forward suffix, and
the migration test suite ends green.

### Milestone 2: publish the fixed contract and validate the repository

Add an `Unreleased` / `Fixed` entry to `CHANGELOG.md`, `kioku-migrations/CHANGELOG.md`, and
`kioku-migrate/CHANGELOG.md`. State that `kioku/0013-restore-host-search-path` restores the host's
configured schema resolution before later components, that no released checksum changes, and that
the composed plan now has 54 rows. Leave the 0.4.0.0 and 0.4.1.0 release sections untouched.

Update the three current user documents named in Context and Orientation. The getting-started and
schema-upgrade pages should say 54 migrations (Kiroku 11, Keiro 30, Kioku 13). The Codd cutover
guide should say 24 post-pin migrations, enumerate the current ranges, include Kioku `0013` as the
session cleanup after the partition and relocation, and show the final 11/30/13 component counts.

Move BUG-1 in
`docs/bug-reports/migration-0011-session-search-path-leaks-into-later-migrations.md` from
`confirmed` to `fixed`, set `fixedVersion: unreleased`, and add a `resolution` that names migration
`0013` and the composed-plan regression. Update its current-content provenance and review metadata
according to `docs/bug-reports/profile.dhall`, then regenerate `docs/bug-reports/index.md`, append a
`Fix` entry to `docs/bug-reports/log.md`, and run strict profile enforcement.

Finish by running the focused migration suite, every repository test inside the Nix development
shell, the flake checks, and whitespace validation. Update Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective with exact evidence. Review those living sections and
ADR-10 for durable new context. Update an ADR only if implementation discovers a reusable
architectural constraint not already captured by ADR-10; otherwise record that the distillation
pass found no ADR change necessary. The milestone is complete when all checks pass and the only
behavioral difference is the added forward reset and its documentation.


## Concrete Steps

Run all commands from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kioku
git status --short
```

Preserve unrelated working-tree changes. In particular, never reset or rewrite a file merely
because it was already modified before this plan began.

After adding the test dependencies and the composed-plan regression, but before creating
`0013`, run:

```bash
nix develop -c cabal test kioku-migrations:kioku-migrations-test \
  --test-show-details=direct
```

The new case should supply the negative proof while the rest of the suite remains healthy. The
essential failure is:

```text
DatabaseSessionFailed (ScriptSessionError
  "ALTER TABLE host_table ADD COLUMN migrated boolean NOT NULL DEFAULT true;"
  (ServerError "42P01" "relation \"host_table\" does not exist" ...))
```

Create the append-only repair through the repository's normal authoring path:

```bash
just new-migration restore-host-search-path
tail -n 3 kioku-migrations/migrations/manifest
```

The manifest tail should be:

```text
0011-kioku-memory-space-partition.sql
0012-relocate-projections-to-kioku-schema.sql
0013-restore-host-search-path.sql
```

Edit only the newly created SQL file so its executable body is:

```sql
RESET search_path;
```

After updating the count assertions and expected forward IDs, rerun the focused suite:

```bash
nix develop -c cabal test kioku-migrations:kioku-migrations-test \
  --test-show-details=direct
git diff --exit-code -- kioku-migrations/migrations.lock
```

The first command must end with all `kioku-migrations` cases passing. The second command must emit
nothing, proving the historical Codd lock was not changed.

After updating BUG-1, its index, and its log, validate the profiled bundle:

```bash
okf index docs/bug-reports --write
okf log add docs/bug-reports \
  --kind Fix \
  --message "BUG-1 is fixed by forward migration 0013 and a composed-plan regression." \
  --date 2026-08-19
okf validate docs/bug-reports \
  --strict \
  --profile docs/bug-reports/profile.dhall \
  --profile-enforce \
  --log-enforce
```

Use the implementation date rather than the example date if work occurs later. Successful
validation prints:

```text
OK: 1 concepts (okf_version 0.2)
```

Run final repository validation:

```bash
nix develop -c cabal build all
nix develop -c cabal test all --test-show-details=direct
nix flake check
git diff --check
git status --short
```

At completion, a commit implementing this plan must use a Conventional Commit subject and both
required trailers. For example:

```text
fix(migrations): restore host search path after kioku migrations

ExecPlan: docs/plans/32-restore-host-search-path-after-kioku-migrations.md
Intention: intention_01m0e0jgvzem4s6jb4xwwgcy5y
```


## Validation and Acceptance

Acceptance is behavioral, not merely a source inspection.

On a fresh ephemeral database whose default `search_path` is `host_app, pg_catalog`, the composed
`kiroku -> keiro -> kioku -> host` test plan must finish in one invocation. The host migration
must use the unqualified name `host_table`, and a qualified catalog assertion must show its new
column. Removing `0013` from the manifest must make this exact test fail with SQLSTATE `42P01`;
restoring `0013` must make it pass. This negative/positive pair proves the test detects the reported
defect and that the repair restores configuration rather than hard-coding `public`.

The manifest must contain 13 Kioku migrations, and verification of a fresh full plan must report
54 applied migrations with no pending, unknown, failed, or checksum-mismatched row. The
Kiroku-only adoption test must still skip the 11 already-applied Kiroku rows and reach the same
54-row verified plan. The Codd rehearsal must still import exactly 30 historical rows without
executing them, apply exactly 24 forward migrations including Kioku `0013`, report 54 applied
rows, and make its second `up` a 54-row no-op.

No file from `kioku-migrations/migrations/0001-kioku-base.sql` through
`0012-relocate-projections-to-kioku-schema.sql` may change, and
`kioku-migrations/migrations.lock` must have no diff. This proves the fix does not create a
checksum repair obligation for any released database.

BUG-1 must validate with `status: fixed`, `fixedVersion: unreleased`, and a resolution naming the
forward reset and regression. The generated bug-report index must carry the corrected description,
and the bundle log must record the fix. Current user documentation must consistently report the
11/30/13 component counts and 54 total.

Finally, `nix develop -c cabal test all --test-show-details=direct`, `nix flake check`, and
`git diff --check` must all exit zero. Record concise transcripts and the ADR distillation result
in this living plan before marking Progress complete.


## Idempotence and Recovery

The migration is idempotent as session behavior: running `RESET search_path` when the path is
already at its configured default makes no catalog or data change. pg-migrate applies `0013` once
per ledger, but rerunning its body manually in an ephemeral test is harmless. The normal
implementation path is forward-only; never delete a ledger row to force it to run again.

`just new-migration restore-host-search-path` is not repeatable after it succeeds because the
manifest will already contain `0013`. If authoring is interrupted before the new file is correct,
edit that still-unreleased `0013` file and rerun the manifest test. Do not invoke the scaffold a
second time, do not renumber it, and do not edit an earlier file as a shortcut.

Every database mutation in the regression happens in a dedicated ephemeral database. Its
`ALTER DATABASE ... SET search_path` setting disappears with that database, even if the test fails.
The production migration changes only connection-local state and writes its ordinary pg-migrate
ledger row; it does not touch application data, schemas, tables, privileges, or database defaults.

If a real deployment of `0013` fails, pg-migrate rolls back both the reset and its ledger insert.
Correct the pending, unreleased migration if appropriate and rerun the complete plan. If `0013`
has already shipped, recovery is another forward migration; never mutate the applied payload or
ledger. The existing workaround for releases 0.1.0.0 through 0.4.1.0 remains to rerun the plan:
on the second invocation the leaking Kioku migrations are already applied, so the pending host
migration starts on a fresh connection with its configured default.


## Interfaces and Dependencies

There is no new production Haskell interface and no production dependency change.
`Kioku.Migrations.kiokuMigrations :: Either DefinitionError MigrationComponent` and
`Kioku.Migrations.kiokuMigrationPlan :: Either PlanError MigrationPlan` retain their existing
types. The observable production interface change is that the former contains one additional
ordered SQL migration, `kioku/0013-restore-host-search-path`.

The regression uses these public dependency interfaces:

- `Kiroku.Store.Migrations.kirokuMigrations` from
  `mori://shinzui/kiroku/packages/kiroku-store-migrations` supplies the first component.
- `Keiro.Migrations.keiroMigrations` from
  `mori://shinzui/keiro/packages/keiro-migrations` supplies the second component.
- `Database.PostgreSQL.Migrate.migrationComponentFromEmbeddedSql` defines the test-only `host`
  component from one SQL byte string and a `Set Text` dependency on `kioku`.
- `Database.PostgreSQL.Migrate.migrationPlan` validates the explicit component order, and
  `runMigrationPlan defaultRunOptions` runs it on the ephemeral database.
- `Kioku.Migrations.TestSupport.withBareDatabase :: (Text -> IO a) -> IO a` supplies an isolated
  database without pre-applied migration state.

Add `containers >=0.6 && <0.8` and `keiro-migrations ^>=0.13.0.0` only to the
`kioku-migrations-test` stanza in `kioku-migrations/kioku-migrations.cabal`. These bounds match the
package's existing production dependencies and introduce no new solver choice. Use the existing
`hasql`, `text`, `pg-migrate`, and `kiroku-store-migrations` test dependencies for setup,
execution, and assertions.

Keep the test helper functions private to `kioku-migrations/test/Main.hs`. At minimum, the end
state needs an assertion such as `testHostSearchPathRestored :: Assertion`, a helper that builds
the four-component `MigrationPlan`, a statement returning `quote_ident(current_database())`, and
a qualified statement that proves `host_app.host_table.migrated` exists. No test helper becomes a
library export.
