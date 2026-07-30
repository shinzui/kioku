---
id: 22
slug: remove-the-codd-import-bridge-from-kioku
title: "Remove the codd import bridge from Kioku"
kind: exec-plan
created_at: 2026-07-30T22:56:58Z
intention: "intention_01kytapemyezfakpdf0ke73cgw"
---

# Remove the codd import bridge from Kioku

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kioku is a Haskell library family that gives an AI agent a durable memory. Its database schema
is evolved by a **migration runner** — a program that applies numbered SQL files in order and
records which ones it has applied, so it never applies one twice. Kioku used to use a runner
called **codd**; `docs/plans/20-move-kioku-off-codd-onto-pg-migrate-and-upgrade-the-keiro-kiroku-cohort.md`
moved it onto a different runner called **pg-migrate**.

Those two runners disagree about how to name an applied migration. codd keys its ledger by the
migration's *filename*; pg-migrate keys its by a stable logical identity of the form
`component/name` and additionally stores a SHA-256 checksum of the SQL it applied. So a database
that codd had already migrated could not simply be handed to pg-migrate — pg-migrate would see an
empty ledger and try to re-apply schema changes that were already there.

Plan 20 therefore shipped a **one-time import bridge**: code that reads an existing codd ledger
and writes the equivalent pg-migrate ledger rows, so a database crosses over without re-running a
single line of DDL. That bridge is what this plan deletes.

The bridge was always meant to be temporary, and `docs/plans/21-release-kioku-for-the-keiki-0-4-keiro-0-4-baikai-0-4-and-shikumi-cohort.md`
deprecated rather than deleted it, because at that time the one downstream consumer — Shikigami —
still had a codd ledger it might need to cross. That gate has now been lifted: the user has
confirmed Shikigami is not yet in use for anything, so no live database needs the crossing. The
evidence backing that is in Surprises & Discoveries item 1.

After this plan, `kioku-migrations` and `kioku-migrate` contain no reference to codd at all.
A person can run `cabal run kioku-migrate -- --help` and see no `import` subcommand; they can
`grep -ri codd` over the two packages' source and cabal files and get nothing back; and
`cabal build all` and `cabal test all` still pass, with the migration plan still applying the
same 38 migrations to a fresh database as it does today. Nothing about how Kioku migrates a
database changes — only the ability to adopt a *foreign* codd ledger goes away.

What this plan deliberately does **not** do is touch the SQL under
`kioku-migrations/migrations/`. Those files carry `-- codd: in-txn` comments, and it is tempting
to remove them as part of "removing codd". Doing so would be a serious bug: pg-migrate stores a
checksum of each applied migration's bytes, so editing an applied file makes `kioku-migrate
verify` report a mismatch on every existing database, and a checksum mismatch has no automatic
repair. The comments stay. Only the *explanation* of why they stay is reworded, because the
reason changes from "the codd import needs them as payload evidence" to "they are inside an
already-checksummed file". See the Decision Log.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

### Milestone 1 — Delete the bridge

- [ ] Delete `kioku-migrations/src/Kioku/Migrations/History/Codd.hs` and drop it from
      `exposed-modules`.
- [ ] Delete the `kioku-migrations/codd-upgrade/` directory and its `extra-doc-files` /
      `extra-source-files` entries.
- [ ] Delete `kioku-migrations/migrations.lock` and its `extra-source-files` entry.
- [ ] Remove the `import` subcommand, its options parser, and its imports from
      `kioku-migrate/app/Main.hs`.
- [ ] Remove `pg-migrate-import-codd` from all three cabal stanzas.
- [ ] Remove `testCoddCohortImport`, its helpers, and its fixture from `kioku-migrations`' test.
- [ ] Remove the two now-pointless `-Wno-deprecations` flags.
- [ ] Reword the `-- codd: in-txn` comment in `Internal/Definition.hs` (do **not** touch the SQL).
- [ ] Delete the user-level `cohort-migrate` skill.

### Milestone 2 — Prove nothing else depended on it

- [ ] `cabal build all` succeeds.
- [ ] `cabal test all` passes, with the migration suite down to 6 tests.
- [ ] `cabal run kioku-migrate -- --help` shows no `import` subcommand.
- [ ] `grep -ri codd` over the two packages returns nothing outside the changelog.
- [ ] A fresh database still migrates to 38 applied migrations and verifies clean.

### Milestone 3 — Document and release

- [ ] Changelog entries under `### Removed` for `kioku-migrations` and `kioku-migrate`.
- [ ] Release as `0.3.0.0` (major — a public module and a subcommand are removed).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**1. The removal gate is clear — no database anywhere on this machine has a codd ledger, and
Shikigami is the only possible consumer.** Plan 21 deferred this removal because Shikigami still
declared `codd`, still Git-pinned `hasql-migration`, and still pinned Kioku at a pre-pg-migrate
commit. The user has since confirmed Shikigami is not in use for anything, so its declarations
describe an unbuilt project rather than a live database. Checked directly:

