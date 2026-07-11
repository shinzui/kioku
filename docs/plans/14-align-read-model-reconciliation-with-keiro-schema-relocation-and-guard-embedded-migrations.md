---
id: 14
slug: align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations
title: "Align read-model reconciliation with keiro schema relocation and guard embedded migrations"
kind: exec-plan
created_at: 2026-07-07T14:58:23Z
intention: "intention_01kwyhabypepdt1mwemmf0dvqa"
master_plan: "docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md"
---

# Align read-model reconciliation with keiro schema relocation and guard embedded migrations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kioku stores its data in PostgreSQL and answers queries through "read models" — SQL
projection tables, each registered in a small registry table named `keiro_read_models` with
a version number and a shape hash. When the code's expected version and the registered row
disagree, every query for that model fails closed with a `ReadModelStaleSchema` error. This
is a deliberate safety property, but today the machinery that keeps the registry current is
a lie in three ways, and this plan makes it truthful:

First, the only thing that ever fixes a stale registry row is a hand-written SQL migration
(`kioku-migrations/sql-migrations/2026-07-03-14-37-18-kioku-session-readmodel-registry-bump.sql`)
that duplicates model names and version literals by hand. The Haskell list that claims to
drive reconciliation (`kiokuReadModelSchemas` in `kioku-core/src/Kioku/ReadModel.hs`) is
consumed by no code anywhere — not in this repo, not in the registered dependents kikan and
shikigami. The next time any read model's version bumps, every query will fail closed in
production until someone hand-writes another migration. After this plan, a code-side
reconciler derived from `kiokuReadModelSchemas` runs at the end of every `kioku-migrate`
invocation and upserts every registry row to the identity the compiled code expects. No
future version bump ever needs a hand-written registry migration again.

Second, that hand-written migration hardcodes `SET search_path TO kiroku, public` because
the pinned version of the keiro framework creates `keiro_read_models` inside the `kiroku`
schema. Keiro's development head has already relocated the table into a dedicated `keiro`
schema. The moment kioku bumps its keiro pin, this migration fails with `undefined_table`
on every fresh database, because keiro's bootstrap (which sorts earlier) creates the table
only in `keiro`. After this plan, the migration locates the table dynamically wherever it
lives, and a test proves it against both physical layouts, so the future pin bump cannot be
broken by this file.

Third, kioku's migrations are embedded into the binary at compile time with Template
Haskell (`$(embedDir "sql-migrations")` in `kioku-migrations/src/Kioku/Migrations.hs`).
Adding a new `.sql` file does not trigger recompilation, so a binary can silently ship
without a migration. After this plan, a test compares the embedded list against the actual
directory on disk and fails loudly when they diverge, and the `just new-migration`
scaffolder touches `Migrations.hs` automatically.

Observable outcome: `cabal test all` includes new tests that (a) fail before these fixes
and pass after, including one that demonstrates the fail-closed `ReadModelStaleSchema`
outage and its automatic repair, and (b) `just migrate` run twice against a dev database is
a no-op the second time and always leaves the registry rows at the code's current identity.


## Progress

- [x] Milestone 1: rewrite the registry-bump migration body to be location-agnostic — 2026-07-11 (`3a55a9b`)
- [x] Milestone 1: add the `kioku-migrations-test` suite with the layout SQL test (three layouts, not two) and the fresh-database test — 2026-07-11 (`3a55a9b`; restoring the old body fails the keiro case with `42P01`)
- [x] Milestone 2: add `reconcileReadModelRegistry` to `kioku-core/src/Kioku/ReadModel.hs` and fix the module haddock — 2026-07-11 (`68efc7b`)
- [x] Milestone 2: wire the reconciler into the `kioku-migrate` executable — 2026-07-11 (`68efc7b`; **the executable moved to a new `kioku-migrate` package — see Surprises**)
- [x] Milestone 2: add `kioku-core/test/Kioku/ReadModelReconcileSpec.hs` proving stale-row fail-closed then repair — 2026-07-11 (`68efc7b`)
- [x] Milestone 3: export `embeddedKiokuMigrationFiles` and add the disk-vs-embedded staleness test — 2026-07-11 (`cfe3623`)
- [x] Milestone 3: make `just new-migration` **edit** (not touch) `Migrations.hs` — 2026-07-11 (`cfe3623`)
- [x] Milestone 4: run the full validation sweep (build, all tests, `just migrate` twice) and update docs/user/library-api.md — 2026-07-11
- [x] Milestone 4: fill in Outcomes & Retrospective — 2026-07-11


## Surprises & Discoveries

These were found while authoring the plan (2026-07-07) and shaped the design. Keep adding
to this section during implementation.

- codd (v0.1.8, source at `/Users/shinzui/Keikaku/hub/haskell/codd-project/codd`) keys
  applied migrations by FILENAME ONLY and never checksums bodies. Evidence:
  `collectPendingMigrations` in `src/Codd/Internal.hs` reads
  `SELECT name, no_txn_failed_at IS NULL, ... FROM codd.sql_migrations` and
  `listPendingFromMemory` filters the provided list with `migrationName mig \`notElem\`
  migNamesFullyApplied`. There is no complaint about applied names missing from the
  provided list either. Consequence: editing an already-applied migration's body in place
  is mechanically safe — codd will simply never re-run it on databases that recorded it.
  This is why the fix for the search_path problem can (and must) be an in-place body edit
  rather than a new migration; see the Decision Log.
- keiro HEAD (`/Users/shinzui/Keikaku/bokuno/keiro`, commit `f562b9e`) not only relocated
  `keiro_read_models` from the `kiroku` schema to a dedicated `keiro` schema
  (bootstrap `keiro-migrations/sql-migrations/2026-05-17-13-58-15-keiro-bootstrap.sql`
  does `CREATE SCHEMA IF NOT EXISTS keiro` and `CREATE TABLE ... keiro.keiro_read_models`),
  it also RENAMED every keiro migration file from sentinel timestamps
  (`2026-05-17-00-00-00-...`) to real UTC timestamps. Existing databases are upgraded via
  `keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql` plus a
  ledger fixup. Consequence: a kioku pin bump is a full cohort-migrate event (see the
  `cohort-migrate` skill at `~/.claude/skills/cohort-migrate/SKILL.md`), and this plan's job
  is only to make kioku's own migration and reconciler survive it, not to perform it.
