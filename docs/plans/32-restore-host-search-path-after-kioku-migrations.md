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

After this change, migration `0011-kioku-memory-space-partition.sql` restores PostgreSQL's
configured default search path before it commits. The correction is intentionally made inside the
offending migration instead of delegated to a later cleanup migration: `0011` cannot reach an
applied state while leaving the shared connection poisoned. A host can apply
`kiroku -> keiro -> kioku -> host` in one run, and a later host migration such as
`ALTER TABLE host_table ...` resolves `host_table` exactly as it did when the migration connection
opened. This is observable in a new ephemeral-database test whose database default is
`host_app, pg_catalog`: the current tree fails with SQLSTATE `42P01`, while the completed tree
applies 55 migrations (Kiroku 11, Keiro 31, Kioku 13) plus the host migration in one run. The
31st Keiro row comes from upgrading the composed component to `keiro-migrations` 0.14.0.0 as part
of this plan. The complete dependency cohort used or constrained by Kioku also moves in lockstep:
`keiro`, `keiro-core`, `keiro-migrations`, and the optional `keiro-pgmq` constraint all target
0.14.0.0. Kioku does not add dependencies on Keiro packages it does not consume.

Correcting released migration `0011` changes its exact-byte SHA-256 checksum and is therefore a
deliberate breaking change for databases that applied Kioku 0.4.0.0 or 0.4.1.0. The release ships
an idempotent, exact-checksum ledger re-baseline for those databases, modelled on the established
Kiroku BUG-1 precedent at `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-1`. Databases still at
Kioku 0.3.x have no `0011` row and apply the corrected payload normally. Fresh databases need no
special handling. No new forward migration is added, the Codd cutover evidence remains unchanged,
and no application-facing Haskell API changes.


## Progress

- [x] (2026-08-21T19:08:09Z) Upgrade the composed Keiro migration component to 0.14.0.0, including
      migration `0031`, and update the full-plan and post-Codd inventory assertions.
- [x] (2026-08-21T19:08:09Z) Add a composed-plan regression that gives the database a nonstandard default
      `search_path`, runs Kioku before a host component, and captures the current `42P01` failure.
- [x] (2026-08-21T19:10:20Z) Correct migration `0011-kioku-memory-space-partition.sql` so it resets
      the session before commit, then make the composed-plan regression pass without adding a
      cleanup migration.
- [x] (2026-08-21T19:14:29Z) Add and test the exact-checksum ledger re-baseline for databases that
      applied the withdrawn 0.4.x payload, while preserving the 55-row plan and the pinned Codd
      import evidence.
- [x] (2026-08-21T19:19:47Z) Close BUG-1 as fixed on the default branch, update current user
      documentation and changelogs, regenerate the bug-report index/log, and validate the OKF
      bundle.
- [x] (2026-08-21T19:23:01Z) Validate and record the durable migration-correction policy in ADR-10,
      run focused and repository-wide validation, perform the final ADR distillation pass, and
      record the results in this plan.
- [x] (2026-08-21T19:29:03Z) Reopen the completed plan, inventory every Keiro package reference,
      verify the 0.14.0.0 releases and tags, and audit Kioku against Keiro's 0.13-to-0.14 source
      migration guide.
- [x] (2026-08-21T19:36:44Z) Raise the remaining `keiro`, `keiro-core`, and optional `keiro-pgmq`
      bounds to 0.14.0.0, update current dependency documentation and changelogs, and pass the
      focused core and migration suites.
- [x] (2026-08-21T19:42:34Z) Re-run focused and repository-wide validation for the full Keiro
      cohort, recover one stale incremental Cabal artifact with a clean rebuild, perform another
      ADR distillation pass, and record the results here.


## Surprises & Discoveries

- Observation: `0011` is the final offender, but not the source of all leaked state. Migrations
  `0001` through `0005` and `0007` through `0011` all contain bare session-scoped `SET search_path`.
  Replacing only `0011`'s opening statement with `SET LOCAL` would restore the already-leaked value
  from `0010` when `0011` commits and would therefore leave BUG-1 unfixed.
  Evidence: `rg -n 'SET( LOCAL)? search_path|RESET search_path' kioku-migrations/migrations` found
  ten bare `SET` statements and no reset.

- Observation: Rewriting all ten historical offenders is incompatible with the active Codd
  cutover bridge, not merely expensive for pg-migrate ledgers. `Kioku.Migrations.History.Codd`
  proves nine of the first ten Kioku migrations with `SamePayload`, using the current embedded SQL
  bytes against `kioku-migrations/migrations.lock`; changing those files would invalidate that
  exact-payload evidence. Correcting only post-pin migration `0011` leaves that bridge intact.
  Evidence: `samePayloadSourcePayloads` in
  `kioku-migrations/src/Kioku/Migrations/History/Codd.hs` is built from
  `embeddedMigrationEntries`, while the Codd cohort imports only Kioku `0001` through `0010`.

- Observation: pg-migrate's public `repair` operation repairs ambiguous nontransactional states;
  it does not authorize checksum replacement for an applied transactional migration. A deliberate
  released-payload correction therefore needs a narrowly guarded operator SQL script, as Kiroku
  already used for its own BUG-1.
  Evidence: `mori://shinzui/pg-migrate/docs/operations` says checksum mismatches must never be
  bypassed, and `mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-1` documents its exact-checksum
  re-baseline precedent.

- Observation: The released 0.4.0.0 and 0.4.1.0 payloads of Kioku `0011` are byte-identical and
  have SHA-256 `eee9cd252b32b563c50f8457596347fff1b2e4d3ea4dafe5b45043e991624192`.
  Evidence: both release-tag payloads and the current file produced that digest with
  `shasum -a 256`.

