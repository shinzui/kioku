---
id: 5
slug: portfolio-compatible-memory-isolation-and-authorization
title: "Portfolio-compatible memory isolation and authorization"
kind: master-plan
created_at: 2026-08-06T14:43:34Z
intention: "intention_01kzbreeh2er1962bwjq8s1yyp"
---

# Portfolio-compatible memory isolation and authorization

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Every Kioku command and query operates inside an explicit `MemorySpaceId`. Writes also carry
the canonical Meibo principal responsible for the action and, where applicable, the principal
that owns the memory. A person, team, agent, service, or organization is represented by its
Meibo kind-prefixed TypeID; Kioku does not create user, team, agent, membership, or ACL tables.

At a service boundary, Shomei authenticates and applies coarse scopes, Meibo resolves the
credential subject to a canonical principal, and En decides whether that principal may read,
record, distill, administer, or share the target memory space. Kioku persists the resulting
principal and space context and enforces partition predicates on every storage and worker path.
This initiative includes the library contracts, event/API propagation, schema migration, and
partition-safe background work. It does not own credentials, directory lifecycle, membership,
or authorization policy, and it does not build the HTTP service requested separately in the
improvement-request backlog.


## Decomposition Strategy

EP-1 pins the portfolio seams before Kioku commits to names or wire shapes. EP-2 carries the
new space and principal context through public types, commands, events, and compatibility
codecs. EP-3 migrates and backfills PostgreSQL projections without weakening uniqueness or
query bounds. EP-4 closes the easily missed paths: timers, subscription workers, reconciliation,
and plaintext workspace mirrors.

The decomposition prevents schema-first design from freezing a private identity vocabulary.
It also makes event compatibility independently reviewable from database backfill. The
repository has no `docs/adr/` corpus today. Implementation should create ADRs for the memory
space ownership model, the legacy default-space policy, and the rule that authorization stays
outside the core event-sourced domain. A column-per-upstream-level design (`team_id`, `task_id`,
`user_id`, `agent_id`) was rejected because teams, people, and agents are principals while
tasks and spaces are objects with relationships; collapsing them into fixed nullable columns
would fork Meibo and En.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Define portfolio identity and authorization contracts for Kioku | docs/plans/24-define-portfolio-identity-and-authorization-contracts-for-kioku.md | None | None | Complete |
| EP-2 | Carry memory-space partitions through Kioku domain and APIs | docs/plans/25-carry-memory-space-partitions-through-kioku-domain-and-apis.md | EP-1 | None | Complete |
| EP-3 | Migrate Kioku read models to partitioned memory spaces | docs/plans/26-migrate-kioku-read-models-to-partitioned-memory-spaces.md | EP-2 | None | Complete |
| EP-4 | Isolate workers timers and workspace artifacts by memory space | docs/plans/27-isolate-workers-timers-and-workspace-artifacts-by-memory-space.md | EP-2, EP-3 | None | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 is the contract gate. It must establish which identifiers are opaque portfolio IDs, what
an En memory-space object looks like, and which checks belong at a host boundary. EP-2 then
defines the public Haskell and JSON surface. EP-3 depends on that stable representation for
columns, indexes, backfill rules, and projection identities. EP-4 depends on both the API and
schema because a worker is safe only when its claim, lookup, mutation, and artifact path all
carry the same space.

The En vocabulary is not fully available today. The user-facing principal and space work is
tracked by `mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-1`; EP-1 must verify
its final released schema before selecting object and permission names. Meibo source already
defines canonical kind-prefixed principal IDs, but its Mori registration metadata is stale;
dependency bounds must be chosen from the authoritative release registry and upstream tags at
implementation time.


## Integration Points

For each shared artifact (type, module, configuration, database table) that multiple
child plans touch, document: which plans are involved, what the shared artifact is,
which plan is responsible for defining it, and how later plans should consume or extend
it. Identify any cross-plan decisions that should become ADRs, especially architecture
boundaries, durable integration constraints, shared interface ownership, decomposition
rationale that will matter later, and deliberate exclusions.

