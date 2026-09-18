---
id: 47
slug: integrate-and-publish-the-keiro-0-17-adoption
title: "Integrate and publish the Keiro 0.17 adoption"
kind: exec-plan
created_at: 2026-09-18T18:42:34Z
intention: "intention_01m2twr1ddexergqvtn2bqztbv"
master_plan: "docs/masterplans/8-adopt-keiro-0-17-comprehensively.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-18T18:42:34Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-18T23:02:30Z
      mode: "implement"
      note: "Started EP-6 integration and release-preparation implementation"
---

# Integrate and publish the Keiro 0.17 adoption

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Integrate the five implementation streams into a release-ready Kioku 0.7.0.0 change set.
The repository will state exactly which Keiro runtime, Haskell, and PostgreSQL patterns it
meets, cite executable evidence, explain bounded non-applicability, and give downstream
projects a Seihou edge that entails Keiro's own 0.16-to-0.17 guidance. A clean checkout can
build, test, validate migrations and blueprints, and scan for removed compatibility APIs
without relying on the research context in these plans.

This plan prepares but does not publish the release. Hackage upload, tags, and pushes require
the separate release workflow and explicit user action.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-18 23:20Z) Milestone 1: reconciled the five implementation streams,
  removed the last test-only legacy freshness API use, and passed focused core, CLI,
  and migration integration tests.
- [x] (2026-09-18 23:20Z) Milestone 2: published the evidence-backed Keiro 0.17
  pattern conformance matrix.
- [x] (2026-09-18 23:20Z) Milestone 3: bumped the five-package cohort to 0.7.0.0 and
  updated release-facing changelogs, capability records, README, and user documentation.
- [x] (2026-09-18 23:20Z) Milestone 4: added and validated the 0.6.0.0-to-0.7.0.0
  Seihou upgrade edge with the exact Keiro 0.16.0.0-to-0.17.0.0 entailment.
- [x] (2026-09-18 23:20Z) Milestone 5: passed the complete release-readiness matrix
  and finalized this plan and the MasterPlan living sections.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The fan-in scan found one remaining use of Keiro's deprecated freshness vocabulary in
  `Kioku.ProjectionCatalogSpec`, hidden behind `-Wno-deprecations`. Replacing the synthetic
  invalid legacy record with `headWaitingReadModel` now proves that Keiro 0.17 refuses a
  cursorless waiting model at construction time, and the suppression is gone.
- The first explicit test solve found two internal `kioku-migrations:test-support` bounds still
  at `^>=0.6.0.0`. The original version audit matched ordinary package dependencies but missed
  the qualified sublibrary spelling; both bounds now require `^>=0.7.0.0`, and a second scan
  covers that spelling.
- Running the three database-heavy suites concurrently caused one ephemeral-Postgres connection
  timeout. The exact failed Codd-import case passed alone in 1.07 seconds, and the subsequent full
  repository run passed all 467 tests, so no timeout or implementation change was warranted.
- The planned `nix fmt -- --check` spelling is not the treefmt CI interface in this repository;
  `nix fmt -- --ci` is the supported no-change gate and processed all 106 formatted files.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use a single evidence-backed conformance document rather than claiming every
    pattern in scattered README prose.
  Rationale: The three pattern libraries evolve independently; one matrix can name the
    exact canonical source, applicability, implementation evidence, and deliberate exception.
  Date: 2026-09-18
- Decision: Prepare a 0.7.0.0 cohort release unless the final PVP audit proves no exposed
    dependency type or source compatibility break.
  Rationale: Kioku exposes Keiro `ReadModel` values and excludes Keiro 0.16 after this work;
    a zero-major upstream move should be signaled conservatively.
  Date: 2026-09-18
- Decision: Confirm the 0.7.0.0 package cohort.
  Rationale: The final API comparison adds public `ReadModelBlueprint` values and
    `Kioku.ProjectionCatalog`, exposes Keiro 0.17 types, and excludes the 0.16 dependency line.
    A conservative pre-1.0 major-component bump is the accurate compatibility signal.
  Date: 2026-09-18
