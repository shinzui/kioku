---
id: 7
slug: remediate-the-kioku-0-3-0-0-to-0-4-0-0-release-range-review
title: "Remediate the Kioku 0.3.0.0 to 0.4.0.0 release-range review"
kind: master-plan
created_at: 2026-08-20T13:57:30Z
intention: "intention_01m0fpyzp4e2kbnhyvcm00zd9t"
---

# Remediate the Kioku 0.3.0.0 to 0.4.0.0 release-range review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

This initiative closes findings 2 through 15 from
`docs/reviews/release-range-0-3-0-0-to-0-4-0-0.md` without duplicating the repair already
owned by `docs/plans/32-restore-host-search-path-after-kioku-migrations.md`. After it is
complete, artifact migration cannot overwrite a file produced after its dry run; every
distillation level spends an explicitly granted permission before reading, writing, or calling
an LLM; memory lineage cannot point to a missing or cross-space winner; watermark and timer
diagnostics identify the correct memory space; full-text recall and embedding maintenance do not
scale with unrelated tenants; and schema names, recall strategies, scope parameters, workspace
slugs, and timer mechanics each have one canonical implementation.

The initiative also removes the Rei-specific foreign-event compatibility decoder once the last
consumer has completed its one-time cutover. Native Kioku events written before memory spaces
remain supported through `Kioku.Partition`; only the fallback for Rei's old
`agent_memory_*`/`agent_session_*` payloads is retired. The external gate is the absence of any
consumer import from `mori://shinzui/rei/packages/rei-core`, not an assumed date or package bound.

Finding 1, migration 0011's session `search_path` leak, is explicitly outside these child plans.
It remains in scope for the release as a whole through ExecPlan 32, but this MasterPlan neither
changes that plan nor creates a second migration owner. Refuted candidates in the review remain
out of scope. No plan broadens Kioku into an identity or authorization service, changes the
meaning of a memory space, weakens native event compatibility, or edits a released migration as
part of the performance work.


## Decomposition Strategy

The fourteen findings owned here are grouped into seven functional work streams. EP-1 owns the
workspace as a filesystem safety boundary. EP-2 owns the distillation authorization path and the
L2/L3 mechanics whose duplication caused it to drift. EP-3 owns aggregate lineage validation and
the shared write-context gate. EP-4 owns tenant bookkeeping that can silently misattribute or
repeat work. EP-5 owns database work whose cost currently grows with other spaces. EP-6 owns two
small public-vocabulary drift points. EP-7 owns the deliberate retirement of foreign legacy
payload support. Each stream has a behavior that can be demonstrated independently and, except
for two documented shared modules, can be implemented without editing another stream's core
files.

The main rejected alternative was one plan per owned review finding. That would produce fourteen small
plans while putting three contributors into the same L2/L3 handlers and two into the same
workspace code. The opposite alternative, one large correctness plan plus one design plan, was
also rejected: artifact collision safety, lineage invariants, timer diagnostics, and watermark
self-healing have unrelated failure modes and tests. The chosen boundary keeps coupled edits
together while retaining independent acceptance.

The relevant local ADRs are:

- [Kioku owns memory, not authorization](../adr/kioku-owns-memory-not-identity.md), which EP-2
  and EP-3 preserve by validating a supplied `MemoryAccessContext` without deriving policy.
- [Namespace is not a security boundary](../adr/namespace-is-not-a-security-boundary.md),
  [the aggregate enforces the partition](../adr/the-aggregate-enforces-the-partition.md), and
  [the partition is a column](../adr/the-partition-is-a-column-not-a-schema.md), which require
  every worker, lineage lookup, index, and diagnostic to stay inside one explicit space.
- [Historical attribution is marked, never invented](../adr/historical-attribution-is-marked-never-invented.md),
  which continues to bind native Kioku event decoding after EP-7 removes the separate Rei
  fallback.
- [The partition reaches the filesystem as a digest](../adr/the-partition-reaches-the-filesystem-as-a-digest.md),
  whose no-overwrite promise EP-1 makes true at apply time.
- [Each recall target gets its own statement](../adr/each-recall-target-gets-its-own-statement.md),
  whose nine query families EP-5 must preserve while changing only their access path.
- [Projections live in the Kioku schema](../adr/projections-live-in-the-kioku-schema.md), which
  EP-5 and EP-6 preserve by appending migration history and using the schema constants.