- Observation: `docs/adr` is neither a profiled bundle in `mori.dhall` nor covered by a repository
  ADR validation recipe; `just check-adr` does not exist here. ADR updates must preserve the
  established filesystem convention directly: stable existing `docId`, advanced `timestamp`, a
  matching `docs/adr/log.md` entry, valid links, and a clean whitespace diff.
  Evidence: `mori show --full` lists only the improvement-request and bug-report OKF bundles, and
  `just --list` exposes no ADR recipe.

- Observation: The working tree advanced after this plan was revised: feature migration
  `0013-partition-aware-fts-index.sql` now exists, so the pre-upgrade composed plan contains 54
  rows and the post-Codd forward suffix contains 24 rows. This does not alter the fix: `0013` uses
  qualified names and `0011` remains the last Kioku migration that assigns a session-scoped
  `search_path`.
  Evidence: `kioku-migrations/migrations/manifest` has 13 entries; commit `2955e2f` added `0013`;
  and the existing migration suite already asserts 54 applied rows.

- Observation: `keiro-migrations` 0.14.0.0 was published on 2026-08-21 after the plan was written.
  It preserves the public `keiroMigrations` component API and appends one transactional,
  schema-qualified migration, `0031.sql`, which adds terminal rejected-outbox audit fields and
  indexes. The upgrade therefore raises the composed-plan total from 54 to 55 and the post-Codd
  forward suffix from 24 to 25 without changing historical migration identities or checksums.
  Evidence: Hackage lists 0.14.0.0 as a normal version, upstream tag
  `keiro-migrations-0.14.0.0` exists, and the upstream 0.13.0.0-to-0.14.0.0 diff changes the
  manifest only by appending `0031.sql`.

- Observation: The local Cabal package index initially lagged Hackage and knew only
  `keiro-migrations` 0.13.0.0, so dependency solving rejected the new 0.14 bound before
  compilation. Refreshing the index made 0.14.0.0 immediately resolvable.
  Evidence: the first focused run reported `rejecting: keiro-migrations-0.13.0.0`; `cabal update`
  advanced the index state to `2026-08-21T18:57:43Z`; the rerun downloaded and built 0.14.0.0.

- Observation: The composed-plan regression detects BUG-1 exactly at the host boundary under
  Keiro 0.14. With the uncorrected `0011`, all other 21 migration tests passed and only the host
  component failed.
  Evidence: the focused suite reported `DatabaseSessionFailed`, SQLSTATE `42P01`, and
  `relation \"host_table\" does not exist` for the unqualified host migration, ending with
  `1 out of 22 tests failed`.

- Observation: Appending the explanatory cleanup and `RESET search_path;` changes migration
  `0011`'s exact-byte SHA-256 to
  `6c83d3f01f784d0d9395953d5bb1763b8eea6cd9439073df42f79775a85197a9`. No other Kioku
  migration byte, manifest entry, or Codd lock changed.
  Evidence: the focused host test passed in 1.02 seconds, the complete migration suite reported
  `All 22 tests passed`, and the migration-directory diff names only `0011`.

- Observation: The guarded ledger re-baseline restores the exact original 55-row snapshot after a
  test models the withdrawn 0.4.x checksum, while leaving the qualified Kioku/Keiro catalog hash
  unchanged. Its second run is a no-op, and its default-ledger guard is observable on a bare
  database.
  Evidence: both focused fixup tests passed; the complete migration suite reported
  `All 24 tests passed`; and the source tarball contains
  `ledger-fixups/2026-08-19-rebaseline-0011-checksum.sql`.

- Observation: The bug-report index generator emits one extra blank line at end of file, which
  fails this repository's required `git diff --check` even though strict OKF validation accepts
  it. Removing that generated trailing blank preserves the index content and both checks pass.
  Evidence: `okf validate ... --profile-enforce --log-enforce` printed
  `OK: 1 concepts (okf_version 0.2)`, and the subsequent whitespace check exited zero.

- Observation: The complete repository validation remained green after the migration correction,
  Keiro 0.14 upgrade, ledger recovery test, and documentation changes.
  Evidence: `nix develop -c cabal build all` exited zero;
  `nix develop -c cabal test all --test-show-details=direct` passed the 24 migration, 125 API,
  53 CLI, and 226 core cases; `nix flake check` passed both the treefmt and pre-commit checks; and
  the final strict OKF and whitespace validations exited zero.

- Observation: The final ADR distillation found no implementation-time policy delta. ADR-10
  already states the exact narrow released-payload correction rule used here and already links
  this ExecPlan; its stable `docId` is `ADR-10`, its timestamp is
  `2026-08-19T22:50:57Z`, and `docs/adr/log.md` contains the matching update entry.
  Evidence: the prescribed `rg` checks found the metadata, two ExecPlan 32 references, and the
  matching log record; the final whitespace check also covers both files.

- Observation: Kioku references four Keiro packages, not all seven packages published from the
  Keiro repository. `keiro` and `keiro-core` are library and test dependencies of `kioku-core`;
  `keiro-migrations` is a library and test dependency of `kioku-migrations`; and `keiro-pgmq` is a
  forward-looking optional-integration constraint in `cabal.project`. There are no references to
  `keiro-dsl`, `keiro-ops`, or `keiro-test-support` in Kioku's package definitions or project
  constraints.
  Evidence: the repository-scoped Cabal search found only those four package names, and
  `mori registry show shinzui/keiro --full` identified the owning source and complete seven-package
  publication set.

- Observation: Keiro 0.14 is a lockstep package release. Its upgrade guide requires every Keiro
  package a project already depends on to move together. Hackage lists 0.14.0.0 as a normal,
  non-deprecated release of all four packages Kioku references, and upstream publishes matching
  `keiro-0.14.0.0`, `keiro-core-0.14.0.0`, `keiro-migrations-0.14.0.0`, and
  `keiro-pgmq-0.14.0.0` tags.
  Evidence: the Hackage preferred-version pages and `git ls-remote --tags` both expose exactly
  those releases; the local upstream source is at the tagged 0.14 package cohort.

