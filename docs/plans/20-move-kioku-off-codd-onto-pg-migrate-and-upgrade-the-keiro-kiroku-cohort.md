---
id: 20
slug: move-kioku-off-codd-onto-pg-migrate-and-upgrade-the-keiro-kiroku-cohort
title: "Move kioku off codd onto pg-migrate and upgrade the keiro kiroku cohort"
kind: exec-plan
created_at: 2026-07-12T00:05:25Z
---

# Move kioku off codd onto pg-migrate and upgrade the keiro kiroku cohort

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, applying kioku's database schema means running `just migrate`, which sets four
`CODD_*` environment variables — two of which are literal dummy strings that exist only to
satisfy a library that never reads them — and shells into a binary that hands a pile of
embedded SQL to **codd**, a schema-migration tool. Codd decides whether a migration has
already run by looking at nothing but its **filename**. Rename a file and codd re-runs it.
Edit an applied file's body and codd never notices. There is no checksum, no verification,
and no way to ask "is this database's schema the one my code expects?"

Our two upstream libraries — **kiroku** (a PostgreSQL event store) and **keiro** (an event
sourcing framework and workflow engine) — have already left codd behind for **pg-migrate**,
a migration runner that keys migrations by a stable logical identity (`component/name`),
records a SHA-256 checksum of every applied migration, and can tell you on demand whether
the database matches the code. Kioku is the last member of the cohort still on codd, and it
is pinned to versions of keiro and kiroku from before their cutover. That pin is now
holding back five months of upstream work.

After this change, a developer can run `cabal run kioku-migrate -- up` against a database
and get a checksummed, verifiable schema. They can run `cabal run kioku-migrate -- status`
and see exactly which of the 35 migrations across the three components are applied and which
are pending. They can run `cabal run kioku-migrate -- verify` and have it *fail loudly* if
someone edited an applied migration's body behind their back — something codd cannot do at
all. The four `CODD_*` environment variables collapse into one `DATABASE_URL`. And kioku
picks up everything keiro and kiroku shipped in the meantime: a logical truncate-before
marker on event streams, batched outbox and inbox processing, and keiro's framework tables
moving out of kiroku's schema into their own.

Kioku is a *library*. Other repositories — mori, shikigami, rei — build their own migrate
binaries that compose kioku's migrations into their own databases. Those databases hold data
and cannot simply be dropped. So this plan also ships an **import path**: a one-time,
forward-only operation that reads a downstream database's existing codd ledger, proves each
historical migration's bytes match what kioku's code now expects, and writes the equivalent
pg-migrate ledger rows **without re-running a single line of DDL**. A downstream operator
runs one command, and their database is on pg-migrate with zero schema churn and zero risk
of a destructive re-apply.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

### Milestone 1 — kioku-migrations becomes a native pg-migrate component

- [x] (2026-07-12T00:33:29Z) Bump the keiro, kiroku, shibuya, and shibuya-pgmq-adapter pins; add the five `pg-migrate` stanzas; leave the codd stanza in place for now.
- [x] (2026-07-12T04:16:35Z) Commit the Keiro source-package fix locally as `3187e9b345c27af077fcbbe122abfae6ad8ba67d`, staging only `keiro-migrations/keiro-migrations.cabal` and preserving unrelated Keiro worktree changes.
- [x] (2026-07-12T04:16:35Z) Validate Keiro's source distribution file list contains `keiro-migrations/migrations.lock`.
- [x] (2026-07-12T04:16:35Z) Confirm `git push --dry-run origin master` would publish only `0a1b5d6..3187e9b` for Keiro.
- [x] (2026-07-12T04:26:48Z) Push Keiro commit `3187e9b`, pin all Keiro packages to it, restore the `keiro-migrations` source-repository stanza, and remove the temporary local override.
- [x] (2026-07-12T00:33:29Z) Confirm `cabal build --dry-run kioku-migrations` produces a resolving build plan, after adding the scoped Baikai/crypton compatibility exception.
- [x] (2026-07-12T00:33:29Z) `git mv` all ten SQL files to `kioku-migrations/migrations/` in `NNNN-slug.sql` form; `git diff --cached --summary -M` reports 100% similarity for all ten.
- [x] (2026-07-12T00:33:29Z) Write `kioku-migrations/migrations/manifest` listing the ten files in apply order.
- [x] (2026-07-12T00:33:29Z) Generate `kioku-migrations/migrations.lock`; re-hashing the renamed files reproduces all ten old-filename lock entries.
- [x] (2026-07-12T00:33:29Z) Rewrite `Kioku.Migrations` to export the native component and full plan, removing the codd runners and file-embed staleness hack.
- [x] (2026-07-12T00:33:29Z) Rewrite `kioku-migrations.cabal` to drop the production codd/file-embed dependencies and add pg-migrate/pg-migrate-embed.
- [x] (2026-07-12T00:33:29Z) Acceptance for the isolated library: `cabal build lib:kioku-migrations` succeeds; the exact package target remains open because Cabal also builds `lib:test-support`, which Milestone 3 intentionally rewrites.
- [x] (2026-07-12T04:10:33Z) Acceptance for the full package target: `cabal build kioku-migrations` succeeds after Milestone 3's test-support migration.

### Milestone 2 — kioku-core absorbs keiro's breaking changes

- [x] (2026-07-12T00:39:10Z) Construct `memoryEventStream` and `sessionEventStream` once with `mkEventStreamOrThrow` before handing them to keiro's command runners; add the required `Ord` instances to both vertex types.
- [x] (2026-07-12T00:39:10Z) Add `schema = "kiroku"` to all 19 `ReadModel` values (10 memory and 9 session in the actual source).
- [x] (2026-07-12T00:39:10Z) Audit source SQL naming `keiro_*`; only migration 0006 names the registry directly, and it deliberately resolves `keiro`, `kiroku`, then `public`. Runtime reconciliation uses keiro's compiled API.
- [x] (2026-07-12T00:39:10Z) Absorb shibuya-core 0.8: `OrderingPolicy`, `AppConfig`, and read-only `Message` handler integration, with explicit `>=0.8.0.1 && <0.9` bounds.
- [x] (2026-07-12T00:39:10Z) Acceptance: `cabal build kioku-core` succeeds.

### Milestone 3 — migrations apply to a live database; codd is gone

- [x] (2026-07-12T00:55:02Z) Rewrite test support onto pg-migrate-test-support and ephemeral-pg while preserving both public signatures exactly.
- [x] (2026-07-12T04:10:33Z) Qualify four test-fixture SQL statements that named Keiro tables without the new `keiro` schema; the focused `kioku-test` suite then passed all 115 tests.
- [x] (2026-07-12T00:55:02Z) Rewrite `kioku-migrate` onto pg-migrate-cli and run read-model reconciliation only after a successful `up`.
- [x] (2026-07-12T00:55:02Z) Delete the codd source/package stanzas and remove `../codd-extras` from the local project configuration.
- [x] (2026-07-12T00:55:02Z) Replace the codd filename/embed tests with pg-migrate manifest integrity while retaining all registry layout and fresh-database tests.
- [x] (2026-07-12T04:10:33Z) Acceptance: `just create-database` on a fresh database succeeds with 35 applied rows; `verify` exits 0, its checksum-negative probe fails as expected, repeated `up` is a no-op, and the final `cabal test all` passes all suites (115 Kioku core tests, 7 Kioku migration tests, and dependency suites).

### Milestone 4 — the codd-history import path for downstream databases

- [x] (2026-07-12T00:55:02Z) Add `Kioku.Migrations.History.Codd` with kioku's ten mappings, legacy names, embedded payloads, lock text, and state validators.
- [x] (2026-07-12T00:55:02Z) Correct the pinned source profile to 30 historical mappings: kiroku 6 + keiro 14 + kioku 10. The remaining five cohort migrations are genuinely pending and run normally after import.
- [x] (2026-07-12T00:55:02Z) Encode nine kioku migrations as `SamePayload`, kioku 0006 as `EquivalentState`, the six byte-identical pinned kiroku migrations as `SamePayload`, and all 14 rewritten keiro migrations as `EquivalentState` with relocated-schema validation.
- [x] (2026-07-12T00:55:02Z) Add the `import` subcommand using the embedded 30-row mapping, mixed payload/state evidence, explicit confirmation, audit reason, and equivalent-history opt-in.
- [x] (2026-07-12T04:16:35Z) Commit the validator-aware partial-manifest adapter and its integration regression locally as pg-migrate `29d036e47bc3e07f5f44846be2c34725ba100246`.
- [x] (2026-07-12T04:16:35Z) Confirm `git push --dry-run origin master` would publish only `4a4dc9d..29d036e` for pg-migrate.
- [x] (2026-07-12T04:26:48Z) Push pg-migrate commit `29d036e`, pin all five pg-migrate packages to it, restore the `pg-migrate-import-codd` source-repository stanza, and remove the temporary local override.
- [x] (2026-07-12T04:26:48Z) Validate the portable project: Cabal fetched both exact remote commits, `cabal build all` and `cabal test all` passed without `cabal.project.local`, the rehearsal still imported 30 then applied five, and live `status`/`verify`/repeated `up` reported a clean 35-row 8/17/10 ledger.
- [x] (2026-07-12T04:10:33Z) Write the rehearsal test from the exact 30 historical payloads at Kiroku `4312aa8`, Keiro `f1d67a0`, and Kioku's pre-cutover tree; run both upstream filename fixups, Keiro relocation, import, forward `up`, `verify`, repeated import, and repeated `up`.
- [x] (2026-07-12T04:10:33Z) Add an adapter-level regression proving a partial manifest supports mixed `SamePayload` and validator-backed `EquivalentState` mappings without executing either target action; all 10 adapter integration tests pass.
- [x] (2026-07-12T04:10:33Z) Acceptance: the rehearsal test passes; `docs/user/upgrading-to-pg-migrate.md` gives a downstream operator a backup-first, quiescent runbook they can follow without reading this plan.