```text
$ mori registry dependents shinzui/kioku
shinzui/kikan      project-level
shinzui/shikigami  project-level

$ # kikan has no kioku-* dependency, and in fact no top-level cabal file
$ # every local database, scanned for the codd ledger table:
$ psql -lqtA | cut -d'|' -f1 | while read db; do
    psql -d "$db" -tAc "SELECT count(*) FROM information_schema.tables
                        WHERE table_schema='codd' AND table_name='sql_migrations'"; done
(no database reported 1)
```

The plan-21 instruction was "check for a surviving `codd.sql_migrations` table before believing
otherwise". None survives.

**2. `migrations.lock` is used only by the bridge, and plan 21's removal list missed it.** Plan 21
enumerated seven things to delete together. An eighth exists: `kioku-migrations/migrations.lock`,
embedded by `kiokuCoddManifestText` at `Kioku/Migrations/History/Codd.hs:208`. It is the codd
*manifest* — the lock file codd itself used — and nothing else reads it:

```text
$ grep -rn "migrations.lock" --include="*.hs" --include="*.cabal" .
kioku-migrations/kioku-migrations.cabal:26:  migrations.lock
kioku-migrations/src/Kioku/Migrations/History/Codd.hs:208:kiokuCoddManifestText = $(embedTextFile "migrations.lock")
```

It must not be confused with `kioku-migrations/migrations/manifest`, which is pg-migrate's apply-
order file and is load-bearing. Deleting the wrong one breaks every build.

**3. The `cohort-migrate` skill is user-level, not repository-level.** Plan 21 said removal "must
also retire `.claude/skills/cohort-migrate`". That path is a symlink farm — the repository's
`.claude/skills/` contains only `exec-plan`, `master-plan` and `release`. The skill actually lives
at `/Users/shinzui/.claude/skills/cohort-migrate`, in the user's global configuration, so its
deletion cannot appear in any commit here.


## Decision Log

- Decision: Do not touch any file under `kioku-migrations/migrations/`, including the
  `-- codd: in-txn` comments inside them. Reword the comment in
  `kioku-migrations/src/Kioku/Migrations/Internal/Definition.hs:24-26` that explains them, rather
  than acting on it.
  Rationale: pg-migrate stores a SHA-256 checksum of each applied migration's bytes. Editing an
  applied migration makes `kioku-migrate verify` report a checksum mismatch on every existing
  database, and there is no automatic repair — plan 21's Idempotence section is explicit that a
  mismatch "no amount of re-running fixes". The comments are inert to pg-migrate, which treats
  them as ordinary SQL. The existing note says they are "historical payload evidence used by the
  one-time Codd import", which stops being true; the new note must say they are frozen because
  the files are checksummed.
  Date: 2026-07-30

