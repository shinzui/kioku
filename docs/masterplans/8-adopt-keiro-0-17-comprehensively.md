---
id: 8
slug: adopt-keiro-0-17-comprehensively
title: "Adopt Keiro 0.17 comprehensively"
kind: master-plan
created_at: 2026-09-18T18:42:27Z
intention: "intention_01m2twr1ddexergqvtn2bqztbv"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-18T18:42:27Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-18T19:10:40Z
      mode: "implement"
      note: "Started EP-1 dependency cohort implementation"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-18T19:31:14Z
      mode: "implement"
      note: "Started EP-2 read-model freshness modernization"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-18T21:56:42Z
      mode: "implement"
      note: "Started EP-3 projection catalog and runtime assembly implementation"
---

# Adopt Keiro 0.17 comprehensively

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

After this initiative, every Kioku package resolves against the released Keiro 0.17
cohort, Kioku no longer calls the Keiro read-model APIs that 0.17 deprecates, and the
repository has executable evidence for the Keiro runtime, Haskell, and PostgreSQL
patterns that actually apply to this reusable library and its command-line hosts. A
consumer can build Kioku without holding Keiro at 0.16, can run every query and command
through semantically equivalent modern APIs, and can follow a versioned upgrade edge
that explains the upstream break before Keiro removes its compatibility surface.

The initiative includes all direct Keiro packages, the optional PGMQ solve encoded in
`cabal.project`, read-model construction and query freshness, projection registration
and runtime assembly, event-stream validation evidence, migration authoring and test
gates, Haskell and CLI conventions, documentation, changelogs, and the
`kioku-upgrade` blueprint. It also produces a durable applicability matrix so a future
review can distinguish a satisfied pattern from one that does not govern Kioku. The
registered project the request calls “postgresql-jitsurei-patterns” is
`mori://shinzui/postgresql-jitsurei`; its migration standards are the PostgreSQL
authority used here.

This work does not adopt `keiro-dsl`, `keiro-pgmq`, inbox/outbox, integration events,
external SQL read contracts, or an operations server merely because Keiro provides
them. Kioku does not consume those surfaces today. It does not rewrite any applied
migration, change memory-space semantics, publish packages to Hackage, or operate on a
real database. Package publication remains a separate user-initiated release.


## Decomposition Strategy

The work is split into six functional streams. EP-1 establishes one resolvable 0.17
dependency baseline. EP-2 removes the concrete deprecated API use found by source
inspection: nineteen direct `ReadModel` declarations and every `runQueryWith` call.
EP-3 owns the broader runtime boundary—one validated projection inventory, catalog
registration, startup validation, and an explicit treatment of Kioku's framework-owned
timer side effects. EP-4 owns migration and PostgreSQL discipline. EP-5 owns the
language, package, record, and CLI conventions that are independent of Keiro behavior.
EP-6 integrates those results, applies the deprecation ratchet, writes the conformance
matrix and release guidance, and proves the whole repository.

This ordering separates “the release can resolve” from “the source is future-proof.” A
single upgrade plan was rejected because dependency solving, read-side semantics,
database invariants, and repository-wide style gates have different failure and rollback
modes. One plan per deprecated occurrence was also rejected because the nineteen model
declarations and their queries must agree on the same cursor and freshness semantics.
The selected plans are independently testable and give the final integration plan one
place to detect drift between them.

The following local decisions constrain the work:

- [Projections live in the Kioku schema](../adr/projections-live-in-the-kioku-schema.md)
  requires application projections to remain in `kioku`, framework tables to remain in
  `keiro`, explicit qualification, migration-first deployment, and reconciliation after
  an additive schema identity change.
- [The aggregate enforces the partition](../adr/the-aggregate-enforces-the-partition.md)
  requires catalog declarations, replay, queries, and background work to preserve the
  memory-space boundary rather than relying on a caller filter.
- [Each recall target gets its own statement](../adr/each-recall-target-gets-its-own-statement.md)
  requires EP-2 to retain the nine distinct recall statement families while changing
  only the Keiro query runner.

