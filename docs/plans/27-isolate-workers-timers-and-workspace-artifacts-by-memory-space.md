---
id: 27
slug: isolate-workers-timers-and-workspace-artifacts-by-memory-space
title: "Isolate workers timers and workspace artifacts by memory space"
kind: exec-plan
created_at: 2026-08-06T14:43:35Z
intention: "intention_01kzbregvqe9rtnrttk4f07pjv"
master_plan: "docs/masterplans/5-portfolio-compatible-memory-isolation-and-authorization.md"
---

# Isolate workers timers and workspace artifacts by memory space

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, Kioku's asynchronous and filesystem behavior honors the same memory-space
boundary as synchronous reads. Timer correlation, subscription handling, embedding backfill,
distillation, reconciliation, and scene/persona mirrors cannot claim work in one space and read,
write, acknowledge, or overwrite artifacts in another. A two-space end-to-end test proves the
boundary across retries and worker restarts.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Inventory every timer, subscription, backfill, reconciliation, and mirror path.
- [ ] Carry memory space through timer payloads, correlation keys, and worker envelopes.
- [ ] Add partition predicates to worker claims, candidate scans, writes, and acknowledgements.
- [ ] Place filesystem artifacts under a traversal-safe per-space root with legacy compatibility.
- [ ] Add two-space concurrency, retry, dead-letter, backfill, and reconciliation tests.
- [ ] Add partition attributes to metrics/traces without high-cardinality principal labels.
- [ ] Document worker upgrade ordering and artifact migration.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The current plaintext mirrors are rooted at `.kioku/scenes` and `.kioku/persona`. Identical
  scope keys from two spaces would target the same filenames even after database isolation.
- At-least-once workers make context loss more dangerous than a one-shot query bug: a retry may
  repeatedly mutate or acknowledge the wrong space unless the partition is in the durable work
  identity.

- **Timer identity is already partitioned; plan 26 did it.** Plan 26 created the situation where
  two spaces can hold the same namespace and scope, and the scene and persona timers are keyed by
  a scope — so leaving their ids alone would have shipped a schedule where keiro's
  `scheduleTimerTx` upsert treats one space's regeneration as a re-arming of the other's and
  silently drops one payload. `l2SceneTimerId`, `l3PersonaTimerId`, and both correlation ids now
  carry the space, both timer payloads carry it, and `fireL2SceneTimer` / `fireL3PersonaTimer`
  take a `MemoryContextProvider` and dead-letter on refusal, matching `fireL1Timer`. Timers
  scheduled before that keep their old ids and fire in the legacy space. What remains for this
  plan is worker claims, dead-letter handling, backfill scans, reconciliation, metrics attributes,
  and the filesystem layout.


## Decision Log

Record every decision made while working on the plan.

- Decision: Memory space is part of every durable asynchronous work identity, not recovered from
  a namespace at execution time.
  Rationale: Namespace is reusable across spaces and lookup-based recovery can cross the boundary.
  Date: 2026-08-06

- Decision: Filesystem roots use a stable encoded/digested space component and never raw caller
  text as a path.
  Rationale: Space IDs are external identifiers; path traversal and collisions must be impossible.
  Date: 2026-08-06

- Decision: Metrics include bounded result/reason labels and traces include the space ID, but
  metric labels do not include principal or arbitrary space values.
  Rationale: Traces need incident correlation while metrics must avoid unbounded cardinality and
  identity leakage.
  Date: 2026-08-06


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

No implementation has started. Completion means an end-to-end two-space worker test passes under
normal delivery, redelivery, and restart.


## Context and Orientation

Embedding work is in `kioku-core/src/Kioku/Memory/Embedding/Worker.hs`. L1 scheduling/firing is
in `Kioku.Distill.Timer` and `Kioku.Distill.Timer.Worker`; L1/L2/L3 data paths are in
`Kioku.Distill.L1`, `L2`, and `L3`. Read-model reconciliation is in `Kioku.ReadModel` and the
migrate executable. `DistillRuntime.workspaceRoot` controls plaintext scene/persona output.