- Observation: Keiro 0.14's new terminal outbox-rejection API does not require a Kioku source
  adaptation. Kioku neither matches `PublishOutcome` or `OutboxStatus` nor constructs `OutboxRow`,
  `OutboxPublishSummary`, or `KeiroMetrics`; it only passes `Maybe KeiroMetrics` through existing
  interfaces. `keiro-core` and `keiro-pgmq` have no API changes beyond their lockstep bounds.
  Evidence: the source audit found no affected constructors or record construction outside
  historical documentation, and Keiro's checked-in `0-13-to-0-14.md` guide and package changelogs
  identify those sites as the complete consumer migration surface.

- Observation: The compiler confirmed the 0.14 upgrade needs no Kioku source adaptation. Cabal
  downloaded and built `keiro-core-0.14.0.0` and `keiro-0.14.0.0`, then rebuilt `kioku-core`
  without an incomplete-pattern or missing-record-field diagnostic. The build still reports
  Keiro's existing deprecations for legacy `ReadModel` fields, `Eventual`, and `runQueryWith`;
  those APIs are outside the 0.14 terminal-rejection migration surface and remain available.
  Evidence: `nix develop -c cabal build kioku-core kioku-migrations` exited zero, followed by
  `All 24 tests passed` in `kioku-migrations-test` and `All 226 tests passed` in `kioku-test`.

- Observation: The first repository-wide test invocation reused a stale in-place `kioku-cli`
  archive compiled against Keiro 0.13 and failed to link against 0.14 symbols, even though Cabal
  had replanned and the focused 0.14 suites passed. This was generated build state, not a missing
  package edge or source incompatibility: `kioku-cli` does not import Keiro directly. Running
  `nix develop -c cabal clean` and rebuilding all packages from scratch removed the mixed archive;
  the clean CLI linked and all 53 CLI tests passed.
  Evidence: the failed linker named `_krzm0zi13...KeiroziReadModel...` symbols inside
  `libHSkioku-cli-0.4.1.0-inplace.a`; the clean `cabal build all` and subsequent full test command
  both exited zero.

- Observation: Final validation remained green for the complete 0.14 cohort and preserved the
  migration behavior delivered earlier in this plan.
  Evidence: the clean full run passed 125 API, 53 CLI, 24 migration, and 226 core tests;
  `nix flake check` passed treefmt and pre-commit; `nix fmt` changed no files; strict bug-report OKF
  validation reported `OK: 1 concepts (okf_version 0.2)`; every current Keiro Cabal reference is
  0.14.0.0; and `git diff --check` exited zero.


## Decision Log

- Decision: Treat BUG-1 as a valid component-isolation defect, but not as a regression introduced
  by migration `0011`.
  Rationale: The owning repository reproduced the exact `42P01` failure on PostgreSQL 17.10.
  Release tags `v0.1.0.0` through `v0.3.0.0` end at migration `0010`, which contains the same
  session-level `SET`; `v0.4.0.0` and `v0.4.1.0` add `0011` as the final such migration and `0012`
  does not restore the setting. There is no released last-working pg-migrate component.
  Date: 2026-08-19

- Decision: Correct released migration `0011` by adding `RESET search_path;` at its end; do not add
  migration `0013`.
  Rationale: A plain `SET` inside a committed transaction persists on the connection, while
  `RESET` restores the database, role, or connection-startup default when the transaction commits.
  Keeping setup and cleanup in `0011` makes session isolation part of the offending migration's
  own correctness: there is no successfully applied `0011` state in the corrected component that
  still relies on a later compensating migration. This deliberately prefers correctness over
  checksum compatibility.
  Date: 2026-08-19

- Decision: Keep `0011`'s opening `SET search_path` and add a persistent reset at the end instead
  of changing that opening statement to `SET LOCAL`.
  Rationale: The connection can already carry `kiroku, pg_catalog` from `0010` before `0011`
  starts. `SET LOCAL` would disappear at commit and reveal that prior leaked value. A final plain
  `RESET` changes the session value that survives commit and restores the configured default.
  Date: 2026-08-19

- Decision: Do not rewrite migrations `0001` through `0010` as part of this fix.
  Rationale: Correcting `0011`, the last pending offender in every current full plan, restores the
  boundary before `0012` and every host component. Rewriting the earlier files would expand one
  controlled 0.4.x checksum break into up to ten per database and would invalidate the exact-byte
  `SamePayload` evidence that keeps the deprecated but still-supported Codd cutover safe. This
  scope preserves that evidence without delegating `0011`'s own cleanup to another migration.
  Date: 2026-08-19

- Decision: Ship a one-time, idempotent ledger re-baseline for the withdrawn `0011` checksum and
  treat the next `kioku-migrations` release as 0.5.0.0-level breaking work.
  Rationale: pg-migrate correctly rejects a changed applied payload. Databases on 0.4.0.0 or
  0.4.1.0 therefore need an explicit operator action before `up` or `verify` can accept the
  corrected plan. The script will match only component `kioku`, migration `0011`, and the known
  withdrawn checksum, replace it with the corrected checksum, and be a no-op otherwise. The old
  and corrected payloads produce the same durable schema and data, so no forward schema
  convergence migration is required.
  Date: 2026-08-19

- Decision: Test behavior at the component boundary instead of adding a text-only ban on
  `SET search_path`.
  Rationale: A full-chain test catches any future Kioku migration that leaks session state after
  corrected `0011`, regardless of spelling, and proves the host-visible effect. Historical files
  before `0011` keep their bare `SET` bytes, so a blanket source grep would either fail forever or
  require a brittle allowlist without proving runtime isolation.
  Date: 2026-08-19

- Decision: Use a nonstandard database default (`host_app, pg_catalog`) in the regression rather
  than relying on PostgreSQL's usual `public` fallback.
  Rationale: This proves the fix restores host configuration rather than merely hard-coding a
  path that happens to work for the reproducer.
  Date: 2026-08-19