- **Canonical principals:** EP-1 consumes `mori://shinzui/meibo/docs/initial-spec` and the
  released `meibo-api` identifier renderer/parser. EP-2 stores the rendered principal ID as
  an opaque value and never copies profile or membership data.
- **Authentication:** the future service adapter consumes
  `mori://shinzui/shomei/packages/shomei-servant`. Shomei provides identity and coarse role or
  scope checks; it does not decide access to a memory space.
- **Authorization:** EP-1 pins En subject/object/permission mappings against
  `mori://shinzui/en/packages/en-core` and its Servant/client packages. En owns relationships
  and consistency tokens. Kioku owns memory-space data and applies the authorized space as an
  indexed predicate.
- **Domain context:** EP-2 owns `MemorySpaceId`, `PrincipalRef`, `MemoryAccessContext`, codec
  compatibility, and legacy constructors. EP-3 and EP-4 consume these types. As shipped it also
  owns `RecordedPrincipal` (the three-case actor a stored fact records) and
  `MemoryContextProvider` (how work that discovers itself gets authorized), and it enforces the
  partition in the aggregate rather than in a read-model precheck — see
  [ADR-4](../adr/the-aggregate-enforces-the-partition.md) and
  [ADR-5](../adr/historical-attribution-is-marked-never-invented.md).
- **Schema:** EP-3 owns the additive migration and backfill across memories, sessions, turns,
  watermarks, decisions, scenes, personas, and any provenance/evidence tables present when it
  lands. EP-4 owns query audits outside ordinary read-model functions. EP-2 left EP-3 two named
  obligations and both are discharged: the write-path idempotency lookup is now scoped to the
  command's own space, so an id in another space answers exactly as one that does not exist, and
  scene and persona rows have composite `(memory_space_id, …)` primary keys. As shipped, EP-3 also
  owns the read-side API shape — every read takes a `MemorySpaceId` — and
  [ADR-6](../adr/the-partition-is-a-column-not-a-schema.md), which records why the boundary is a
  column and a predicate rather than a schema, database, or RLS policy per space. EP-2 carried the
  L1 timer payload's space itself rather than leaving it to EP-4, because distillation writes
  memories and would otherwise have written every background pass into the legacy space; EP-3 did
  the same for the scene and persona timers, whose ids are keyed by a scope that two spaces may
  share. As shipped, EP-4 owns the embedding subscription's claim (`MemoryContextProvider`,
  `EmbedSpaceMismatch`, `EmbeddingBackfillScope`), the timer dead-letter and span diagnostics, and
  `Kioku.Workspace` — the `.kioku/spaces/<space-dir>/{scenes,persona}` layout and the
  `kioku migrate-artifacts` command. It confirmed that `reconcileReadModelRegistry` is correctly
  space-independent: keiro's `keiro_read_models` is a schema-identity registry, not memory data.
  Any later plan adding a worker, an artifact kind, or an instrument must go through
  [ADR-7](../adr/the-partition-reaches-the-filesystem-as-a-digest.md): artifact paths come from
  `Kioku.Workspace.spaceArtifactRoot`, and no metric may be labelled by a space or a principal.
- **Recall:** `docs/masterplans/6-explicit-and-safe-recall-boundaries.md` consumed the completed
  partition contract and closed on 2026-08-07. Its constraint — recall must never be namespace-wide
  *across* memory spaces — is discharged: `RecallTarget` names the exact scope and the
  namespace-wide case separately, each target has its own statement, and every statement puts
  `memory_space_id` first in the predicate before applying any scope condition. The breadth that
  initiative added therefore stops at this initiative's boundary rather than reaching past it.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: pin Meibo, Shomei, En, and Kikan-En compatibility contracts and conformance cases.
  (2026-08-06 — types and 19 conformance fixtures shipped; the literal object type and permission
  names stay host-supplied because Kikan-En IR-1 is still `proposed`.)
- [x] EP-1: decide the legacy default-space and authorization-boundary policies in ADRs.
  (2026-08-06 — `docs/adr/` ADR-1, ADR-2, ADR-3.)
- [x] EP-2: carry space and principal context through APIs, commands, events, and codecs.
  (2026-08-06 — every command and event payload carries the space and the acting principal; writes
  take a `MemoryAccessContext` and are checked against it.)