- Decision: Lift plan 21's removal gate on the user's statement that Shikigami is unused, rather
  than on Shikigami having completed its plan 38.
  Rationale: The gate's purpose was never plan 38 as such — it was to avoid stranding a live
  database with no forward-only route across. An unused project has no live database, so the risk
  the gate protects against does not exist. This was corroborated rather than taken on faith: no
  database on this machine has a `codd.sql_migrations` table (Discovery 1). Should a codd-era
  database appear later, the bridge remains available in the published `kioku-migrations-0.2.0.0`,
  which is permanent on Hackage — so this removal is recoverable in the only way that matters.
  Date: 2026-07-30

- Decision: Delete the user-level `cohort-migrate` skill as part of this work, at the user's
  explicit direction.
  Rationale: The skill exists solely to drive this bridge and stops working the moment the bridge
  is gone; leaving it would present a broken workflow as available. It lives outside the
  repository (Discovery 3), so it cannot appear in a commit — its deletion is recorded here
  instead. The user chose this over being left to remove it themselves.
  Date: 2026-07-30

- Decision: Release the removal as `0.3.0.0`, a PVP major bump.
  Rationale: `Kioku.Migrations.History.Codd` is an `exposed-module` of a published package and
  the `import` subcommand is part of `kioku-migrate`'s command-line contract. Removing either is
  a breaking change by definition, regardless of whether anyone was using them. The release skill
  at `agents/skills/release/SKILL.md` versions all five packages together, so all five move.
  Date: 2026-07-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This repository is at `/Users/shinzui/Keikaku/bokuno/kioku` and holds five Haskell packages
listed in `cabal.project`. Only two are touched by this plan:

`kioku-migrations/` owns the database schema evolution. Its library builds a **migration plan** —
the ordered list of every migration Kioku needs — in `kioku-migrations/src/Kioku/Migrations.hs`,
composing three **components** in dependency order: Kiroku's, then Keiro's, then Kioku's own. A
component is one package's set of migrations; the first two arrive compiled-in from the
`kiroku-store-migrations` and `keiro-migrations` packages, and Kioku's own is built from the SQL
files under `kioku-migrations/migrations/` in the order given by the plain-text file
`kioku-migrations/migrations/manifest`.

`kioku-migrate/` is a standalone executable that applies that plan. It lives in its own package
rather than inside `kioku-migrations` because `kioku-core`'s test-suite depends on
`kioku-migrations:test-support`, and an executable stanza inside `kioku-migrations` would close a
package-level dependency cycle that Cabal's solver rejects. The header comment in
`kioku-migrate/kioku-migrate.cabal` explains this.

Terms used below:

A **ledger** is the table a migration runner keeps to record which migrations it has applied.
codd's lives at `codd.sql_migrations` and is keyed by filename. pg-migrate's is keyed by
`component/name` and also stores a checksum.

The **import bridge** is the code being deleted. It reads a codd ledger and writes the equivalent
pg-migrate rows. Its Kioku-side half is the module
`kioku-migrations/src/Kioku/Migrations/History/Codd.hs`, which defines the mapping from each of
the 30 historical codd filenames to its pg-migrate identity, plus the payload evidence that lets
the import verify it is adopting the history it thinks it is. The generic half lives in the
upstream package `pg-migrate-import-codd`. The subcommand that drives it is
`kioku-migrate import` — note that plan 21 called it `import-codd` in several places, which was
wrong; the actual `Opt.command` string at `kioku-migrate/app/Main.hs:87` is `"import"`.

`kioku-migrations/codd-upgrade/` holds three reviewed SQL fixups that a downstream operator ran
alongside the import — two that realign codd's migration timestamps and one that relocates
Keiro's tables into a dedicated `keiro` schema — plus a `README.md` runbook that plan 21 extended
with the removal gate this plan satisfies.

`kioku-migrations/migrations.lock` is codd's own manifest file, kept only so the bridge could
verify payloads. Do not confuse it with `kioku-migrations/migrations/manifest`, which is
pg-migrate's apply-order file and must survive.