- Decision: Update ADR-10 rather than create a second migration-policy ADR.
  Rationale: [ADR-10](../adr/projections-live-in-the-kioku-schema.md) already owns the relevant
  rules: schema qualification, migration-first deployment, forward recovery, and the rejection of
  broad historical DDL rewrites. It must now distinguish that normal rule from the narrow,
  breaking correction of a known-unsafe released payload with an exact-checksum re-baseline. A
  second ADR would split one migration-governance boundary across two records.
  Date: 2026-08-19

- Decision: Rebase the plan's inventory assertions onto the current tree and upgrade
  `keiro-migrations` from `^>=0.13.0.0` to `^>=0.14.0.0` in the Kioku migrations library and test
  suite.
  Rationale: The user explicitly brought the newly released Keiro migration component into scope.
  Its only migration-plan delta is appended migration `0031`, so the upgrade is compatible with
  the composed-plan regression and requires exact, reviewable count and expected-ID updates.
  Date: 2026-08-21

- Decision: Preserve unrelated Kioku feature migration `0013` and forbid adding a new cleanup
  migration (which would now be `0014`).
  Rationale: `0013` landed independently after planning and is already part of the default branch.
  Reverting or renumbering it would discard unrelated completed work; it changes inventory counts
  but not the `0011` correction or ledger recovery.
  Date: 2026-08-21

- Decision: Make no additional ADR edit during final distillation.
  Rationale: Implementation followed ADR-10's already-recorded rule exactly: one known-unsafe
  released payload was corrected as a breaking change, the durable database outcome remained
  equivalent, both exact checksums are known, and operators receive a guarded re-baseline. No
  architecture boundary or recovery policy changed while executing the plan.
  Date: 2026-08-21

- Decision: Interpret “upgrade all Keiro packages” as upgrading every Keiro package Kioku already
  uses or constrains, without adding unused Keiro packages.
  Rationale: Lockstep requires `keiro`, `keiro-core`, `keiro-migrations`, and `keiro-pgmq` to share
  the 0.14 series. Adding `keiro-dsl`, `keiro-ops`, or `keiro-test-support` would enlarge Kioku's
  dependency surface without a consumer, build target, or user-visible capability.
  Date: 2026-08-21

- Decision: Treat the remaining Keiro upgrade as a bounds-and-documentation change unless the
  compiler identifies an affected API site.
  Rationale: The authoritative Keiro upgrade guide names every new constructor and record field;
  the source audit found none constructed or exhaustively matched by Kioku. Compilation with the
  repository's incomplete-pattern warnings remains the final proof.
  Date: 2026-08-21

- Decision: Do not create or update an ADR for the complete Keiro 0.14 cohort alignment.
  Rationale: The lockstep rule is the upstream package family's release constraint, and the current
  selected versions belong in Cabal bounds, changelogs, user baseline documentation, and this
  execution record. It does not change Kioku's architecture, ownership boundaries, persistence
  policy, or exported interface. The existing ADR-10 migration policy remains unchanged.
  Date: 2026-08-21


## Outcomes & Retrospective

Completed 2026-08-21. Migration `0011` now ends by resetting `search_path`, so the composed
`kiroku -> keiro -> kioku -> host` plan preserves the host database's configured namespace on the
same reused pg-migrate connection. The regression first failed at the host boundary with SQLSTATE
`42P01` and then passed after the reset, providing the intended negative/positive proof rather
than a source-only assertion.

The change deliberately replaces the released `0011` checksum with
`6c83d3f01f784d0d9395953d5bb1763b8eea6cd9439073df42f79775a85197a9`. The published, guarded
ledger fixup accepts only the withdrawn 0.4.x checksum, is a tested no-op on a second run, and does
not alter schema or data. All pre-Codd migration bytes and lock evidence remain untouched. The
Keiro dependency is now 0.14.0.0, so the verified composed inventory is 11 Kiroku, 31 Keiro, and
13 Kioku rows: 55 total, with 25 migrations after the Codd pin.

BUG-1 is fixed on the default branch, operator guidance distinguishes applied 0.4.x ledgers from
fresh, pending, and Codd-era databases, and the fixup is included in the source distribution.
Focused migration tests, repository-wide build and tests, strict OKF validation, Nix flake checks,
formatting, and whitespace validation all pass. The final ADR pass found that ADR-10 already
captures the implemented exception and its recovery constraints, so no additional architecture
record change was necessary.

Reopened 2026-08-21 at the user's request to finish the Keiro cohort upgrade. The migration package
was already on 0.14.0.0, but `kioku-core` still admitted only `keiro` and `keiro-core` 0.13, and the
optional PGMQ constraint still selected `keiro-pgmq` 0.13. Those three references now target
0.14.0.0, current dependency documentation names the real cohort, and both affected focused suites
pass. A clean repository build and all four test suites pass against the resolved Hackage releases;
the 55-row migration plan is unchanged. The repeat ADR pass found no durable Kioku architecture
change, and no work remains.


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
each contain `SET search_path TO kiroku, pg_catalog`; `0006`, `0012`, and `0013` do not. Migrations
`0012` and `0013` fully qualify their DDL but inherit the value left by `0011`, so the runner
reaches the next component with `kiroku, pg_catalog` still active. Released migration bytes are
normally immutable.
This plan makes a deliberate exception for `0011` because the migration's own successful outcome
is unsafe; the change is breaking and carries an explicit ledger re-baseline. Migrations `0001`
through `0010`, `0012`, `0013`, the manifest, and `kioku-migrations/migrations.lock` remain
byte-for-byte unchanged.

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
`keiro-migrations ^>=0.14.0.0` and `containers >=0.6 && <0.8`; the library dependency on
`keiro-migrations` also advances from `^>=0.13.0.0` to `^>=0.14.0.0`. The host SQL bytes can be
produced
with the already available `Data.Text.Encoding.encodeUtf8`, so no new `bytestring` test dependency
is necessary. This bound was verified against Hackage and the upstream
`keiro-migrations-0.14.0.0` tag. The existing pg-migrate 1.1.0.0 bound was likewise
verified against Hackage and upstream tag `v1.1.0.0`.