- Decision: Test the impossible cursorless-waiting state through Keiro's public smart constructor.
  Rationale: Constructing a deprecated compatibility record solely to test later catalog
    validation kept the removed API alive. Keiro 0.17 makes the invalid state unrepresentable
    earlier, and that refusal is the stronger invariant.
  Date: 2026-09-18


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Kioku is release-ready at 0.7.0.0 without publishing it. The final Cabal plan resolves all five
Kioku packages at 0.7.0.0 and `keiro`, `keiro-core`, and `keiro-migrations` at 0.17.0.0. The
source-and-test legacy freshness scan is empty, and every migration payload remains byte-identical
to v0.6.0.0. The new conformance matrix classifies every selected runtime, Haskell/CLI, and
PostgreSQL pattern with implementation evidence and bounds every deliberately unused Keiro surface.

The downstream blueprint is version 0.2.0 and declares the exact Kioku 0.6.0.0-to-0.7.0.0 edge,
entailed after Keiro's exact 0.16.0.0-to-0.17.0.0 work. It preserves the 56-migration expectation,
requires no ledger repair, and gives direct Keiro consumers a deprecation-as-error validation path.

Release readiness passed: dry-run solve, warnings-as-errors build, all five `cabal check` runs,
all 467 tests (125 API, 248 core, 64 CLI, 30 migrations), Haskell convention ratchet, Seihou
blueprint validation, treefmt CI, `nix flake check`, and `git diff --check`. No package was uploaded,
no tag or push was created, and no production database was touched. No new ADR was needed at fan-in:
the durable catalog/timer, migration-history, and convention boundaries are already recorded in
ADRs 13, 10, and 14 respectively.


## Context and Orientation

This is the fan-in for `docs/masterplans/8-adopt-keiro-0-17-comprehensively.md`.
`docs/plans/42-align-kioku-with-the-released-keiro-0-17-dependency-cohort.md` owns
released bounds; `docs/plans/43-replace-deprecated-keiro-read-model-freshness-apis.md`
owns the read-model migration;
`docs/plans/44-establish-a-validated-projection-catalog-and-runtime-assembly.md` owns the
runtime boundary; `docs/plans/45-harden-kioku-migrations-to-the-postgresql-patterns.md`
owns migration conformance; and
`docs/plans/46-ratchet-haskell-and-cli-pattern-conformance.md` owns Haskell/CLI
conformance. Do not start this plan until each predecessor's Progress and Outcomes describe
its actual final interfaces and all required tests pass independently.

All five Kioku packages currently report 0.6.0.0 and depend on one another with
`^>=0.6.0.0`. The root and package changelogs describe Keiro 0.16. README and user docs
contain older Keiro 0.14/PGMQ 0.5 claims that must be found rather than updating only the
front page. `blueprints/kioku-upgrade/blueprint.dhall` already declares a
`0.5.2.0 -> 0.6.0.0` edge entailing Keiro `0.15.0.0 -> 0.16.0.0`. The owning upstream
project `mori://shinzui/keiro` now declares the exact `0.16.0.0 -> 0.17.0.0` edge.

The conformance document must cover, at minimum, the canonical references used by the child
plans: Keiro read models/projections, runtime assembly, two-schema arrangement, migration
authoring/testing/operations, brownfield adoption and rollout; Haskell core standards,
custom Prelude, records, CLI option/help/completion patterns; and PostgreSQL schema-qualified
migration objects. It must classify each as Conformant, Conformant with documented boundary,
Not applicable, or Deferred with an owner. “Deferred” is not acceptable for a 0.17 API that
Keiro already deprecates.

Relevant local authorities are [ADR-10](../adr/projections-live-in-the-kioku-schema.md),
[ADR-4](../adr/the-aggregate-enforces-the-partition.md), and
[ADR-9](../adr/each-recall-target-gets-its-own-statement.md). Incorporate any ADR created by
`docs/plans/44-establish-a-validated-projection-catalog-and-runtime-assembly.md` for shared
timer ownership. Do not create an ADR for a package version or a test
command; reserve ADRs for durable architectural boundaries.


## Plan of Work

Milestone 1 reconciles integration. Review the diffs from plans 42–46 for duplicated
registration lists, conflicting Cabal stanzas, or documentation ownership. Run focused
read-model, catalog, migration, parser, and schema tests before editing release metadata.
Resolve failures in the owning child plan and update its living sections first.

Milestone 2 creates `docs/architecture/keiro-017-pattern-conformance.md`. For every selected
pattern, include the canonical `mori://` URI, why it applies or does not, exact Kioku module,
test, command, or ADR evidence, and any bounded exception. State that
`postgresql-jitsurei-patterns` resolves to `mori://shinzui/postgresql-jitsurei`. Include a
short inventory of unused Keiro surfaces (`keiro-dsl`, PGMQ, inbox/outbox, integration events,
external read contracts) so a later upgrade does not mistake absence for an incomplete search.