The prior plans are `docs/plans/20-move-kioku-off-codd-onto-pg-migrate-and-upgrade-the-keiro-kiroku-cohort.md`,
which built the bridge, and `docs/plans/21-release-kioku-for-the-keiki-0-4-keiro-0-4-baikai-0-4-and-shikumi-cohort.md`,
which deprecated it and specified this removal at the end of its Milestone 5. Kioku `0.2.0.0`,
which ships the deprecated-but-working bridge, is published on Hackage and stays there
permanently — that is the recovery path if a codd-era database ever turns up.

Every commit made under this plan must carry two git trailers, separated from the body by a
blank line:

```text
ExecPlan: docs/plans/22-remove-the-codd-import-bridge-from-kioku.md
Intention: intention_01kytapemyezfakpdf0ke73cgw
```

Commit messages follow Conventional Commits, and removing a public module is a breaking change,
so the subject takes a `!`. Commit directly to the current branch; do not create a feature branch.


## Plan of Work

### Milestone 1 — Delete the bridge

**Scope.** Every reference to codd leaves `kioku-migrations` and `kioku-migrate`, in one commit,
because the pieces do not compile independently of each other. At the end, the two packages build
and their tests pass.

Work outward from the module, since everything else is either its dependency or its consumer.

**Delete `kioku-migrations/src/Kioku/Migrations/History/Codd.hs`** and remove
`Kioku.Migrations.History.Codd` from the `exposed-modules` list of the `library` stanza in
`kioku-migrations/kioku-migrations.cabal` (line 48). It exports `kiokuCoddHistoryMappings`,
`cohortCoddHistoryMappings`, `cohortCoddSourceConfig`, `kiokuCoddSourcePayloads`,
`kiokuCoddManifestText` and `cohortCoddStateValidators`; nothing outside the bridge uses any of
them, which is what makes this a clean cut.

**Delete the directory `kioku-migrations/codd-upgrade/`** — `README.md` and the three `.sql`
fixups — and remove its two references in the same cabal file: `codd-upgrade/README.md` under
`extra-doc-files` (line 20) and `codd-upgrade/*.sql` under `extra-source-files` (line 23).

**Delete `kioku-migrations/migrations.lock`** and its `extra-source-files` entry (line 26). Read
Discovery 2 before doing this and make sure you are deleting `migrations.lock`, not
`migrations/manifest`.

**Remove `pg-migrate-import-codd` from three stanzas**: `kioku-migrations.cabal`'s `library`
(line 65) and `test-suite kioku-migrations-test` (line 98), and `kioku-migrate.cabal`'s
`executable kioku-migrate` (line 58).

**Strip the subcommand from `kioku-migrate/app/Main.hs`.** Remove the two import blocks at lines
23-26 (`Database.PostgreSQL.Migrate.History.Codd`) and 31-34 (`Kioku.Migrations.History.Codd`);
the `ImportCodd` constructor from the command sum type (line 70) and its dispatch arm (line 66);
the `CoddImportOptions` record (line 72); the `Opt.command "import"` block (lines 87-97); the
`coddImportOptionsParser` (lines 99-114); and `runImportCommand` (lines 135-163). Check whether
`renderHistoryImportJson`, used at line 162, is still referenced afterwards — if not, its import
goes too, and GHC's `-Wunused-imports` will say so.

**Remove `testCoddCohortImport` from `kioku-migrations/test/Main.hs`**: the test-list entry (line
77), the assertion itself (lines 203 onward), and the helpers `coddV5Ledger` (line 283) and
`coddSnapshotStatement` (line 362), plus the two imports at lines 42 and 51-55. Delete its
fixture `kioku-migrations/test/fixtures/pre-cutover-schema.sql`; if that leaves the fixtures
directory empty, drop `test/fixtures/*.sql` from `extra-source-files` too.

`testHistoryMappings` (line 76) also goes — it asserts `length (toList
cohortCoddHistoryMappings) @?= 30` and `kiokuCoddHistoryMappings @?= 10` against the module being
deleted, so it cannot survive it. That takes the suite from 7 tests to 6. Note that this is a
genuine reduction in coverage of nothing: both tests only ever exercised the bridge.