- [x] EP-2: prove old event streams replay into the explicit legacy space. (2026-08-06 — the
  pre-upgrade codec fixtures decode into `kioku_legacy`, and a whole pre-partition session stream
  rehydrates there and then refuses a command from another space.)
- [x] EP-3: migrate and backfill every Kioku read model with composite partition indexes.
  (2026-08-06 — `0011-kioku-memory-space-partition.sql`; every statement names the column, and
  scene and persona keys are composite.)
- [x] EP-3: prove cross-space uniqueness and read isolation in real PostgreSQL. (2026-08-06 —
  `Kioku.SpaceIsolationSpec`: two spaces sharing everything but the partition, with every public
  read asserted in both directions and every partitioned lookup shown to use a partition-leading
  index.)
- [x] EP-4: partition timers, subscribers, reconciliation, and workspace mirrors end to end.
  (2026-08-06 — the embedding subscription gained a provider gate and a partitioned claim, mirrors
  moved under `.kioku/spaces/<space-dir>/`, and reconciliation was confirmed to be correctly
  space-independent. One worker over two spaces sharing a scope keeps their rows, files, and bytes
  disjoint.)


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Meibo's current source already implements `PrincipalId` as seven kind-prefixed TypeID
  variants and defines one canonical renderer. Kioku should consume that seam rather than
  preserving arbitrary free-text `agent_id` as the long-term identity contract.
- The current Kikan-En schema is still agent/action-focused. Its proposed IR-1 adds person,
  team, role, organization, and space vocabulary. Kioku must not claim ACL compatibility until
  that dependency is resolved and conformance-tested.
- The reviewed `mori://TencentCloud/TencentDB-Agent-Memory` v2.0.0 release includes an explicit
  data-format-v2-to-v3 migration in the project-relative
  `MemoryCore/scripts/migrate-v2-to-v3/` directory. That third-party project is not yet in the
  Mori registry, so an artifact-level URI is pending. Kioku's inherited storage shape therefore
  appears closest to upstream data format v2 and the v0.3.6-to-v1.x product line. No exact source
  pin is recorded, so this is an inference rather than a compatibility guarantee. EP-3 starts
  from Kioku's actual current `pg-migrate` schema and treats upstream v3 only as design evidence.
- The upstream memory system's newer schema uses fixed team/task/user/agent dimensions. The
  useful requirement is an explicit outer isolation boundary; its fixed identity vocabulary
  does not fit the portfolio trust triad and is intentionally not copied.

- **The decomposition under-counted EP-2 and EP-3 and over-counted EP-4.** EP-4 was scoped to
  "timers, subscribers, reconciliation, and artifacts", but by the time it started all three timer
  paths were partitioned: EP-2 took the L1 payload because distillation writes memories, and EP-3
  took the scene and persona timer ids because they are keyed by a scope two spaces may share.
  Each was the right call at the time — leaving either would have shipped a known defect — and
  each was recorded as an obligation moved rather than an obligation skipped. EP-4's remaining
  half was still real: the embedding subscription, the backfill scan, the filesystem, and
  diagnostics. The lesson for a future decomposition is that "the worker plan owns every worker
  path" does not survive contact with a plan that must make its own change correct.

- **An opaque identifier validated for one sink is not validated for another.** `MemorySpaceId`
  rejects exactly what a database column and a relationship tuple need it to
  (`:`, `#`, `%`, `/`, whitespace, control characters). That list is complete for those sinks and
  leaves `..` and `.` legal, which is a path traversal the moment a space id is used as a
  directory name. EP-4 encodes rather than validates, and
  [ADR-7](../adr/the-partition-reaches-the-filesystem-as-a-digest.md) records the rule so the next
  sink asks the same question instead of inheriting the answer.

- **The partition contract survived its first consumer without amendment.** MasterPlan 6 took
  `MemorySpaceId` and `MemoryAccessContext` through a new public request type, three new SQL
  statements, a CLI grammar, and a candidate finder between 2026-08-06 and 2026-08-07, and changed
  nothing in this initiative's boundary — no type moved, no ADR here was superseded, and no
  statement it added needed an exception to the rule that every statement names the column. That is
  the strongest available evidence that the boundary was drawn in the right place, and it is worth
  recording because the reverse would have been discovered the same way.