Worker behavior is at-least-once and already has bounded retry/dead-letter rules from
`docs/plans/11-harden-worker-resilience-with-ack-policy-bounded-retries-and-loop-supervision.md`.
This plan preserves those semantics and adds a partition invariant. Plans 25 and 26 supply the
durable context and schema. No additional ADR is expected unless the artifact layout changes
beyond the contract recorded by plan 24.


## Plan of Work

### Milestone 1: asynchronous context audit and propagation

Create a checklist of every payload and correlation key that survives beyond one call stack.
Add `memorySpaceId` to timer payloads, embedding envelopes, distillation work descriptions, and
reconciliation selectors. Version decoders so historical work maps only to the legacy space.
Include space in debounce/correlation keys, otherwise identical namespaces in two spaces will
suppress each other's timers.

At each handler, validate the envelope space against the loaded entity before mutation. A
mismatch is fatal and visible, not retryable and not an empty success.

### Milestone 2: partition all worker data access

Update candidate scans, embedding state reads/writes, L1 fallback memory reads, L2/L3 source
queries, timer claim/apply paths, and reconciliation selection to take space explicitly. Audit
raw SQL in tests and CLI commands as well as public read-model helpers. Preserve bounded retries
and ensure dead-letter diagnostics carry the space in structured trace attributes.

### Milestone 3: isolate and migrate workspace artifacts

Introduce a helper such as `spaceArtifactRoot :: FilePath -> MemorySpaceId -> FilePath` that
uses a stable safe encoding or digest. New artifacts live under
`.kioku/spaces/<encoded-space>/scenes` and `.kioku/spaces/<encoded-space>/persona`. The legacy
space may read the historical root during one compatibility window, but new writes go to the
partitioned layout. Provide a dry-run migration command that reports moves and collisions before
changing files.

### Milestone 4: end-to-end proof and observability

Run two workers against fixtures with the same namespace/scope and different spaces. Exercise
timer debounce, redelivery, transient failure, dead-letter, embedding backfill, scene/persona
regeneration, reconciliation, and restart. Assert database rows and filesystem outputs remain
disjoint. Add trace attributes for memory space and bounded outcome/reason metrics.


## Concrete Steps

Run from the repository root:

```bash
nix develop -c cabal test kioku-core --test-options='-p "worker|timer|embedding|memory space"'
nix develop -c cabal test kioku-core --test-options='-p "Distillation pyramid"'
nix develop -c cabal test kioku-migrations
nix develop -c cabal test all
```

Run the artifact migration in dry-run mode before applying it to a real workspace. The command
name is finalized during implementation and must print source, destination, and collision status
without writing.


## Validation and Acceptance

Acceptance requires:

- Two spaces with identical namespace/scope schedule distinct timers and both fire.
- A forged or stale envelope whose space disagrees with the loaded entity is rejected visibly
  and never mutates or acknowledges another space's work.
- Embedding backfill, L1 fallback, L2, L3, and reconciliation return/write rows only in the
  envelope space.
- Scene/persona files for identical scope keys have different safe roots; an ID containing path
  separators cannot escape `.kioku/spaces`.
- Redelivery and restart preserve isolation and existing bounded retry/dead-letter behavior.
- Metrics have no arbitrary principal/space label; traces contain enough space context to audit
  an incident.


## Idempotence and Recovery

Message/timer codec changes must decode old work into the legacy space. Worker rollout follows
schema and writer rollout: migrate database, deploy dual-reading/new-writing code, drain or
convert old work, then enable multiple spaces. The artifact migration is idempotent and refuses
collisions unless file content hashes match. It supports dry-run and leaves historical files in
place until verification succeeds; no recursive deletion belongs in this plan.


## Interfaces and Dependencies

All worker environment/query records gain `memorySpaceId :: MemorySpaceId`. The shared artifact
helper is equivalent to:

```haskell
spaceArtifactRoot :: FilePath -> MemorySpaceId -> FilePath
```

Use the existing `mori://shinzui/keiro/packages/keiro` timer APIs and
`mori://shinzui/shibuya/packages/shibuya-core` plus
`mori://shinzui/kiroku/packages/kiroku-store` subscription APIs; do not add a second queue. The
plan depends on domain/API work in plan 25 and schema work in plan 26. It integrates with the
current tracing/metrics surface in `Kioku.App` and preserves plan 11's error taxonomy.