The rest of the Keiro cohort appears in two places. `kioku-core/kioku-core.cabal` declares
`keiro ^>=0.13.0.0` and `keiro-core ^>=0.13.0.0` in both its library and test suite.
`cabal.project` constrains optional integration package `keiro-pgmq ^>=0.13.0.0`; it is not in
Kioku's build closure today, but the constraint prevents a downstream project from resolving an
older optional stack. Keiro's own 0.13-to-0.14 upgrade contract says all existing Keiro references
must move in lockstep. Raise these remaining bounds to `^>=0.14.0.0`. Do not add dependencies on
`keiro-dsl`, `keiro-ops`, or `keiro-test-support` because Kioku does not consume them.

Keiro 0.14 adds terminal outbox rejection constructors and fields in the `keiro` package. The
repository audit must search for `PublishOutcome`, `PublishSucceeded`, `PublishFailed`,
`OutboxStatus`, `OutboxRow`, `OutboxPublishSummary`, and direct `KeiroMetrics` construction. Kioku
contains none of those adaptation sites: it carries `Maybe KeiroMetrics` values but does not build
the record. Therefore this extension should require no Haskell source edit. The build and tests,
including incomplete-pattern warnings, are the authoritative confirmation.

No Kioku migration identity is added, but the Keiro 0.14 upgrade appends `keiro/0031`. The final
totals are therefore 55 rows in the full plan, 13 in the Kioku component, 31 in the Keiro
component, 25 in the post-Codd-pin forward suffix, and 55 `AlreadyApplied` results on a repeated
run. `expectedForwardMigrationIds` gains `keiro/0031` before the Kioku suffix and continues to end
at `kioku/0013-partition-aware-fts-index`, while
`forwardMigrationEffectCountStatement` remains six. The Codd cutover guide at
`docs/user/upgrading-to-pg-migrate.md` must describe the 25-row suffix: five Kiroku rows (`0007`
through `0011`), seventeen Keiro rows (`0015` through `0031`), and three Kioku rows (`0011`
through `0013`), ending at 55 total. `docs/user/getting-started.md` and
`docs/user/upgrading-to-the-kioku-schema.md` must use the final 11/31/13 and 55-row counts.
Historical release sections in changelogs remain historical; the correction and operator action
go under a new `Unreleased` heading.

The released 0.4.x `0011` checksum is
`eee9cd252b32b563c50f8457596347fff1b2e4d3ea4dafe5b45043e991624192`. After editing `0011`, compute
the corrected exact-byte checksum and place both values in a new guarded script at
`kioku-migrations/ledger-fixups/2026-08-19-rebaseline-0011-checksum.sql`. Add
`ledger-fixups/*.sql` to the package's `extra-source-files` so the operator artifact is published.
The script changes only an applied `pgmigrate.migrations` row whose component, migration name, and
checksum all match the withdrawn payload. It must reject a missing default ledger table with a
clear message, be safe to run twice, and explain how to adapt the schema name when the host uses a
nondefault `LedgerConfig`. Unlike the Kiroku precedent, no forward convergence migration is needed:
old and corrected `0011` produce the same durable catalog and data, and the withdrawn session value
ceased to exist when its runner connection closed.

The relevant local architecture decision is
[ADR-10](../adr/projections-live-in-the-kioku-schema.md). It says Kioku-owned runtime SQL names
relations explicitly rather than relying on host connection search paths, requires migration-first
deployment and forward recovery, and rejects broadly rewriting `0001` through `0011` to change the
schema layout. This plan revision updates ADR-10 to distinguish that normal immutability rule from
one narrow exception: a released migration whose successful execution is itself unsafe may be
corrected as an explicit breaking change when the exact withdrawn checksum is known, the durable
old and corrected outcomes are equivalent or converged, and operators receive a guarded
re-baseline. No other local ADR governs this session-cleanup defect.


## Plan of Work

### Milestone 1: prove and repair the composed-plan boundary

First raise the library's `keiro-migrations` bound to `^>=0.14.0.0`, then extend the test stanza
with direct `keiro-migrations ^>=0.14.0.0` and `containers >=0.6 && <0.8` dependencies. Update the
existing full-plan expectations for appended Keiro migration `0031`: 55 total rows, 25 post-Codd
forward rows, 31 Keiro rows, and `keiro/0031` immediately before the Kioku suffix in
`expectedForwardMigrationIds`. In `kioku-migrations/test/Main.hs`, add a group for
migration-session isolation
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

Before correcting `0011`, run this focused test once and record the negative proof in this
plan's Surprises & Discoveries section. It must fail with `DatabaseSessionFailed`, SQLSTATE
`42P01`, and `relation "host_table" does not exist`. Do not commit that red state. Then edit
`kioku-migrations/migrations/0011-kioku-memory-space-partition.sql` itself. Keep its opening
session-scoped `SET`, because it supplies the unqualified names inside the migration, and append an
explanatory comment plus `RESET search_path;` after its final DDL statement. The comment must say
that plain `SET` survives transaction commit on pg-migrate's reused connection, that `0010` may
already have supplied the same leaked value, and that this final reset restores the database/role
default for `0012` and later components. Do not replace the opening statement with `SET LOCAL`, do
not add a cleanup migration, and do not edit the Kioku manifest or `migrations.lock`.

Rerun the exact composed-plan case and the full `kioku-migrations` suite. The same case that failed
must now pass. The existing plan-count, Kiroku-adoption, Codd-import, expected-forward-ID, and
six-effect assertions must reflect only the Keiro 0.14 inventory addition. The milestone is
complete when the regression passes, the manifest integrity test still reports 13 Kioku
migrations, the Codd rehearsal still imports 30 historical rows and applies the 25-row forward
suffix, and the suite ends green.

### Milestone 2: make the checksum break explicit and recoverable