**Remove the two `-Wno-deprecations` flags** that plan 21 added solely to silence this bridge —
`kioku-migrations.cabal` line 90 and `kioku-migrate.cabal` line 47 — together with the
explanatory comments above them (lines 88-89 and 43-45 respectively). Leaving them would silence
future deprecations that nobody has thought about.

**Reword, do not delete, the comment at
`kioku-migrations/src/Kioku/Migrations/Internal/Definition.hs:24-26`.** It currently justifies
the `-- codd: in-txn` comments in the SQL as payload evidence for the import. After this plan the
justification is different and stronger: the files are checksummed by pg-migrate, so their bytes
are frozen on every already-migrated database. Say that. Do not open a file under
`kioku-migrations/migrations/`.

**Delete the user-level skill** at `/Users/shinzui/.claude/skills/cohort-migrate`. It is outside
this repository, so it will not appear in the commit; record it in Progress and Outcomes instead.

**Acceptance.** Concrete Steps §1.2: `cabal build all` succeeds and `grep -ri codd` over the two
packages returns nothing but changelog text.

### Milestone 2 — Prove nothing else depended on it

**Scope.** No edits, unless the evidence demands them. This milestone exists because the risk in
a deletion is not that it fails to compile — it is that something silently stops being tested, or
that a database behaves differently than before.

Run the suites, then check the two behaviors that actually matter to an operator. First, the help
output must no longer advertise a subcommand that does not exist. Second, and more important, the
migration plan itself must be unchanged: a fresh database must still receive the same 38
migrations in the same order, because nothing in this plan touches the plan-building code. That
second check is what distinguishes "I deleted the bridge" from "I broke migrations".

**Acceptance.** `cabal test all` green with the migration suite reporting 6 tests;
`cabal run kioku-migrate -- --help` listing no `import`; and the §2.3 fresh-database transcript
showing `applied=38 pending=0 unknown=0`.

### Milestone 3 — Document and release

**Scope.** Changelogs and a `0.3.0.0` release, driven by `agents/skills/release/SKILL.md`. Read
that file first; it is the authority. Note that it is marked `disable-model-invocation: true`, so
it cannot be invoked as `/release` — follow its steps by hand.

`kioku-migrations`' changelog gets a `### Removed` heading naming the module, the `codd-upgrade/`
directory, `migrations.lock`, and the `pg-migrate-import-codd` dependency, and stating plainly
that a database with a codd ledger must use `kioku-migrations-0.2.0.0` to cross over, since that
release stays on Hackage forever. `kioku-migrate`'s gets a `### Removed` naming the `import`
subcommand with the same pointer. The other three packages get "no API change; released in
lockstep". The root changelog gets the combined summary for the GitHub release.

Two of the skill's steps deserve attention here, both learned the hard way in plan 21: build
documentation with `cabal haddock lib:<pkg>` rather than bare `cabal haddock`, because the
unscoped form includes the `test-support` sublibrary and produces an archive entry containing a
`:` that Hackage rejects; and expect the post-release scratch-project check to be slow on a cold
package database rather than hung.

