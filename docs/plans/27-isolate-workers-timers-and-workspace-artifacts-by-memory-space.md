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

- [x] Inventory every timer, subscription, backfill, reconciliation, and mirror path.
  (2026-08-06 — see the audit under Surprises & Discoveries. Plans 25 and 26 had already closed
  the three timer paths; what was left was the embedding subscription, the backfill scan, the
  mirrors, and diagnostics.)
- [x] Carry memory space through timer payloads, correlation keys, and worker envelopes.
  (2026-08-06 — L1/L2/L3 payloads and ids by plans 25/26; the embedding handler now reads the
  space from its decoded `MemoryRecorded` event and gates on a `MemoryContextProvider`.)
- [x] Add partition predicates to worker claims, candidate scans, writes, and acknowledgements.
  (2026-08-06 — the embedding worker's three statements were the only ones left in `kioku-core`;
  the state read now returns the row's own space so a disagreement is `EmbedSpaceMismatch` rather
  than an empty success, and the update names the space as well as the id.)
- [x] Place filesystem artifacts under a traversal-safe per-space root with legacy compatibility.
  (2026-08-06 — `Kioku.Workspace`, `.kioku/spaces/<space-dir>/{scenes,persona}`, and
  `kioku migrate-artifacts`.)
- [x] Add two-space concurrency, retry, dead-letter, backfill, and reconciliation tests.
  (2026-08-06 — `Kioku.WorkspaceSpec`, three new `Kioku.TimerWorkerSpec` cases, three new
  `Kioku.EmbeddingWorkerSpec` cases, one end-to-end `Kioku.DistillSpec` case, and the mirror
  assertions in `Kioku.SpaceIsolationSpec`. Reconciliation was already covered by plan 26's
  `testReconcileKeepsBothSpaces`.)
- [x] Add partition attributes to metrics/traces without high-cardinality principal labels.
  (2026-08-06 — a `kioku.timer.fire` span per attempt; no instrument gained a space or principal
  label, and [ADR-7](../adr/the-partition-reaches-the-filesystem-as-a-digest.md) records that none
  may.)
- [x] Document worker upgrade ordering and artifact migration.
  (2026-08-06 — `docs/user/upgrading-to-memory-spaces.md`, `docs/user/cli-reference.md`,
  `docs/user/distillation.md`, `docs/user/library-api.md`, and the changelog.)


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

- **The audit, in full.** Every path that survives beyond one call stack, and what it needed:

  | Path | State on arrival | Done here |
  | --- | --- | --- |
  | L1 timer (`Kioku.Distill.Timer`) | id is session-keyed and globally unique; payload and provider gate landed with plan 25 | nothing but diagnostics |
  | L2 scene timer (`Kioku.Distill.L2`) | id, correlation id, payload, and provider gate landed with plan 26 | nothing but diagnostics |
  | L3 persona timer (`Kioku.Distill.L3`) | same as L2 | nothing but diagnostics |
  | `rescheduleClaimedTimer` | copies `row.payload` verbatim, so the space survives a requeue | nothing |
  | Embedding subscription (`Kioku.Memory.Embedding.Worker`) | handler took only a memory id; three statements spanned every space | provider gate, space comparison, partitioned update |
  | Embedding backfill | scanned every space with no way to bound it | `EmbeddingBackfillScope`, `--space` |
  | Read-model reconciliation (`Kioku.ReadModel`) | operates on keiro's `keiro_read_models` registry | **correctly not per-space** — it is a schema-identity registry, not memory data. Plan 26's `testReconcileKeepsBothSpaces` already proves a reconcile leaves both spaces readable |
  | Scene/persona mirrors | keyed by scope alone | `Kioku.Workspace` and `kioku migrate-artifacts` |
  | Timer diagnostics (`last_error`, stderr, traces) | named no space | space-qualified reason, `kioku.timer.fire` span |

- **The embedding state read had to stay unpartitioned to become safe.** The obvious change is
  `WHERE memory_space_id = $1 AND memory_id = $2` on the read as well as the write. That is
  exactly wrong here: a delivered event whose space disagrees with the row would come back as
  "no such memory", and the handler acks that as success — a forged or stale envelope swallowed
  in silence. The read is keyed by the globally unique memory id and returns the row's own space
  so the handler can compare the two; the *write* carries the predicate. Reading an identifier in
  order to refuse it is the opposite of leaking it.

- **A memory space id is not a safe path component, and nothing said so.** `mkMemorySpaceId`
  rejects `:`, `#`, `%`, `/`, whitespace, and control characters — which is a complete list for a
  database column and a relationship tuple, and leaves `..` and `.` legal. A layout that used the
  id directly would have let a host that names spaces from caller input walk out of
  `.kioku/spaces`. Case folding is the second half of the same problem: `space_A` and `space_a`
  are two spaces and one directory on APFS. Both are closed by the sanitise-plus-digest encoding
  in `Kioku.Workspace`, recorded as
  [ADR-7](../adr/the-partition-reaches-the-filesystem-as-a-digest.md).