Compute the corrected SHA-256 only after the final SQL comments and reset are stable. Create
`kioku-migrations/ledger-fixups/2026-08-19-rebaseline-0011-checksum.sql`, modelled on the Kiroku
BUG-1 precedent but self-contained for Kioku. The script runs in one transaction, resolves the
default `pgmigrate.migrations` table with `to_regclass`, raises if the table is absent, and updates
only the row satisfying all of these facts: component `kioku`, migration
`0011-kioku-memory-space-partition`, status `applied`, and checksum equal to the withdrawn digest
recorded above. It replaces that checksum with the corrected digest. Zero matching rows is an
informative no-op, one matching row is success, and more than one is impossible under the ledger's
primary key. The header explains who must run it, how a custom ledger schema changes the script,
why schema convergence is unnecessary, and why this narrow script is not permission to bypass
other checksum mismatches. Add `ledger-fixups/*.sql` to `extra-source-files`.

Extend `kioku-migrations/test/Main.hs` with a ledger re-baseline case that uses the actual script,
not a reimplementation. Apply the corrected plan to an ephemeral database, replace only its
`kioku/0011-kioku-memory-space-partition` ledger checksum with the known withdrawn digest to model
a 0.4.x database, and prove strict verification reports `MigrationChecksumMismatch`. Execute the
checked-in script, prove strict verification succeeds without applying any migration, execute the
script again, and prove it is a no-op. Assert the 55 ledger rows and the qualified Kioku catalog are
unchanged throughout. Also test that the script fails clearly when the expected ledger table does
not exist. Read the file as text with existing `text` APIs; no new test dependency is needed.

The milestone is complete when the source-distribution file list contains the fixup, the focused
suite proves the mismatch-before/success-after/idempotent sequence, the manifest still contains 13
Kioku migrations, and `migrations.lock` still has no diff.

### Milestone 3: publish the breaking contract and validate the repository

Add an `Unreleased` / `Breaking Changes` and `Fixed` entry as appropriate to `CHANGELOG.md`,
`kioku-migrations/CHANGELOG.md`, and `kioku-migrate/CHANGELOG.md`. State that the corrected
`kioku/0011-kioku-memory-space-partition` now restores the configured host search path inside its
own transaction, that its checksum changed from the withdrawn digest, that 0.4.0.0/0.4.1.0
databases must run the shipped ledger re-baseline before `up` or `verify`, and that databases with
`0011` still pending need no special action. State that the next release must use the breaking
0.5.0.0 series. Also record the `keiro-migrations` 0.14.0.0 dependency upgrade and appended
`keiro/0031` row. Leave historical 0.4.x sections untouched and do not change Kioku package
versions as part of this implementation-only plan.

Update `docs/user/upgrading-to-the-kioku-schema.md` with the 0.4.x-to-corrected-payload preflight
and the exact command for the re-baseline, and report the final 55-row total. Bring
`docs/user/upgrading-to-pg-migrate.md` up to the current 25-row forward suffix and 55-row total;
make clear that a Codd-era database has no applied Kioku `0011` before the cutover and therefore
does not run the re-baseline before its first corrected `up`. `docs/user/getting-started.md` needs
no count change, but add a short pointer to the upgrade guide near its checksum explanation so an
operator with a 0.4.x ledger does not mistake the intentional mismatch for corruption.

Move BUG-1 in
`docs/bug-reports/migration-0011-session-search-path-leaks-into-later-migrations.md` from
`confirmed` to `fixed`, set `fixedVersion: unreleased`, and add a `resolution` that names migration
`0011`'s corrected payload, the breaking checksum, the ledger fixup, and the composed-plan
regression. Replace the old append-a-cleanup-migration fix direction throughout the body. Update its
current-content provenance and review metadata according to `docs/bug-reports/profile.dhall`, then
regenerate `docs/bug-reports/index.md`, append a `Fix` entry to `docs/bug-reports/log.md`, and run
strict profile enforcement.

Finish by running the focused migration suite, every repository test inside the Nix development
shell, the flake checks, and whitespace validation. Update Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective with exact evidence. ADR-10 already records the narrow
released-payload correction policy established by this revision; update it again only if
implementation changes that policy. Because this repository's ADR directory is not a profiled Mori
bundle and has no dedicated ADR recipe, validate its established filesystem convention by
confirming ADR-10's stable `docId`, advanced timestamp, matching log entry, links, and whitespace.
The milestone is complete when all checks pass, 0.4.x recovery is fully documented, and the only
database behavior difference is that corrected `0011` no longer leaks session state.

### Milestone 4: align the complete Keiro dependency cohort

Raise `keiro` and `keiro-core` in both stanzas of `kioku-core/kioku-core.cabal` from
`^>=0.13.0.0` to `^>=0.14.0.0`. Raise the optional `keiro-pgmq` constraint in `cabal.project` to
`^>=0.14.0.0`, and update its cohort comment so it no longer describes Keiro 0.13. Keep the
already-completed `keiro-migrations ^>=0.14.0.0` changes. Do not add unused Keiro packages.

Update the root and `kioku-core` Unreleased changelogs to describe the full lockstep cohort and the
consumer-visible outbox additions. State that Kioku has no affected exhaustive match or direct
record construction, so its source and exported API are unchanged. Correct the current framework
baseline in `README.md` and `docs/user/library-api.md`; do not rewrite historical release notes or
BUG-1's historical Keiro 0.13 reproduction.

Run a solver/build check first, then the `kioku-core` and `kioku-migrations` test suites, because
they exercise the runtime and migration halves of the cohort. Finish with the complete repository
build and tests, Nix flake checks, formatting, strict BUG-1 bundle validation, and whitespace
checks. The milestone is complete when no 0.13 Keiro bound remains outside historical records, the
solver selects the released 0.14 packages, every check passes, and the final ADR distillation
finds either a recorded durable change or an explicit no-change result.


## Concrete Steps