Milestone 3 performs the release metadata bump. First compare exposed modules and signatures
against 0.6.0.0. Unless that evidence refutes the MasterPlan's conservative PVP decision,
change all five package versions to 0.7.0.0 and all internal Kioku bounds to
`^>=0.7.0.0`. Add 0.7.0.0 sections to the root and five package changelogs, distinguishing
dependency, deprecated API removal, catalog/runtime, migration-test, and CLI changes. Update
README, `docs/user/library-api.md`, `docs/user/integrations.md`, getting-started and
troubleshooting pages, and the cohort/migration tables. Do not change the 56 migration count.

Milestone 4 adds `blueprints/kioku-upgrade/migrations/0-6-0-0-to-0-7-0-0.md`, declares the
edge in `blueprint.dhall`, and updates the blueprint README and cohort reference. Entail the
exact `keiro-upgrade` edge from `0.16.0.0` to `0.17.0.0`. The prompt must tell consumers to
replace legacy read-model freshness APIs if they use Keiro directly, update optional PGMQ
cohorts, retain the unchanged 56 migration expectation, apply no ledger fixup, and run their
own deprecation build. Kioku consumers that use none of those direct surfaces may complete
after the dependency solve and tests.

Milestone 5 runs the release-readiness matrix. Treat any legacy Keiro symbol, stale version
claim, missing catalog registration, altered migration checksum, invalid blueprint, or failing
Nix check as a blocker. Update child Outcomes and the MasterPlan's Progress, Surprises,
Decision Log, and Outcomes. Distill only durable decisions into ADRs.


## Concrete Steps

Run from the repository root:

```sh
cabal build all --dry-run
cabal build all --ghc-options=-Werror
cabal test all --enable-tests
for package_dir in kioku-api kioku-core kioku-cli kioku-migrations kioku-migrate; do (cd "$package_dir" && cabal check) || exit; done
seihou validate-blueprint blueprints/kioku-upgrade
nix fmt -- --ci
nix flake check
git diff --check
```

Run explicit drift searches:

```sh
rg -n 'ConsistencyMode|StrongScope|\bEventual\b|\bEntireLog\b|runQueryWith\b|defaultConsistency|strongScope|subscriptionName' kioku-core/src kioku-core/test
rg -n 'Keiro 0\.(14|15|16)|keiro(-core|-migrations|-pgmq)?[[:space:]]+\^>=0\.(14|15|16)|PGMQ 0\.5|56 migrations|Keiro 32' README.md CHANGELOG.md docs blueprints --glob '*.md' --glob '*.dhall'
```

The first search must be empty except historical plan/changelog prose outside source. Review
every second-search result: historical release records stay; current-baseline prose must say
Keiro 0.17, and migration totals remain 56 / 32.


## Validation and Acceptance

The final Cabal plan resolves Keiro 0.17 throughout and all package versions agree on
0.7.0.0. All suites pass with warnings as errors, including real PostgreSQL catalog,
migration, projection, and CLI tests. Catalog startup rejects invalid definitions and valid
commands still update read models and timers atomically. The migration plan remains 56 with
all historical checksums intact.

The conformance matrix must contain no unsupported assertion: every Conformant row links to
a module/test/command, every boundary links to an ADR or precise explanation, and every Not
applicable row names the absent capability. Seihou validation must accept the new edge and its
entailed Keiro coordinates. No package upload, tag, push, or production database action occurs.


## Idempotence and Recovery

All checks are repeatable. Release metadata should be edited last so failed integration does
not advertise an incomplete version. If a child interface changes during fan-in, update that
child plan and rerun its focused tests before retrying this plan. Blueprint edits are append-only;
never rewrite an existing released edge. Preserve unrelated worktree changes throughout.


## Interfaces and Dependencies

The final public dependency cohort is Keiro 0.17 and Kioku 0.7.0.0 across `kioku-api`,
`kioku-core`, `kioku-cli`, `kioku-migrations`, and `kioku-migrate`. The runtime interfaces
defined by ExecPlans 43 and 44—truthful read models, one validated catalog, catalog-derived
registration, and explicit timer ownership—are the release contract. The migration interface
remains `Kioku.Migrations.kiokuMigrationPlan`; CLI command names remain stable. Cross-repository
guidance is referenced with `mori://shinzui/keiro` and exact canonical document/package URIs,
never a bare upstream path.
