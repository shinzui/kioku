# Changelog

## 0.2.0.0 — 2026-07-30

### Breaking Changes

- Moved onto the Keiki 0.4 and Keiro 0.4 cohort: `keiki ^>=0.4.0.0`, `keiro ^>=0.4.0.1`, and
  `keiro-core ^>=0.4.0.1`. Kioku no longer builds against Keiki 0.2 or Keiro 0.3, and there is
  no version of `kioku-core` that spans both.
- Keiro 0.4 tightens validated event-stream assembly: `mkEventStreamOrThrow` now rejects a codec
  whose schema version, event tags, or upcaster chain fail `mkCodec`, and it does so at
  evaluation time. Kioku's `memoryEventStream` and `sessionEventStream` both satisfy the stricter
  contract, but a consumer that builds its own streams alongside Kioku's will see the new
  validation at startup.
- A consumer that links `kioku-core` now links Keiro 0.4's API changes directly, including the
  snapshot `state_shape_hash` invalidation and the timer and workflow-children changes. Kioku
  itself calls none of them — both of its event streams set `snapshotPolicy = Never` and
  `stateCodec = Nothing`, and it has no durable workflows — but the types are on the consumer's
  path.
- Moved onto the Baikai 0.4 / Shikumi 0.3.0.1 cohort: `baikai ^>=0.4.1.0`,
  `baikai-claude ^>=0.4.0.1`, `baikai-effectful ^>=0.3.0.2`, `shikumi ^>=0.3.0.1`, and
  `shikumi-trace ^>=0.2.0.1`. The Shikumi bound names an exact patch level deliberately:
  `shikumi-0.3.0.0` is pinned to the Baikai 0.3 series and would let the solver fall off the
  intended cohort silently.

### Changed

- The connection-settings path is unchanged. `Kioku.App.AppEnv.connectionSettings` still carries
  a `Kiroku.Store.Connection.ConnectionSettings` and `runAppIO` still acquires the store resource
  from it; `kiroku-store` does not move major versions in this cohort.

### Added

- Added `Kioku.CodecCompatSpec` to the test-suite: thirteen literal pre-upgrade JSON payloads —
  one per `MemoryEvent` and `SessionEvent` constructor — asserted to decode under the new cohort,
  plus two tests pinning the native and legacy arms of `parseMemoryEvent`'s fallback.

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