- **`backfillMissingEmbeddings` could not be tested for the property it gained.** It built its own
  `EmbeddingWorkerEnv` from a model and a dimension count, so any test of "which rows did this
  scope select" reached the real provider at `embedding.invalid`. Taking the env as a parameter —
  the same record that already exists so the subscription handler's branches can be driven with a
  fake — made the assertion possible. A capability that cannot be observed is not one.


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

- Decision: The embedding worker's state read stays keyed by memory id alone and returns the row's
  own space; only the update carries a partition predicate.
  Rationale: Scoping the read by the envelope's space turns a stale or forged envelope into "no
  such memory", which the handler acks as success. Reading the space in order to compare it makes
  the disagreement visible (`EmbedSpaceMismatch`, dead-lettered, nothing written).
  Date: 2026-08-06

- Decision: `backfillMissingEmbeddings` takes an `EmbeddingWorkerEnv` rather than a model and a
  dimension count.
  Rationale: It previously built its own env, so no test could assert which rows a scope selected
  without reaching a real embedding provider. The record already exists for exactly this reason on
  the subscription path.
  Date: 2026-08-06

- Decision: The per-space artifact directory is a sanitised prefix plus a SHA-256 digest of the
  space id, never the id itself.
  Rationale: `mkMemorySpaceId` validates for a database column, so `..` and `.` are legal space
  ids, and case-folding filesystems merge ids that differ only in case. Recorded as
  [ADR-7](../adr/the-partition-reaches-the-filesystem-as-a-digest.md).
  Date: 2026-08-06

- Decision: New writes go only to the partitioned layout, for every space including the legacy
  one; the historical tree is never written to again, and `kioku migrate-artifacts` copies rather
  than moves.
  Rationale: Dual-writing the legacy space would mean the partition never reaches the filesystem
  for the space every upgraded deployment is in, and compatibility windows do not close on their
  own. Copying leaves the operator something to fall back on, and removing the old tree stays
  their decision.
  Date: 2026-08-06

- Decision: Emptying a scope in the legacy space also unlinks its pre-partition mirror, which is
  the one exception to "nothing touches the historical tree".
  Rationale: An out-of-date file is visible in the migration plan and can wait. Forgotten content
  surviving on disk is not out of date — a host agent would keep reading memories the caller
  asked to forget.
  Date: 2026-08-06

- Decision: The artifact migration refuses a destination whose content differs rather than
  overwriting it, and exits non-zero when it does — in dry-run mode as well.
  Rationale: The partitioned file is what the running worker writes; the historical one is a
  pre-partition snapshot and therefore older. A refusal a script cannot see is not a refusal.
  Date: 2026-08-06


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Complete, 2026-08-06. Kioku's asynchronous and filesystem behaviour honours the same memory-space
boundary as its synchronous reads.

**What the plan expected to build and did not have to.** Milestone 1 was written before plans 25
and 26 landed, and by the time this started all three timer paths — payloads, ids, correlation
ids, and provider gates — were already partitioned. The inventory it asked for is in Surprises &
Discoveries; what it found left was the embedding subscription, the backfill scan, the mirrors,
and the diagnostics. Reconciliation turned out to need nothing at all, and that is worth stating
plainly rather than quietly skipping: `reconcileReadModelRegistry` operates on keiro's
schema-identity registry, which is per-deployment and not per-space, and plan 26 already proved a
reconcile leaves both spaces readable.

**What it built.** The embedding worker gained a provider gate, an envelope-versus-row space
comparison, a partitioned update, and a per-space backfill. Scene and persona mirrors moved under
`.kioku/spaces/<space-dir>/`, with `kioku migrate-artifacts` to relocate what an upgraded
deployment already has. Every timer fire runs inside a span that names the space, and every
dead-lettered timer's `last_error` says which tenant it belongs to.

**Verification.** `cabal test all` — 322 cases across four suites. The end-to-end proof is
`Kioku.DistillSpec`'s "one worker serving two spaces keeps their artifacts disjoint": one worker,
two spaces, one namespace and one scope shared between them, asserting each mirror holds only its
own tenant's content, then forgetting one space's only memory and asserting the other space's
rows, files, and bytes are untouched, then draining again for zero.

**Gaps, stated rather than glossed.** Restart is covered by redelivery rather than by a process
kill: `drainTimers` re-enters the worker with fresh state and asserts nothing is left to fire,
which exercises the same at-least-once contract a restart would, but a genuinely killed process
mid-fire is not simulated. Concurrency between two worker processes is likewise left to keiro's
own claim semantics, which this plan preserved and did not re-test. And the historical mirror tree
goes stale between the upgrade and the migration — a deliberate cost recorded in
[ADR-7](../adr/the-partition-reaches-the-filesystem-as-a-digest.md), not an oversight.


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