- keiro's `Keiro.ReadModel.Schema` exposes `markLive :: Text -> Int -> Text -> Eff es
  ReadModelMetadata` at BOTH the pinned commit (`f1d67a0`) and HEAD, implemented as an
  upsert that sets `version`, `shape_hash`, `status`, and `last_built_at`. Its SQL is
  compiled into keiro, so it targets the table wherever the linked keiro version puts it
  (unqualified name + search_path at the pin; schema-qualified `keiro.keiro_read_models` at
  HEAD). Consequence: a reconciler built on keiro's own API is pin-bump-proof by
  construction, which is the decisive argument for the code-side reconciler.
- `file-embed` 0.0.16's `embedDir` already calls `qAddDependentFile` on every file it
  embeds (`pairToExp` in `Data/FileEmbed.hs`), so EDITS and DELETIONS of existing files do
  trigger recompilation. Only files ADDED to the directory are invisible. GHC's dependent-
  file mechanism cannot watch a directory, which is why the guard must be a runtime test.
- The stale-schema check is per-query with no process-level caching: keiro's
  `ensureReadModel` does `lookupReadModel` on every `runQuery` call, and `registerReadModel`
  inserts a row only when none exists — `ON CONFLICT (name) DO UPDATE SET name =
  EXCLUDED.name` deliberately never bumps version or shape_hash of an existing row. This
  confirms Finding 1's mechanism and means the reconcile-then-requery test needs no process
  restart.

Found during implementation (2026-07-11):

- **The Decision Log's "zero cycle risk" claim was false, and it cost the plan a package.**
  The plan reasoned that because nothing depends on the `kioku-migrate` executable, giving
  it a `kioku-core` dependency could not close the `kioku-core:test → kioku-migrations:test-support`
  loop. The *component* graph is indeed acyclic — but cabal's solver does cycle detection at
  PACKAGE granularity, and it rejected the whole build plan outright:
  `rejecting: kioku-core:*test (cyclic dependencies; conflict set: kioku-core, kioku-migrations)`.
  Not a warning, not a per-component fallback: `cabal build` could not solve at all.
  Moving `test-support` into its own package does not help (the cycle just gets longer), so
  the executable had to leave `kioku-migrations` entirely. It now lives in a new
  `kioku-migrate` package (`kioku-migrate/kioku-migrate.cabal`, added to `cabal.project`),
  which depends on both `kioku-migrations` and `kioku-core` while `kioku-migrations` stays
  dependency-clean. The executable name, the `just migrate` recipe, and every consumer's
  entry point are unchanged. **This is the same failure shape EP-4 and EP-5 recorded: a
  plan's reasoning about a build system it never ran is a hypothesis.**
- **`Kioku.Migrations.TestSupport` already passes `keiro` in `namespacesToCheck`**
  (`noCheckCoddSettings ["kiroku", "keiro", "kioku", "public"]`), so half of the pin-bump
  follow-up this plan's Validation section flagged is already done. `Justfile`'s
  `CODD_SCHEMAS=kiroku` still needs `keiro` added when the pin moves.
- **The plan's hasql calls were wrong for the pinned version.** Step 3 prescribed
  `Hasql.Connection.acquire` + `Hasql.Session.run` + `Hasql.Session.sql`. The version in
  this project has neither `Session.run` nor `Session.sql`: raw scripts go through
  `Connection.use conn (Session.script :: Text -> Session ())`, and `preparable` takes the
  SQL as `Text`, not `ByteString`. `Kioku.SchemaSpec` was the correct reference, not the
  plan.
- **The layout test grew a third case.** The plan specified two layouts (`kiroku`, `keiro`);
  `public` is a third real one (long-lived dev databases), and the rewritten body claims to
  handle it, so it is now asserted. Running the OLD body against all three is what shows the
  test is honest: it passes on `kiroku` and `public` (both were on the old `search_path`)
  and fails only on `keiro`, with exactly the predicted
  `42P01 relation "keiro_read_models" does not exist`.
- **`just migrate`'s `touch kioku-migrations/kioku-migrations.cabal` never did anything** and
  has been removed. It was there to force the TH re-embed; per EP-5's discovery, GHC's
  recompilation check is content-based, so touching any file — the cabal file least of all —
  cannot invalidate the splice. Leaving it in would have kept implying a guarantee that did
  not exist. `just new-migration` now rewrites the `-- Last added:` line in `Migrations.hs`,
  which is a real byte change, and fails loudly if that line is missing.
- **The ephemeral-Postgres startup contention EP-5 warned about is real here too.** One
  full-suite run failed with `TimeoutError (ConnectionTimeout {durationSeconds = 60})` in an
  unrelated `IdempotencySpec` case and passed on rerun. Two more database-backed cases were
  added by this plan.


## Decision Log

- Decision: Fix stale-registry reconciliation with a code-side reconciler
  (`reconcileReadModelRegistry` in `kioku-core`, driven by `kiokuReadModelSchemas` and
  implemented on keiro's `lookupReadModel` / `registerReadModel` / `markLive`), and retire
  the hand-written-SQL-per-bump pattern for all FUTURE version bumps.
  Rationale: keiro's registry statements are compiled into whatever keiro version kioku
  links against, so they always target `keiro_read_models` where that version physically
  put it — the reconciler cannot be broken by the pending schema relocation, unlike any SQL
  we write ourselves. It derives names/versions/hashes from the same `ReadModel` values the
  queries use, so it can never disagree with the code (sibling plans that bump versions are
  covered automatically). codd imposes no constraint against running code after
  `applyMigrationsNoCheck`; the `kioku-migrate` executable already exists as the single
  place both `just migrate` and process-compose go through. The alternative — a test that
  cross-checks the code list against the latest reconciliation SQL — was rejected because
  it still requires a human to hand-write a migration per bump; it merely converts the
  production outage into a test failure plus manual work, and the SQL it checks remains
  fragile against the schema relocation.
  Date: 2026-07-07.
- Decision: `kiokuReadModelSchemas` stays, becomes load-bearing (the reconciler's input),
  and its haddock is corrected to describe the reconciler that actually consumes it.
  Rationale: the alternative (delete it) died with the decision above; a documentation-only
  API with no consumer was the defect, not the list itself.
  Date: 2026-07-07.
- Decision: Fix the pin-bump fragility of
  `2026-07-03-14-37-18-kioku-session-readmodel-registry-bump.sql` by EDITING ITS BODY IN
  PLACE (same filename) to locate `keiro_read_models` via `to_regclass` across the `keiro`,
  `kiroku`, and `public` schemas, instead of adding a new migration.
  Rationale: a new migration cannot fix this — on a fresh database with a future keiro pin,
  codd applies the OLD file first and it errors with `undefined_table` before any newer
  file runs. codd v0.1.8 keys applied migrations by filename only and never checksums
  bodies (verified in `Codd/Internal.hs`, see Surprises & Discoveries), so databases that
  already recorded this filename never re-run the new body: the edit is provably identical
  in effect there. On fresh databases with the pinned keiro it performs the same UPDATE
  against the same table (found in `kiroku`). The only behavioral change is on fresh
  databases with a relocated keiro, where the old body errors and the new body succeeds —
  which is the point. This is a narrow, justified exception to the cohort-migrate skill's
  "never edit an applied migration" invariant: that invariant exists to prevent silently
  skipping schema changes, and this edit changes no effect on any database where the old
  body ever ran successfully. A test proves the body against both physical layouts.
  Date: 2026-07-07.
- Decision: Reconciler semantics per model: row absent → `registerReadModel` (inserts a
  live row at current identity); row present with matching version and shape hash → leave
  completely untouched (preserves status); row present with differing identity →
  `markLive name version shapeHash` (bumps identity, sets status to live, stamps
  `last_built_at`).
  Rationale: this reproduces exactly what the hand-written migration did (`SET version = 3,
  shape_hash = ..., status = 'live', last_built_at = now()` guarded by "identity differs").
  It is safe because kioku's read-model migrations are additive by policy (columns added
  with defaults; existing rows stay correct for the newer version — see the haddock of
  `Kioku.ReadModel`), so advancing the registry guard needs no rebuild. Kioku does not use
  keiro's rebuild workflow (`markRebuilding` has no caller in this repo), so the theoretical
  case of flipping a mid-rebuild row to live does not arise; if a future non-additive
  reshape ever needs a rebuild, its own plan must rewrite the projected data in a migration
  before the reconciler runs, exactly as the old haddock warned.
  Date: 2026-07-07.
- Decision: Run the reconciler in the `kioku-migrate` executable
  (`kioku-migrations/app/Main.hs`) immediately after migrations apply — not in
  `Kioku.Migrations.TestSupport`, not at app startup in `Kioku.App`.
  Rationale: migration time is the semantically right moment (the registry is part of the
  schema's truth, and version bumps ship with migrations); app startup would make every
  host process (kioku-cli, kikan, shikigami workers) race to write the registry on boot.
  Placing it in `TestSupport` would require the `kioku-migrations:test-support` sublibrary
  to depend on `kioku-core`, creating a package-level dependency loop with
  `kioku-core:test → kioku-migrations:test-support` that cabal may or may not resolve
  per-component; the executable, which nothing depends on, carries the new `kioku-core`
  dependency with zero cycle risk. Tests that need reconciliation call
  `reconcileReadModelRegistry` directly. Library consumers that apply migrations via
  `runKiokuMigrations` instead of the executable must call it themselves — documented in
  Interfaces and Dependencies and in `docs/user/library-api.md`.
  Date: 2026-07-07.
  **SUPERSEDED 2026-07-11 as to placement; the reasoning above is wrong.** "The executable,
  which nothing depends on, carries the new `kioku-core` dependency with zero cycle risk" is
  false. Cabal's solver detects cycles at package granularity, not component granularity: with
  the executable inside `kioku-migrations`, `cabal build` refused to produce any plan at all
  (`rejecting: kioku-core:*test (cyclic dependencies; conflict set: kioku-core,
  kioku-migrations)`). Everything else in this decision stands — migration time is still the
  right moment, app startup would still have every host racing on boot, and `TestSupport`
  still must not depend on `kioku-core`. The executable simply had to move OUT of
  `kioku-migrations` into its own `kioku-migrate` package, which is free to depend on both.
  `kioku-migrations` stays dependency-clean, the binary name and `just migrate` are unchanged,
  and the cycle is gone.
- Decision: Guard the TH-embedded migration list with a runtime test (disk listing vs
  embedded names) in a new `kioku-migrations-test` suite, plus making `just new-migration`
  touch `Migrations.hs`; rejected `qAddDependentFile` on the directory and a custom
  `Setup.hs`.
  Rationale: GHC's dependent-file tracking works on files, not directories — `file-embed`
  already registers every embedded FILE (so edits/deletes recompile), and the only gap is
  new files, which no TH-side trick can see without a rebuild that the gap itself prevents.
  A custom `Setup.hs` would abandon `build-type: Simple` for all consumers of the package
  for marginal benefit. The test is simple, testable (delete a file from the embed by
  simulation, or add one without touching `Migrations.hs`, and watch it fail), runs in CI,
  and its failure message tells the developer the exact fix. The Justfile touch closes the
  common path proactively so the test rarely fires.
  Date: 2026-07-07.
- Decision: Prove the keiro-HEAD scenario by executing the rewritten migration body against
  a hand-built replica of keiro HEAD's physical layout in an ephemeral database, rather
  than by compiling kioku against keiro HEAD.
  Rationale: kioku cannot compile against keiro HEAD today — keiro HEAD requires a newer
  kiroku than kioku's pin (`4312aa8`), so a real pin bump is a cohort upgrade governed by
  the `cohort-migrate` skill and is out of this plan's scope. What this plan must guarantee
  is that kioku's own migration file cannot break that future upgrade. The migration body
  is plain SQL whose only environmental dependency is where `keiro_read_models` lives; a
  test that creates the table exactly as keiro HEAD's bootstrap does (DDL copied verbatim
  into the test) and runs the body against it exercises the full failure mode the review
  identified. The reconciler needs no such simulation because it rides keiro's own
  compiled statements. Recorded as a documented limitation in Validation.
  Date: 2026-07-07.


## Outcomes & Retrospective

All four milestones landed (`3a55a9b`, `68efc7b`, `cfe3623`, plus this doc pass). The suite
went from 106 to 108 kioku-core tests, and a new `kioku-migrations-test` suite adds 6 more.
Each of the three defects is now covered by a test that fails without its fix.

**What the plan got right.** The central bet — that a code-side reconciler riding keiro's own
compiled registry statements is pin-bump-proof by construction, while any SQL we write
ourselves is not — held exactly. `reconcileReadModelRegistry` is 20 lines, derives everything
from `kiokuReadModelSchemas`, and needs no knowledge of where `keiro_read_models` physically
lives. The in-place migration edit was also right, and for the reason given: codd never
re-runs a filename it recorded, so the edit is a no-op on every database where the old body
succeeded, and it is the *only* fix that also works on a fresh keiro-HEAD database. The
three-layout test proves it: restoring the old body fails the `keiro` case with the predicted
`42P01`, and passes on `kiroku` and `public`.

**What it got wrong, and the lesson.** The Decision Log asserted that putting the reconciler's
`kioku-core` dependency on the *executable* carried "zero cycle risk" because nothing depends
on the executable. That is true of the component graph and false of cabal, which does cycle
detection per package and refused to solve the build at all. The fix was mechanical (a new
`kioku-migrate` package) but it was not a detail — it changed the repository's package layout,
which is exactly the kind of thing a plan is supposed to settle in advance. This is the third
consecutive plan in this MasterPlan whose Decision Log contained a confident claim about a
system the author never ran (EP-4's timestamps, EP-5's `ef_search`, EP-6's cabal cycle), and
all three were caught only by execution. The pattern is worth naming: **a plan's claim about
tooling behavior deserves the same "verify before trusting" treatment as a claim about query
plans.**

**One deliberate scope addition.** `just migrate`'s `touch kioku-migrations.cabal` was removed
rather than left alone. EP-5 had already established that `touch` cannot invalidate a Template
Haskell embed (GHC's recompilation check is content-based), which makes that line a no-op that
*looks* like a safeguard — worse than nothing, because it invites the reader to believe the
staleness problem is handled. `just new-migration` now rewrites the `-- Last added:` line for
real, and the guard test catches the hand-created case.

**Gaps and follow-ups.**

- The keiro-HEAD scenario is proven against a hand-built *replica* of its layout, not against
  a kioku compiled on keiro HEAD — as the plan intended, and for the reason it gave (that is a
  cohort pin bump, governed by the `cohort-migrate` skill). What this plan guarantees is that
  kioku's own migration and reconciler are correct on both sides of that bump.
- One pin-bump follow-up remains: `Justfile`'s `CODD_SCHEMAS=kiroku` will need `keiro` added.
  The other one the plan flagged — `TestSupport`'s `namespacesToCheck` — turned out to be done
  already.
- The reconciler advances a registry row's identity without rebuilding data, which is safe
  only because kioku's read-model migrations are additive by policy. That contract is now
  stated in `Kioku.ReadModel`'s haddock and in `docs/user/library-api.md`; a future
  non-additive reshape must rewrite the projected data in its own migration before the
  reconciler runs. Nothing enforces this mechanically.


## Context and Orientation

Kioku is an event-sourced agent memory and session library. Events are stored through the
kiroku library ("the event store") and projected into queryable SQL tables through the
keiro library ("the framework": read models, subscriptions, workflows). Kioku is a
consumer of both. This repository holds four packages: `kioku-api` (types), `kioku-core`
(domain logic, read models, queries), `kioku-cli` (command-line host), and
`kioku-migrations` (schema evolution).

A "read model" is a named, versioned SQL projection: for example
`kioku-session-by-id` projects session events into the `kioku_sessions` table. Every read
model declares a `name`, an integer `version`, and a `shapeHash` (an arbitrary string
identifying the table shape, e.g. `"kioku-session-v3"`). The declarations live in
`kioku-core/src/Kioku/Session/ReadModel.hs` (nine session models, currently version 3 /
`kioku-session-v3`, except `kioku-turns-by-session` at version 1 / `kioku-turn-v1`) and
`kioku-core/src/Kioku/Memory/ReadModel.hs` (ten memory models, all version 1 /
`kioku-memory-v1`). Do not rename any read-model name — other plans and stored registry
rows key on them.

Keiro maintains a registry table, `keiro_read_models`, with columns `name` (primary key),
`version`, `shape_hash`, `last_built_at`, `status`, `updated_at`. Before serving any query,
keiro's `runQuery` (in the keiro checkout at
`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/ReadModel.hs`) calls
`ensureReadModel`: it looks up the model's registry row, inserts one at the current
identity if absent (`registerReadModel` — insert-only; it never updates an existing row's
version), and then compares. On mismatch the query returns
`Left (ReadModelStaleSchema name expectedVersion foundVersion expectedHash foundHash)`.
This "fail closed" design means a database whose registry rows lag the code's declared
versions serves NO queries for those models at all.

That is precisely the outage that happened when the session models went v1 → v2 → v3: the
column migrations were additive and left the data correct, but the registry rows stayed at
the old version, and every session query failed. The fix shipped as the hand-written
migration `kioku-migrations/sql-migrations/2026-07-03-14-37-18-kioku-session-readmodel-registry-bump.sql`,
which does `SET search_path TO kiroku, public, pg_catalog;` and then
`UPDATE keiro_read_models SET version = 3, shape_hash = 'kioku-session-v3', status = 'live', ...`
for the eight v3 session model names, guarded so rows already at v3 are untouched.

Migrations are applied by codd, a PostgreSQL migration tool that orders migration files by
the UTC timestamp in their filename and records each applied file BY FILENAME in a ledger
table (`codd.sql_migrations`). Kioku composes a single codd ledger out of three sources in
`kioku-migrations/src/Kioku/Migrations.hs`: kiroku's migrations, keiro's framework
migrations, and kioku's own six files under `kioku-migrations/sql-migrations/`, embedded
into the binary at compile time by the Template Haskell splice
`$(embedDir "sql-migrations")` (lines 56–59; `embedDir` comes from the `file-embed`
package and produces `[(FilePath, ByteString)]`). The `kioku-migrate` executable
(`kioku-migrations/app/Main.hs`) reads codd settings from environment variables
(`CODD_CONNECTION` etc.) and applies everything; `just migrate` (see `Justfile`) is the
developer entry point and `process-compose.yaml` uses it too.

Three versions of keiro matter here. Kioku pins keiro at git tag
`f1d67a01b7457387a4861e7268d1c521ef82287d` (see `cabal.project`); at that pin, keiro's
bootstrap migration runs under `SET search_path TO kiroku` and creates `keiro_read_models`
unqualified — i.e. physically inside the `kiroku` schema — and keiro's registry statements
use the unqualified table name. Keiro HEAD (checkout at
`/Users/shinzui/Keikaku/bokuno/keiro`) creates a dedicated `keiro` schema, creates
`keiro.keiro_read_models` there, uses schema-qualified statements, renamed all its
migration files to real UTC timestamps, and ships a remediation script
(`keiro-migrations/remediation/2026-07-05-relocate-keiro-tables-to-keiro-schema.sql`) that
moves existing tables. When kioku eventually bumps its pin, fresh databases will have the
registry only at `keiro.keiro_read_models` — and kioku's registry-bump migration, whose
search_path names only `kiroku` and `public`, will fail with `undefined_table` on every
fresh database, because keiro's bootstrap timestamp (2026-05-17) sorts before kioku's
registry bump (2026-07-03) regardless of cohort. Existing production-grade databases are
upgraded through the `cohort-migrate` skill (`~/.claude/skills/cohort-migrate/SKILL.md`),
which is forward-only and clone-proven; this plan does not perform that upgrade, it only
removes kioku's contribution to breaking it.

The Template Haskell staleness problem is orthogonal: `embedDir` registers each embedded
file as a compilation dependency (so edits recompile), but a file newly ADDED to
`sql-migrations/` is not a registered dependency of anything, so GHC considers
`Migrations.hs` up to date and the binary silently lacks the new migration. The current
defense is a comment ("Keep this binding source-touched when adding SQL files... Last
touched: ...") — a convention, not a guarantee. Sibling plans 10, 12, and 13 (paths in
Interfaces and Dependencies) will add migration files and currently must remember to touch
`Migrations.hs` by hand.

Testing infrastructure: `kioku-migrations` exposes a public sublibrary `test-support`
whose `withKiokuMigratedDatabase :: (Text -> IO a) -> IO a`
(`kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs`) starts an ephemeral
PostgreSQL (via the `ephemeral-pg` package, cached across tests), applies the full
migration chain with `runKiokuMigrationsNoCheck`, and hands the connection string to the
test. The `kioku-core` test suite (`kioku-test`) uses it heavily (see
`kioku-core/test/Kioku/AwaitingSpec.hs` for the idiom: `withStore
(defaultConnectionSettings connStr)` from `Kiroku.Store.Connection`, then `runAppIO
AppEnv{..}` from `Kioku.App` to run `Store`-effect code). `kioku-migrations` itself has no
test suite yet.


## Plan of Work

The work is four milestones. Each is independently verifiable and lands compiling with
green tests.

### Milestone 1 — Make the reconciliation migration location-agnostic

Scope: rewrite the body of
`kioku-migrations/sql-migrations/2026-07-03-14-37-18-kioku-session-readmodel-registry-bump.sql`
(same filename — see Decision Log for why an in-place edit is required and safe) so it
finds `keiro_read_models` wherever it physically lives, and create the new test suite
`kioku-migrations-test` that proves the body against both physical layouts and proves the
full chain still applies to a fresh database.

Replace the file's SQL (keep the `-- codd: in-txn` header line and the header comments,
updating them to tell the truth) with a `DO` block that resolves the table via
`to_regclass` in precedence order `keiro`, then `kiroku`, then `public` (`to_regclass`
returns NULL instead of erroring when the name does not resolve; `keiro` first because a
relocated database is the newest layout and the relocation removes the old location, so at
most one resolves in practice). If none resolves, `RAISE EXCEPTION` — the keiro bootstrap
always precedes this file in the ledger, so a missing table means a genuinely broken
database and silence would be worse. Then `EXECUTE format(...)` the exact UPDATE the old
body performed (same eight names, same v3 identity, same idempotence guard) against the
resolved regclass. The full new body is given in Concrete Steps.

Add to `kioku-migrations/kioku-migrations.cabal` a test suite `kioku-migrations-test`
(`type: exitcode-stdio-1.0`, `hs-source-dirs: test`, `main-is: Main.hs`) depending on
`base`, `bytestring`, `directory`, `filepath`, `hasql`, `tasty`, `tasty-hunit`, `text`,
`ephemeral-pg`, `kioku-migrations`, and `kioku-migrations:test-support`. Create
`kioku-migrations/test/Main.hs` with two DB-backed tests in this milestone (the third,
the embed guard, arrives in Milestone 3):

The layout test starts a bare ephemeral database (use `EphemeralPg.withCached`, do NOT run
migrations), and for each of the two layouts — `kiroku.keiro_read_models` as the pinned
keiro bootstrap builds it, and `keiro.keiro_read_models` as keiro HEAD's bootstrap builds
it (both DDLs verbatim in the test; they are identical apart from the schema:
`name TEXT PRIMARY KEY, version BIGINT NOT NULL, shape_hash TEXT NOT NULL, last_built_at
TIMESTAMPTZ, status TEXT NOT NULL, updated_at TIMESTAMPTZ NOT NULL DEFAULT now()`) —
creates the schema and table, seeds a stale row (`'kioku-session-by-id', 2,
'kioku-session-v2', now(), 'live'`), executes the migration file's bytes as one SQL script
over a raw hasql connection, and asserts the row is now `version = 3, shape_hash =
'kioku-session-v3', status = 'live'`. Obtain the body from the embedded list so the test
exercises exactly what ships: import `embeddedKiokuMigrationFiles` (exported in this
milestone, see Concrete Steps) and look up the filename. Executing the whole file works
because `-- codd:` directives are ordinary SQL comments. Reset state between layouts
(`DROP SCHEMA ... CASCADE`).

The fresh-database test simply runs `withKiokuMigratedDatabase` and asserts the migrated
database has the registry table (query
`to_regclass('kiroku.keiro_read_models') IS NOT NULL` — pinned cohort) — this pins down
that the rewritten body applies cleanly inside the real codd chain on scenario (1), a
fresh empty database with pinned keiro.

Acceptance: `cabal test kioku-migrations` passes; reverting the SQL rewrite makes the
keiro-layout half of the layout test fail with `undefined_table`, proving the test tests
the finding.

### Milestone 2 — Code-side reconciler, wired into kioku-migrate, with the fail-closed test

Scope: make `kiokuReadModelSchemas` load-bearing. At the end of this milestone, running
`kioku-migrate` reconciles every registry row to the compiled code's identity, and a test
demonstrates the full arc: stale row → every session query fails closed → reconcile →
queries succeed.

In `kioku-core/src/Kioku/ReadModel.hs`, add and export `ReconcileOutcome` (constructors
`Registered`, `Reconciled`, `AlreadyCurrent`) and `reconcileReadModelRegistry :: (Store :>
es) => Eff es [(ReadModelSchema, ReconcileOutcome)]`, implementing the semantics fixed in
the Decision Log (absent → `registerReadModel`; identity equal → untouched; identity
differs → `markLive`), iterating over `kiokuReadModelSchemas`. Import
`Keiro.ReadModel.Schema` (exposed by keiro at both pin and HEAD) qualified. Rewrite the
module haddock: it currently says the list "lets a migration runner reconcile" — make it
name `reconcileReadModelRegistry` and the `kioku-migrate` executable as the consumers, and
keep the additive-migrations contract paragraph (it is the safety argument for advancing
the guard without a rebuild).

In `kioku-migrations/kioku-migrations.cabal`, add `kioku-core`, `kiroku-store`, and `text`
to the `kioku-migrate` executable's `build-depends` (executable only — the library must
not depend on kioku-core; see Decision Log). In `kioku-migrations/app/Main.hs`, after
`runKiokuMigrationsNoCheck`, read the `CODD_CONNECTION` environment variable (the same
libpq keyword string codd used), open a store with `withStore (defaultConnectionSettings
...)`, build an `AppEnv` with `noopTracer` and `metrics = Nothing`, run
`reconcileReadModelRegistry` via `runAppIO`, exit non-zero on `Left StoreError`, and print
a one-line summary per non-`AlreadyCurrent` outcome so `just migrate` output shows what
was repaired.

Add `kioku-core/test/Kioku/ReadModelReconcileSpec.hs` (register in the `kioku-test`
suite's `other-modules` and in `kioku-core/test/Main.hs`; add `keiro` to the test suite's
`build-depends` if not already present, for `Keiro.ReadModel (ReadModelError (..))`). The
test, using the `AwaitingSpec` idiom (`withKiokuMigratedDatabase` + `withStore` +
`runAppIO`): (1) start a session and fetch it by id so the registry rows exist at v3;
(2) corrupt the registry with raw SQL (`runTransaction` + a hasql statement):
`UPDATE keiro_read_models SET version = 2, shape_hash = 'kioku-session-v2' WHERE name =
'kioku-session-by-id'` (unqualified name — the store session's search_path resolves it
exactly as pinned keiro's own statements do); (3) fetch again and assert
`Left (ReadModelStaleSchema ...)` — this proves the fail-closed outage is real and the
test is testing something; (4) run `reconcileReadModelRegistry`, assert the outcome for
`kioku-session-by-id` is `Reconciled` and every other is `AlreadyCurrent` or `Registered`;
(5) fetch again and assert `Right`; (6) run the reconciler a second time and assert
every outcome is `AlreadyCurrent` (idempotence).

Acceptance: `cabal test kioku-core` passes; commenting out the `markLive` branch of the
reconciler makes step (5) fail. `just migrate` against a dev database prints the
reconciliation summary and exits 0.

### Milestone 3 — Guard the embedded migration list

Scope: a shipped binary can no longer silently lack a migration file without a test
failing, and the common developer path cannot even reach that state.

Export the embedded list from `kioku-migrations/src/Kioku/Migrations.hs`: rename nothing,
just add `embeddedKiokuMigrationFiles :: [(FilePath, ByteString)]` to the export list
(alias of the existing `embeddedKiokuFiles` binding, or export the binding under that
name). Replace the "Last touched" comment with one that explains the real contract: the
splice re-embeds only when this file recompiles; new files in `sql-migrations/` require
touching this file; the `kioku-migrations-test` suite fails if the embed is stale; `just
new-migration` touches this file automatically. (Milestone 1's layout test already needs
this export — implement the export as part of Milestone 1 if you execute strictly in
order; it is listed here because this is the milestone that makes it a guarded contract.)

Add the guard test to `kioku-migrations/test/Main.hs`: list `sql-migrations` at runtime
with `System.Directory.listDirectory` (the test's working directory is the package root,
the same relative path the TH splice used), filter to `.sql`, sort, and assert equality
with `sort (map fst embeddedKiokuMigrationFiles)`. On mismatch the assertion message must
name the offending files and say exactly: touch
`kioku-migrations/src/Kioku/Migrations.hs` and rebuild. Also assert every filename matches
the `YYYY-MM-DD-HH-MM-SS-slug.sql` shape (a regex or manual parse), which catches a
mis-scaffolded file that codd would order surprisingly.

Update the `new-migration` recipe in `Justfile` to `touch
kioku-migrations/src/Kioku/Migrations.hs` after writing the scaffold, and print a line
saying it did so. Note for sibling plans (10, 12, 13): their flow is unchanged — mint a
fresh UTC-timestamp filename (ideally via `just new-migration`), and if they create files
by hand, the guard test now catches a forgotten touch instead of a silently stale binary.

Acceptance: `cabal test kioku-migrations` passes. Demonstrate the guard: create
`sql-migrations/2099-01-01-00-00-00-guard-demo.sql` WITHOUT touching `Migrations.hs`, run
`cabal test kioku-migrations`, observe the guard test fail naming the file; delete the
demo file; test passes again. (GHC will not have recompiled the library, which is exactly
the condition being tested; if your local build happens to recompile for unrelated
reasons, the test passes trivially — run the demonstration from a clean `cabal build
kioku-migrations` state.)

### Milestone 4 — End-to-end validation and documentation

Scope: prove the three safety scenarios end to end, update user docs, and close out the
plan. Run the full sweep in Concrete Steps (build all, test all, `just migrate` twice
against the dev database asserting the second run applies nothing and reconciles nothing).
Update `docs/user/library-api.md` (the section around line 326 that describes composing
migrations) to state that `kioku-migrate` reconciles the read-model registry after
applying migrations, and that library consumers calling `runKiokuMigrations` /
`runKiokuMigrationsNoCheck` directly must call
`Kioku.ReadModel.reconcileReadModelRegistry` afterwards, otherwise a version bump leaves
their queries failing with `ReadModelStaleSchema`. Fill in Outcomes & Retrospective, check
off Progress, and commit (conventional commits; e.g. `fix(migrations): locate
keiro_read_models across schema relocation`, `feat(core): reconcile read-model registry
from code`, `test(migrations): guard TH-embedded migration list`).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kioku` unless
stated otherwise. The dev-database commands assume the nix devShell's `PG*` environment
variables, as `Justfile` does.