No new architectural decision is needed to create these plans. EP-3 must create or
update a local ADR if implementation establishes a durable boundary between
application-owned catalog projections and Keiro's shared timer table. The repository's
existing filesystem ADR convention remains authoritative; `docs/adr` is not currently
an OKF bundle.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Align Kioku with the released Keiro 0.17 dependency cohort | docs/plans/42-align-kioku-with-the-released-keiro-0-17-dependency-cohort.md | None | None | Complete |
| EP-2 | Replace deprecated Keiro read-model freshness APIs | docs/plans/43-replace-deprecated-keiro-read-model-freshness-apis.md | EP-1 | None | Complete |
| EP-3 | Establish a validated projection catalog and runtime assembly | docs/plans/44-establish-a-validated-projection-catalog-and-runtime-assembly.md | EP-2 | None | Complete |
| EP-4 | Harden Kioku migrations to the PostgreSQL patterns | docs/plans/45-harden-kioku-migrations-to-the-postgresql-patterns.md | EP-1 | EP-3 | Not Started |
| EP-5 | Ratchet Haskell and CLI pattern conformance | docs/plans/46-ratchet-haskell-and-cli-pattern-conformance.md | EP-1 | EP-2 | Not Started |
| EP-6 | Integrate and publish the Keiro 0.17 adoption | docs/plans/47-integrate-and-publish-the-keiro-0-17-adoption.md | EP-1, EP-2, EP-3, EP-4, EP-5 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 is the root because every implementation and test must compile against the actual
0.17 types. EP-2 then establishes truthful `ReadModelBlueprint` values; EP-3 consumes
those values when it creates the catalog's query-model bindings and registration path.
EP-4 and EP-5 may proceed in parallel after EP-1. EP-4 has only a soft dependency on
EP-3: migration tests should use the final catalog registration path when available,
but their manifest, lockfile, hostile-`search_path`, and schema-qualification checks do
not require it. EP-5 can audit in parallel, but should incorporate EP-2's imports and
new modules before its final formatting and warning pass.

EP-6 is the only fan-in. It requires the real code and test artifacts from all earlier
plans so its conformance matrix cites evidence rather than intentions and so the
upgrade blueprint describes the version that will actually ship.


## Integration Points

- **Cabal dependency declarations:** EP-1 owns every Keiro/PGMQ bound in the five
  package files and `cabal.project`. EP-5 may reorganize common stanzas but must preserve
  EP-1's bounds. EP-6 owns the package-version bump and release-facing tables.
- **Read models:** EP-2 owns `Kioku.Memory.ReadModel`, `Kioku.Session.ReadModel`, and
  query call sites. EP-3 consumes their blueprint/model values and owns catalog
  bindings; it must not duplicate names, versions, hashes, or SQL statements.
- **Projection registration:** EP-3 owns the validated catalog and `Kioku.App` startup
  path. EP-4 may use that public boundary in fixtures; EP-6 documents it. The existing
  `Kioku.ReadModel.reconcileReadModelRegistry` behavior must remain available for
  migration-time additive identity reconciliation.
- **Migration fixtures:** EP-4 owns `kioku-migrations` test support, migration linting,
  and any expected-schema artifact. EP-3 must not add a second database fixture.
- **Warnings and formatting:** EP-5 owns repository-wide Haskell convention checks.
  EP-2 owns the Keiro-deprecation removal; EP-6 turns that result into a final gate.
- **Documentation and release metadata:** EP-6 owns root/package changelogs, README and
  user-guide version claims, the conformance matrix, and the Seihou upgrade edge. Earlier
  plans record implementation facts in their own living sections without competing edits.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: Align Kioku with the released Keiro 0.17 dependency cohort (complete;
  direct and optional solves, build, 445 tests, and 56-migration invariant passed).
- [x] EP-2: Replace deprecated Keiro read-model freshness APIs (complete;
  nineteen blueprints, twenty-one modern query calls, deprecation ratchet, and
  445-test repository suite passed).