### Milestone 5 — tooling and documentation

- [x] (2026-07-12T04:10:33Z) Rewrite the `migrate`, `create-database`, and `new-migration` recipes in `Justfile`; a temporary scaffold created `0011-codex-rehearsal.sql`, appended the manifest, and passed its integrity test before being removed.
- [x] (2026-07-12T04:10:33Z) Prove a stray SQL file is rejected with `UnlistedSqlFiles ["9999-codex-unlisted.sql"]`, then remove the probe and restore the ten-entry manifest.
- [x] (2026-07-12T04:10:33Z) Update `docs/user/library-api.md`, `docs/user/getting-started.md`, `docs/user/recall.md`, `docs/user/troubleshooting.md`, `README.md`, and the stale codd comment in `nix/haskell.nix`; add the downstream upgrade runbook.
- [x] (2026-07-12T04:16:35Z) Add `kioku-migrations/CHANGELOG.md` documenting the breaking runner API replacement, stable migration identities, history importer, and signature-preserving test support; include it in the source package.
- [x] (2026-07-12T04:16:35Z) Validate Kioku's source distribution includes the changelog, history lock, migration SQL/manifest, and exact pre-cutover rehearsal fixtures.
- [x] (2026-07-12T04:16:35Z) Ship byte-identical copies of the two upstream ledger fixups and Keiro relocation under `kioku-migrations/codd-upgrade/`, point the runbook and rehearsal at those operator artifacts, and remove the runbook's dependency on sibling source checkouts.
- [x] (2026-07-12T04:10:33Z) Fill in Outcomes & Retrospective with the delivered behavior, evidence, lessons, and publication progress.
- [x] (2026-07-12T04:30:59Z) Commit the portable Kioku implementation as `27d566265d029a5a8aa5ef079d5bf4069b0e95f8` with the ExecPlan trailer, then complete the post-commit audit: clean build, all tests, live 35-row status/verify/no-op up, source-distribution contents, 100% SQL renames, lock hashes, byte-identical operator scripts, removed Codd configuration, 19 read-model schemas, validated streams, and exact upstream remote heads all pass.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Two things were already discovered during the research that produced this plan. They are
recorded here because they shaped the design, and the implementer will trip over them
otherwise.

**`pg-migrate-import-codd` does not depend on codd.** This was not obvious and it is load-bearing.
The adapter reads codd's ledger tables directly over `hasql` — it never links the codd
library. Confirmed by reading its build-depends:

```text
$ grep -A8 build-depends pg-migrate-import-codd/pg-migrate-import-codd.cabal
  build-depends:
      base
    , hasql                 >=1.10 && <1.11
    , optparse-applicative  >=0.19 && <0.20
    , pg-migrate            >=1.0  && <1.1
    , pg-migrate-cli        >=1.0  && <1.1
```

The consequence is that kioku can delete codd from its build entirely — including the
untracked `../codd-extras` local checkout — and *still* offer downstream databases a
codd-history import path. Without this fact the plan would have had to keep codd around
forever just to read the old ledger.

**The pg-migrate pin exposes a pre-existing `baikai-claude` bound that is too narrow.** The
current and pinned Baikai HEAD declares `crypton ^>=1.0`, while pg-migrate 1.0 requires
`crypton >=1.1 && <1.2`, so Cabal cannot select both without an override. Baikai uses only the
stable `Crypto.Hash` `Digest`, `SHA256`, and `hash` API, and there is no newer Baikai commit to
pin. The project therefore carries the narrow `allow-newer: baikai-claude:crypton` exception.
The original dry-run failed with:

```text
rejecting: pg-migrate-1.0.0.0
(conflict: crypton==1.0.6, pg-migrate => crypton>=1.1 && <1.2)
```

**Keiro 0.2.0.0's source package omits the lock file that its library embeds.** A
source-repository build reaches `Keiro.Migrations.History.Codd` and then fails because
`keiro-migrations/keiro-migrations.cabal` lists the SQL and manifest under
`extra-source-files` but not `migrations.lock`:

```text
Exception when trying to run compile-time code:
  ./migrations.lock: withBinaryFile: does not exist (No such file or directory)
```

The fix was published as Keiro commit `3187e9b345c27af077fcbbe122abfae6ad8ba67d`, which adds
`migrations.lock` to `extra-source-files`. Kioku pins that commit and a source-distribution listing
proves the embedded lock is shipped.

**`cabal build kioku-migrations` is not an isolated library gate in this project.** Because
`kioku-migrations` contains a public `test-support` sublibrary, the package target builds both
libraries. The native migration library compiled successfully, then the old test-support code failed
on its import of `runKiokuMigrationsNoCheck`, which this milestone deliberately removes and Milestone
3 deliberately replaces. The build transcript ends with:

```text
Module ‘Kioku.Migrations’ does not export ‘runKiokuMigrationsNoCheck’.
```

The Milestone 1 proof is therefore the `lib:kioku-migrations` component; the original package-level
command remains a full-package gate after the Milestone 3 rewrite.

**The Keiro validation constructor is not named `validateEventStream`.** At the pinned API,
`validateEventStream` returns a list of warnings and cannot produce the wrapper command runners
require. `mkEventStream` returns the `Either`, and `mkEventStreamOrThrow` is the documented partial
constructor for static definitions. Kioku uses the latter once at module initialization. That also
exposed that both vertex enums needed `Ord`, in addition to their existing `Eq`, `Enum`, and
`Bounded` instances.

**The plan's 19-read-model split was reversed.** The compiler and source contain 10 memory read
models and 9 session read models, not 11 and 8. The total and required change were still correct;
an exact count after the edit reports 10 and 9 `schema = "kiroku"` fields.

**The pinned pre-cutover cohort has 30 codd rows, not 33.** The old kiroku pin contains six
migrations while current kiroku history mapping contains seven; the old keiro pin contains 14 while
current keiro history mapping contains 16. Kioku contributes ten. The three absent migrations are
not historical evidence and must not be imported. Along with the two schema canaries, they are the
five migrations a subsequent native `up` correctly applies. Git tree evidence at the old pins is:

```text
kiroku 4312aa8: 6 sql-migrations files
keiro  f1d67a0: 14 sql-migrations files
kioku current: 10 historical files
```

**Keiro's 14 pinned migration payloads are not byte-identical to the pg-migrate targets.** The
schema-relocation commits rewrote every file to qualify DDL under `keiro`; rename similarity from the
old pin ranges from 50% to 89%, not 100%. Therefore the upstream `SamePayload` mappings cannot
honestly describe a database upgraded by the relocation remediation. Kioku replaces those 14
relations with `EquivalentState` backed by a read-only catalog/data validator. Kiroku's six pinned
files are true 100% renames and retain `SamePayload`.

**pg-migrate-import-codd 1.0 cannot express mixed payload/state imports as published.** Its importer
hardcodes an empty state-validator list, and when any manifest is present it requires a manifest row
and source payload for every selected codd row. The local dependency now has a backward-compatible
`importCoddHistoryWithValidators` entry point and treats rows omitted from a partial manifest as
ledger-only evidence; target validation still rejects `SamePayload` mappings without checksums. This
was published as pg-migrate commit `29d036e47bc3e07f5f44846be2c34725ba100246` and is pinned here.

**Keiro's rename changed its apply order for fresh databases.** Codd ordered migrations by the
UTC timestamp in the filename. When keiro renamed its files from sentinel timestamps
(`2026-06-05-00-00-00-…`) to real authoring times, two pairs swapped: `messaging-crash-recovery`
now runs *before* `workflows-instances`, and `projection-dedup` now runs *last* instead of
before `gc-index`. This is baked into keiro's `migrations/manifest` at positions 0010/0011
and 0014. For a database that already applied everything, this is inert. For a **fresh**
database — which is every kioku dev and test database — the DDL now executes in a different
sequence than it ever has before. Milestone 1's acceptance (a fresh `just create-database`
succeeding) is the first time anyone will have exercised that order in kioku's context.

**The downstream specs contained four schema-dependent fixture statements.** Keiro's runtime SQL is
fully qualified and explicitly documents that it must not depend on `search_path`, but three test
modules still issued unqualified `UPDATE`/`SELECT` statements against `keiro_read_models` and
`keiro_timers`. After the schema relocation those fixtures failed with `42P01`; qualifying them as
`keiro.keiro_read_models` and `keiro.keiro_timers` restored all 115 `kioku-test` cases. The original
expectation that no downstream database spec would change was therefore too strong: production code
needed no search-path workaround, while test-owned SQL correctly had to follow the new schema.

**The exact historical fixture is small enough to make the import rehearsal hermetic.** The 30
pre-cutover payloads total roughly 62 KiB. Checking them into `test/fixtures/pre-cutover-schema.sql`
with source commit annotations avoids runtime dependency on sibling repositories and lets the test
execute the actual old DDL in Codd timestamp order. Byte-identical copies of the two upstream ledger
fixups and the Keiro relocation script live under `codd-upgrade/`; both the test and operator runbook
execute those shipped artifacts.