- **A partition predicate can create the silence it was added to prevent.** The embedding
  handler's state read looks like every other partitioned read and must not be one: scoping it by
  the envelope's space turns "this event names the wrong space" into "no such memory", which acks
  as a success. It reads the row's own space and compares. Any future worker that validates an
  envelope against stored state has the same trap.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Use an explicit memory-space partition plus canonical principal references instead
  of nullable team/task/user/agent columns.
  Rationale: Meibo owns principals, En owns relationships, and task/space authorization is
  graph-derived. A generic space keeps storage isolation stable as the relationship graph grows.
  Date: 2026-08-06

- Decision: Kioku records authorization context but does not own or infer authorization.
  Rationale: Embedded callers and future HTTP callers have different authentication surfaces;
  both can supply one validated context while Shomei, Meibo, and En retain their boundaries.
  Date: 2026-08-06

- Decision: Legacy data is backfilled into one explicit legacy memory space and never treated
  as globally visible across newly created spaces.
  Rationale: This preserves old behavior for upgraded single-space deployments without making
  absence of a partition mean unrestricted access.
  Date: 2026-08-06

- Decision: Kioku stays independently usable, and no child plan in this initiative may add a
  dependency on an identity service. The dependency set remains Baikai, the
  Keiro/Keiki/Kiroku/Shibuya cohort, Shikumi, and ordinary Hackage libraries; identity is consumed
  through function records (`PrincipalDirectory`, `PermissionChecker`), and any Meibo/Shomei/En
  mapping lives in a separate adapter package that depends on Kioku.
  Rationale: A memory library that pulls one authentication service in behind it is unusable by
  anyone who already has a different one. Recorded durably as
  [ADR-1](../adr/kioku-owns-memory-not-identity.md).
  Date: 2026-08-06 (user directive during EP-1 implementation)

- Decision: Where a plan cannot ship a correct change without work assigned to a later plan, it
  takes that work and the MasterPlan records the obligation as moved, naming the reason.
  Rationale: EP-2 needed the L1 timer payload's space (distillation writes memories) and EP-3
  needed the scene and persona timer ids (they are keyed by a scope two spaces may share). Leaving
  either would have shipped a known defect to keep a boundary tidy. Recording the move in
  Integration Points is what let EP-4 start from what was actually left.
  Date: 2026-08-06

- Decision: The memory space appears on traces and in dead-letter diagnostics, and on no metric
  label, ever.
  Rationale: A space id is caller-supplied text with no bound on its cardinality, so an instrument
  keyed on it is an unbounded time series per tenant and an identity leak into a metrics backend.
  Traces are sampled and per-incident. Recorded durably as
  [ADR-7](../adr/the-partition-reaches-the-filesystem-as-a-digest.md).
  Date: 2026-08-06


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

Planning completed on 2026-08-06. Four child plans define the contract, propagate it through
the event domain, migrate storage, and close worker/artifact paths.

**Complete, 2026-08-06.** All four child plans landed the same day. Every Kioku command, query,
timer, subscription, and plaintext artifact now names exactly one memory space, and every write
names the principal responsible for it.

Measured against the Vision & Scope: the library contracts, event and API propagation, schema
migration, and partition-safe background work are all done. The exclusions held — Kioku owns no
credentials, no directory, no membership, and no policy, and it took no build dependency on any
identity service. The HTTP service remains out of scope and unbuilt.

**Where the boundary is enforced, in one list, because it is in four places on purpose.**

- The *aggregate* refuses a command naming another space, so the write side holds without any
  schema ([ADR-4](../adr/the-aggregate-enforces-the-partition.md)).
- Every *statement* names `memory_space_id`, unconditionally, even where the key is globally
  unique ([ADR-6](../adr/the-partition-is-a-column-not-a-schema.md)).
- Every *durable work identity* — timer id, correlation id, payload, subscription envelope —
  carries the space, so a retry cannot cross it.