Step 1 (Milestone 1). Replace the body of
`kioku-migrations/sql-migrations/2026-07-03-14-37-18-kioku-session-readmodel-registry-bump.sql`
with:

```sql
-- codd: in-txn

-- Migration: kioku-session-readmodel-registry-bump
-- Created: 2026-07-03-14-37-18 UTC
-- Body rewritten 2026-07-07: locate keiro_read_models dynamically. See
-- docs/plans/14-align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations.md
--
-- The session read model reshaped v1 -> v2 (delegation lineage) -> v3 (awaiting
-- park/resume) through purely additive column migrations that left kioku_sessions
-- data correct for v3 but never touched the keiro_read_models registry. Because
-- keiro's registerReadModel only inserts (never bumps an existing row), pre-existing
-- registrations stay pinned at the old version and every session query fails closed
-- with ReadModelStaleSchema. Reconcile those rows to the v3 identity.
--
-- keiro_read_models physically lives in the kiroku schema on the pinned keiro
-- cohort, in the dedicated keiro schema after keiro's schema relocation, and in
-- public on some long-lived development databases. Resolve it dynamically so this
-- file is correct on all three layouts and survives the keiro pin bump. codd applies
-- keiro's bootstrap (which creates the table) before this file on every cohort, so a
-- missing table is a genuinely broken database: fail loudly.
-- Idempotent: the guard skips rows already at v3.
DO $do$
DECLARE
  registry regclass;
BEGIN
  registry := COALESCE(
    to_regclass('keiro.keiro_read_models'),
    to_regclass('kiroku.keiro_read_models'),
    to_regclass('public.keiro_read_models'));
  IF registry IS NULL THEN
    RAISE EXCEPTION 'keiro_read_models not found in keiro, kiroku, or public';
  END IF;
  EXECUTE format($sql$
    UPDATE %s
    SET version = 3,
        shape_hash = 'kioku-session-v3',
        status = 'live',
        last_built_at = now(),
        updated_at = now()
    WHERE name IN (
        'kioku-session-by-id',
        'kioku-sessions-by-namespace',
        'kioku-sessions-by-scope',
        'kioku-sessions-by-focus',
        'kioku-sessions-by-started-range',
        'kioku-session-chain',
        'kioku-session-delegation-children',
        'kioku-sessions-awaiting-by-correlation-key'
      )
      AND (version <> 3 OR shape_hash <> 'kioku-session-v3')
  $sql$, registry);
END
$do$;
```

