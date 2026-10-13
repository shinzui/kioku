---
id: 48
slug: upgrade-kioku-to-keiro-0-20-and-propagate-seihou-upgrade-guidance
title: "Upgrade Kioku to Keiro 0.20 and propagate Seihou upgrade guidance"
kind: exec-plan
created_at: 2026-10-13T00:03:51Z
intention: "intention_01m4s934beewgbxd1h5eesbg14"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-13T00:03:51Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-13T00:20:39Z
      mode: "implement"
      note: "Implement released cohort, subscription lifecycle, migration preservation, and downstream upgrade guidance"
---

# Upgrade Kioku to Keiro 0.20 and propagate Seihou upgrade guidance

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Move Kioku from the Keiro 0.19 cohort to the latest released Keiro cohort verified for
this plan, 0.20.0.0. Kioku must still write, project, recall, embed, and schedule timers
correctly, while consuming Kiroku's hardened subscriptions and expanded migration plan.
A downstream project upgrading Kioku must receive the required upstream guidance through
Seihou, even if it has never declared Keiro or Kiroku directly.

The deliverable is a validated, release-ready Kioku 0.9.0.0 package set and an append-only
`kioku-upgrade` edge from 0.8.0.2 to 0.9.0.0. Demonstrate the result with a released-package
build, disposable PostgreSQL tests, a 60-entry composed migration plan, and a Seihou debug
preview that expands the exact upstream edges in order. Package publication is a separate
release operation; persistent databases receive an operator runbook rather than automatic
migration during this work.


## Progress

- [ ] Milestone 1: the released Keiro 0.20 cohort resolves, all Kioku components compile
  with warnings as errors, and a real embedding adapter starts, delivers an event, and
  shuts down cleanly against a disposable migrated database.
- [ ] Milestone 2: fresh, previous-cohort, Kiroku-only, and supported Codd-upgrade fixtures
  converge on the 60-entry plan, preserve data and historical checksums, and rerun cleanly.
- [x] Milestone 3 (2026-10-13): the new Kioku blueprint edge resolves the two Kiroku edges and the
  exact Keiro edge once each before Kioku's own guidance; historical edges remain intact.
  Dhall validation/format check passed. Disposable Seihou previews from all three
  0.8 patches produced four ordered steps; 0.7 produced eight distinct steps.
- [ ] Milestone 4: all five packages and release-facing documentation agree on Kioku
  0.9.0.0, the complete validation matrix passes, and durable decisions are distilled.

Implementation is underway. Release endpoints and peeled tags still match the target.
The initial tree was clean; concurrent toolchain work described during planning is
already committed. Bounds resolve without new overrides. Worker lifecycle tests are
being compiled before extending migration fixtures.


## Surprises & Discoveries

The warnings-as-errors gate exposed pre-existing warnings: a redundant `Show`
constraint in the API test helper and four missing Codd evidence/validation type
signatures. Remove the redundant constraint and declare the exported pg-migrate
types rather than weakening the gate. The new solve also selects compatible AI
patch/minor releases within unchanged bounds.


## Decision Log

- Decision: Target the verified Keiro 0.20.0.0 release and prepare Kioku 0.9.0.0 in
  lockstep across all five packages.
  Rationale: Kioku exposes framework types, excludes the old upstream cohort, and changes
  its composed database plan. A conservative pre-1.0 major-component bump conveys that
  compatibility boundary. Do not drift to a later release without updating this plan.
  Date: 2026-10-12
- Decision: Entail Keiro's exact 0.19.0.1-to-0.20.0.0 edge, letting that edge entail
  Kiroku's hardening and inspection edges recursively.
  Rationale: Upstream owns its source and operational guidance. Exact entailment avoids
  copied instructions and gives shared upstream work one receipt regardless of entry point.
  Date: 2026-10-12