**pg-migrate-cli's inferred filename does not retain a requested slug.** With a numeric manifest,
`new` can infer the next prefix, but it creates a bare name such as `0011.sql`; its parser has no
positional slug. Producing Kioku's required `0011-some-slug.sql` identity therefore requires the
Justfile to validate the slug, derive the next fixed-width prefix, and pass the combined basename via
`--name`. The CLI still owns exclusive file creation and atomic manifest replacement.


## Decision Log

Record every decision made while working on the plan.

- **Decision:** Ship a codd-history import path for downstream consumers rather than requiring
  them to drop and recreate their databases.
  **Rationale:** Kioku is a library. Its own dev and test databases are disposable
  (`db/` is gitignored; test databases are ephemeral per-test), but mori, shikigami, and rei
  each compose `kiokuMigrations` into their own migrate binary against their own database,
  and those hold real data. Keiro and kiroku both shipped exactly this facility
  (`frameworkCoddHistoryMappings`, `kirokuCoddHistoryMappings`); kioku would be the one
  cohort member that forces a destructive rebuild on its consumers. The user explicitly
  chose this option when scoping the plan.
  **Consequence:** The ten SQL files must be renamed with their bytes preserved exactly, which
  means the now-inert `-- codd: in-txn` header line stays in every file. It is harmless —
  pg-migrate's scanner only recognizes directives beginning `pg-migrate:`, so a `codd:`
  comment is just a comment — but it will look like dead code to a future reader. Milestone 1
  must leave a note in the files or the manifest explaining why the line survives.
  **Date:** 2026-07-12

- **Decision:** Do not relocate kioku's own tables out of the `kiroku` schema.
  **Rationale:** Kioku's tables (`kioku_memories`, `kioku_scenes`, …) currently live inside
  the `kiroku` schema because every migration begins `SET search_path TO kiroku, pg_catalog;`.
  Keiro just did the equivalent relocation for its own tables, so there is an obvious
  temptation to follow. We are declining: it is a second database-breaking change riding on
  an already-large upgrade, it would need its own remediation script and its own rehearsal
  against downstream data, and nothing in this plan requires it. Recorded as a follow-up.
  **Date:** 2026-07-12

- **Decision:** Pin kiroku at `876fb66` (its HEAD, the release commit) rather than at
  `6399844`, the commit keiro's own `cabal.project` pins.
  **Rationale:** Keiro's `keiro-migrations` requires `kiroku-store-migrations ^>=0.2.0.0`.
  That bound is satisfied at *both* shas — `kiroku-store-migrations` is already 0.2.0.0 at
  `6399844`. The four commits between them are documentation, the removal of expected-schema
  leftovers, and the release version bumps for the other kiroku packages. Pinning HEAD gets
  kioku the properly-versioned `kiroku-store` 0.3.0.0 rather than an unreleased intermediate.
  Note that keiro's `cabal.project` is *not* consulted when keiro is consumed as a
  `source-repository-package` — kioku's own `cabal.project` picks the shas for the whole
  build plan, so there is no conflict to resolve.
  **Date:** 2026-07-12

- **Decision:** Sequence the work as five milestones that follow the package dependency DAG,
  accepting that the tree does not fully compile until the end of Milestone 3.
  **Rationale:** Bumping the keiro and kiroku pins breaks three things at once and there is no
  way to avoid it: `kioku-migrations` (the migration API it calls is gone), `kioku-core`
  (`ValidatedEventStream` and `ReadModel.schema`), and `kioku-migrate` (which depends on both,
  plus codd). But those three form a DAG, and `kioku-migrations`'s *library* does not depend
  on `kioku-core` at all. So `cabal build kioku-migrations` is a real, checkable acceptance
  gate for Milestone 1 even while the rest of the tree is red. The alternative — one giant
  "make it compile" milestone — would have no intermediate verification at all.
  **Date:** 2026-07-12

- **Decision:** Permit only `baikai-claude` to exceed its `crypton ^>=1.0` upper bound.
  **Rationale:** pg-migrate requires the 1.1 series, Baikai HEAD has no compatible-bound commit to
  pin, and Baikai's source uses only the unchanged `Crypto.Hash` hashing surface. Scoping the
  exception to one package/dependency pair preserves all other solver bounds.
  **Date:** 2026-07-12

- **Decision:** Keep pg-migrate's manifest strictly data-only and document the retained
  `-- codd: in-txn` headers in this plan and source-level migration API commentary instead of adding
  a manifest comment.
  **Rationale:** The plan's early prose requested a comment at the top of the manifest, but the same
  plan correctly states later that manifest format v1 rejects comments and blank lines. A comment
  would make the component fail at compile time. Preserving valid manifest input takes precedence.
  **Date:** 2026-07-12

- **Decision:** Use `cabal build lib:kioku-migrations` as Milestone 1's isolated component gate and
  defer the exact package target to Milestone 3.
  **Rationale:** Cabal includes the public test-support sublibrary in a package target, and that
  sublibrary necessarily remains broken between removal of the codd runner in Milestone 1 and its
  pg-migrate rewrite in Milestone 3. The narrower target proves exactly the DAG claim the milestone
  intended without pretending the known downstream sublibrary is already migrated.
  **Date:** 2026-07-12

- **Decision:** Construct the two validated static streams with `mkEventStreamOrThrow` at module
  initialization.
  **Rationale:** The current Keiro source documents this constructor for generated or otherwise
  statically-proven definitions. It validates once, returns the opaque `ValidatedEventStream` the
  command runners require, and turns any future replay-safety regression into a loud programmer
  error instead of repeated runtime validation.
  **Date:** 2026-07-12

- **Decision:** Preserve `embeddingHandler`'s existing `Ingested`-based test surface while adding an
  internal `Message` adapter for shibuya 0.8 production wiring.
  **Rationale:** Shibuya intentionally removed acknowledgement handles from application handlers,
  but kioku's exported helper and tests only inspect the envelope. Routing both entry points through
  a common envelope function adopts the safety change without forcing unrelated database specs to
  construct new framework values.
  **Date:** 2026-07-12

- **Decision:** Import the exact 30 migrations present at kioku's pinned keiro/kiroku cohort, then
  let native `up` apply the five later cohort migrations.
  **Rationale:** Importing mappings for absent codd rows fails source validation and fabricates
  history. The old pins prove a 6/14/10 split. Applying kiroku 0007/0008 and keiro 0015/0016/0017
  normally preserves the component prefix invariant and produces the final 8/17/10 (35-row) ledger.
  **Date:** 2026-07-12

- **Decision:** Override upstream keiro history mappings for the 14 pinned migrations with
  `EquivalentState` and a comprehensive relocated-schema validator.
  **Rationale:** Those payloads were edited in place when keiro moved its tables from `kiroku` to
  `keiro`; Git proves they are not the bytes the old database ran. The remediation produces an
  equivalent final schema, which is exactly what state-verified history represents.
  **Date:** 2026-07-12

- **Decision:** Extend pg-migrate-import-codd with validator-aware import and partial-manifest
  evidence rather than weakening mappings to false `SamePayload` claims.
  **Rationale:** A partial manifest lets genuinely byte-identical rows carry checksummed evidence
  while rewritten rows remain ledger-only and rely on explicit read-only validators. The generic
  history layer already enforces that every `SamePayload` relation has a matching checksum.
  **Date:** 2026-07-12

- **Decision:** Use `EquivalentState` rather than
  `SamePayload` for the history mapping of `0006-kioku-session-readmodel-registry-bump`.
  **Rationale:** That migration's *body was rewritten in place* on 2026-07-11 (see
  `docs/plans/14-…`). This was safe under codd, which keys by filename and never re-reads an
  applied file. But it means a downstream database that migrated before that date executed
  **different bytes** than the file now contains. `SamePayload` is an assertion that the
  database ran exactly these bytes, and for `0006` on such a database that assertion is false.
  The import would still *succeed* — the checksum we would supply as evidence comes from the
  same current bytes as the target plan, so the two would trivially agree — which makes this a
  silent, self-certifying lie rather than a caught error. The honest encoding is
  `EquivalentState` plus a `StateValidator` that reads `keiro_read_models` and proves the eight
  session read-model rows are at version 3 with shape hash `kioku-session-v3`, which is the
  outcome the migration exists to produce regardless of which body produced it. This requires
  passing `withEquivalentHistory AllowEquivalentHistory` to the import options. The other nine
  migrations have never had their bodies edited post-apply and keep `SamePayload`.
  Git history confirmed that the other nine Kioku payloads retained their historical bytes; the
  implemented 30-row rehearsal validates this mapping against a pre-cutover database.
  **Date:** 2026-07-12

- **Decision:** Let the Justfile derive only the descriptive basename while pg-migrate-cli performs
  the actual migration creation.
  **Rationale:** The published CLI's numeric inference creates `NNNN.sql` and cannot accept a slug to
  combine with that inferred prefix. Passing an explicit `--name NNNN-slug` preserves Kioku's stable
  naming convention without reimplementing the safety-critical exclusive-create and atomic-manifest
  behavior.
  **Date:** 2026-07-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

The repository now has a native, manifest-embedded 35-migration plan: Kiroku 8, Keiro 17, and
Kioku 10. Fresh migration, status, verification, repeated `up`, and checksum-mismatch behavior have
all been exercised. The Keiro/Kiroku/Shibuya cohort upgrade compiles, all 19 read models declare their
schema, event-stream definitions are validated once, and the Shibuya 0.8 handler boundary is in use.