Step 2 (Milestone 1). In `kioku-migrations/src/Kioku/Migrations.hs`, add
`embeddedKiokuMigrationFiles` to the module export list and define it as the existing
`embeddedKiokuFiles` (or export the binding directly under the new name). Touching this
file also forces the splice to re-embed the rewritten SQL.

Step 3 (Milestone 1). Add the test suite stanza to
`kioku-migrations/kioku-migrations.cabal` and create `kioku-migrations/test/Main.hs` with
the layout test and the fresh-database test described in Plan of Work. Executing raw SQL
over hasql: `Hasql.Connection.acquire` with the ephemeral connection string encoded to
bytes, then `Hasql.Session.run (Hasql.Session.sql bytes) conn`; assert `Right`.

Step 4 (Milestone 1 acceptance).

```bash
cabal build kioku-migrations && cabal test kioku-migrations --test-show-details=direct
```

Expected output ends with all tests passing, e.g.:

```text
registry bump SQL is layout-agnostic (kiroku layout): OK
registry bump SQL is layout-agnostic (keiro layout):  OK
fresh database migrates cleanly:                      OK
All 3 tests passed
```

To prove the keiro-layout test bites, temporarily restore the old `SET search_path TO
kiroku, public, pg_catalog; UPDATE keiro_read_models ...` body and re-run: the keiro-layout
case must fail with a message containing `relation "keiro_read_models" does not exist
(42P01 / undefined_table)`. Restore the new body afterwards.