- Decision: Preserve Kioku's existing command/projection/timer transaction boundary;
  do not adopt guarded catalog commands, asynchronous projection conversion, sharded
  topology changes, inspection services, or exhaustive upstream performance benchmarks.
  Rationale: These are additional capabilities or architecture changes. Keiro explicitly
  makes guards opt-in, and local ADR-13 explains Kioku's existing shared-timer boundary.
  Date: 2026-10-12


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kioku has five Cabal packages: `kioku-api/kioku-api.cabal`,
`kioku-core/kioku-core.cabal`, `kioku-cli/kioku-cli.cabal`,
`kioku-migrations/kioku-migrations.cabal`, and `kioku-migrate/kioku-migrate.cabal`.
Each currently reports 0.8.0.2. Their internal dependencies, including the qualified
`kioku-migrations:test-support` sublibrary, move together. A cohort means the mutually
compatible package versions selected together. `cabal.project` also constrains optional
PGMQ queue packages which Kioku itself does not build. Preserve that distinction when
inspecting `dist-newstyle/cache/plan.json`, the actual Cabal dependency solution.

At planning time that solution contains Keiro, core, migrations, and test support at
0.19.0.1; Kiroku Store 0.9.0.1; Kiroku migrations 0.6.0.0; Shibuya core 0.10.0.0;
the Kiroku adapter 0.5.1.5; and pg-migrate 1.2.0.0. On 2026-10-12 Hackage's preferred
version endpoints reported Keiro 0.20.0.0 across the consumed packages, Kiroku Store
0.11.0.0, Kiroku migrations 0.7.1.0, the Kiroku adapter 0.6.0.1, and Shibuya core
0.10.0.1. Remote annotated Keiro release tags peel to
`d1492d748fc1063a7eceb8e36516c71b853397b3`; the corresponding Kiroku package tags
peel to `7394055de458bef8f6ec2e68231f3ca7932bb9be`. These are released dependencies,
not development pins. Verify them again before editing bounds.

Discover source with `mori registry list`, `mori registry search keiro`,
`mori registry search kiroku`, `mori registry show shinzui/keiro --full`, and
`mori registry show shinzui/kiroku --full`. `mori registry docs` currently returns no
curated documents for these two projects, so read their source and checked-in blueprint
files directly after resolving their project roots with `mori path`. The upstream
blueprint directories are `mori://shinzui/keiro` plus project-relative
`blueprints/keiro-upgrade/`, and `mori://shinzui/kiroku` plus project-relative
`blueprints/kiroku-upgrade/`. Artifact-level blueprint URI coverage is pending in the
installed Mori CLI; keep each project URI beside any upstream path.

The released Keiro blueprint at `mori://shinzui/keiro` plus
`blueprints/keiro-upgrade/blueprint.dhall` is version 0.9.0 and declares the exact
0.19.0.1-to-0.20.0.0 edge. Its prompt is at the same project's
`blueprints/keiro-upgrade/migrations/0.19.0.1-to-0.20.0.0.md`. It entails Kiroku
0.9.0.1-to-0.10.0.0 and 0.10.0.0-to-0.11.0.0, in that order. Read those prompts at
`mori://shinzui/kiroku` plus project-relative
`blueprints/kiroku-upgrade/migrations/0.9.0.1-to-0.10.0.0.md` and
`blueprints/kiroku-upgrade/migrations/0-10-to-0-11.md`. The current Kiroku checkout
includes the hardening blueprint addition after its package release commit; use the
current blueprint declarations, but released tags/package manifests for API evidence.

Kiroku hardening makes subscription capacities and group sizes validated values,
introduces typed decode failures and target binding, and adds migrations 0013 and 0014.
A target binding records what event stream or category a checkpoint belongs to, so the
same checkpoint cannot silently be reused for unrelated history. Inspection adds five
`Store` effect constructors, the `Subscriber.subDropped` counter, and migration 0015's
stream-browsing index. Keiro adds `ShardReaderStartupFailed` to `ShardWorkerError` and
an optional guarded catalog command runner. Kioku currently has no `.keiro` DSL
specifications, custom `Store` interpreter, complete `Subscriber` construction, sharded
worker, PGMQ worker, or inspection server. Recheck those absences; do not implement absent
surfaces to satisfy an upstream checklist.

