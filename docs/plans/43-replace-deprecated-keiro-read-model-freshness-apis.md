---
id: 43
slug: replace-deprecated-keiro-read-model-freshness-apis
title: "Replace deprecated Keiro read-model freshness APIs"
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
      at: 2026-09-18T19:34:49Z
      mode: "implement"
      note: "Implemented read-model blueprints and immediate freshness calls"
---

# Replace deprecated Keiro read-model freshness APIs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Remove Kioku's dependence on the read-model compatibility layer that Keiro 0.17 marks
for removal. Every Kioku query remains an immediate read of an inline, transactionally
updated projection, but that truth is represented by `ReadModelBlueprint`,
`NoQueryCursor`, `immediateReadModel`, `QueryFreshness.Immediate`, and
`runQueryWithFreshness`. A focused build treats Keiro deprecations as errors, proving that
a later Keiro release may delete `ConsistencyMode`, `StrongScope`, the legacy record
fields, and `runQueryWith` without forcing this migration again.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-18 19:34Z) Converted all nineteen memory and session read-model
  declarations to exported `ReadModelBlueprint` values with `NoQueryCursor` and
  `immediateReadModel`.
- [x] (2026-09-18 19:34Z) Replaced all twenty-one Kioku query calls with
  `runQueryWithFreshness Nothing Immediate`.
- [x] (2026-09-18 19:34Z) Modernized the stale-schema fixture to derive its old
  identity from the session blueprint and enabled `-Werror=deprecations` for
  `kioku-core` library and test builds.
- [x] (2026-09-18 19:38Z) Formatted the repository, proved the legacy-symbol
  search empty, compiled `lib:kioku-core` with deprecations as errors, and passed
  all 238 `kioku-core` tests.
- [x] (2026-09-18 19:43Z) Passed the complete 445-test multi-package suite,
  reviewed the final diff, and completed ADR distillation; no durable
  architecture decision changed.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The planned Cabal library target `kioku-core:lib` is not accepted by the
  installed Cabal version (`Cabal-7131`, no component named `lib`). The canonical
  target `lib:kioku-core` builds the intended public library and passed with
  `-Werror=deprecations`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Every current Kioku read model uses `Immediate` freshness and
    `NoQueryCursor`.
  Rationale: Both memory and session projections execute inline in the append transaction;
    the current `Eventual` override performs no wait and the synthetic `*-inline`
    subscription names do not identify durable cursors. Claiming a wait capability would
    make the model less truthful and violate the 0.17 pattern.
  Date: 2026-09-18
- Decision: Preserve read-model names, versions, shape hashes, SQL, and return types byte
    for byte.
  Rationale: This is an API representation migration, not a projection rebuild or schema
    change. Stable identities avoid false stale-schema failures and registry churn.
  Date: 2026-09-18
- Decision: Export each new blueprint alongside its existing read-model value.
  Rationale: The next child plan must bind the same declarations into Keiro's
    projection catalog. Exporting the authoritative blueprints prevents that plan
    from reconstructing nineteen parallel identities and queries.
  Date: 2026-09-18


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

All nineteen read-model declarations now originate from explicit, exported
`ReadModelBlueprint` values with `NoQueryCursor`, and all twenty-one production
and test queries use `runQueryWithFreshness Nothing Immediate`. Model names,
qualified tables, versions, hashes, SQL statements, inputs, and results remain
unchanged. The old synthetic inline subscription names and every Keiro 0.17
deprecated freshness symbol are absent from core source and tests.

The permanent Cabal ratchet makes deprecation warnings errors for both the
`kioku-core` library and its test suite. `lib:kioku-core` compiled under that
ratchet, all 238 core tests passed, and `cabal test all` passed 445 tests across
the repository. Existing reconciliation evidence still proves stale identities
fail closed in both directions and recover correctly. ADR distillation found no
new architectural boundary: this plan implemented the immediate-read semantics
already established by the projection and partition ADRs. The exported
blueprints are the authoritative input for the catalog work in the next child
plan.


## Context and Orientation

This plan starts after
`docs/plans/42-align-kioku-with-the-released-keiro-0-17-dependency-cohort.md` has made
Keiro 0.17 the compiling baseline; that is a hard dependency because the replacement
builders and deprecation pragmas are defined by the released 0.17 API.

`kioku-core/src/Kioku/Memory/ReadModel.hs` directly constructs ten `ReadModel` records;
`kioku-core/src/Kioku/Session/ReadModel.hs` constructs nine. Each sets
`defaultConsistency = Eventual`, `strongScope = EntireLog`, and a synthetic
`subscriptionName`, even though the owning projection is inline. Production calls in
`Kioku.Memory`, `Kioku.Session`, and `Kioku.Recall` use `runQueryWith ... Eventual`.
`kioku-core/test/Kioku/ReadModelReconcileSpec.hs` uses the same legacy runner and updates a
model record to simulate stale schema metadata.