The downstream cutover is also executable rather than merely documented. The rehearsal starts with
the exact 30 historical Codd payloads and sentinel ledger identities, runs both realignment scripts
and Keiro's table relocation, imports 30 ledger rows without changing source or application schema,
then proves native `up` applies only the five post-pin migrations. A second import reports 30
`AlreadyImported` results; a second `up` reports all 35 already applied.

The main lesson was that migration identity and schema equivalence are separate claims. Kiroku's six
renames and nine Kioku files can honestly use checksum-backed `SamePayload`; Keiro's rewritten files
and Kioku 0006 cannot. Encoding that distinction required a small backward-compatible extension to
`pg-migrate-import-codd`, but it avoided turning the cutover into a self-certifying checksum claim.

The two upstream prerequisites were published and pinned: Keiro
`3187e9b345c27af077fcbbe122abfae6ad8ba67d` ships its embedded lock, and pg-migrate
`29d036e47bc3e07f5f44846be2c34725ba100246` provides validator-aware partial manifests. Cabal fetched
both exact commits and the full build/test/live-database validation passed with no local project
override. Kioku commit `27d566265d029a5a8aa5ef079d5bf4069b0e95f8` contains the portable
implementation, and the post-commit audit reproduced every acceptance gate. No planned work remains.


## Context and Orientation

This section assumes you have never seen this repository. Read it before touching anything.

### What kioku is

Kioku is a Haskell **library** providing agent memory and session storage on PostgreSQL. It
is not an application and it does not own a database. It is built as a
[Cabal](https://cabal.readthedocs.io/) multi-package project; the packages are listed at the
top of `/Users/shinzui/Keikaku/bokuno/kioku/cabal.project`:

- `kioku-core` — the library proper: memory and session aggregates, read models, workers.
- `kioku-api` — an HTTP surface over kioku-core.
- `kioku-cli` — a command-line surface.
- `kioku-migrations` — the SQL schema, and the code that hands it to a migration runner.
- `kioku-migrate` — a small executable that applies the schema to a database.

Downstream repositories (mori, shikigami, rei) depend on kioku and build their *own* migrate
binaries that compose kioku's migrations into their own databases.

### What a "migration" is here, and what codd does with them

A **migration** is a file of SQL that moves a database's schema forward one step — creating a
table, adding a column, building an index. A **migration runner** applies the pending ones in
order and records which it has applied, in a bookkeeping table usually called a **ledger**, so
that running it twice does not re-apply anything.

Kioku currently uses **codd** as its runner. Codd's ledger is the table `codd.sql_migrations`,
and the only thing it stores as the identity of an applied migration is the migration's
**filename**. This has three consequences you must hold in your head for the rest of this plan:

1. Codd determines apply order by parsing a UTC timestamp out of the front of the filename.
   Kioku's files are named like `2026-06-24-00-00-00-kioku-base.sql`.
2. Renaming an applied file makes codd think it is a brand-new migration, and it will re-run it.
3. Codd never checksums a migration's body. Editing an applied file in place is invisible to it.

Fact 3 is why `kioku-migrations/sql-migrations/2026-07-03-14-37-18-kioku-session-readmodel-registry-bump.sql`
could have its body legitimately rewritten in place on 2026-07-11, and it is the reason for the
final `EquivalentState` decision about that file in the Decision Log above.

### What pg-migrate does differently

**pg-migrate** (`/Users/shinzui/Keikaku/bokuno/pg-migrate`, pinned at commit `29d036e`) replaces
all three of those behaviors:

- A migration's identity is a **component** and a **name** — `kioku/0003-kioku-distillation` —
  stored as the primary key `(component, migration)` of the table `pgmigrate.migrations`. The
  component is a string you choose in Haskell (`"kiroku"`, `"keiro"`, `"kioku"`); the name is
  the filename with `.sql` stripped.
- Apply order is **explicit**, not derived from filenames. Within a component, order comes from a
  plain-text file literally named `manifest` sitting beside the SQL: one filename per line, in
  order. Across components, order comes from a declared dependency graph — keiro's component
  declares `Set.singleton "kiroku"`, so kiroku's migrations always run first.
- Every applied migration's body is **SHA-256 checksummed** into the ledger. `pg-migrate` can
  therefore tell you, via `verify`, whether the database's history matches the code's — codd
  cannot.

A **component** in pg-migrate is a named, independently-versioned group of migrations owned by
one library. This plan's whole shape follows from the fact that kiroku, keiro, and kioku are
three components composed into one **plan**, applied against one database, with one ledger.

pg-migrate supports **PostgreSQL 17 and 18 only** and hard-rejects anything else with
`UnsupportedPostgresVersion`. Kioku's dev server is PostgreSQL 17.10 (confirmed:
`psql --version` → `psql (PostgreSQL) 17.10`), so no server upgrade is needed. Do not
assume this — re-check it if the nix pin ever moves.

### Where kioku touches codd today

Codd is confined to two packages plus build configuration. `kioku-api`, `kioku-cli`, and the
`kioku-core` *library* have no codd dependency at all; `kioku-core`'s **test suite** reaches it
only transitively through `kioku-migrations:test-support`.

`/Users/shinzui/Keikaku/bokuno/kioku/kioku-migrations/src/Kioku/Migrations.hs` is 59 lines and
composes the three libraries' migrations into one list:

```haskell
kiokuMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
kiokuMigrations = do
  kiroku <- kirokuMigrations       -- from kiroku-store-migrations
  keiro  <- keiroFrameworkMigrations  -- from keiro-migrations
  own    <- kiokuOwnMigrations
  pure (kiroku <> keiro <> own)
```

Note that the `<>` here is *nominal* — codd re-sorts everything by filename timestamp anyway.
Under pg-migrate the composition order becomes real and explicit, which is an improvement.

The same file carries a hack you are going to delete with satisfaction. The SQL is embedded into
the binary at compile time by Template Haskell (`$(embedDir "sql-migrations")` from the
`file-embed` library). `embedDir` registers a recompilation dependency on every file it *found* —
so edits and deletions correctly force a rebuild, but a **brand-new** file is invisible to GHC and
would silently not be embedded. `touch` cannot fix this, because GHC's recompilation check is
content-based. The workaround is a comment line:

```haskell
-- Last added: 2026-07-11 kioku-scope-identity-recompute.
embeddedKiokuMigrationFiles :: [(FilePath, ByteString)]
embeddedKiokuMigrationFiles = sortOn fst $(embedDir "sql-migrations")
```

which `just new-migration` rewrites with `sed` purely to change the module's bytes and force a
recompile. pg-migrate's `embedMigrationManifest` has no such gap — it calls `addDependentFile` on
the manifest *and* every file the manifest lists, and a new migration is not a new migration until
it appears in the manifest. The hack, and the guard test that backstops it, both go away.

`/Users/shinzui/Keikaku/bokuno/kioku/kioku-migrate/app/Main.hs` reads codd settings from four
`CODD_*` environment variables, applies the composed migrations, then re-reads `CODD_CONNECTION`
to open a second connection and run `reconcileReadModelRegistry`. That reconciliation step is
**codd-independent** — it rides keiro's compiled API, not SQL — and survives this plan unchanged.

The `Justfile` recipe shows how much of codd's configuration is ceremony:

```bash
CODD_CONNECTION="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
CODD_EXPECTED_SCHEMA_DIR=unused-for-unverified-embedded-migrations \
CODD_SCHEMAS=kiroku \
  cabal run kioku-migrate
```

Two of those four are literal dummy strings. `getCoddSettings` demands them; embedded,
unverified mode never reads them.

Finally, and importantly: **`codd-extras` is not in `cabal.project`.** It comes from
`/Users/shinzui/Keikaku/bokuno/kioku/cabal.project.local`, which is *gitignored*, and points at
a sibling checkout at `/Users/shinzui/Keikaku/bokuno/codd-extras`. The build today silently
depends on an untracked local path. Deleting that line is one of the quieter wins in this plan.

### Where the cohort is now

Kioku is pinned to keiro `f1d67a0` and kiroku `4312aa8`. Both are ancestors of their repos'
current HEADs, so these are clean fast-forwards — 73 commits for keiro, 31 for kiroku. Both
have since cut over to pg-migrate, and both renamed their SQL files **twice**: once from
sentinel timestamps to real authoring times (still under codd), and once again to
manifest-ordered `NNNN-` names (under pg-migrate). Kioku is pinned at the *sentinel* stage,
which is why the downstream import runbook in Milestone 4 has four steps rather than one.

Bumping those pins brings three breaking changes that have nothing to do with migrations, and
you will meet all three as compile errors:

- **`ValidatedEventStream`** (keiro `9c69f7b`). Keiro's command runners no longer accept a raw
  `EventStream`; they require a `ValidatedEventStream`, produced by `validateEventStream` from
  `Keiro.EventStream.Validate`. Kioku constructs `EventStream` records directly in
  `kioku-core/src/Kioku/Memory/EventStream.hs` and `kioku-core/src/Kioku/Session/EventStream.hs`
  and passes them to runners at `kioku-core/src/Kioku/Memory.hs:309` and
  `kioku-core/src/Kioku/Session.hs:534`.
- **`ReadModel.schema`** (keiro `bd9cad2`). The `ReadModel` record gained a `schema :: !Text`
  field. Kioku declares 19 read models across `kioku-core/src/Kioku/Memory/ReadModel.hs` and
  `kioku-core/src/Kioku/Session/ReadModel.hs`; every one needs the new field.