There is one confirmed exhaustive match to adapt:
`Kioku.Worker.Failure.isTransientStoreError` in
`kioku-core/src/Kioku/Worker/Failure.hs` must classify `EventDecodeFailed`. Its behavioral
tests live in `kioku-core/test/Kioku/EmbeddingWorkerSpec.hs`. The real embedding adapter
is assembled by `embeddingWorkerProcessor` in
`kioku-core/src/Kioku/Memory/Embedding/Worker.hs`; `embeddingAdapterConfig` already
updates `defaultKirokuAdapterConfig` rather than filling a whole record. Its durable
subscription is `kioku-memory-embedding`, targeting category `kioku_memory` and filtering
`MemoryRecorded`. Preserve that identity, retry policy, and partition handling.
`kioku-cli/src/Kioku/Cli/Commands/Worker.hs` owns continuous-worker supervision.
`kioku-core/src/Kioku/App.hs` delegates interpretation to upstream `runStoreResource`.

`Kioku.Migrations.kiokuMigrationPlan` in
`kioku-migrations/src/Kioku/Migrations.hs` composes Kiroku, Keiro, then Kioku components.
It currently has 57 entries: 12 Kiroku, 32 Keiro, 13 Kioku. The target is 60: 15, 32,
and 13 respectively; Keiro's own composed plan is 47. The native Kioku manifest and SQL
are under `kioku-migrations/migrations/`, with frozen payload evidence in
`kioku-migrations/test/Main.hs`. That file also asserts total counts, the 12-entry
Kiroku-only adoption prefix, ordered forward IDs, and the Kiroku schema comment through
0012. Its Codd fixture imports a fixed 30-entry historical ledger; Codd is the previous
migration system. That historical count must remain 30. Test fixtures delegate to
Keiro test support through
`kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs`.

`blueprints/kioku-upgrade/blueprint.dhall` is currently version 0.3.0. Its latest edge is
0.7.0.0-to-0.8.0.0 and entails both Keiro 0.17-to-0.18 and 0.18-to-0.19. The README
still says blueprint version 0.2.0 and omits that latest edge. The cohort reference at
`blueprints/kioku-upgrade/files/kioku-cohort-versions.md` includes Kioku 0.8.0.1 and
0.8.0.2 as bounds/test-fixture patches without new edges. Seihou selects declared edges
within a version window; gaps mean no intervention was needed. An entailed edge names
one exact upstream `from`/`to` pair, expands before its parent, and receives its own
receipt. A receipt records completion of an agent interaction, not completion of a
database maintenance operation. A planning-time disposable preview of the existing
0.7-to-0.8 edge successfully resolved its four-step recursive chain.

Relevant local ADRs were selected after scanning filenames and headings.
[ADR-13](../adr/catalog-application-projections-not-framework-timers.md) keeps the
three application projection tables in Kioku's catalog and appends shared framework
timer callbacks explicitly at the command boundary, preserving atomic event/projection/
timer writes. Its compatibility runner remains intentional.
[ADR-10](../adr/projections-live-in-the-kioku-schema.md) separates Kioku-owned projections
from the shared event store, preserves migration history, and requires migration before
runtime registration. [ADR-14](../adr/haskell-and-cli-conventions-are-executable-contracts.md)
makes GHC 9.12/GHC2024, warning policy, and tested CLI behavior executable contracts.
`mori.dhall` currently declares no profiled ADR bundle; preserve the existing local ADR
format rather than incidentally introducing a new profile.


## Plan of Work

### Milestone 1: released dependencies and worker compatibility


Raise every consumed Keiro bound in all library, executable, test, and test-support
stanzas to `^>=0.20.0.0`. Move direct Kiroku Store bounds to `^>=0.11.0.0`, Kiroku
migrations to `^>=0.7.1.0`, the Kiroku adapter to `^>=0.6.0.1`, and Shibuya core to
`^>=0.10.0.1`. In `cabal.project`, move the optional Keiro PGMQ constraint to 0.20 and
the four declared PGMQ package floors to `>=0.6.1.1 && <0.7`; retain
`shibuya-pgmq-adapter ^>=0.16.1.0`. Keep the existing Baikai, Shikumi, Keiki,
pg-migrate, and Effectful compatibility choices unless an actual released-cohort
conflict requires a documented change. Do not add solver exceptions or source pins.