Step 5 (Milestone 2). Edit `kioku-core/src/Kioku/ReadModel.hs`: add the import
`import Keiro.ReadModel.Schema qualified as Schema`, the `ReconcileOutcome` type
(`deriving stock (Eq, Show)`), and:

```haskell
reconcileReadModelRegistry ::
  (Store :> es) => Eff es [(ReadModelSchema, ReconcileOutcome)]
reconcileReadModelRegistry =
  for kiokuReadModelSchemas \schema -> do
    existing <- Schema.lookupReadModel schema.readModelName
    outcome <- case existing of
      Nothing ->
        Registered
          <$ Schema.registerReadModel
            schema.readModelName
            schema.readModelVersion
            schema.readModelShapeHash
      Just metadata
        | metadata.version == schema.readModelVersion
            && metadata.shapeHash == schema.readModelShapeHash ->
            pure AlreadyCurrent
        | otherwise ->
            Reconciled
              <$ Schema.markLive
                schema.readModelName
                schema.readModelVersion
                schema.readModelShapeHash
    pure (schema, outcome)
```

Rewrite the module haddock as described in Plan of Work.

Step 6 (Milestone 2). Update the `kioku-migrate` executable. In the cabal file add
`kioku-core`, `kiroku-store`, `text` to its `build-depends`. New
`kioku-migrations/app/Main.hs` shape:

```haskell
main :: IO ()
main = do
  settings <- getCoddSettings
  _ <- runKiokuMigrationsNoCheck settings (secondsToDiffTime 5)
  connStr <- getEnv "CODD_CONNECTION"
  tracer <- noopTracer
  withStore (defaultConnectionSettings (Text.pack connStr)) $ \store -> do
    result <-
      runAppIO
        AppEnv {store = store, tracer = tracer, metrics = Nothing}
        reconcileReadModelRegistry
    case result of
      Left err -> die ("read-model registry reconciliation failed: " <> show err)
      Right outcomes ->
        for_ outcomes $ \(schema, outcome) ->
          case outcome of
            AlreadyCurrent -> pure ()
            _ ->
              putStrLn
                ( "reconciled read model "
                    <> Text.unpack schema.readModelName
                    <> ": "
                    <> show outcome
                )
```

(`getEnv` from `System.Environment`, `die` from `System.Exit`; `withStore`,
`defaultConnectionSettings` from `Kiroku.Store.Connection`; `AppEnv`, `noopTracer`,
`runAppIO` from `Kioku.App`; `reconcileReadModelRegistry` and friends from
`Kioku.ReadModel`.)

Step 7 (Milestone 2). Add `kioku-core/test/Kioku/ReadModelReconcileSpec.hs` per Plan of
Work, register it in `kioku-core.cabal` (`other-modules`) and `kioku-core/test/Main.hs`,
and add `keiro` to the test suite's `build-depends` if missing. Run:

```bash
cabal test kioku-core --test-show-details=direct --test-options='-p "Reconcile"'
```

Expected:

```text
stale registry row fails closed then reconciles: OK
reconciliation is idempotent:                    OK
```

Step 8 (Milestone 2 acceptance, against the dev database):

```bash
just migrate
```

On a database that has already applied all migrations the expected tail of the output is
codd reporting zero pending migrations and no `reconciled read model` lines. To see the
reconciler act, downgrade a row and re-run:

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "UPDATE kiroku.keiro_read_models SET version = 2, shape_hash = 'kioku-session-v2' \
   WHERE name = 'kioku-session-by-id'"
just migrate
```

Expected in the output:

```text
reconciled read model kioku-session-by-id: Reconciled
```

Step 9 (Milestone 3). Export/comment changes in `Migrations.hs`, the guard test in
`kioku-migrations/test/Main.hs`, and the Justfile `new-migration` touch, per Plan of Work.
Demonstrate the guard as described in Milestone 3's acceptance paragraph:

```bash
cabal build kioku-migrations
touch kioku-migrations/sql-migrations/2099-01-01-00-00-00-guard-demo.sql
cabal test kioku-migrations --test-show-details=direct
# expect: embedded migration list matches sql-migrations/: FAIL
#         missing from embed: 2099-01-01-00-00-00-guard-demo.sql
#         fix: touch kioku-migrations/src/Kioku/Migrations.hs and rebuild
rm kioku-migrations/sql-migrations/2099-01-01-00-00-00-guard-demo.sql
cabal test kioku-migrations --test-show-details=direct   # all pass again
```

Step 10 (Milestone 4). Full sweep:

```bash
cabal build all
cabal test all --test-show-details=direct
just migrate && just migrate   # second run: zero pending migrations, zero reconciled lines
```

Update `docs/user/library-api.md` as described, complete the living sections, and commit.


## Validation and Acceptance

The plan is accepted when all of the following hold, mapped to the review findings and the
three safety scenarios for databases that may hold critical production data.

Finding 1(a) — dead reconciliation API and SQL-per-bump: `kiokuReadModelSchemas` now has a
real consumer (`reconcileReadModelRegistry`), invoked by `kioku-migrate`. Behavior to
observe: Step 8's transcript — downgrading a registry row and running `just migrate`
prints `reconciled read model kioku-session-by-id: Reconciled`, and session queries work
immediately after. A future version bump (e.g. by sibling plan 12 or 13) requires no
hand-written registry migration: bumping a model's `version`/`shapeHash` in code and
running `just migrate` is sufficient, because the reconciler derives from the same values.

Finding 1(b) — relocation fragility: the layout test in `kioku-migrations-test` executes
the shipped migration bytes against a database whose only `keiro_read_models` is
`keiro.keiro_read_models` (keiro HEAD's exact DDL) and asserts the stale row is bumped;
the same test also covers the pinned `kiroku` layout. Reverting the SQL rewrite makes the
keiro-layout case fail with `undefined_table`, proving the test detects the exact defect
the review found. Documented limitation: this simulates the relocated LAYOUT, not a full
kioku build against keiro HEAD — that requires the cohort pin bump (kiroku + keiro
together), which is separate work governed by the `cohort-migrate` skill; what this plan
guarantees is that kioku's migration file and reconciler are correct on both sides of it.
(Two pin-bump follow-ups outside this plan's scope, recorded here so they are not lost:
`Justfile`'s `CODD_SCHEMAS=kiroku` and TestSupport's `namespacesToCheck = IncludeSchemas
[kiroku, public]` will need `keiro` added when the pin moves.)

Finding 1(c) — no stale-registry test: `Kioku.ReadModelReconcileSpec` asserts, in order:
queries succeed at v3; after downgrading the registry row the same query returns `Left
(ReadModelStaleSchema "kioku-session-by-id" 3 2 "kioku-session-v3" "kioku-session-v2")`
(the fail-closed outage, observed before the fix runs — proving the test tests
something); after `reconcileReadModelRegistry` the query succeeds; a second reconcile
reports all `AlreadyCurrent`.

Finding 2 — silent embed staleness: the guard test fails, with an actionable message,
whenever `sql-migrations/` and the compiled-in list diverge; Step 9's transcript is the
demonstration. `just new-migration` now touches `Migrations.hs` so the normal flow never
trips it.

Safety scenarios: (1) fresh empty database, pinned keiro — covered by the fresh-database
test (full codd chain incl. the rewritten body) and by `just create-database` on a scratch
`PGDATABASE`; (2) fresh empty database, keiro HEAD — covered by the keiro-layout half of
the layout test as argued above; (3) existing database already carrying the old
reconciliation — codd keys applied migrations by filename and never re-runs or checksums
this file (verified in codd's source, see Surprises & Discoveries), so the body edit has
provably no effect there; `just migrate` run twice (Step 10) additionally shows zero
pending migrations and a no-op reconciler, i.e. the whole pipeline is idempotent against a
current database. No step in this plan drops, truncates, or rewrites any data table; the
only writes are UPDATE/INSERT on registry rows, guarded to touch only rows that disagree
with the code.

Exact commands: Steps 4, 7, 8, 9, 10 above, each with its expected transcript.


## Idempotence and Recovery

Every step is safe to repeat. The rewritten migration is idempotent by construction (the
UPDATE's guard matches only rows not already at the v3 identity), and codd will not re-run
it on databases that recorded its filename. The reconciler is idempotent: a second run
returns `AlreadyCurrent` for every model and writes nothing (the spec asserts this). `just
migrate` is idempotent end to end (Step 10 runs it twice). The guard-demo file in Step 9
must be deleted after the demonstration; it is never committed.

If the reconciler fails midway (e.g. connection loss), rows already upserted are
individually correct — each `markLive`/`registerReadModel` is its own transaction — and
re-running `kioku-migrate` completes the remainder. If the migration body edit is botched,
fresh test databases fail immediately in `kioku-migrations-test` before any real database
is touched; fix and re-run — no real database applies the file twice. For real databases
holding critical data, the standing rule from the `cohort-migrate` skill applies to any
manual poking: take a `pg_dump` before hand-running SQL against them; nothing in this
plan's normal path requires hand-run SQL.

Do not "fix" a stale registry by hand-editing rows on production; run `kioku-migrate`
(or `just migrate`) so the repair is the tested code path.


## Interfaces and Dependencies

New/changed Haskell surface, by module:

- `Kioku.ReadModel` (kioku-core): existing `ReadModelSchema (..)` and
  `kiokuReadModelSchemas :: [ReadModelSchema]` are kept (do not rename fields or reorder
  meaning — the plan makes them load-bearing); new `data ReconcileOutcome = Registered |
  Reconciled | AlreadyCurrent` and `reconcileReadModelRegistry :: (Store :> es) => Eff es
  [(ReadModelSchema, ReconcileOutcome)]` where `Store` is `Kiroku.Store.Effect.Store`.
  Implemented on `Keiro.ReadModel.Schema.lookupReadModel` / `.registerReadModel` /
  `.markLive` (exposed module at both the pinned keiro `f1d67a0` and HEAD; signatures
  identical, so the reconciler compiles unchanged across the future pin bump).
- `Kioku.Migrations` (kioku-migrations): new export `embeddedKiokuMigrationFiles ::
  [(FilePath, ByteString)]`. All existing exports unchanged.
- `kioku-migrate` executable: gains `build-depends: kioku-core, kiroku-store, text`;
  behavior extended with post-apply reconciliation (non-zero exit on reconciliation
  failure). The `kioku-migrations` LIBRARY must not depend on `kioku-core` (cycle risk via
  `kioku-core:test → kioku-migrations:test-support`; see Decision Log).
- New test suite `kioku-migrations-test` (deps: base, bytestring, directory, filepath,
  hasql, tasty, tasty-hunit, text, ephemeral-pg, kioku-migrations,
  kioku-migrations:test-support). New spec module `Kioku.ReadModelReconcileSpec` in the
  existing `kioku-test` suite of kioku-core (may need `keiro` added to its build-depends).

Shared artifacts with sibling plans (reference by path only): the migration directory
`kioku-migrations/sql-migrations/` and the embed guard are shared with
`docs/plans/10-propagate-memory-forget-operations-to-scenes-personas-and-workspace-mirrors.md`,
`docs/plans/12-enforce-aggregate-invariants-for-lineage-resume-correlation-and-idempotent-commands.md`,
and
`docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md`.
Their convention: mint a fresh UTC-timestamp filename (`just new-migration name=<slug>`),
and until this plan's guard lands, also touch
`kioku-migrations/src/Kioku/Migrations.hs`; after it lands, the touch is automatic via the
recipe and the guard test catches hand-created files. If those plans bump a read model's
version or shapeHash, the reconciler here picks the new identity up automatically because
it derives from the `ReadModel` values in code, not from any frozen list — they must NOT
add hand-written registry-bump SQL. Do not rename read-model names or process-manager
names anywhere; other plans and stored registry rows key on them.

Downstream consumers: kikan and shikigami (per `mori registry dependents shinzui/kioku`)
depend on kioku at the project level. If they apply migrations through the
`kioku-migrate` executable they inherit reconciliation for free; if they call
`runKiokuMigrations`/`runKiokuMigrationsNoCheck` as a library they must call
`Kioku.ReadModel.reconcileReadModelRegistry` afterwards — this is documented in
`docs/user/library-api.md` by Milestone 4.

External libraries relied on and why: codd (migration application; filename-keyed ledger —
the property the in-place edit decision rests on), file-embed 0.0.16 (`embedDir`;
per-file `qAddDependentFile` — the property the guard design rests on), ephemeral-pg
(throwaway PostgreSQL for tests), hasql (raw SQL execution in the layout test), tasty /
tasty-hunit (test framework, matching the repo's existing suites), keiro (registry API),
kiroku-store (`withStore`, `defaultConnectionSettings`, `Store` effect,
`runTransaction`).
