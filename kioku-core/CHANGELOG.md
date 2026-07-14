# Changelog

## 0.1.0.0 — 2026-07-14

### Added

- Added event-sourced memory commands, read models, merge and forget behavior, full-detail reads,
  and scoped active-memory lookup.
- Added event-sourced sessions with turns, delegation lineage, awaiting/resume state, scoped reads,
  and aggregate-enforced identity and correlation invariants.
- Added hybrid full-text and pgvector recall using Reciprocal Rank Fusion, vector capability and
  dimension checks, direct memory lookup, and continuous or one-shot embedding workers.
- Added L1 memory extraction and consolidation, L2 scene regeneration, and L3 persona distillation
  through Shikumi programs, durable timers, and worker dispatch.
- Added code-driven read-model registration and reconciliation plus compatibility decoding for
  legacy Rei events.

### Fixed

- Prevented selective scopes from starving the approximate-nearest-neighbor recall channel and
  ordered vector candidates by distance before fusion.
- Made atom and scope identities deterministic and collision-safe, surfaced extraction and
  consolidation failures, and validated LLM outputs before accepting them.
- Propagated memory forget and confidence changes through scene and persona artifacts.
- Made session lineage validation cycle-safe and returned conflicts for non-idempotent command
  replays instead of reporting false success.
- Classified embedding failures into retry, dead-letter, and halt outcomes and wired recall-based
  merge candidates into timer processing.

### Changed

- Updated the application environment for Keiro 0.3 and Kiroku Store 0.3: it now carries connection
  settings, acquires a `KirokuStoreResource`, and explicitly registers read models at startup.
- Removed the unused `embedBatched` API, whose implementation did not perform batched requests.