Add an explicit non-transient `EventDecodeFailed` branch to `isTransientStoreError`
and extend its existing classification test with a real typed decode failure constructed
through the released Kiroku API. This failure describes deterministic bad stored input;
it must not enter the infrastructure retry path. Search production and tests for the
other changed surfaces and adapt only actual usage. Preserve default adapter construction;
do not replace validated capacities with unsafe coercions or enable the advisory watchdog
as an upgrade side effect.

Prove the producer/consumer interaction early: extend
`kioku-core/test/Kioku/EmbeddingWorkerSpec.hs` with a real adapter lifecycle case using
`withKiokuMigratedDatabase`, the production `embeddingWorkerProcessor`, and a fake embedding
provider. Record a valid memory in an authorized space, observe delivery and stored vector
without a network call, stop and await the worker within a bounded test timeout, and prove
it does not remain blocked on acknowledgement. Extend the same fixture to cover a
restart from a confirmed legacy unbound checkpoint and a wrong bound target refusing
startup without advancing the checkpoint; create pre-0014 state only inside that disposable
fixture. If existing tests already exercise these exact paths, cite and reuse them.
Require the warning-as-error build and focused embedding tests before broad fixture edits.

### Milestone 2: composed migrations and preservation


Update `kioku-migrations/test/Main.hs` semantically: total 57 becomes 60 where it
describes the current full plan; Kiroku-only prefix 12 becomes 15; add ordered
`kiroku/0013`, `kiroku/0014`, and `kiroku/0015` to current forward expectations; change
the current Kiroku schema comment expectation to `through 0015`. Keep Kioku 13, Keiro
32, the Codd import 30, and historical cutover fixtures unchanged. Do not globally replace
12 or 57, and never modify released SQL to make a fixture pass.

Add a previous-cohort upgrade case starting from the genuine released Kiroku 0.6
manifest through 0012, with events and a known subscription checkpoint. Obtain those
bytes from the authoritative package archive or the verified tag via Mori-located source;
freeze their provenance and hashes if checking a fixture into this repository. Apply
the current composed plan with workers stopped and prove migrations 0013–0015 preserve
events, checkpoint position, and Kioku projection data. Demonstrate inferred group size,
the expected unbound legacy target awaiting confirmed adoption, and the browsing index.
Keep this distinct from the much older Codd fixture. Run fresh, Kiroku-only adoption,
Codd convergence, repeat-up, and checksum tests. Acceptance is actual successful
database evolution to 60 entries, with a second up reporting every entry already applied
and no historical payload or checksum repair introduced.

### Milestone 3: downstream Seihou guidance


Append `blueprints/kioku-upgrade/migrations/0-8-0-2-to-0-9-0-0.md` and declare
0.8.0.2-to-0.9.0.0 in `blueprints/kioku-upgrade/blueprint.dhall`. Bump the blueprint
artifact version from 0.3.0 to 0.4.0. Its sole direct entailment is `keiro-upgrade`
0.19.0.1-to-0.20.0.0; the two exact Kiroku edges come from Keiro, not duplicated
Kioku declarations. Earlier consumers at 0.8.0.0 or 0.8.0.1 still select this edge
because those patch intervals intentionally contain no source/operations edge.

The prompt must establish that an affected Kioku package is used, align the five-package
0.9 cohort, verify previously entailed work, update Kioku composed-plan assertions to
60/15/32/13, and distinguish direct Kioku API consumers from hosts that run workers or
migrations. State that Kioku adds no native SQL, rewrites no historical payload, and
requires no new Kioku ledger fixup. Name the upstream maintenance obligations: stop all
subscription workers for 0013/0014, confirm historical targets before binding legacy
checkpoints, and plan the 0015 index-build write pause. Delegate the detailed upstream
runbook to the entailed prompts; do not reproduce it or apply persistent migrations.
Fresh disposable databases follow normal test setup. Preserve timer and memory-space
semantics, and keep guards/sharding/inspection adoption optional.

Update `blueprints/kioku-upgrade/README.md`, `prompt.md` if baseline guidance needs
clarification, and `files/kioku-cohort-versions.md`. Correct the README's artifact
version and add both its missing historical 0.7-to-0.8 row and the new row. Preserve all
published migration prompts and coordinates. Add current runtime, migration, AI-unchanged,
and composed-plan rows, explaining the patch gaps and operator boundaries. Validate
Dhall fields and a recursive Seihou debug preview against local unpublished Kioku content
and current upstream blueprints. Acceptance is exactly four new-chain steps, ordered
Kiroku hardening, Kiroku inspection, Keiro, Kioku; also preview from 0.8.0.0 and 0.8.0.1
and a longer 0.7.0.0 window to ensure historical edges still resolve without duplication.

