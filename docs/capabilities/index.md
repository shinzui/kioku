---
okf_version: "0.2"
---

# kioku capabilities

What the **kioku** agent-memory library provides to a consumer today: what a host can
depend on, adopt, and verify against evidence it can open. Each record is one
capability — one thing a consumer adopts *and* verifies independently — backed by at
least one artifact (a test, a worked example, a guide, or a module) that a reader can
open. There is no roadmap here: a capability that does not yet exist is an improvement
request, not a record.

kioku is a Haskell library plus two executables, embedded by a host application over a
Postgres database it shares with the host's kiroku event store. It is pre-1.0 and under
active development: every capability below is **experimental** in its compatibility
promise, which reflects the project's single uniform stability policy rather than a
missing distinction.

## What kioku provides

| Capability | Handle | Since | Provides |
|---|---|---|---|
| [Event-sourced memory records with honest idempotency](event-sourced-memory-records.md) | CAP-1 | 0.1.0.0 | Durable facts, patterns, preferences, constraints, instructions; aggregate-enforced conflicts |
| [Event-sourced agent sessions, turns, and park-and-resume](event-sourced-agent-sessions.md) | CAP-2 | 0.1.0.0 | Ordered turns, continuation and delegation lineage, correlated resume |
| [Host-agnostic memory scopes and collision-free scope identity](host-agnostic-memory-scopes.md) | CAP-3 | 0.1.0.0 | namespace / kind / ref partitioning, digest-backed derived identities |
| [Memory-space isolation on a host-supplied access decision](memory-space-isolation.md) | CAP-4 | 0.4.0.0 | The tenancy boundary, carried as a context Kioku never mints itself |
| [Hybrid recall with explicit targets and RRF ranking](hybrid-recall-with-explicit-targets.md) | CAP-5 | 0.1.0.0 | FTS + pgvector fused by RRF, re-ranked and budget-trimmed |
| [Starvation-resistant vector recall with channel diagnostics](starvation-resistant-vector-recall.md) | CAP-6 | 0.1.0.0 | An exact second pass when filtered ANN starves, and a per-call outcome |
| [Embedding worker, per-space backfill, and graceful vector degradation](embedding-worker-and-degradation.md) | CAP-7 | 0.1.0.0 | Vector production, tenant-bounded backfill, four-way capability detection |
| [L1 distillation: extraction, audited consolidation, and watermarks](l1-atom-distillation.md) | CAP-8 | 0.1.0.0 | Turns into atoms, with an audit row per applied decision |
| [L2 scenes and L3 personas with content-hashed regeneration](scenes-and-personas.md) | CAP-9 | 0.1.0.0 | Readable per-scope summaries that skip the model call when unchanged |
| [Timer-driven distillation with a typed fire-outcome taxonomy](distillation-timers.md) | CAP-10 | 0.1.0.0 | Ramp / final / idle scheduling, bounded retries, diagnostic dead letters |
| [Workspace mirroring of scenes and personas](workspace-artifact-mirroring.md) | CAP-11 | 0.1.0.0 | Per-space markdown a coding agent reads without a database |
| [Typed memory and session event streams with compatible decoding](typed-event-streams-and-codecs.md) | CAP-12 | 0.1.0.0 | Payloads that still decode across every schema change shipped |
| [Embedded, checksummed migration component and composed plan](embedded-migration-component.md) | CAP-13 | 0.1.0.0 | The `kioku` schema as one pg-migrate component a host composes |
| [Read-model registry reconciliation](read-model-registry-reconciliation.md) | CAP-14 | 0.1.0.0 | The repair that keeps a version bump from taking every query down |
| [Operational CLI for recall, distillation, and workers](operational-cli.md) | CAP-15 | 0.1.0.0 | `kioku` and `kioku-migrate`, with permanent writes opted into |
| [Ephemeral-Postgres test support for the migrated schema](migration-test-support.md) | CAP-16 | 0.1.0.0 | A published sublibrary giving tests the real schema, or none of it |
| [Host-owned AI execution with an explicit, versioned capability grant](host-owned-ai-execution.md) | CAP-17 | unreleased | Disabled by default; API, batch, interactive, and embedding granted separately |
| [Deferred interactive work: parking and leased foreground resume](deferred-interactive-recovery.md) | CAP-18 | unreleased | Park rather than fall back, then resume under a Keiro 0.16 lease |
| [One-time Codd migration-history import](codd-history-import.md) | CAP-19 | 0.1.0.0 | **Deprecated.** The zero-replay cutover onto CAP-13 |

## What is not here

- **Authentication, a principal directory, or an authorization engine.** Kioku carries a
  decision a host already made and its build closure contains none of those services.
  See [CAP-4](memory-space-isolation.md) and `docs/user/integrations.md`.
- **An event store.** Kioku appends to the host's kiroku streams and creates no second
  store; it owns the `kioku` schema and nothing else.
- **An authenticated HTTP service, published TypeScript or Python SDKs, or versioned
  learned skills.** Those are improvement requests in `docs/improvement-requests`, not
  capabilities.

## Packages

| Package | Carries |
|---|---|
| `kioku-api` | CAP-1, CAP-2, CAP-3, CAP-4, CAP-5 (pure types, scopes, ids, access) |
| `kioku-core` | CAP-1, CAP-2, CAP-3, CAP-4, CAP-5, CAP-6, CAP-7, CAP-8, CAP-9, CAP-10, CAP-11, CAP-12, CAP-14, CAP-17, CAP-18 |
| `kioku-cli` | CAP-11, CAP-15, CAP-18 |
| `kioku-migrations` | CAP-13, CAP-16, CAP-19 |
| `kioku-migrate` | CAP-13, CAP-14, CAP-19 |