No cross-repository ADR changes the decomposition. Mori was used to inspect the current Rei
package and upgrade work; those are implementation gates rather than Kioku architectural
authority. The repository has an ordinary filesystem ADR corpus rather than a profile-governed
`docs/adr` OKF bundle, so later ADR edits must preserve the existing frontmatter and filename
convention.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Make workspace artifact migration no-clobber and share slug derivation | docs/plans/33-make-workspace-artifact-migration-no-clobber-and-share-slug-derivation.md | None | None | Complete |
| EP-2 | Enforce distillation permissions through shared timer primitives | docs/plans/34-enforce-distillation-permissions-through-shared-timer-primitives.md | None | None | Complete |
| EP-3 | Enforce memory lineage and centralize write-context gates | docs/plans/35-enforce-memory-lineage-and-centralize-write-context-gates.md | None | None | Not Started |
| EP-4 | Repair L1 watermark ownership and timer-space attribution | docs/plans/36-repair-l1-watermark-ownership-and-timer-space-attribution.md | None | EP-2 | Not Started |
| EP-5 | Scale full-text recall and embedding backfill by memory space | docs/plans/37-scale-full-text-recall-and-embedding-backfill-by-memory-space.md | None | None | Not Started |
| EP-6 | Use canonical schema and recall-strategy vocabularies | docs/plans/38-use-canonical-schema-and-recall-strategy-vocabularies.md | None | None | Not Started |
| EP-7 | Retire Rei legacy event decoders after consumer cutover | docs/plans/39-retire-rei-legacy-event-decoders-after-consumer-cutover.md | External Rei cutover gate | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3), or name an
external evidence gate explicitly when no child plan owns it.


## Dependency Graph

EP-1, EP-2, EP-3, EP-5, and EP-6 can proceed in parallel. They share the release changelog and
package metadata but no implementation prerequisite. EP-4 can also start independently, although
running it after EP-2 is preferred because both touch `Kioku.Distill.L1`,
`Kioku.Distill.Timer.Worker`, and `Kioku.Partition`; EP-2 owns the shared timer and partition
primitives, and EP-4 should consume the resulting layout instead of producing a second spelling.
This is a soft dependency because EP-4's watermark and diagnostic behavior can be tested without
EP-2.

EP-7 has no Kioku child-plan dependency, but it has a real external hard gate. Before deleting a
single decoder, its implementer must use Mori to locate every dependent and prove that no released
or deployable consumer still imports `parseMemoryEvent` or `parseSessionEvent` to translate Rei
payloads. The current Rei tree still contains `rei-kioku-migrate`, so EP-7 must stop at its first
milestone until that executable has been used where required and retired. The intended related
upgrade artifacts are
`mori://shinzui/rei/plans/203-land-the-released-keiro-0-13-cohort-build-plan` and
`mori://shinzui/rei/plans/210-cut-the-production-database-over-to-the-0-13-cohort-and-prove-it`;
current Mori plan-URI coverage may lag, so the package URI and source audit remain the executable
proof.

ExecPlan 32 is coordinated but not a dependency. EP-5 must create the next migration with
`just new-migration` at implementation time rather than assuming a number, so whichever plan
changes the manifest first wins the next ordinal without a conflict.


## Integration Points

For each shared artifact (type, module, configuration, database table) that multiple
child plans touch, document: which plans are involved, what the shared artifact is,
which plan is responsible for defining it, and how later plans should consume or extend
it. Identify any cross-plan decisions that should become ADRs, especially architecture
boundaries, durable integration constraints, shared interface ownership, decomposition
rationale that will matter later, and deliberate exclusions.

- **Distillation and partition helpers:** EP-2 owns the shared `PartitionedScope` record and
  Hasql encoder in `Kioku.Partition`, the common L2/L3 timer-fire pipeline beside `FireOutcome`,
  and the shared best-effort file-removal helper in `Kioku.Workspace`. EP-4 may extend
  `Kioku.Partition` with an optional diagnostic parser, but must not change the legacy-defaulting
  parser used by native events and known timer payloads.
- **Authorization context:** EP-3 owns the generic permission/space/actor gate in
  `Kioku.Api.Access`. EP-2 consumes the existing read-only accessors and checks required
  permissions at the start of each distillation operation. Neither plan may export the
  `MemoryAccessContext` constructor or move policy into Kioku.
- **L1 implementation:** EP-2 changes the permission preflight in
  `Kioku.Distill.L1.distillSessionL1`; EP-4 changes only the watermark upsert in the same module.
  If implemented concurrently, reconcile both before either plan's final test run.
- **Timer worker:** EP-2 consolidates how L2/L3 obtain and validate a context; EP-4 changes how
  `Timer.Worker` extracts a space for diagnostics. The action parser keeps legacy defaulting;
  the diagnostic parser reports absence as `unknown`.
- **Migration manifest:** EP-5 is the only child plan that adds a Kioku migration. It owns the
  partition-aware full-text index and its migration tests. ExecPlan 32 owns the 0011 leak and any
  associated released-history treatment. Neither plan edits the other's artifact.
- **Release notes and package metadata:** every child adds its own concise `Unreleased` entry to
  the relevant package changelog. The first implemented plan creates the heading; later plans
  append without rewriting earlier entries. EP-1 alone may add the direct `unix` dependency.
- **Rei compatibility boundary:** EP-7 removes only the foreign Rei fallback. It preserves native
  Kioku old-event tests by relocating the pre-`force` session fixtures out of
  `Kioku.ReiCompatSpec`. The decision that a reusable library does not indefinitely own a
  consumer's one-time migration codec is durable and should become a local ADR during EP-7.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: publish artifact copies atomically without replacing a destination created after planning.