Run all commands from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kioku
git status --short
```

Preserve unrelated working-tree changes. In particular, never reset or rewrite a file merely
because it was already modified before this plan began.

After adding the test dependencies and the composed-plan regression, but before correcting
`0011`, run:

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

Confirm the exact withdrawn checksum from both released tags before editing:

```bash
git show v0.4.0.0:kioku-migrations/migrations/0011-kioku-memory-space-partition.sql \
  | shasum -a 256
git show v0.4.1.0:kioku-migrations/migrations/0011-kioku-memory-space-partition.sql \
  | shasum -a 256
```

Both commands must print:

```text
eee9cd252b32b563c50f8457596347fff1b2e4d3ea4dafe5b45043e991624192  -
```

Edit `0011` so its final executable statement is:

```sql
RESET search_path;
```

Do not run `just new-migration`. Compute the corrected checksum after the file is final, use it in
the ledger fixup, and verify the migration inventory did not change:

```bash
shasum -a 256 kioku-migrations/migrations/0011-kioku-memory-space-partition.sql
git diff --exit-code -- kioku-migrations/migrations/manifest
git diff --exit-code -- kioku-migrations/migrations.lock
git diff --name-only -- kioku-migrations/migrations
```

The final command must name only
`kioku-migrations/migrations/0011-kioku-memory-space-partition.sql`. Then rerun the focused suite:

```bash
nix develop -c cabal test kioku-migrations:kioku-migrations-test \
  --test-show-details=direct
```

The command must end with all `kioku-migrations` cases passing, including the fresh composed-plan
boundary and the exact-checksum ledger re-baseline sequence.

After updating BUG-1, its index, and its log, validate the profiled bundle:

```bash
okf index docs/bug-reports --write
okf log add docs/bug-reports \
  --kind Fix \
  --message "BUG-1 is fixed by correcting migration 0011, shipping its ledger re-baseline, and adding a composed-plan regression." \
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
rg -n '^timestamp:|^docId:' docs/adr/projections-live-in-the-kioku-schema.md
rg -n 'ADR-10|ExecPlan 32' docs/adr/log.md docs/adr/projections-live-in-the-kioku-schema.md
nix develop -c cabal build all
nix develop -c cabal test all --test-show-details=direct
nix flake check
git diff --check
git status --short
```

For the full Keiro-cohort extension, verify the remaining references and affected API surface,
then run focused validation before repeating the final commands above:

```bash
rg -n --glob '*.cabal' --glob 'cabal.project*' '\bkeiro(?:-[a-z0-9-]+)?\b' .
rg -n 'PublishSucceeded|PublishFailed|PublishOutcome|OutboxStatus|OutboxRow|OutboxPublishSummary|KeiroMetrics' \
  kioku-core kioku-api kioku-cli kioku-migrate kioku-migrations
nix develop -c cabal build kioku-core kioku-migrations
nix develop -c cabal test kioku-core:kioku-test kioku-migrations:kioku-migrations-test \
  --test-show-details=direct
```

The first search must show 0.14.0.0 for `keiro`, `keiro-core`, `keiro-migrations`, and
`keiro-pgmq`. The second may find `KeiroMetrics` type plumbing but must find no direct record
construction or affected outbox match. Both focused suites must pass before repository-wide
validation.

At completion, a commit implementing this plan must use a Conventional Commit subject and both
required trailers. For example:

```text
fix(migrations)!: contain migration 0011 search path state