- **keiro's schema relocation** (keiro `f388d24`, `fcd9770`). Keiro's eleven framework tables
  (`keiro_read_models`, `keiro_timers`, `keiro_outbox`, …) used to be created *unqualified* under
  `SET search_path TO kiroku`, so they physically landed inside **kiroku's** schema. They now live
  in a dedicated **`keiro`** schema, and `Keiro.Schema.keiroSchema :: Text` is the single source of
  truth for that name. Any kioku SQL that hardcodes `kiroku.keiro_*` is now wrong.

Plus a transitive version floor: keiro requires `shibuya-core >=0.8.0.1 && <0.9`, and kioku is
pinned to a shibuya carrying 0.7.1.0.

Prior plan `docs/plans/14-align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations.md`
is checked in and directly relevant: it anticipated keiro's schema relocation, made
`reconcileReadModelRegistry` location-agnostic, and rewrote migration `0006`'s body to find
`keiro_read_models` in whichever of the three schemas it happens to occupy. Read it if the
read-model registry behavior confuses you.


## Plan of Work

The work is five milestones. Milestones 1 through 3 follow the package dependency graph, so
that each has a real acceptance gate even though the tree as a whole does not compile until the
end of Milestone 3. Milestone 4 adds the downstream import path. Milestone 5 is tooling and docs.

### Milestone 1 — kioku-migrations becomes a native pg-migrate component

**Scope.** Move the pins, restructure the SQL into pg-migrate's manifest layout, and rewrite
`Kioku.Migrations` to export a component and a plan instead of a codd runner. At the end of this
milestone `cabal build kioku-migrations` succeeds. `kioku-core` and `kioku-migrate` will still be
broken; that is expected and correct, because they sit downstream in the dependency graph and
Milestones 2 and 3 fix them.

**Why the library builds in isolation.** `kioku-migrations`'s *library* depends only on
`keiro-migrations` and `kiroku-store-migrations` — not on `kioku-core`. (It is
`kioku-core`'s *test suite* that depends on `kioku-migrations:test-support`, and
`kioku-migrate` that depends on `kioku-core`. The arrows point away from us.) So this is a
genuine, checkable gate.

**The pins.** Rewrite the `source-repository-package` stanzas in `cabal.project`:

| dependency | from | to | why |
| --- | --- | --- | --- |
| keiro | `f1d67a0` | `3187e9b345c27af077fcbbe122abfae6ad8ba67d` | pg-migrate cutover plus source-package lock fix |
| kiroku | `4312aa8` | `876fb66f60508441970211c56de0bfb234ccb3f6` | HEAD; pg-migrate cutover |
| shibuya | `3f276ee` | `172df245f40a454af46dd7f4cde855eaa4414c5a` | shibuya-core 0.7.1.0 → 0.8.0.1, required by keiro |
| shibuya-pgmq-adapter | `71a7b82` | `99e997e8a05f4a0deb92ddede4d419351f6da3d8` | 0.8.0.0 → 0.11.0.0 |
| pg-migrate | — | `29d036e47bc3e07f5f44846be2c34725ba100246` | v1.0 plus validator-aware Codd import; five subdirs |
| keiki | `bc987f4` | unchanged | already matches keiro's own pin |
| ephemeral-pg | `304c160f` | unchanged | 0.2.1.0 satisfies pg-migrate-test-support's `>=0.2 && <0.3` |

The five pg-migrate subdirs to add are `pg-migrate`, `pg-migrate-embed`, `pg-migrate-cli`,
`pg-migrate-import-codd`, and `pg-migrate-test-support`. All are at commit `29d036e` and none are
on Hackage, so each needs its own `source-repository-package` stanza.

Leave the codd stanza and the `package codd` stanza **in place** for now — `kioku-migrate` still
imports `Codd.Environment` until Milestone 3, and removing codd before then would just trade one
compile error for another. Milestone 3 deletes them.

One optional bump worth considering: `ephemeral-pg` HEAD is `215e4ae5` (0.2.2.0), whose commit
message is *"fix(ephemeral-pg): publish initdb cache atomically."* Plan 14 recorded a known flake
where a full test run failed with `TimeoutError (ConnectionTimeout {durationSeconds = 60})` from
ephemeral-Postgres startup contention and passed on rerun. That fix plausibly addresses it. It is
not required — 0.2.1.0 satisfies the bound — so treat it as a separate, revertable commit and note
in Surprises & Discoveries whether the flake recurs.

**The SQL layout.** pg-migrate reads a directory containing the `.sql` files and a plain-text file
named `manifest`. Rename the directory and the files:

| old name (`sql-migrations/`) | new name (`migrations/`) |
| --- | --- |
| `2026-06-24-00-00-00-kioku-base.sql` | `0001-kioku-base.sql` |
| `2026-06-24-01-00-00-kioku-memory-embeddings.sql` | `0002-kioku-memory-embeddings.sql` |
| `2026-06-24-02-00-00-kioku-distillation.sql` | `0003-kioku-distillation.sql` |
| `2026-06-27-20-35-00-kioku-session-delegation-lineage.sql` | `0004-kioku-session-delegation-lineage.sql` |
| `2026-06-27-21-10-35-kioku-awaiting-session-state.sql` | `0005-kioku-awaiting-session-state.sql` |
| `2026-07-03-14-37-18-kioku-session-readmodel-registry-bump.sql` | `0006-kioku-session-readmodel-registry-bump.sql` |
| `2026-07-10-14-41-38-kioku-l1-watermarks.sql` | `0007-kioku-l1-watermarks.sql` |
| `2026-07-11-17-35-11-kioku-schema-hardening.sql` | `0008-kioku-schema-hardening.sql` |
| `2026-07-11-17-45-43-kioku-embedding-schema-heal.sql` | `0009-kioku-embedding-schema-heal.sql` |
| `2026-07-11-18-18-36-kioku-scope-identity-recompute.sql` | `0010-kioku-scope-identity-recompute.sql` |

The numbering preserves codd's timestamp order exactly, so a fresh database gets the same DDL
sequence it always did.

**Byte preservation is a hard requirement, not a nicety.** Milestone 4's import path asserts to
pg-migrate that a downstream database ran *these exact bytes*, and pg-migrate checks that claim
against a SHA-256. Use `git mv` and verify afterwards that `git diff --cached -M --stat` reports
`R100` (100% rename similarity) for every one of the ten. Do not reformat. Do not strip the
`-- codd: in-txn` line from the top of each file — it is now inert (pg-migrate's scanner only
recognizes directives that begin `pg-migrate:`, so a comment beginning `codd:` is just a comment)
but removing it changes the bytes and breaks the import. Add a short note at the top of the
manifest explaining why those lines are still there, so the next reader does not "clean them up."

All ten migrations are transactional (`-- codd: in-txn`), none use `CREATE INDEX CONCURRENTLY`, and
none are `no-txn`. pg-migrate treats SQL as transactional by default. So there is **no transaction-mode
translation to do at all** — a genuinely lucky break, because pg-migrate's `-- pg-migrate: no-transaction`
directive additionally requires the file to contain exactly one statement, which several of these do not.

**The manifest.** `kioku-migrations/migrations/manifest` is exactly ten lines, one filename each,
in the order above. No header, no comments, no blank lines — pg-migrate's manifest format v1 rejects
all of those, and it also rejects any `.sql` file sitting in the directory that the manifest does not
list (`UnlistedSqlFiles`), which is a nice built-in guard against the very "forgot to register the new
migration" bug the `-- Last added:` hack existed to prevent.

**The lock file.** `kioku-migrations/migrations.lock` is needed by Milestone 4 and is cheapest to
generate now, while the old filenames are still fresh in the git index. Its format is one line per
migration, `<64-char-lowercase-sha256> <filename>`, where the filename is the **old codd name** —
that is the key a downstream database's codd ledger will have. Because the bytes are preserved
across the rename, the checksum of the old file equals the checksum of the new file, so you can
generate this from the new files and simply re-key.

**The module.** Rewrite `kioku-migrations/src/Kioku/Migrations.hs` to:

```haskell
module Kioku.Migrations
  ( DefinitionError, MigrationComponent, MigrationPlan, PlanError
  , kiokuMigrations, kiokuMigrationPlan
  ) where

-- The component: named "kioku", depends on "keiro" (which itself depends on "kiroku").
kiokuMigrations :: Either DefinitionError MigrationComponent
kiokuMigrations =
  migrationComponentFromEmbeddedSql "kioku" (Set.singleton "keiro")
    $(embedMigrationManifest "migrations/manifest")

-- The full three-component plan, in dependency order.
kiokuMigrationPlan :: Either PlanError MigrationPlan
kiokuMigrationPlan = do
  kiroku <- first ... Kiroku.kirokuMigrations
  keiro  <- first ... Keiro.keiroMigrations
  kioku  <- first ... kiokuMigrations
  migrationPlan (kiroku :| [keiro, kioku])
```

Declaring the dependency as `Set.singleton "keiro"` (rather than listing both `keiro` and `kiroku`)
is sufficient and correct: keiro's own component already declares `Set.singleton "kiroku"`, and
pg-migrate validates the transitive graph. Use `migrationPlan` (which *validates* that the explicit
order respects the declared dependencies) rather than `resolveMigrationPlan` (which topologically
sorts for you) — we want a loud failure if the order is ever wrong, not a silent repair.

Note the shape change carefully: keiro and kiroku both **kept the name** `kirokuMigrations` /
`keiroMigrations` while completely changing its type, from `m [AddedSqlMigration m]` to
`Either DefinitionError MigrationComponent`. A call site that merely re-exports one of these will
still compile and now mean something entirely different. Read the types, not the names.

