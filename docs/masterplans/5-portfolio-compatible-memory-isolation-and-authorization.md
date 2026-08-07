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
| EP-4 | Isolate workers timers and workspace artifacts by memory space | docs/plans/27-isolate-workers-timers-and-workspace-artifacts-by-memory-space.md | EP-2, EP-3 | None | Not Started |

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
  share. EP-4 still owns worker claims, dead-letter handling, metrics attributes, and the
  `.kioku/scenes` and `.kioku/persona` filesystem layout, which remains keyed by scope alone.
- **Recall:** `docs/masterplans/6-explicit-and-safe-recall-boundaries.md` consumes the completed
  partition contract; recall must never be namespace-wide across memory spaces.


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
- [ ] EP-3: migrate and backfill every Kioku read model with composite partition indexes.
- [ ] EP-3: prove cross-space uniqueness and read isolation in real PostgreSQL.
- [ ] EP-4: partition timers, subscribers, reconciliation, and workspace mirrors end to end.


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

Planning completed on 2026-08-06. Four child plans define the contract, propagate it through
the event domain, migrate storage, and close worker/artifact paths.

EP-1 and EP-2 are complete as of 2026-08-06. Writes are partitioned end to end and every stored
event names its space and its actor; the boundary is enforced by the aggregates themselves, so it
holds without any schema change. Reads are not partitioned yet and deliberately do not pretend to
be — that is EP-3's column and predicate. The remaining exposure is therefore read-side and
worker-side, which is exactly the shape the decomposition predicted.