- Every *artifact path* is rooted at a digest of the space, because an id validated for a column
  is not validated for a path ([ADR-7](../adr/the-partition-reaches-the-filesystem-as-a-digest.md)).

**What the decomposition got right.** Pinning the contracts before the schema (EP-1 before EP-3)
is what kept a private identity vocabulary out of the columns; the object type and permission
names are still host-supplied, which is exactly the state Kikan-En IR-1 leaves them in. Splitting
event compatibility (EP-2) from database backfill (EP-3) let the codec fixtures and the migration
be reviewed against different questions.

**What it got wrong, and it is worth writing down.** Work migrated *earlier* than planned twice,
both times because a plan could not ship a correct change without it: EP-2 took the L1 timer
payload, EP-3 took the scene and persona timer ids. EP-4 was left holding the embedding
subscription, the artifact layout, and diagnostics — still a real plan, but not the one that was
scoped. "The worker plan owns every worker path" is not a boundary that survives contact with a
plan that must make its own change correct. The mitigation that worked was cheap: each migration
was recorded in the MasterPlan's Integration Points as an obligation *moved*, with the reason, so
EP-4 started from what was actually left rather than from what had been written down.

**Verification.** `cabal test all` — 322 cases across `kioku-api`, `kioku-cli`, `kioku-core`, and
`kioku-migrations`, including two-space fixtures at every layer: the aggregate
(`Kioku.MemorySpaceSpec`), the read models and their query plans (`Kioku.SpaceIsolationSpec`), the
schema constraints (`Kioku.SchemaSpec`), the workers (`Kioku.TimerWorkerSpec`,
`Kioku.EmbeddingWorkerSpec`), the filesystem (`Kioku.WorkspaceSpec`), and one end-to-end worker
run over two spaces sharing a namespace and a scope (`Kioku.DistillSpec`).

**Distilled into `docs/adr/`.** ADR-1 (Kioku owns memory, not identity), ADR-2 (a namespace is not
a security boundary), ADR-3 (legacy data lands in one explicit space), ADR-4 (the aggregate
enforces the partition), ADR-5 (historical attribution is marked, never invented), ADR-6 (the
partition is a column and a predicate), ADR-7 (the partition reaches the filesystem as a digest,
and never a metric label). What stayed in the plans is task-local: which call sites changed, which
fixtures were added, and the order the milestones ran in.

**What is deliberately not done.** Recall targets are still a `MemoryScope`, so "the exact global
bucket" and "every scope in this namespace" remain one value with two meanings — unchanged by the
partition and owned by
`docs/masterplans/6-explicit-and-safe-recall-boundaries.md`. Kikan-En IR-1 is still `proposed`, so
the En object type and permission names stay host-supplied rather than defaulted. A killed worker
process mid-fire is covered by redelivery rather than by an actual restart, and two concurrent
worker processes are left to keiro's own claim semantics, which this initiative preserved and did
not re-test.


### What is left, reviewed 2026-08-07


The paragraph above is the state at closing and is kept as written. This is what survives it, one
day later, sorted by who can act on it.

**Discharged since closing: the recall handoff.** The first exclusion is gone.
`docs/masterplans/6-explicit-and-safe-recall-boundaries.md` completed on 2026-08-07 across all
three of its child plans, and the two meanings now have two names, two statements, and two proven
row sets. Nothing in that work reopened the partition; it consumed it. What remains on that side is
a release action rather than engineering — the legacy `MemoryScope` wrapper's deprecation window
has not opened, because no released version yet carries `RecallTarget`, and its removal is gated on
the three conditions in
[ADR-8](../adr/an-explicit-recall-target-replaces-the-overloaded-scope.md), one of which is met.
That clock belongs to MasterPlan 6, not here.