### Milestone 4: coherent release preparation and final evidence


Bump all five Kioku versions and every internal bound, including qualified test-support
references, to 0.9.0.0. Update root `CHANGELOG.md` and each package's `CHANGELOG.md`
with package-specific changes. Refresh the current baseline in `README.md`,
`docs/user/getting-started.md`, `docs/user/upgrading-to-pg-migrate.md`, and
`docs/user/upgrading-to-the-kioku-schema.md`, retaining historical release facts and
previous ledger-fixup guidance. Explain that the current plan is 60 entries and that
the new migration maintenance requirements also apply through Kioku's runner.
Review `docs/capabilities/embedded-migration-component.md`,
`docs/capabilities/migration-test-support.md`, and
`docs/capabilities/embedding-worker-and-degradation.md` for changed evidence. If those
profile-governed records change, follow their local descriptor and log convention.
The existing `docs/architecture/keiro-017-pattern-conformance.md` records a historical
adoption; do not relabel its old evidence as a fresh comprehensive 0.20 pattern audit.

Run the final matrix below, recording exact resolved versions and concise acceptance
evidence in this plan. Preserve the independently changing toolchain files. Stage only
this task's new files when needed so Nix can see them, and resolve formatter changes
without reverting other work. Review the living sections for durable new constraints;
update an existing ADR if its project-level reasoning changed, or add a new local ADR
only for a new architectural decision. Complete the plan with the release-ready outcome
and remaining operator actions. Any implementation commit uses Conventional Commits
and both the `ExecPlan` and frontmatter `Intention` trailers.


## Concrete Steps

All commands below start at the Kioku repository root unless a block changes directory.
Use the Nix development shell for GHC, Cabal, and PostgreSQL executables; the test suites
provision disposable clusters, so they do not require `just migrate` against the host
database. Seihou and Dhall are currently available from the user profile. Never inspect
or traverse `/nix/store`; use Mori for dependency code.

Verify release evidence before edits:

```bash
mori registry list
mori registry search keiro
mori registry search kiroku
mori registry show shinzui/keiro --full
mori registry show shinzui/kiroku --full
mori registry docs shinzui/keiro
mori registry docs shinzui/kiroku
curl -fsSL https://hackage.haskell.org/package/keiro/preferred.json
git ls-remote --tags https://github.com/shinzui/keiro.git 'refs/tags/keiro-0.20.0.0*'
git ls-remote --tags https://github.com/shinzui/kiroku.git 'refs/tags/kiroku-store-v0.11.0.0*' 'refs/tags/kiroku-store-migrations-v0.7.1.0*' 'refs/tags/shibuya-kiroku-adapter-v0.6.0.1*'
```

The preferred list includes 0.20.0.0, and peeled hashes match Context and Orientation.
Check the other changed package preferred endpoints the same way; do not infer publication
from a checkout's version. After bounds/source edits, use:

```bash
nix develop -c cabal update
nix develop -c cabal build all --enable-tests --dry-run
nix develop -c cabal build all --enable-tests --ghc-options=-Werror
nix develop -c cabal test kioku-test --test-options='-p "Embedding worker"'
nix develop -c cabal test kioku-migrations-test
jq -r '."install-plan"[] | select(."pkg-name" | test("^(keiro|kiroku|shibuya|pg-migrate)")) | [."pkg-name", ."pkg-version"] | @tsv' dist-newstyle/cache/plan.json | sort -u
```

Expect Keiro packages at 0.20.0.0, Store 0.11.0.0, Kiroku migrations 0.7.1.0,
Kiroku adapter 0.6.0.1, and Shibuya core 0.10.0.1. Optional PGMQ constraints need
not appear as resolved packages. Investigate every warning or failed assertion.

After authoring the new blueprint, validate its decoded declarations:

```bash
seihou validate-blueprint blueprints/kioku-upgrade
dhall format --check blueprints/kioku-upgrade/blueprint.dhall
dhall-to-json --file blueprints/kioku-upgrade/blueprint.dhall > /tmp/kioku-upgrade-blueprint.json
jq '{version, versionProbe, migrations: [.migrations[] | {from, to, entails}]}' /tmp/kioku-upgrade-blueprint.json
```

Expect artifact version 0.4.0 and the exact new entailment. Blueprint validation alone
does not prove upstream edge existence. Preview using Seihou's supported project-local
`.seihou/modules` search path; this tests unpublished changes without replacing global
installations or contacting an agent provider:

```bash
kioku_source_root="$PWD"
kioku_keiro_root="$(mori path mori://shinzui/keiro)"
kioku_kiroku_root="$(mori path mori://shinzui/kiroku)"
kioku_preview_root=$(mktemp -d /tmp/kioku-blueprint-preview.XXXXXX)
mkdir -p "$kioku_preview_root/.seihou/modules"
cp -R "$kioku_source_root/blueprints/kioku-upgrade" "$kioku_preview_root/.seihou/modules/kioku-upgrade"
cp -R "$kioku_keiro_root/blueprints/keiro-upgrade" "$kioku_preview_root/.seihou/modules/keiro-upgrade"
cp -R "$kioku_kiroku_root/blueprints/kiroku-upgrade" "$kioku_preview_root/.seihou/modules/kiroku-upgrade"
cd "$kioku_preview_root"
seihou agent --debug migrate kioku-upgrade --from 0.8.0.2 --to 0.9.0.0 > preview.txt
rg '^===== ' preview.txt
seihou agent --debug migrate kioku-upgrade --from 0.8.0.0 --to 0.9.0.0 > patch-zero.txt
seihou agent --debug migrate kioku-upgrade --from 0.8.0.1 --to 0.9.0.0 > patch-one.txt
seihou agent --debug migrate kioku-upgrade --from 0.7.0.0 --to 0.9.0.0 > historical.txt
cd "$kioku_source_root"
```

The first three previews must show these four step headers in order:

```text
[1/4] kiroku-upgrade 0.9.0.1 -> 0.10.0.0
[2/4] kiroku-upgrade 0.10.0.0 -> 0.11.0.0
[3/4] keiro-upgrade 0.19.0.1 -> 0.20.0.0
[4/4] kioku-upgrade 0.8.0.2 -> 0.9.0.0
```

Actual headers include `=====` delimiters and entailment annotations. The historical
window adds the existing four-step 0.7-to-0.8 chain, for eight distinct steps overall.
Debug mode writes no migration receipts. Retain concise headers as evidence rather than
the full prompt dump. If a dependency's current blueprint is missing an exact edge,
refresh its Mori-located checkout/installed artifact and verify the declaration; do not
change coordinates to a fabricated edge.

Final checks, from the root after versions/documentation are consistent:

```bash
nix develop -c cabal build all --enable-tests --ghc-options=-Werror
nix develop -c cabal test all --enable-tests --test-show-details=direct
nix develop -c bash scripts/check-haskell-conventions.sh
for kioku_package_dir in kioku-api kioku-core kioku-cli kioku-migrations kioku-migrate; do
  (cd "$kioku_package_dir" && cabal check) || exit 1
done
nix fmt -- --ci
nix flake check
git diff --check
git diff v0.8.0.2 -- kioku-migrations/migrations kioku-migrations/migrations.lock
```

All checks exit zero; the last diff is empty. Re-run the version probe embedded in
`blueprint.dhall` against the final build plan; it must print 0.9.0.0. Review current
version/count claims with `rg` over README, current user docs, Cabal files, and blueprint
reference material, allowing explicitly historical rows and changelog entries. Do not
rewrite past plans or past migration prompts to erase old versions.


## Validation and Acceptance

The final Cabal plan resolves the verified released cohort with all five Kioku packages
at 0.9.0.0 and no new override. A warnings-as-errors build proves exhaustive matches are
adapted. Existing write, recall, partition, catalog registration, reconciliation, timer,
CLI, and migration suites still pass. The actual embedding adapter lifecycle check proves
delivery through the new subscription configuration, correct legacy-target adoption,
refusal of target reuse, and bounded shutdown without an AI account. A handler-only unit
test cannot substitute for this interaction.

