---
id: 42
slug: align-kioku-with-the-released-keiro-0-17-dependency-cohort
title: "Align Kioku with the released Keiro 0.17 dependency cohort"
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

# Align Kioku with the released Keiro 0.17 dependency cohort

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Move Kioku's entire declared Keiro cohort from 0.16 to the released 0.17 line before
changing source APIs. The visible result is a complete Cabal install plan containing
`keiro-0.17.0.0`, `keiro-core-0.17.0.0`, and `keiro-migrations-0.17.0.0`; the optional
PGMQ constraints also admit only the compatible `keiro-pgmq-0.17`, PGMQ 0.6, and
`shibuya-pgmq-adapter-0.16` family. All existing tests still pass and the composed
migration plan stays at 56 migrations because Keiro 0.17 adds no migration.

This plan deliberately allows focused deprecation warnings to remain:
`docs/plans/43-replace-deprecated-keiro-read-model-freshness-apis.md` removes
them. It must not hide warnings or add `allow-newer`; its job is to establish an honest
released baseline on which the source modernization can proceed.


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

- Decision: Pin the lockstep Keiro packages with `^>=0.17.0.0` and the optional PGMQ
    family at PGMQ 0.6 / adapter 0.16.
  Rationale: The configured package registry contains all five 0.17 packages, upstream
    release tags match them, and the released `keiro-pgmq.cabal` declares PGMQ
    `>=0.6 && <0.7` plus `shibuya-pgmq-adapter ^>=0.16.0.0`.
  Date: 2026-09-18
- Decision: Do not widen unchanged transitive cohort bounds.
  Rationale: Keiro 0.17 still requires `kiroku-store >=0.8 && <0.9`,
    `kiroku-store-migrations ^>=0.4.0.0`, `keiki >=0.9 && <0.10`, and
    `shibuya-core ^>=0.9.0.0`; unrelated upgrades would obscure the causal change.
  Date: 2026-09-18


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Kioku is a five-package Cabal project. `kioku-core/kioku-core.cabal` depends on `keiro`
and `keiro-core`; `kioku-cli/kioku-cli.cabal` depends on `keiro` in its library and test;
and `kioku-migrations/kioku-migrations.cabal` depends on `keiro-migrations` in its library
and test. `cabal.project` carries a forward-looking solve for `keiro-pgmq`, four PGMQ
packages, and `shibuya-pgmq-adapter` even though Kioku does not compile PGMQ code.

Every direct Keiro bound is currently `^>=0.16.0.0`. The optional constraints still name
`keiro-pgmq ^>=0.16.0.0`, PGMQ `^>=0.5.0.0`, and adapter `^>=0.14.0.0`. The configured
authoritative Cabal registry lists 0.17 for `keiro`, `keiro-core`, `keiro-migrations`,
`keiro-pgmq`, and `keiro-test-support`; `cabal get` retrieves those releases. Remote
upstream tags also exist. The source is registered as `mori://shinzui/keiro`, with the
main runtime package at `mori://shinzui/keiro/packages/keiro`.

The root `CHANGELOG.md` records the prior Keiro 0.16 move and a 56-entry composed plan:
Kiroku 11, Keiro 32, Kioku 13. Keiro 0.17 changes APIs but appends no migration, so those
counts are invariants, not values to increment. No local ADR governs package bounds. The
schema ownership decision in [ADR-10](../adr/projections-live-in-the-kioku-schema.md) is
relevant only as a guard that the dependency move must not relocate tables.


## Plan of Work

Milestone 1 updates the direct lockstep packages. In both the library and test stanzas of
`kioku-core/kioku-core.cabal`, change `keiro` and `keiro-core` to
`^>=0.17.0.0`. In the library and test stanzas of `kioku-cli/kioku-cli.cabal`, change
`keiro` likewise. In the library and test stanzas of
`kioku-migrations/kioku-migrations.cabal`, change `keiro-migrations` likewise. Do not add
`keiro-dsl` or `keiro-pgmq` to a component.

Milestone 2 updates `cabal.project`: set `keiro-pgmq ^>=0.17.0.0`, each of
`pgmq-core`, `pgmq-effectful`, `pgmq-hasql`, and `pgmq-migration` to
`^>=0.6.0.0`, and `shibuya-pgmq-adapter` to `^>=0.16.0.0`. Correct the nearby comment
so it describes 0.17 rather than an earlier cohort. Retain all other constraints.

Milestone 3 proves the solve and behavior. Generate the normal install plan, inspect
`dist-newstyle/cache/plan.json` for exact resolved versions, build all components, and run
all suites. The migration tests must still assert 56 entries and pass unchanged. Capture
Keiro deprecation warnings in this plan's Surprises section as the bounded input to
`docs/plans/43-replace-deprecated-keiro-read-model-freshness-apis.md`; do not silence them.


## Concrete Steps

Run from the repository root:

```sh
cabal build all --dry-run
jq -r '."install-plan"[] | select(."pkg-name" | test("^keiro($|-core$|-migrations$)")) | [."pkg-name", ."pkg-version"] | @tsv' dist-newstyle/cache/plan.json | sort -u
```

The second command must include:

```text
keiro	0.17.0.0
keiro-core	0.17.0.0
keiro-migrations	0.17.0.0
```

Then run:

```sh
cabal build all
cabal test all
rg -n 'keiro(-core|-migrations|-pgmq)?[[:space:]]+\^>=0\.16|pgmq-(core|effectful|hasql|migration)[[:space:]]+\^>=0\.5|shibuya-pgmq-adapter[[:space:]]+\^>=0\.14' --glob '*.cabal' cabal.project
```

The final search must print nothing. Do not pipe the test command through `tail`; preserve
Cabal's exit status and every suite summary.


## Validation and Acceptance

Acceptance requires an unmodified solver: no `source-repository-package`, `allow-newer`, or
local Keiro checkout may be introduced. `cabal build all --dry-run` resolves the three
direct Keiro packages to 0.17.0.0. `cabal build all` and `cabal test all` exit zero. The
migration suite reports its fresh-plan and history tests as passing with 56 migrations.

Inspect the plan for the optional family when selected with a focused dry run or test
project: `keiro-pgmq` must resolve at 0.17.0.0, all PGMQ libraries at 0.6.x, and the
adapter at 0.16.x. This is a solve assertion, not authorization to add PGMQ to Kioku.


## Idempotence and Recovery

Bounds edits and Cabal planning are repeatable. A failed solve changes no source; inspect
the first conflicting package and compare its released Cabal bounds through Mori and the
configured registry rather than adding `allow-newer`. Cabal build artifacts may be reused.
Do not reset or clean unrelated working-tree changes.


## Interfaces and Dependencies

The released interfaces are `keiro ^>=0.17.0.0`, `keiro-core ^>=0.17.0.0`, and
`keiro-migrations ^>=0.17.0.0`. The optional compatibility set is
`keiro-pgmq ^>=0.17.0.0`, PGMQ `^>=0.6.0.0`, and
`shibuya-pgmq-adapter ^>=0.16.0.0`. Existing Kiroku, Keiki, Shibuya core, and
pg-migrate bounds remain unchanged. No Haskell interface is intentionally changed in this
plan.