- [x] EP-3: Establish a validated projection catalog and runtime assembly (complete;
  two sources, three targets, two rebuild groups, nineteen query bindings, ten focused
  tests, and the 455-test repository suite passed).

## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- EP-1 confirmed the exact modernization inventory that EP-2 must remove: 19 direct
  legacy `ReadModel` declarations and 21 `runQueryWith` calls, including one test
  call. A clean Keiro 0.17 build emits the corresponding deprecations but otherwise
  compiles and passes all suites.
- Mori correctly locates `mori://shinzui/keiro`, but its observed dependency metadata
  can lag a released package manifest. EP-1 therefore used Mori for source discovery
  and verified the selected cohort against both Hackage and the upstream
  `keiro-*-0.17.0.0` tags, as required by the repository dependency policy.
- EP-2 found that Cabal 3.14 rejects the planned `kioku-core:lib` spelling;
  `lib:kioku-core` is the accepted public-library target. The replacement APIs
  otherwise matched the released Keiro 0.17 contract exactly.
- EP-2 exports all nineteen `ReadModelBlueprint` values alongside their existing
  model values. EP-3 can therefore bind the catalog to the authoritative names,
  tables, versions, hashes, cursor authorities, and SQL without reconstructing a
  parallel inventory.
- EP-3 confirmed that Keiro's exclusive target-ownership invariant cannot represent
  the shared framework-owned timer table truthfully. Kioku therefore catalogs only
  its three application tables and keeps both timer callbacks explicit in the same
  append transaction; a rollback fixture proves the boundary remains atomic.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Treat Keiro 0.17 as a source-modernization initiative, not a bounds-only upgrade.
  Rationale: Keiro 0.17 deprecates the exact `ConsistencyMode`, `StrongScope`, direct
    `ReadModel` construction, and `runQueryWith` APIs Kioku uses. Merely compiling would
    defer known removal work to the next major release.
  Date: 2026-09-18
- Decision: Use six workstreams with one final integration owner.
  Rationale: This keeps dependency, runtime, database, and language changes independently
    reviewable while preventing release documentation from being edited by every plan.
  Date: 2026-09-18
- Decision: Target Kioku 0.7.0.0 for the eventual release edge.
  Rationale: Kioku exposes values whose types come from the zero-major Keiro package and
    will exclude the 0.16 cohort; the conservative PVP signal is a Kioku major-component
    bump. EP-6 must confirm this against the final API diff before release metadata is cut.
  Date: 2026-09-18
- Decision: Verify pattern applicability instead of manufacturing unused architecture.
  Rationale: Kioku does not use the DSL, PGMQ, inbox/outbox, or a deployed six-package
    service topology. The final matrix must say “not applicable” with evidence where
    appropriate and must not introduce those systems solely to satisfy a checklist.
  Date: 2026-09-18
- Decision: Treat the EP-2 blueprints as the read-model definition boundary for
    EP-3's catalog.
  Rationale: The blueprints now own all nineteen identities and queries with
    truthful `NoQueryCursor` capabilities; a second catalog-local definition
    would reintroduce the drift this initiative is intended to remove.
  Date: 2026-09-18
- Decision: Catalog Kioku-owned projections and retain Keiro timer scheduling as an
    explicit framework callback at each command boundary.
  Rationale: The released catalog requires one owner per target, while
    `keiro.keiro_timers` is shared framework state written by both event families.
    ADR-13 records the boundary and the capability needed before adopting the
    catalog-fenced command runner.
  Date: 2026-09-18


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

EP-3 established the initiative's runtime source of truth: catalog validation,
registration, migration reconciliation identities, typed application handlers, rebuild
metadata, and the persisted fingerprint now derive from one validated declaration. The
application-owned projections and existing timer schedules remain transactionally atomic,
and all invalid catalog fixtures fail before traffic. The durable shared-framework boundary
is recorded in [ADR-13](../adr/catalog-application-projections-not-framework-timers.md).