Migration acceptance requires fresh and upgraded disposable databases to have exactly
60 current entries, repeat application to be a no-op, and event/projection/checkpoint
data to survive. Native Kioku SQL and locks remain byte-identical to v0.8.0.2; the
supported Codd import still maps 30 historical entries. The three new upstream IDs
appear in order before Keiro's component. No new ledger fixup is presented as necessary.

Blueprint acceptance requires both valid Dhall and observed recursive expansion from
each of Kioku 0.8.0.0, 0.8.0.1, and 0.8.0.2. The expanded sequence is the four-step
sequence above, and the longer historical preview still works. Each new edge appears
once under its owning blueprint. The prompt distinguishes source completion from
pending operator database maintenance and states a cheap not-applicable path.

Release readiness requires coherent versions/changelogs/current documentation, passing
Cabal checks, all tests, convention checks, formatting, Nix checks, and whitespace checks.
Report any environment-limited check as unverified; do not mark its milestone complete
based solely on compilation. Guards, sharding changes, new inspection services, a general
0.20 architecture audit, and upstream exhaustive performance work are outside acceptance.


## Idempotence and Recovery

Read-only release lookups, builds, tests, and debug previews are repeatable. Each preview
uses a fresh temporary project and copies the three blueprints into its local search
path. It changes no global Seihou installation and writes no receipts. Recreate the
temporary project after a blueprint edit so the copied source cannot become stale.
Never use `--mark-applied` to manufacture acceptance evidence.

All database integration work uses disposable fixtures. Do not run `just migrate` or
`kioku-migrate up` against a persistent host database during this plan. Persistent
cutover requires the owning operator's backup, clone rehearsal, worker stop, historical
target confirmation, and index-build maintenance window, as described by the entailed
upstream edges. Do not delete checkpoints, bypass owner refusals, edit ledger checksums,
or modify historical SQL in response to a failure.

Preserve unrelated edits. Use focused diffs and explicit file staging; never reset the
working tree wholesale. If a solve fails, identify the actual bound conflict through
the released manifests and Mori source rather than widening bounds blindly. Preserve
the accepted Milestone 1 interaction evidence unless a later relevant edit invalidates
it, and rerun affected checks before final acceptance.


## Interfaces and Dependencies

This is a standalone plan. Runtime dependencies are
`mori://shinzui/keiro/packages/keiro`,
`mori://shinzui/keiro/packages/keiro-core`,
`mori://shinzui/keiro/packages/keiro-migrations`, and
`mori://shinzui/keiro/packages/keiro-test-support`, all at 0.20.0.0;
`mori://shinzui/kiroku/packages/kiroku-store` at 0.11.0.0;
`mori://shinzui/kiroku/packages/kiroku-store-migrations` at 0.7.1.0;
`mori://shinzui/kiroku/packages/shibuya-kiroku-adapter` at 0.6.0.1; and
`mori://shinzui/shibuya/packages/shibuya-core` at 0.10.0.1. Version requirements use
the compatible bounds stated in Milestone 1, not source hashes. The hashes above are
release evidence only.

Keep `Kioku.Migrations.kiokuMigrationPlan`, `Kioku.App.runAppIO`, public memory/session
command signatures, memory-space authorization, CLI command names, and timer atomicity
as the Kioku contracts. Upstream `Kiroku.Store.Error.StoreError.EventDecodeFailed` is the
confirmed new classification obligation. The supported default subscription/adapter
constructors carry the new validated capacities and defaults. Any newly discovered direct
upstream type usage must be adapted without claiming absent capabilities are implemented.

Seihou's interface is `S.BlueprintMigration` with exact `S.EntailedEdge` coordinates.
The Kioku artifact becomes version 0.4.0 independently of Kioku's package version
0.9.0.0. Its `versionProbe` reads resolved Kioku package versions; its new edge entails
Keiro 0.19.0.1-to-0.20.0.0. Keiro recursively entails Kiroku 0.9.0.1-to-0.10.0.0
then 0.10.0.0-to-0.11.0.0. Preserve identity and existing receipts by appending edges,
never renumbering or rewriting published ones.