Keiro 0.17 keeps these names only for Language 4 compatibility and attaches deprecation
pragmas to `ConsistencyMode`, `Strong`, `Eventual`, `PositionWait`, `StrongScope`,
`EntireLog`, `CategoryHead`, the three legacy `ReadModel` fields, and `runQueryWith`.
The replacement contract is documented by
`mori://shinzui/keiro-runtime-patterns/docs/keiro-read-models-and-projections` and
implemented in `mori://shinzui/keiro/packages/keiro`.

`ReadModelBlueprint q r` carries the stable name, qualified table, schema version, shape
hash, cursor authority, and Hasql query. `immediateReadModel` turns a blueprint into the
same `ReadModel q r` public type. `NoQueryCursor` says no durable projection checkpoint
can be waited on. `runQueryWithFreshness model Immediate input` performs registration and
liveness checks, then executes immediately.

[ADR-10](../adr/projections-live-in-the-kioku-schema.md) requires the qualified table names
to stay in `kioku` and registry reconciliation to remain migration-driven. [ADR-9](../adr/each-recall-target-gets-its-own-statement.md)
requires all nine recall statement families and mandatory `memory_space_id` predicates to
remain distinct. No new ADR is needed for substituting a deprecated API with its semantic
replacement.


## Plan of Work

Milestone 1 converts declarations. In `Kioku.Memory.ReadModel` and
`Kioku.Session.ReadModel`, replace the legacy imports with `ReadModelBlueprint (..)`,
`QueryCursorAuthority (NoQueryCursor)`, and `immediateReadModel`. Define a blueprint beside
each existing model using the existing `name`, `tableName`, `schema`, `version`,
`shapeHash`, and `query`; set `cursorAuthority = NoQueryCursor`. Define the exported model
by applying `immediateReadModel` to that blueprint. Remove every synthetic subscription,
consistency, and strong-scope field. Keep the existing model values and signatures exported
so downstream source does not need to change.

Milestone 2 converts queries. In `Kioku.Memory`, `Kioku.Session`, and `Kioku.Recall`, import
`QueryFreshness (Immediate)` and `runQueryWithFreshness`; mechanically replace each
`runQueryWith model Eventual argument` with
`runQueryWithFreshness model Immediate argument`. Do not consolidate recall statements,
change parameter order, or introduce a wait mode.

Milestone 3 modernizes tests and installs the ratchet. In
`Kioku.ReadModelReconcileSpec`, build the altered test model from a test-only blueprint
through `immediateReadModel` instead of using legacy fields. Test the modern runner. Add a
focused Cabal warning option or repository check that makes use of the listed Keiro legacy
symbols fail in `kioku-core` while retaining the narrowly scoped deprecation suppression
for the intentional Codd bridge in `kioku-migrations` and `kioku-migrate`.


## Concrete Steps

Run from the repository root:

```sh
rg -n 'ConsistencyMode|StrongScope|\bEventual\b|\bEntireLog\b|runQueryWith\b|defaultConsistency|strongScope|subscriptionName' kioku-core/src kioku-core/test
cabal build lib:kioku-core --ghc-options=-Werror=deprecations
cabal test kioku-core:kioku-test
```

The source search must print nothing except comments that explicitly describe the removed
API; preferably update those comments too. The build and test commands must exit zero.
Then run the full suite because recall and session query behavior is shared with CLI tests:

```sh
cabal test all
```


## Validation and Acceptance

All existing read-model tests must retain their outcomes: an unregistered model fails
closed, a stale version/hash fails closed, reconciliation repairs only the intended row,
and the repaired query succeeds. Memory, session, and recall tests must return the same
rows in the same order and retain space isolation. The read-model registry names, versions,
and shape hashes before and after the edit must compare equal.

The strongest acceptance is negative: compiling `kioku-core:lib` with
`-Werror=deprecations` succeeds and the legacy-symbol search is empty. There must be no
`-Wno-deprecations` added to core or its tests to manufacture that result.


## Idempotence and Recovery

The conversion is local and repeatable. Convert one module at a time and run its focused
tests. If a builder choice changes behavior, restore the old declaration long enough to
compare its name/table/version/hash/query fields, then correct the blueprint; do not change
registry rows or add a migration to compensate for a construction bug.


## Interfaces and Dependencies

Use `Keiro.ReadModel.ReadModelBlueprint`, `QueryCursorAuthority.NoQueryCursor`,
`QueryFreshness.Immediate`, `immediateReadModel`, and `runQueryWithFreshness` from Keiro
0.17. Existing public values such as `memoryByIdReadModel :: ReadModel ...` and
`sessionByIdReadModel :: ReadModel ...` retain their signatures. `Kioku.ReadModel.schemaOf`
continues to read `name`, `version`, and `shapeHash` from the built model, so migration-time
reconciliation remains compatible until
`docs/plans/44-establish-a-validated-projection-catalog-and-runtime-assembly.md` derives the same inventory from the
validated catalog.