**Acceptance.** `git tag --list 'v*'` shows `v0.3.0.0`, five packages are on Hackage at
`0.3.0.0`, and a scratch project outside the repository resolves `kioku-migrations-0.3.0.0` from
Hackage alone.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/kioku` unless stated otherwise.

### §1 — Milestone 1

**§1.1 Confirm the gate one more time before deleting anything.** This is cheap and the deletion
is the kind of thing that is embarrassing to get wrong.

```bash
psql -lqtA | cut -d'|' -f1 | grep -v '^$' | while read db; do
  n=$(psql -d "$db" -tAc "SELECT count(*) FROM information_schema.tables
                          WHERE table_schema='codd' AND table_name='sql_migrations'" 2>/dev/null)
  [ "$n" = "1" ] && echo "$db HAS codd.sql_migrations"
done
```

Expect no output. If any database is named, **stop** — that database still needs the bridge, and
this plan's premise is wrong for it.

**§1.2 Make the edits** described in Plan of Work Milestone 1, then:

```bash
rm -rf kioku-migrations/codd-upgrade kioku-migrations/migrations.lock
rm -f kioku-migrations/test/fixtures/pre-cutover-schema.sql
rm -f kioku-migrations/src/Kioku/Migrations/History/Codd.hs
rm -rf /Users/shinzui/.claude/skills/cohort-migrate
cabal build all 2>&1 | tail -20
grep -rni codd --include='*.hs' --include='*.cabal' kioku-migrations kioku-migrate
```

Expect the build to succeed and the grep to return nothing at all. `migrations/manifest` must
still exist — check it explicitly, because deleting the wrong manifest is the one mistake here
that a build failure might not catch immediately:

```bash
test -f kioku-migrations/migrations/manifest && echo "apply-order manifest intact"
```

**§1.3 Commit** as `feat(migrations)!: remove the codd import bridge`, with a body naming what
went and pointing at `kioku-migrations-0.2.0.0` as the crossing path for any codd-era database.

### §2 — Milestone 2

**§2.1 Run the suites.**

```bash
cabal test all
```

Expect green, with `kioku-migrations` reporting `All 6 tests passed` — down from 7, because
`testCoddCohortImport` and `testHistoryMappings` are gone. `kioku-core` should still report 130
and `kioku-cli` 36; if either moves, something unrelated broke.

**§2.2 Confirm the subcommand is gone.**

```bash
cabal run kioku-migrate -- --help
```

Expect `up`, `status`, `verify` and the rest, with no `import` line.

**§2.3 Confirm the migration plan is unchanged** against a throwaway database. This is the check
that matters; it proves the deletion touched only the bridge.

```bash
createdb kioku_plan22_check
DATABASE_URL="host=$PGHOST dbname=kioku_plan22_check user=$(id -un)" cabal run kioku-migrate -- up
DATABASE_URL="host=$PGHOST dbname=kioku_plan22_check user=$(id -un)" cabal run kioku-migrate -- verify
```

Expect every migration to report `outcome=applied_now`, and the verify to print:

```text
verification ok
applied=38
pending=0
unknown=0
```

38 is the same total plan 21 established, which is the point. Drop the database afterwards:
`dropdb kioku_plan22_check`.

### §3 — Milestone 3

**§3.1 Write the changelog entries** described in Plan of Work Milestone 3 under an
`## Unreleased` heading, and commit as `docs(changelog): describe the codd bridge removal`.

**§3.2 Follow `agents/skills/release/SKILL.md` by hand** with a `major` bump, giving `0.3.0.0`.
Its four gates are mandatory: `nix fmt`, `cabal build all`, `cabal test all`, `nix flake check`.
Publish in the order it specifies: `kioku-api`, `kioku-migrations`, `kioku-core`, `kioku-cli`,
`kioku-migrate`.

**§3.3 Verify from Hackage alone**, in a scratch directory outside this repository with no
`cabal.project`:

```bash
mkdir -p /tmp/kioku-0300-check && cd /tmp/kioku-0300-check
cabal update
cat > check.cabal <<'EOF'
cabal-version: 3.0
name:          check
version:       0
build-type:    Simple

library
  default-language: GHC2024
  build-depends: base, kioku-migrations ^>=0.3.0.0
EOF
cabal build --dry-run
```

Expect a complete plan naming `kioku-migrations-0.3.0.0`. Give it several minutes on a cold
package database.


## Validation and Acceptance

The change is effective when all five of these hold.

*The bridge is gone from the source.* `grep -rni codd --include='*.hs' --include='*.cabal'
kioku-migrations kioku-migrate` returns nothing. Note the `-i` — `Codd`, `codd` and `CoddImport`
all matter.

*The operator-visible surface is gone.* `cabal run kioku-migrate -- --help` lists no `import`
subcommand, and `cabal run kioku-migrate -- import` exits with a usage error naming it as an
unknown command.

*Nothing else regressed.* `cabal build all` and `cabal test all` green, with `kioku-core` at 130
tests, `kioku-cli` at 36, and `kioku-migrations` at 6.

*Migration behavior is byte-for-byte unchanged.* §2.3 on a fresh database reports
`applied=38 pending=0 unknown=0`, and no file under `kioku-migrations/migrations/` differs:
`git diff --stat HEAD~1 -- kioku-migrations/migrations/` prints nothing on the removal commit.
This is the check that would catch the checksum-breaking mistake described in the Decision Log.

*The removal is published honestly.* Five packages at `0.3.0.0` on Hackage, changelogs naming
what was removed and pointing at `0.2.0.0` for anyone who still needs to cross over.


## Idempotence and Recovery

Every step in Milestones 1 and 2 is an ordinary source edit under version control. Until the
removal commit is pushed, `git checkout -- <path>` or `git reset --hard` restores anything;
after it, `git revert` does. The deletion is therefore not a one-way door inside this repository.

The genuinely irreversible parts are two, and both are already mitigated. Deleting
`/Users/shinzui/.claude/skills/cohort-migrate` is outside version control — if it turns out to be
wanted, it must be rewritten from scratch, so confirm the intent before running the `rm`. And a
published Hackage version cannot be withdrawn or reused; but the recovery path for the *bridge*
is not a Kioku change at all — `kioku-migrations-0.2.0.0` and `kioku-migrate-0.2.0.0` carry the
working bridge and stay on Hackage permanently. Anyone who discovers a codd-era database after
this release pins those versions, crosses over, then upgrades. That is why this removal is safe
to make even though a migration ledger has no unapply.

The one step that touches a database, §2.3, creates its own throwaway (`kioku_plan22_check`) and
drops it afterwards. Do not point it at a database you care about; there is no reason to, since
the check is about a *fresh* database reaching 38 migrations.

If `cabal build all` fails midway through Milestone 1 with unused-import or missing-symbol
errors, that is expected — the pieces do not compile independently, which is why they are one
commit. Work through the errors rather than reverting; GHC's messages name the exact remaining
reference.


## Interfaces and Dependencies

At the end of Milestone 1, `kioku-migrations`' `library` stanza exposes exactly one module:

```haskell
-- kioku-migrations/kioku-migrations.cabal, library stanza
exposed-modules: Kioku.Migrations
```

and these signatures, which this plan does not change, must still hold:

```haskell
-- kioku-migrations/src/Kioku/Migrations.hs
kiokuMigrationPlan :: Either PlanError MigrationPlan

-- kioku-migrations/src/Kioku/Migrations/Internal/Definition.hs
embeddedMigrationEntries :: NonEmpty (FilePath, ByteString)
kiokuMigrations :: Either DefinitionError MigrationComponent
```

`Kioku.Migrations.History.Codd` and every symbol it exported —
`kiokuCoddHistoryMappings`, `cohortCoddHistoryMappings`, `cohortCoddSourceConfig`,
`kiokuCoddSourcePayloads`, `kiokuCoddManifestText`, `cohortCoddStateValidators` — no longer
exist. That is the breaking change the major bump announces.

The dependency `pg-migrate-import-codd ^>=1.1.0.0` is removed from all three stanzas that
declared it. The remaining pg-migrate packages stay exactly as they are: `pg-migrate ^>=1.1.0.0`
and `pg-migrate-embed ^>=1.1.0.0` in `kioku-migrations`' library, plus `pg-migrate-cli ^>=1.1.0.0`
in `kioku-migrate` and `pg-migrate-test-support` behind `test-support`. Nothing else in the
cohort — `keiro-migrations ^>=0.4.0.1`, `kiroku-store-migrations ^>=0.3.0.0` — moves, because this
plan is a deletion rather than an upgrade.

The upstream package `pg-migrate-import-codd` continues to exist on Hackage; Kioku simply stops
depending on it. Should the bridge ever be needed again, it is reachable both through that
package directly and through the published `kioku-migrations-0.2.0.0`.
