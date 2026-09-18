---
id: 44
slug: establish-a-validated-projection-catalog-and-runtime-assembly
title: "Establish a validated projection catalog and runtime assembly"
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

# Establish a validated projection catalog and runtime assembly

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Give Kioku one validated, inspectable source of truth for its application-owned
projections and query models, register that inventory before any query is served, and make
startup validation failures explicit. The catalog must cover the memory, session, and turn
read-side targets and all nineteen query bindings. Tests must prove duplicate ownership,
missing suppliers, incompatible cursor claims, and fingerprint drift fail at startup rather
than after traffic begins.

Kioku also schedules Keiro timers inside command transactions. Those rows live in Keiro's
shared framework table and are written by projections from two event types, so they cannot
honestly be declared as an exclusively owned application target. This plan records and tests
that boundary instead of falsifying catalog ownership. It uses catalog-derived handlers for
Kioku-owned projection tables and retains the timer handlers as framework side effects in
the same transaction until Keiro offers a catalog declaration for shared framework targets.


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

- Decision: Catalog application-owned projection tables, not Keiro's shared timer table.
  Rationale: A `TargetDeclaration` has one qualified table and exactly one projection owner;
    `keiro.keiro_timers` is framework-owned and receives writes from both memory and session
    handlers. Declaring it twice violates closed-world validation; assigning it to one Kioku
    projection would be false ownership.
  Date: 2026-09-18
- Decision: Preserve a single transactional append path for read-model updates and timer
    scheduling.
  Rationale: Splitting those writes would weaken existing atomicity. Catalog adoption must
    not trade a stylistic improvement for orphaned timers or projections.
  Date: 2026-09-18
- Decision: Treat top-level `mkEventStreamOrThrow` as temporary and require explicit
    `mkEventStream` proof at startup.
  Rationale: The streams are hand-written, while the runtime pattern reserves the throwing
    helper for generated definitions or fixtures with colocated proof. Startup should report
    validation diagnostics rather than crash during module evaluation.
  Date: 2026-09-18


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`Kioku.Memory.ReadModel` and `Kioku.Session.ReadModel` define inline Hasql projections.
Memory commands run `memoryInlineProjection` and `l2SceneTimerScheduleProjection`; session
commands run `sessionInlineProjection` and `l1TimerScheduleProjection`, all through
`runCommandWithProjections`. `Kioku.ReadModel` separately lists nineteen models for startup
registration and migration reconciliation. `Kioku.App.withNoopAppEnv` acquires a store,
calls `registerKiokuReadModels`, and only then exposes `AppEnv`.

That arrangement works, but projection handlers, query bindings, registration, and future
rebuild ownership can drift because they are separate lists. Keiro 0.17 provides
`ProjectionCatalog`, `validateProjectionCatalog`, opaque `ValidatedProjectionCatalog`,
`registerProjectionCatalog`, typed `ProjectionSet event` values, and catalog inventory.
The normative guides are
`mori://shinzui/keiro-runtime-patterns/docs/keiro-read-models-and-projections` and
`mori://shinzui/keiro-runtime-patterns/docs/keiro-runtime-assembly`.

`Kioku.Memory.EventStream` and `Kioku.Session.EventStream` currently create top-level
validated values with `mkEventStreamOrThrow`. The definitions are hand-written, so the
runtime should call `mkEventStream` once and propagate diagnostics before it registers the
catalog. Kioku is a reusable library, not a deployed service package: migration application
remains a deployment job and `kioku-core` cannot depend on `kioku-migrations` without
closing the documented package cycle. Host startup-handshake responsibilities must be
documented rather than smuggled into core.

[ADR-10](../adr/projections-live-in-the-kioku-schema.md) fixes table ownership and migration
ordering. [ADR-4](../adr/the-aggregate-enforces-the-partition.md) requires every catalog
query and replay adapter to preserve memory-space isolation. If the shared-timer boundary
remains a durable exception after implementation, add an ADR under `docs/adr/` in the same
change and cite the missing Keiro capability precisely.


## Plan of Work

Milestone 1 adds `kioku-core/src/Kioku/ProjectionCatalog.hs` and exposes it from
`kioku-core.cabal`. Declare stable source, target, rebuild-group, projection, and query-model
identifiers. The target set contains the application relations actually supplied by the
memory/session inline projections (`kioku.memories`, `kioku.sessions`, and `kioku.turns`);
derive dependencies from their foreign keys and keep all identifiers stable text. Construct
typed memory and session `ProjectionSet` values, bind every model produced by
`docs/plans/43-replace-deprecated-keiro-read-model-freshness-apis.md` through
`QueryModelBinding`, validate once, and expose only the `ValidatedProjectionCatalog`, typed
sets, inventory/fingerprint accessors needed by hosts, and a diagnostic-rendering constructor
for tests. Replay adapters must decode with `memoryCodec` or `sessionCodec` and must preserve
recorded event time. If a target cannot be replayed safely, declare `LiveOnly` with a specific
reason rather than a fake adapter.