Delete `runKiokuMigrations`, `runKiokuMigrationsNoCheck`, `kiokuOwnMigrations`, the
`embeddedKiokuMigrationFiles` binding, and the `-- Last added:` comment. Nothing downstream of this
plan calls them, and the two functions that *do* survive — the ones downstream repos use — are the
component and the plan.

**Acceptance.** From `/Users/shinzui/Keikaku/bokuno/kioku`:

```bash
cabal build kioku-migrations
```

succeeds. Also confirm the build plan resolved the pins you intended:

```bash
cabal build --dry-run kioku-migrations 2>&1 | grep -E 'keiro|kiroku|pg-migrate|shibuya'
```

### Milestone 2 — kioku-core absorbs keiro's breaking changes

**Scope.** Fix the three keiro API breaks and the shibuya bump in `kioku-core`. At the end,
`cabal build kioku-core` succeeds. The test suite still will not build — it needs
`kioku-migrations:test-support`, which Milestone 3 rewrites.

**`ValidatedEventStream`.** Keiro's command runners now demand a `ValidatedEventStream`, a newtype
from `Keiro.EventStream.Validate` that you obtain by passing a raw `EventStream` through
`validateEventStream`. The point is that the stream's invariants are checked once, up front, rather
than assumed at every command dispatch. Kioku has two streams: `memoryEventStream` (built in
`kioku-core/src/Kioku/Memory/EventStream.hs`, handed to a runner at
`kioku-core/src/Kioku/Memory.hs:309`) and `sessionEventStream` (built in
`kioku-core/src/Kioku/Session/EventStream.hs`, handed to a runner at
`kioku-core/src/Kioku/Session.hs:534`). Validate each **once**, at the module level where the stream
is defined, and export the validated value — not at each call site, which would re-run validation on
every command. `validateEventStream` returns an `Either`, so decide deliberately how a validation
failure surfaces; since the streams are compile-time constants, a failure is a programmer error and
failing loudly at startup is appropriate.

**`ReadModel.schema`.** The `ReadModel` record gained `schema :: !Text`. Kioku declares 19 read
models — 11 in `kioku-core/src/Kioku/Memory/ReadModel.hs`, 8 in
`kioku-core/src/Kioku/Session/ReadModel.hs`. Every one needs the field. Kioku's *own* tables
(`kioku_memories`, `kioku_sessions`, …) still live in the `kiroku` schema — we explicitly decided
not to relocate them — so the correct value for all 19 is `"kiroku"`, **not** `Keiro.Schema.keiroSchema`.
Getting this backwards would point every kioku read model at keiro's schema, where its tables do not
exist. Do not blindly reach for the new constant just because it is new.

**Keiro's schema relocation.** Keiro's eleven framework tables moved from the `kiroku` schema into a
new `keiro` schema. Grep kioku for any SQL that names a `keiro_*` table and confirm it is either
schema-qualified correctly or goes through keiro's compiled API. Two places are already known-good:
`reconcileReadModelRegistry` in `kioku-core/src/Kioku/ReadModel.hs` uses keiro's
`lookupReadModel`/`registerReadModel`/`markLive` and is location-agnostic by construction; and
migration `0006` resolves the table with
`COALESCE(to_regclass('keiro.keiro_read_models'), to_regclass('kiroku.keiro_read_models'), to_regclass('public.keiro_read_models'))`.
Both were done deliberately in plan 14 in anticipation of exactly this move. Find any third place.

**shibuya-core 0.8.** `kioku-core.cabal` lists `shibuya-core` with no version bound (lines 94 and
144). Add `>=0.8.0.1 && <0.9` to match keiro's requirement, and fix whatever the 0.7 → 0.8 API change
breaks.

**Acceptance.** `cabal build kioku-core` succeeds.

### Milestone 3 — migrations apply to a live database; codd is gone

**Scope.** Rewrite the test-support shim and the migrate binary onto pg-migrate, delete codd from the
build entirely, and get the whole tree green. This is the milestone where the plan's headline claim
becomes real: a developer runs `just create-database` and gets a checksummed schema.

**Test support is the highest-leverage file in this plan.** Every database-backed test in the repo —
all 10 spec files in `kioku-core/test/`, plus `kioku-migrations/test/Main.hs` — funnels through two
functions in `kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs`:

```haskell
withKiokuMigratedDatabase :: (Text -> IO a) -> IO a
withBareDatabase          :: (Text -> IO a) -> IO a
```

**Preserve both signatures exactly.** If you do, not one line of any spec file changes and the entire
test blast radius of this plan is 27 lines. If you let pg-migrate's `Connection`-passing style leak
through (its `withMigratedDatabase` hands the callback a `Hasql.Connection.Connection`, not a `Text`
connection string), you will instead be editing 10 spec files for no benefit. Adapt inside the shim.

Be aware of pg-migrate's **nested `Either`** ergonomics here: `withMigratedDatabase` returns
`IO (Either MigratedDatabaseError value)`, and the value itself may be an `Either` from your callback.
Its `docs/user/testing.md` calls this out as a known gotcha. The shim should unwrap and `fail` loudly
on `MigratedDatabaseError`, so tests see a clear message rather than a type puzzle.

**The migrate binary.** Rewrite `kioku-migrate/app/Main.hs` onto `pg-migrate-cli`, which provides a
ready-made command parser (`migrationCommandParser`) and runner (`runMigrationCommand`) exposing
`plan`, `list`, `check`, `status`, `verify`, `up`, `repair`, and `new`. Note that pg-migrate-cli is a
*library*, not an executable: the application owns its own configuration, streams, and exit codes. Read
the connection string from `DATABASE_URL`, replacing all four `CODD_*` variables.

Keep the read-model reconciliation step. It must run **after** `up` succeeds, and it should not run at
all for the read-only commands (`status`, `verify`, `plan`, `list`) — reconciliation writes to
`keiro_read_models`, and a command named `verify` must not mutate the database. This is a behavior
change from today's binary, which always reconciles because it only ever did one thing.

`kioku-migrate` exists as its own package solely to break a Cabal dependency cycle (it needs
`kioku-core` for the read-model schemas, while `kioku-core`'s test suite needs
`kioku-migrations:test-support`; Cabal detects cycles at package granularity). That constraint is
unchanged — do not try to fold it back into `kioku-migrations`.

**Delete codd.** Remove the `source-repository-package` stanza for `shinzui/codd-project` and the
`package codd { tests: False; benchmarks: False }` stanza from `cabal.project`. Remove the
`packages: ../codd-extras` line from the gitignored `cabal.project.local` — and check whether that
file has any other content before deleting it outright. Then confirm codd is really gone:

```bash
rg '(^|[ ,])codd([ <=>]|$)' --glob '*.cabal' --glob 'cabal.project*'  # expect no matches
```

**The migrations test suite.** `kioku-migrations/test/Main.hs` has a test, `testMigrationNames`,
asserting every filename matches `YYYY-MM-DD-HH-MM-SS-slug.sql`, and another, `testEmbedIsCurrent`,
comparing `listDirectory "sql-migrations"` against the embedded file list. Both exist to backstop
codd-specific hazards that pg-migrate does not have. Replace them with a single manifest-integrity
test: assert `checkMigrationManifest "migrations/manifest"` returns `Right`, which transitively proves
every listed file exists, no unlisted `.sql` file is lurking in the directory, and no entry is
malformed. Keep the three `assertRegistryBump` layout tests and `testFreshDatabase` — they test
behavior, not codd mechanics. Note that `assertRegistryBump` reaches into `embeddedKiokuMigrationFiles`
by old filename to pull out migration `0006`'s bytes; re-point it at the new embedding and the new name.

**Acceptance.** From `/Users/shinzui/Keikaku/bokuno/kioku`, against a fresh database:

```bash
rm -rf db && just create-database
cabal run kioku-migrate -- status
cabal run kioku-migrate -- verify   # exit 0
cabal test all
```

`status` should show 35 migrations applied across three components. This is also the first time
keiro's reordered fresh-database DDL sequence (see Surprises & Discoveries) is exercised in kioku, so
a failure here is more likely to be keiro's ordering than your code — check that before assuming your
own bug.

### Milestone 4 — the codd-history import path for downstream databases

**Scope.** Give mori, shikigami, and rei a way to move their existing, data-bearing databases onto
pg-migrate without re-running any DDL. Nothing in kioku's own repo needs this — kioku's databases are
disposable — which is exactly why it needs a **test**, not just code. Without a rehearsal, this
feature's first real execution would be against someone's production data.

**How pg-migrate's import works.** `importMigrationHistory` writes ledger rows with
`status='applied'` **without executing the migrations**, atomically, alongside an audit row in
`pgmigrate.history_imports` recording where the claim came from. You supply a list of
`HistoryMapping`s, each saying: *this target migration* (`kioku/0003-kioku-distillation`) *is already
applied, and here is my evidence* — where the evidence is a row in the old codd ledger, keyed
`codd:<old-filename>`. Two grades of claim exist:

- `SamePayload key` — "the database ran exactly these bytes." pg-migrate checks the evidence's
  SHA-256 against the target plan's SHA-256 and refuses if they differ. This requires supplying the
  source `migrations.lock` and the exact source bytes; without a manifest, `SamePayload` is rejected
  outright (`CoddSamePayloadRequiresManifest`).
- `EquivalentState` — "the database is in the state these bytes would have produced, and here is a
  read-only check that proves it." Requires a `StateValidator` and the explicit opt-in
  `withEquivalentHistory AllowEquivalentHistory`.

