# Changelog

## 0.1.0.0 — 2026-07-14

### Added

- **kioku-api:** Introduced host-agnostic memory scopes, TypeID-backed memory and session
  identifiers, shared memory wire types, and a common prelude.
- **kioku-core:** Added event-sourced memory and session aggregates with delegation, awaiting and
  resume state, scoped reads, idempotent commands, and durable read models.
- **kioku-core:** Added hybrid full-text and pgvector recall, embedding workers, and L1 memory, L2
  scene, and L3 persona distillation with timer-driven processing.
- **kioku-cli:** Added commands for demonstrations, recall, distillation, scenes, personas, memory
  backfills, timers, and continuously supervised workers.
- **kioku-migrations:** Added the manifest-ordered Kioku migration component, Codd-history import,
  schema repair and hardening migrations, and ephemeral PostgreSQL test support.
- **kioku-migrate:** Added the migration administration executable, including planning, applying,
  verifying, repairing, Codd-history import, and read-model registry reconciliation.

### Fixed

- Prevented filtered approximate-nearest-neighbor searches from starving the vector recall channel
  and ordered vector candidates by distance alone.
- Made distillation identities deterministic and collision-safe, validated LLM outputs, propagated
  forgotten memories, and regenerated scenes when memory confidence changes.
- Enforced session lineage and resume invariants, cycle-safe traversal, and honest idempotency
  conflicts for session and memory writes.
- Hardened migration discovery, embedding schema repair, read-model registration, and migration
  manifest freshness checks.

### Changed

- Adopted Keiki 0.2, Keiro 0.3, Kiroku Store 0.3, PGMQ 0.4, and pg-migrate 1.1 from Hackage.
- Demo commands now require explicit `--yes-write-events` consent and write only to the isolated
  `kioku_demo` scope.
- Operator-supplied identifiers use strict prefix validation; explicitly named lenient parsing is
  retained only for legacy events, LLM responses, and timer correlations.