Milestone 2 removes duplicate inventories. Change `Kioku.ReadModel.kiokuReadModelSchemas`
to derive from `catalogRegistrations` (or one typed projection of that result) and make
`registerKiokuReadModels` delegate to `registerProjectionCatalog`. Keep
`reconcileReadModelRegistry` for the migration executable, but derive its expected identities
from the catalog. In `Kioku.App.withNoopAppEnv`, validate event streams, validate/register the
catalog, reject `CatalogRegistrationError`, then expose the environment. Do not start a query
or worker after a failed registration.

Milestone 3 routes Kioku-owned handlers from the catalog. Replace hand-maintained read-model
projection lists with `typedInlineProjections` from the validated catalog. Keep the L1/L2
timer scheduling handlers adjacent as explicitly framework-owned transactional callbacks;
tests must show append, Kioku projection update, and timer schedule still commit or roll back
together. Do not declare `keiro.keiro_timers` as a Kioku target. Record the boundary in an ADR
if no released catalog API can express it honestly.

Milestone 4 adds tests in `kioku-core/test/Kioku/ProjectionCatalogSpec.hs` and updates
`Main.hs`. Assert inventory cardinalities and stable fingerprint, validate all nineteen query
suppliers, reject duplicate/unknown ownership and a waiting query without a cursor, register
against an ephemeral migrated database, and run a real memory and session command followed by
an immediate query. Add explicit tests that `mkEventStream` accepts both definitions; expose
definition constructors internally if necessary without making unchecked streams public.


## Concrete Steps

Run from the repository root:

```sh
cabal test kioku-core:kioku-test --test-options='--pattern ProjectionCatalog'
cabal test kioku-core:kioku-test --test-options='--pattern ReadModel'
cabal test kioku-core:kioku-test --test-options='--pattern Idempotency'
cabal test all
```

Add a small test assertion whose failure transcript renders Keiro diagnostic codes. A valid
catalog should report a non-empty fingerprint and exactly nineteen query registrations;
invalid fixtures should report stable codes such as
`catalog.query-model-without-supplier` rather than throwing.

Also run:

```sh
rg -n 'registerReadModel|kiokuReadModelSchemas|runCommandWithProjections|mkEventStreamOrThrow' kioku-core/src
```

Every remaining match must be explained in the module comment as migration reconciliation,
the framework-timer transaction boundary, or a test fixture; no second runtime inventory may
remain.


## Validation and Acceptance

Startup with a valid database must validate two event streams, validate one catalog,
register it, and only then call the continuation. A deliberately invalid catalog or persisted
fingerprint mismatch must prevent the continuation. A memory/session command must atomically
append its event, update its Kioku projection, and schedule its due timer when applicable;
injected handler failure must leave none of those writes committed.

Catalog inventory must have no duplicate target or query identities, every query must have
exactly one supplier, and all immediate models must resolve to `NoQueryCursor`. Existing stale
schema reconciliation tests must still pass. The full suite must preserve space isolation and
the 56-entry migration plan.


## Idempotence and Recovery

Validation and registration are idempotent; rerunning startup against an unchanged catalog
must succeed without duplicate rows. Build the catalog beside the existing path first, test
its inventory, then switch registration and commands. If registration fails, retain the old
runtime path until diagnostics are understood; never delete registry rows or change a
fingerprint merely to make a test pass.


## Interfaces and Dependencies

`Kioku.ProjectionCatalog` must expose a single
`kiokuProjectionCatalog :: ValidatedProjectionCatalog`, typed memory/session
`ProjectionSet` values, and a testable validation function returning Keiro's
`Validation (NonEmpty CatalogDiagnostic)`. Use `Keiro.Projection.Catalog` for declarations
and derived views and `Keiro.ReadModel.Rebuild.registerProjectionCatalog` for startup.
`Kioku.App.withNoopAppEnv` retains its public callback shape unless the implementation can
add a typed startup error without breaking consumers; internal helpers may distinguish stream,
catalog, registration, and store failures. The migration package remains the owner of the
complete `MigrationPlan`; core documents the host handshake but does not import it.