Per the Decision Log, nine of kioku's ten migrations get `SamePayload`; `0006-kioku-session-readmodel-registry-bump`
gets `EquivalentState` plus a validator that asserts the eight session read models sit at version 3
with shape hash `kioku-session-v3`, because that file's body was legitimately rewritten in place
after downstream databases had already applied the older body.

**The four-step runbook, and why it is four steps.** A downstream database was migrated by *kioku's*
old binary, which composed the *old* keiro and kiroku. So its codd ledger holds those libraries'
**sentinel-timestamp** filenames (`2026-05-17-00-00-00-keiro-bootstrap.sql`), while keiro's and
kiroku's shipped `HistoryMapping`s reference their **real-UTC** names — they assume you already ran
their rename fixups. And keiro's eleven tables are still sitting in the `kiroku` schema. So:

1. Run kiroku's ledger fixup
   (`kioku-migrations/codd-upgrade/realign-kiroku-migration-timestamps.sql`) — 7 rows renamed.
2. Run keiro's ledger fixup
   (`kioku-migrations/codd-upgrade/realign-keiro-migration-timestamps.sql`) — 14 rows renamed.
3. Run keiro's schema relocation
   (`kioku-migrations/codd-upgrade/relocate-keiro-tables-to-keiro-schema.sql`) — `ALTER TABLE … SET SCHEMA`
   for eleven tables. This is metadata-only: indexes and constraints move with the table, no rows are
   copied, nothing is lost.
4. Run `kioku-migrate import`, which imports the 30 mappings actually present at kioku's pinned
   cohort, then run `kioku-migrate up` to apply the five later migrations normally.

Order matters: the importer matches evidence by the ledger's *current* filenames, so the renames must
happen before the import. This exact sequence is what the repo's `cohort-migrate` skill exists to
handle, and no upstream doc covers it end-to-end — kioku is the first consumer in this position, so
kioku is where the runbook has to live.

**A known upstream bug to verify, not trust.** Keiro's ledger fixup appears to write
`migration_timestamp = old_timestamp` — that is, it renames the row but writes the timestamp column
back to the value it already had, contradicting its own header comment. Kiroku's equivalent script
correctly writes the new timestamp. This is probably harmless for our purposes, because
`coddEvidenceKey` derives the evidence key from the **filename alone** (`"codd:" <> filename`) and
never reads `migration_timestamp`. But *verify that* against
`pg-migrate-import-codd`'s source before relying on it, and record the finding in Surprises &
Discoveries either way. If it turns out to matter, the fix belongs upstream in keiro, not in a
workaround here.

**The rehearsal test.** Construct, in a test, an ephemeral database that looks like a downstream
consumer's: create a `codd.sql_migrations` table with the 30 sentinel-and-real-named rows the
pre-cutover kioku would have written, and create the schema those migrations would have produced with
keiro's tables in the `kiroku` schema. Then run the four-step runbook against it and assert:

- The import reports all 30 historical migrations imported.
- `pgmigrate.migrations` holds 30 rows with `status='applied'` immediately after import.
- **No imported DDL ran.** A subsequent `up` applies exactly the five migrations absent from the
  pinned codd cohort: kiroku 0007/0008 and keiro 0015/0016/0017. The other 30 report
  `AlreadyApplied`; schema changes are limited to those five reviewed forward migrations.
- A subsequent `verify` exits clean, and a subsequent `up` reports every migration already applied.
- Running the import a second time is idempotent — pg-migrate returns `AlreadyImported` rather than
  erroring or double-writing.

**Acceptance.** The rehearsal test passes, and `docs/user/upgrading-to-pg-migrate.md` walks a
downstream operator through the four steps — including taking a backup first — without requiring them
to read this plan.

### Milestone 5 — tooling and documentation

**Scope.** Make the developer-facing surface match reality.

Rewrite the `Justfile`. The `migrate` recipe loses its four `CODD_*` variables and gains a single
`DATABASE_URL`. The `new-migration` recipe changes shape substantially: it no longer mints a
timestamped filename, no longer writes a `-- codd: in-txn` header, and no longer `sed`s the
`-- Last added:` comment (which no longer exists). Instead it should create `migrations/NNNN-<slug>.sql`
with the next zero-padded number and append the filename to `migrations/manifest`. pg-migrate-cli's
`new` command infers a bare numeric name but does not combine that prefix with a slug, so the recipe
validates the slug and passes the next `NNNN-slug` basename through `--name`. The CLI remains
responsible for exclusive file creation and atomic manifest replacement.

Update the docs that describe codd: `docs/user/library-api.md` (the Migrations section, roughly lines
359–410), `docs/user/getting-started.md` (lines 29–56), `docs/user/recall.md` (lines 206–215, which
tell the reader to hand-apply a migration because "codd will not re-run anything"),
`docs/user/troubleshooting.md` (lines 19–34), `README.md` (lines 32 and 49), and the comment at
`nix/haskell.nix:29` that explains codd's apply-anyway semantics.

Leave `docs/plans/*` alone. Those are the historical design record and should not be retconned.

Fill in Outcomes & Retrospective.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/kioku` unless stated otherwise. The nix devShell
must be active — it supplies `PGHOST`, `PGDATA`, `PGDATABASE`, and a PostgreSQL 17 with pgvector.

**Confirm the starting state.** Before touching anything:

```bash
git status                        # expect: clean
psql --version                    # expect: psql (PostgreSQL) 17.x  — pg-migrate needs 17 or 18
cat cabal.project.local           # note what is in here; the ../codd-extras line goes away in M3
```

**Milestone 1.** Edit `cabal.project` per the pin table above, then:

```bash
cabal build --dry-run kioku-migrations 2>&1 | grep -E 'keiro|kiroku|pg-migrate|shibuya'
```

Expect to see `pg-migrate-1.0.0.0`, `pg-migrate-embed-1.0.0.0`, `keiro-migrations-0.2.0.0`,
`kiroku-store-migrations-0.2.0.0`, and `shibuya-core-0.8.0.1`. If the solver fails, the message names
the conflicting bound — read it before changing pins at random.

Rename the SQL, preserving bytes:

```bash
mkdir -p kioku-migrations/migrations
git mv kioku-migrations/sql-migrations/2026-06-24-00-00-00-kioku-base.sql \
       kioku-migrations/migrations/0001-kioku-base.sql
# ... the remaining nine, per the table in Milestone 1 ...
rmdir kioku-migrations/sql-migrations

# Prove every rename preserved the bytes exactly. Ten lines, every one R100.
git diff --cached -M --stat -- kioku-migrations/
```

If any line reads anything other than `R100`, you have modified a file's contents — probably an editor
stripping trailing whitespace or rewriting line endings. Fix it before continuing; Milestone 4's import
depends on these bytes.

Generate the lock file, keyed by the **old** codd filenames:

```bash
# Bytes are preserved across the rename, so the new file's hash is the old file's hash.
# Emit "<sha256>  <old-codd-filename>" per line.
```

Write this as a small script rather than by hand — ten hashes typed by hand is ten chances to typo a
64-character string, and a wrong hash surfaces much later as a confusing import failure.

Then rewrite `Kioku/Migrations.hs` and `kioku-migrations.cabal`, and:

```bash
cabal build kioku-migrations      # acceptance gate for M1
```

**Milestone 2.**

```bash
cabal build kioku-core 2>&1 | tee /tmp/m2-errors.txt
```

The first run will produce a wall of errors. That is the work list. Expect them to cluster into the
four groups named in the milestone: `ValidatedEventStream` at the two runner call sites, the missing
`schema` field across 19 read models, any `keiro_*` table reference that needs re-qualifying, and the
shibuya-core 0.8 changes. Work through them by group, not file by file.

**Milestone 3.**

```bash
cabal build all
rm -rf db && just create-database
cabal run kioku-migrate -- status
```

Expected `status` output: 35 migrations, all applied, across components `kiroku` (8), `keiro` (17),
and `kioku` (10). Note those counts include the two new canary migrations upstream added.

```bash
cabal run kioku-migrate -- verify ; echo "exit=$?"    # expect exit=0
cabal test all
rg '(^|[ ,])codd([ <=>]|$)' --glob '*.cabal' --glob 'cabal.project*'  # expect no matches
```

**Milestone 4.**

```bash
cabal test kioku-migrations-test                       # includes the codd-import rehearsal
```

**Milestone 5.**

```bash
just new-migration test-scaffold                        # should create migrations/0011-test-scaffold.sql
                                                        # and append it to migrations/manifest
git checkout -- kioku-migrations/migrations              # undo the scaffold test
```


## Validation and Acceptance

The plan is done when all of the following hold. Each is a behavior a human can check, not an internal
attribute.

**A fresh database migrates cleanly.** From a clean tree with no `db/` directory,
`rm -rf db && just create-database` completes without error and creates a database whose
`pgmigrate.migrations` table holds 35 rows, all with `status='applied'`. Confirm directly:

```bash
psql -c "SELECT component, count(*) FROM pgmigrate.migrations WHERE status='applied' GROUP BY component ORDER BY component"
```

```text
 component | count
-----------+-------
 keiro     |    17
 kioku     |    10
 kiroku    |     8