ExecPlan: docs/plans/32-restore-host-search-path-after-kioku-migrations.md
Intention: intention_01m0e0jgvzem4s6jb4xwwgcy5y
```


## Validation and Acceptance

Acceptance is behavioral, not merely a source inspection.

On a fresh ephemeral database whose default `search_path` is `host_app, pg_catalog`, the composed
`kiroku -> keiro -> kioku -> host` test plan must finish in one invocation. The host migration
must use the unqualified name `host_table`, and a qualified catalog assertion must show its new
column. Reverting only the final reset from corrected `0011` must make this exact test fail with
SQLSTATE `42P01`; restoring it must make the test pass. This negative/positive pair proves the test
detects the reported defect and that the correction restores configuration rather than hard-coding
`public`.

The manifest must still contain 13 Kioku migrations, and verification of a fresh full plan must
report 55 applied migrations with no pending, unknown, failed, or checksum-mismatched row. The
Kiroku-only adoption test must still skip the 11 already-applied Kiroku rows and reach the same
55-row verified plan. The Codd rehearsal must still import exactly 30 historical rows without
executing them, apply exactly 25 forward migrations ending at Kioku `0013`, report 55 applied
rows, and make its second `up` a 55-row no-op.

Only `kioku-migrations/migrations/0011-kioku-memory-space-partition.sql` may change within the
migration directory. Migrations `0001` through `0010`, migrations `0012` and `0013`, the manifest,
and `kioku-migrations/migrations.lock` must have no diff. The corrected `0011` checksum must differ
from the withdrawn digest. A database modelled with the withdrawn digest must fail strict
verification before the fixup, pass after it without applying DDL, and remain verified after the
fixup is run a second time. This proves the breaking checksum obligation is explicit and
recoverable rather than silently bypassed.

BUG-1 must validate with `status: fixed`, `fixedVersion: unreleased`, and a resolution naming the
corrected `0011`, checksum re-baseline, and regression. The generated bug-report index must carry
the corrected description, the bundle log must record the fix, and ADR-10 must contain the narrow
released-payload correction policy. Current user documentation must consistently report the final
11/31/13 component counts and 55 total, and must distinguish 0.4.x ledgers from
pending/fresh `0011` paths.

Finally, `nix develop -c cabal test all --test-show-details=direct`, `nix flake check`, and
`git diff --check` must all exit zero. Record concise transcripts and the ADR distillation result
in this living plan before marking Progress complete.

The dependency extension additionally requires all current Kioku references to `keiro`,
`keiro-core`, `keiro-migrations`, and `keiro-pgmq` to select `^>=0.14.0.0`. Cabal must solve and
compile without `allow-newer` or source overrides. No new incomplete-pattern warning may appear,
and the existing 55-row migration behavior must remain unchanged. Current user documentation must
identify Keiro 0.14 as the supported baseline; historical changelog and reproduction statements
remain unchanged.


## Idempotence and Recovery

The corrected migration is idempotent as session behavior: running `RESET search_path` when the
path is already at its configured default makes no catalog or data change. For a database where
`0011` is pending, pg-migrate applies the corrected payload normally and records only its corrected
checksum. Never delete an applied ledger row to force `0011` to run again; a closed historical
connection has no session state left to repair.

The ledger re-baseline is idempotent because it matches only the exact withdrawn checksum. Its
second run changes zero rows. It must be run only after a verified backup and before the corrected
binary's first `up` or `verify` on a database that already applied 0.4.x `0011`. If it reports a
missing ledger table, check the configured ledger schema and adapt the explicit table reference;
do not broaden the predicate. If it reports no matching row, determine whether `0011` is pending,
already corrected, or carries an unexpected checksum before proceeding.

Every database mutation in the regression happens in a dedicated ephemeral database. Its
`ALTER DATABASE ... SET search_path` setting disappears with that database, even if the test fails.
The corrected statement changes only connection-local state; `0011`'s durable schema and data
effects are otherwise identical. If corrected `0011` fails before commit, pg-migrate rolls back its
DDL, reset, and ledger insert together. Once this corrected payload ships, treat its bytes as the
new immutable history; any later defect is repaired forward rather than by changing `0011` again.
The existing workaround for older uncorrected releases remains to rerun the plan: the leaking
Kioku migrations are then already applied, so the pending host migration starts on a fresh
connection. That workaround is recovery for old artifacts, not the corrected contract.

Changing a transitive package cohort can leave an existing `dist-newstyle` with in-place archives
compiled against the previous package identity. If a local incremental link names 0.13 Keiro
symbols after the bounds select 0.14, run `nix develop -c cabal clean` and rebuild; this deletes
only generated Cabal artifacts. A clean checkout does not carry that state. Do not add a redundant
direct Keiro dependency merely to repair an incremental cache.


## Interfaces and Dependencies

There is no new Kioku production Haskell interface. The production dependency changes raise
`keiro`, `keiro-core`, and `keiro-migrations` from the 0.13 series to `^>=0.14.0.0`; the project
constraint for optional `keiro-pgmq` moves to the same series. Keiro migration `0031` is appended
without changing the component API. Keiro's exported outbox types gain terminal-rejection
constructors and fields, but Kioku does not match or construct them; downstream applications that
also use those Keiro APIs must follow Keiro's 0.13-to-0.14 upgrade contract.
`Kioku.Migrations.kiokuMigrations :: Either DefinitionError MigrationComponent` and
`Kioku.Migrations.kiokuMigrationPlan :: Either PlanError MigrationPlan` retain their existing
types and the same migration identities. The observable production interface change is that
`kioku/0011-kioku-memory-space-partition` has a corrected exact-byte payload and leaves the shared
connection at its configured default `search_path`. The operator artifact
`kioku-migrations/ledger-fixups/2026-08-19-rebaseline-0011-checksum.sql` is new, but it is not part
of the embedded migration plan and never runs automatically.

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

Raise the library's `keiro-migrations` bound and add `containers >=0.6 && <0.8` plus
`keiro-migrations ^>=0.14.0.0` to the `kioku-migrations-test` stanza in
`kioku-migrations/kioku-migrations.cabal`. Use the existing
`hasql`, `text`, `pg-migrate`, and `kiroku-store-migrations` test dependencies for setup,
execution, and assertions.

Also raise `keiro` and `keiro-core` in the `kioku-core` library and test stanzas, plus the
`keiro-pgmq` project constraint, to `^>=0.14.0.0`. No new package dependency or source import is
needed.

Keep the test helper functions private to `kioku-migrations/test/Main.hs`. At minimum, the end
state needs an assertion such as `testHostSearchPathRestored :: Assertion`, a helper that builds
the four-component `MigrationPlan`, a statement returning `quote_ident(current_database())`, and
a qualified statement that proves `host_app.host_table.migrated` exists. The ledger test also
needs private statements that install the withdrawn checksum fixture, read back the `0011` ledger
row, and prove the qualified Kioku catalog remains present. No test helper becomes a library
export.


## Revision Note

Revised 2026-08-19 after reconsidering the long-term safety tradeoff. The original plan preserved
all released checksums by appending cleanup migration `0013`. This revision instead makes the
offending `0011` migration self-contained by restoring the host search path before its own commit,
accepts the resulting 0.4.x checksum break, adds an exact-checksum ledger re-baseline and recovery
test, preserves the still-supported Codd evidence for `0001` through `0010`, kept the then-current
plan at 53 rows, and records the narrow released-payload correction policy in ADR-10. The change prefers a
correct migration boundary over compatibility with a known-unsafe payload while keeping the
operator cost explicit and bounded.

Revised 2026-08-21 at implementation start because the default branch had since gained unrelated
Kioku feature migration `0013-partition-aware-fts-index.sql`, and because the user added the newly
released `keiro-migrations` 0.14.0.0 upgrade to this plan. Inventory, Codd-forward-suffix, tests,
and documentation now target 11 Kiroku, 31 Keiro, and 13 Kioku migrations: 55 total and 25 after
the Codd pin. The plan still corrects only released Kioku migration `0011` and forbids adding a
cleanup migration.

Revised again 2026-08-21 after the user requested that the entire Keiro package cohort be upgraded,
not only its migration component. The plan now aligns every Keiro package Kioku already uses or
constrains (`keiro`, `keiro-core`, `keiro-migrations`, and `keiro-pgmq`) at 0.14.0.0, audits the
terminal outbox-rejection API, updates current baseline documentation, and repeats focused and
repository-wide validation. It deliberately does not add the three unused Keiro packages.