- [x] EP-1: make workspace and scope slugs consume one sanitise-plus-digest primitive.
- [x] EP-2: reject L1, L2, and L3 work before any LLM or write when required permissions are absent.
- [x] EP-2: replace L2/L3 timer, partition-parameter, and mirror-removal duplication with shared primitives.
- [ ] EP-3: reject missing and cross-space lineage targets before appending memory events.
- [ ] EP-3: make Memory and Session writes consume one parameterized context gate.
- [ ] EP-4: make a divergent watermark row self-heal and become readable to the next pass.
- [ ] EP-4: report `unknown` rather than `kioku_legacy` for payloads that do not name a space.
- [ ] EP-5: install and prove a partition-aware full-text access path with a safe fallback.
- [ ] EP-5: push the settled-embedding skip predicate into both backfill SQL statements.
- [ ] EP-6: build the vector capability probe and CLI strategy reader from canonical constants.
- [ ] EP-6: prove every API recall strategy is accepted by the CLI with the canonical diagnostics.
- [ ] EP-7: prove every Rei consumer has completed or retired the foreign-event migration path.
- [ ] EP-7: remove Rei decoders while preserving every native Kioku compatibility fixture.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Mori reports `mori://shinzui/rei/packages/rei-core` on Kioku `^>=0.4.1`, but the current
  source still builds a `rei-kioku-migrate` executable that imports the two compatibility
  parsers. A version bound is therefore not sufficient evidence for EP-7; source and operational
  cutover evidence are required.
- `unix` is not registered in the local Mori corpus. The compiler package database, Hackage
  index, and upstream `v2.8.8.0` tag agree on 2.8.8.0, whose `OpenFileFlags` supports exclusive
  creation. EP-1 should prefer a fully written temporary file plus atomic same-directory hard
  link, which publishes without replacement and avoids exposing a partial destination.
- `kioku_l1_watermarks.session_id` remains the primary key after memory spaces are added. The
  minimal repair is therefore to update `memory_space_id` from `EXCLUDED` on the existing
  conflict target, not to create a second row for the same globally unique session id.
- EP-2's shared timer pipeline also rejects a provider that returns a context for a different
  space than the payload requested. This preserves EP-4's assumption that it may change diagnostic
  attribution without weakening or duplicating execution-time partition validation.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Do not create a child plan for review finding 1.
  Rationale: BUG-1 and `docs/plans/32-restore-host-search-path-after-kioku-migrations.md` already
  own the migration 0011 leak. A second owner would create incompatible migration-history work.
  Date: 2026-08-20

- Decision: Resolve finding 13 by retiring Rei-specific legacy decoders after a proven consumer
  cutover, rather than consolidating their defaults into `Kioku.Partition`.
  Rationale: Rei is moving on the current Kioku packages, and a reusable library should not keep
  a consumer-specific one-time migration codec indefinitely. Native Kioku compatibility remains.
  Date: 2026-08-20

- Decision: Group findings 3, 5, and 12 into one distillation plan.
  Rationale: the permission omissions and the duplicated L2/L3 fire pipelines are the same drift
  boundary; separate plans would edit the same handlers and could restore the divergence.
  Date: 2026-08-20

- Decision: Group workspace collision safety with shared slug derivation, and memory lineage with
  the shared write-context gate.
  Rationale: each pair shares the file and invariant it is meant to harden, while remaining
  independently verifiable from the other review findings.
  Date: 2026-08-20

- Decision: Append a new full-text-index migration at implementation time and never assign its
  ordinal in this plan.
  Rationale: the manifest is shared with ExecPlan 32 and possibly other work; `just new-migration`
  is the repository's atomic source of numbering truth.
  Date: 2026-08-20

- Decision: Defer new ADR authoring until implementation, while identifying EP-7's compatibility
  ownership boundary as the likely new record.
  Rationale: the existing ADRs already decide partitioning, authorization, schema ownership,
  recall statement families, and filesystem identity. Only the foreign-decoder retirement adds
  durable architectural policy rather than applying an accepted decision.
  Date: 2026-08-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

EP-1 completed on 2026-08-21. Workspace artifact migration now preserves a live destination even
when it appears after planning, accepts byte-identical late publication idempotently, preserves
source permissions, and removes its temporary sibling on handled success and failure. Workspace
and scope persisted names share one byte-stable slug primitive. The full affected core and CLI
suites pass; six child plans remain.

EP-2 completed on 2026-08-21. L1 preflights distill, record, and forget authority before evidence
reads; L2/L3 use one partitioned timer pipeline that validates provider refusal, permission, and
space agreement before derived work. Shared partition encoders and mirror removal eliminate the
remaining handler duplication. The full API/core/CLI suites pass (119/220/50 tests), and ADR-4
now records the durable background-context rule. Five child plans remain.