```

**The runner can prove the schema matches the code.** `cabal run kioku-migrate -- verify` exits 0.
Then demonstrate that it *actually verifies* rather than merely exiting 0 — this is the capability codd
never had, so prove it rather than asserting it. Edit one byte of an already-applied migration's body,
rebuild, and re-run `verify`: it must now fail with a `MigrationChecksumMismatch`. Revert the edit and
confirm `verify` passes again. If `verify` passes with the byte edited, the checksum path is not wired
up and the milestone is not done.

**Re-running is a no-op.** `cabal run kioku-migrate -- up` against an already-migrated database reports
every migration already applied, changes nothing, and exits 0.

**The test suite is green.** `cabal test all` passes, including all 10 database-backed spec files in
`kioku-core/test/`. The three specs that own SQL fixture statements for relocated Keiro tables use
the explicit `keiro` schema; production Keiro access needs no search-path workaround.

**The Codd runner is gone.** No Cabal/project file depends on the `codd` package, and no production
file imports a `Codd.*` module or reads `CODD_` configuration. The deliberately retained
`pg-migrate-import-codd` adapter reads the old ledger directly through Hasql and is not the Codd
runner. Historical plans, master plans, and rehearsal fixtures may still describe Codd. The gitignored
`cabal.project.local` no longer points at `../codd-extras`, and the build works for someone who has
never had that sibling checkout — which you can prove by temporarily moving it aside and rebuilding.

**A downstream database can adopt pg-migrate without re-running DDL.** The rehearsal test in
`kioku-migrations-test` builds a synthetic pre-cutover database, runs the four-step runbook, and
asserts 30 imported migrations, a clean verification after `up`, an `up` that applies only the five
post-pin migrations, and — the point of the whole exercise — that none of the 30 imported migrations
executed. Running the import twice is idempotent.

**A developer can add a migration.** `just new-migration some-slug` creates
`kioku-migrations/migrations/0011-some-slug.sql` and appends it to the manifest. Building without
adding it to the manifest fails loudly — which you can check by creating a stray `.sql` file in
`migrations/` and confirming the build rejects it with `UnlistedSqlFiles`. This is the guarantee that
replaces the old `-- Last added:` hack, so verify it works rather than trusting it.


## Idempotence and Recovery

**Everything in Milestones 1 through 3 and 5 is ordinary source editing** against a disposable
database. Nothing is at risk. If a migration run leaves the dev database in a strange state, delete it
and start over — `rm -rf db && just create-database` is the recovery path for every local problem, and
`db/` is gitignored precisely because it is disposable.

**The pin bump is the one change that is annoying to undo halfway**, not because it is dangerous but
because the compile errors it produces are numerous and land all at once. Commit `cabal.project` and
the SQL renames as their own commit before starting the Haskell edits, so you can `git stash` your
in-progress fixes without losing the mechanical work.

**Milestone 4's import path is the only genuinely irreversible operation in this plan, and it never
runs against kioku's own database** — only against a downstream consumer's. Treat it accordingly:

- The rehearsal test is not optional. It is the only thing standing between this code and someone's
  production data. Write it before, or at the same time as, the import code — not after.
- The `docs/user/upgrading-to-pg-migrate.md` runbook must open by telling the operator to take a backup
  (`pg_dump`) and must state plainly that restoring from that backup is the *only* rollback. pg-migrate
  is forward-only by design: there is no down-migration API, and deleting ledger rows to "undo" an
  import is explicitly called out upstream as unsafe.
- The runbook must require **quiescence**: no other process may be writing to the database during the
  import. pg-migrate's codd adapter takes an advisory lock on the source connection, but codd itself
  never took that lock, so the lock protects against other *pg-migrate* wrappers, not against a running
  application. Say so explicitly rather than implying the lock makes it safe.
- The import is idempotent by design — a second run with identical evidence returns `AlreadyImported`
  rather than double-writing. Changed evidence raises `HistoryImportConflict` rather than silently
  updating. The rehearsal test asserts both, so an operator who is unsure whether step 4 completed can
  safely re-run it.
- Steps 1 through 3 of the runbook (the two ledger fixups and the schema relocation) are each
  individually idempotent: the ledger fixups match on the old filename and become no-ops once renamed,
  and the relocation is guarded by `to_regclass(...) IS NOT NULL` per table. Re-running any of them is
  safe.


## Interfaces and Dependencies

### New dependencies

All from `https://github.com/shinzui/pg-migrate.git` at commit
`29d036e47bc3e07f5f44846be2c34725ba100246`, each as its own
`source-repository-package` stanza (none are on Hackage):

- **`pg-migrate`** — the core runner. Provides `Database.PostgreSQL.Migrate`, which exports the
  identifier types (`ComponentName`, `MigrationName`, `MigrationId`, `MigrationChecksum`), the plan
  types (`MigrationComponent`, `MigrationPlan`), the runner
  (`runMigrationPlan :: RunOptions -> Settings -> MigrationPlan -> IO (Either MigrationError MigrationReport)`),
  and the status/verify/import entry points. Connections are `hasql`, which is what kioku already uses.
- **`pg-migrate-embed`** — Template Haskell embedding.
  `embedMigrationManifest :: FilePath -> Q Exp` splices a `NonEmpty (FilePath, ByteString)` and calls
  `addDependentFile` on the manifest *and* every SQL file it lists, closing the recompilation gap that
  `file-embed`'s `embedDir` left open.
- **`pg-migrate-cli`** — the command parser and runner behind `kioku-migrate`. A library, not an
  executable; the application owns config, streams, and exit codes.
- **`pg-migrate-import-codd`** — the codd-history adapter for Milestone 4. Reads codd's ledger tables
  directly over `hasql`; **does not depend on the codd library**.
- **`pg-migrate-test-support`** — ephemeral-database helpers for test suites, backed by `ephemeral-pg`.
  Deliberately kept out of production build closures.

### Upstream API kioku must call

From `Kiroku.Store.Migrations` (kiroku-store-migrations 0.2.0.0):

```haskell
kirokuMigrations    :: Either DefinitionError MigrationComponent   -- component "kiroku", no deps
kirokuMigrationPlan :: Either PlanError MigrationPlan
```

From `Keiro.Migrations` (keiro-migrations 0.2.0.0):

```haskell
keiroMigrations       :: Either DefinitionError MigrationComponent  -- component "keiro", depends on "kiroku"
frameworkMigrationPlan :: MigrationComponent -> MigrationComponent -> Either PlanError MigrationPlan
```

Every `run*` function these two used to export — `runKirokuMigrations`, `runAllKeiroMigrations`,
`runKeiroMigrationsNoCheck`, and friends — **is gone**. Consumers now compose a plan and hand it to
pg-migrate's own runner. Note again that `kirokuMigrations` and `keiroMigrations` kept their *names*
while changing their *types* completely.

For Milestone 4, from `Keiro.Migrations.History.Codd` and `Kiroku.Store.Migrations.History.Codd`:

```haskell
frameworkCoddHistoryMappings :: NonEmpty HistoryMapping   -- kiroku's 7 <> keiro's 16 = 23
frameworkCoddSourceConfig    :: ConnectionProvider -> Bool -> Text -> Confirmation
                             -> Either CoddDefinitionError CoddSourceConfig
keiroCoddSourcePayloads      :: Map FilePath ByteString
keiroCoddManifestText        :: Text
keiroLegacyMigrationNames    :: NonEmpty FilePath
```

Those upstream exports describe their latest codd cohorts (23 rows), but kioku's pins predate three
of them. Kioku therefore takes the pinned prefixes (kiroku 6 + keiro 14) and adds its own ten, for 30.

### What kioku must export at the end

From `Kioku.Migrations` (this is the surface mori, shikigami, and rei consume — treat it as a
published API and note the change in a CHANGELOG):

```haskell
kiokuMigrations    :: Either DefinitionError MigrationComponent  -- component "kioku", depends on "keiro"
kiokuMigrationPlan :: Either PlanError MigrationPlan             -- kiroku <> keiro <> kioku
```

From `Kioku.Migrations.History.Codd` (new, Milestone 4):

```haskell
kiokuCoddHistoryMappings  :: NonEmpty HistoryMapping     -- kioku's 10
cohortCoddHistoryMappings :: NonEmpty HistoryMapping     -- pinned cohort: all 30 historical rows
cohortCoddSourceConfig    :: ConnectionProvider -> Bool -> Text -> Confirmation
                          -> Either CoddDefinitionError CoddSourceConfig
kiokuCoddSourcePayloads   :: Map FilePath ByteString     -- old codd filename -> bytes
kiokuCoddManifestText     :: Text                        -- embedded migrations.lock
kiokuLegacyMigrationNames :: NonEmpty FilePath           -- the ten old codd filenames
```

From `Kioku.Migrations.TestSupport` — **signatures unchanged**, which is the entire point:

```haskell
withKiokuMigratedDatabase :: (Text -> IO a) -> IO a
withBareDatabase          :: (Text -> IO a) -> IO a
```

### Dependencies removed

- **`codd`** — the `source-repository-package` for `shinzui/codd-project` and the `package codd` stanza
  in `cabal.project`.
- **`codd-extras`** — the `packages: ../codd-extras` line in the gitignored `cabal.project.local`,
  pointing at an untracked sibling checkout. Its removal is what makes a fresh clone of kioku buildable
  by someone who has never had that directory.
- **`file-embed`** — superseded by `pg-migrate-embed`.


## Revision Notes

2026-07-12: Revised throughout implementation to record the actual 30-row historical cohort, the
mixed checksum/state-evidence design, the exact downstream rehearsal, corrected read-model counts,
test-fixture schema qualification, validation results, and the two dependency publication gaps.
Recorded the locally prepared Keiro and pg-migrate commit SHAs so a future continuation can publish
and pin them without reconstructing the upstream work.

2026-07-12: Finalized the plan after publishing and pinning both upstream fixes, shipping the
operator SQL inside Kioku's source distribution, committing the portable implementation, and
re-running the requirement-by-requirement completion audit against the committed tree.