**Open, and blocked outside this repository: the En binding and the adapter.** Kikan-En IR-1 is
still `status: proposed` and its live `Kikan.En.Schema` still declares no `space` object and no
`person` or `team` subject type (re-verified 2026-08-07). The En object type and permission names
therefore remain a required host input, and `mkMemoryAuthorizationBinding` still refuses a partial
one. Neither Meibo, Shomei, En, nor Kikan-En has a release tag (all four checkouts still have empty
`git tag` output), so the adapter package that would map `PrincipalDirectory` and
`PermissionChecker` onto them is still unwritten — deliberately, per
[ADR-1](../adr/kioku-owns-memory-not-identity.md), which is why waiting costs Kioku nothing. When
the owner ships, the change here is a default binding and one fixture; no type in `kioku-api` or
`kioku-core` moves. There is no work to schedule until then, only a trigger to watch.

**Open, and accepted: the two worker gaps.** A genuinely killed process mid-fire is still simulated
by redelivery rather than by a kill, and concurrency between two worker processes is still left to
keiro's claim semantics. Both stay open on purpose: neither is a partition question. The partition
invariant is proven per fire, per claim, and per artifact path; what is untested is the
at-least-once contract underneath it, which this initiative inherited and preserved rather than
introduced. Whoever tests it is testing keiro, and should say so.

**Open, and operational: the artifact migration.** An upgraded deployment's scene and persona
mirrors stay at their pre-partition `.kioku/scenes` and `.kioku/persona` paths until an operator
runs `kioku migrate-artifacts`, and the historical tree goes stale in the interval. That is the
cost [ADR-7](../adr/the-partition-reaches-the-filesystem-as-a-digest.md) records, not an oversight,
but it is the one remaining item that a person outside this repository has to actually do.

**Downstream, now unblocked: IR-4 and IR-5.**
`docs/improvement-requests/add-an-authenticated-http-service.md` names exactly two dependencies —
partitioned memory spaces and explicit recall targets — and refuses to ship "an unpartitioned
endpoint or private identity/ACL model". Both dependencies are now satisfied, by this MasterPlan
and by MasterPlan 6 respectively, so IR-4 is blocked on nothing but a decision to plan it; it
remains `proposed`. `docs/improvement-requests/publish-typescript-and-python-sdks.md` (IR-5) waits
on IR-4's OpenAPI contract. Any such service is the fifth surface the space and the target must be
named on, and it inherits every rule in ADR-4 through ADR-8 rather than re-deciding them.


## Revision Notes

**2026-08-07 — remaining-work review.** This MasterPlan closed on 2026-08-06 with four exclusions
stated in one paragraph. One of them has since been discharged and the other three have not, so
Outcomes & Retrospective gains a dated **What is left** subsection that sorts what survives by who
can act on it: a release action owned by MasterPlan 6, an external trigger to watch, two accepted
gaps that belong to keiro's at-least-once contract rather than to the partition, one operator
action, and two now-unblocked downstream improvement requests. The closing paragraph is kept
verbatim above it, because it is the accurate record of what was true at closing and the point of
the review is the delta.

Integration Points' **Recall** entry moves from an expectation to a result: MasterPlan 6 completed
on 2026-08-07 and its statements place `memory_space_id` ahead of every scope condition, so the
constraint that recall never widen across spaces is discharged rather than pending. Surprises &
Discoveries gains the corresponding cross-plan observation — the partition contract went through a
full consumer initiative without a type moving or an ADR being superseded.

The decomposition is unchanged: no child plan was split, merged, reordered, or cancelled, and the
Exec-Plan Registry and Progress sections are already final. No child ExecPlan was cascaded, because
each one's "what is not done" note is a point-in-time record of what was true when it shipped, and
rewriting those would destroy the record this review depends on. No ADR changed: the recall closure
is recorded in [ADR-8](../adr/an-explicit-recall-target-replaces-the-overloaded-scope.md) by
MasterPlan 6, and nothing here superseded ADR-1 through ADR-7.

Verified rather than assumed while writing this: Kikan-En IR-1 is still `status: proposed`;
`Kikan.En.Schema` still has no `space` object or `person`/`team` subject; Meibo, Shomei, En, and
Kikan-En all still have empty `git tag` output; `mkMemoryAuthorizationBinding`,
`PrincipalDirectory`, `PermissionChecker`, `RecallTarget`, and `kioku migrate-artifacts` all still
exist under the names used above.
