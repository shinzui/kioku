# Changelog

## Unreleased

### Breaking Changes

- Every memory and session command payload gained required fields: `memorySpaceId` and
  `actorPrincipal` on all of them, plus `ownerPrincipal` on `RecordMemoryData`,
  `StartSessionData`, and `RecordInteractiveSessionData`. Every construction site is a compile
  error until updated. The corresponding event payloads gained the same fields.
- Every write function takes a `MemoryAccessContext` first and is named `*WithContext`:
  `recordWithContext`, `supersedeWithContext`, `archiveWithContext`, `updateTagsWithContext`,
  `updateConfidenceWithContext`, `mergeWithContext`, `startWithContext`, `awaitInputWithContext`,
  `resumeWithContext`, `forceResumeWithContext`, `completeWithContext`, `failSessionWithContext`,
  `recordInteractiveWithContext`, and `recordTurnWithContext`. The unsuffixed names remain as
  **deprecated** wrappers for one release; they take no context and refuse any payload naming a
  space other than `legacyMemorySpaceId`.
- `distillSessionL1` takes a `MemoryAccessContext` first and demands the `MemoryDistill`
  permission before any LLM call.
- `fireL1Timer`, `fireKiokuTimer`, `runKiokuTimerWorkerOnce`, and `drainKiokuTimers` take a
  `MemoryContextProvider`, because a worker discovers its own work and cannot arrive holding a
  context.
- `MemoryWriteError` gained `MemoryNotPermitted`, `MemorySpaceMismatch`, and
  `MemoryActorMismatch`; `SessionWriteError` gained the three equivalents; `L1Error` gained
  `L1NotPermitted`.
- An L1 timer payload that cannot be parsed now dead-letters instead of being ignored. Payloads
  written before this release parse fine and fire in the legacy space.
- Every read function takes a `MemorySpaceId` first and returns nothing outside it:
  `Kioku.Memory.getMemoryRowById`, `getActiveRowsInNamespace`, `getActiveRowsByScope`,
  `getRowsBySession`, `getActiveRowsByType`, `getSupersessionChain`; `Kioku.Session.getById`,
  `getRecentInNamespace`, `getByScope`, `getByFocus`, `getByStartedRange`, `getChain`,
  `getDelegationChildren`, `getAwaitingByCorrelationKey`, `getTurns`; `Kioku.Recall.getById`,
  `getActiveByScope`, `getActiveInNamespace`, `getGlobal`, `getBySession`, `getByType`;
  `Kioku.Distill.L2.getScenesByScope` and `regenerateScene`; `Kioku.Distill.L3.getPersonaByScope`
  and `regeneratePersona`. Pass `memoryContextSpace` of the context that authorized the read.
- `RecallRequest` gained a required `memorySpaceId` field.
- Every read-model query record is now a record with named fields rather than a positional
  constructor, with `memorySpaceId` first: `MemoryByIdQuery`, `MemoriesByNamespaceQuery`,
  `MemoriesByScopeQuery`, `MemoriesBySessionQuery`, `MemoriesByTypeQuery`,
  `MemorySupersessionChainQuery`, and the nine session equivalents.
- `MemoryRow`, `SessionRow`, `TurnRow`, `SceneRow`, and `PersonaRow` gained a leading
  `memorySpaceId` field.
- `fireL2SceneTimer` and `fireL3PersonaTimer` take a `MemoryContextProvider`, like `fireL1Timer`.
- Scene and persona timer ids and correlation ids now include the memory space, so two spaces
  sharing a namespace and scope no longer share one timer. Timers already scheduled keep their
  old ids and fire in the legacy space.
- `runEmbeddingWorkerHost`, `embeddingWorkerProcessor`, and `embeddingHandler` take a
  `MemoryContextProvider`, like the timer handlers, because the embedding worker also discovers
  its own work.
- `backfillMissingEmbeddings` takes an `EmbeddingWorkerEnv` and an `EmbeddingBackfillScope` in
  place of an `EmbeddingModel` and a dimension count.
- `EmbedOutcome` gained `EmbedSpaceMismatch`.
- `runKiokuTimerWorkerOnce` and `drainKiokuTimers` require `Tracing :> es`.
- Scene and persona mirrors moved from `.kioku/{scenes,persona}/<slug>.md` to
  `.kioku/spaces/<space-dir>/{scenes,persona}/<slug>.md`. `sceneMirrorPath` and
  `personaMirrorPath` keep their signatures — the space comes from the row — but return different
  paths. Run `kioku migrate-artifacts` to relocate existing files.
- A cross-space id on a write path now returns `MemoryNotFound` / `SessionNotFound` rather than
  reaching the aggregate and returning `MemoryCommandRejected`. That closes the existence oracle
  the previous release documented: an id in another space is now indistinguishable from one that
  was never written.
- Read-model registry identities advanced: memory models to v2 / `kioku-memory-v2`, session models
  to v4 / `kioku-session-v4`, turns to v2 / `kioku-turn-v2`. `kioku-migrate` reconciles them; a
  host applying migrations as a library must call `reconcileReadModelRegistry` itself.

### Added

- `Kioku.Partition` — the single place that decides what a payload written before memory spaces
  means: the legacy space, and a legacy-marked agent label. No codec invents its own default.
- `Kioku.Distill.Timer.L1TimerPayload`, which carries the memory space a scheduled distillation
  pass belongs to.
- `Kioku.Workspace` — the per-space artifact layout and the migration of the pre-partition tree.
  A memory space id is validated for a database column rather than for a path, so the directory
  component is a sanitised prefix plus a digest of the exact id: `..` cannot escape
  `.kioku/spaces`, and two ids that differ only in case cannot share a directory.
- `kioku migrate-artifacts` — a dry run by default; `--apply` copies, never moves, and refuses a
  destination whose content differs.
- `kioku worker --backfill --space ID` — an embedding backfill bounded to one memory space. The
  default stays every space.
- A `kioku.timer.fire` span per fire attempt, carrying `kioku.memory_space_id`, the timer id, the
  attempt count, a bounded `kioku.timer.outcome`, and the failure reason. Metrics gained no space
  or principal label and must not: a space is caller-supplied text.
- Aggregate state carries the memory space, and every non-creation edge guards on it, so a command
  naming a different space is refused by the state machine rather than by a read-model precheck.

### Compatibility

- Events already on disk keep decoding. They land in `legacyMemorySpaceId`; an old free-text
  `agentId` is recorded as a legacy-marked label and never rewritten into a directory principal;
  an event that recorded no agent is `UnattributedPrincipal`. Encoders emit only the new form.
- Reads are partitioned by the schema. Every read-model table carries a non-null
  `memory_space_id`, backfilled to `kioku_legacy`, and every statement names it. An upgraded
  single-space deployment sees exactly what it saw before. See
  `docs/user/upgrading-to-memory-spaces.md`.
- Workspace mirrors are partitioned. Files written before this release stay at `.kioku/scenes`
  and `.kioku/persona`, which nothing writes to any more; `kioku migrate-artifacts` reports and
  relocates them. The one exception is deletion: emptying a scope in the legacy space unlinks its
  historical mirror too, because forgotten content surviving on disk is a retention failure
  rather than a stale cache.

## 0.3.0.0 — 2026-08-05

### Breaking Changes

- Moved onto the Keiki 0.9 and Keiro 0.11 cohort: `keiki ^>=0.9.0.0`, `keiro ^>=0.11.0.0`, and
  `keiro-core ^>=0.11.0.0`. Kioku no longer builds against Keiki 0.4 or Keiro 0.4, and there is no
  version of `kioku-core` that spans both cohorts.
- A consumer that links `kioku-core` now links Keiki 0.9's sealed constructor API. `InCtor` and
  `WireCtor` construction and record update are behind read-only patterns: manual behavior must go
  through `unavailableInCtor` / `unavailableWireCtor`, and constructors that need trusted
  structural evidence must use Keiki's Generic or Template Haskell producers. `mkWireCtor`,
  `mkWireCtor0`, `mkInCtor` and `mkInCtor0` are deprecated. Kioku's own aggregates already use the
  trusted TH path and needed no change, but a consumer that hand-writes constructors alongside
  Kioku's does.
- Keiki 0.9 classifies replay head identity structurally and rewrites the default
  inversion-ambiguity analysis, so `validateEventStream` and `mkEventStream` may report a
  different conservative warning set after recompilation. `Kioku.Memory.EventStream` and
  `Kioku.Session.EventStream` both assemble through `mkEventStreamOrThrow`, which turns a warning
  into a runtime `error` at first use rather than a compile failure; both still assemble clean
  under 0.9. A consumer that builds its own streams should re-run its startup path, not just
  rebuild.

### Changed

- No Kioku source change was required by the upgrade. Keiro's 0.5–0.11 releases are almost
  entirely `keiro-dsl` work, which Kioku does not depend on; the Keiro runtime surface Kioku
  imports is unchanged across the whole range.
- Event payloads are unaffected. The `keiki-codec-json` wire format is unchanged across 0.4 → 0.9,
  and `Kioku.CodecCompatSpec` continues to decode literal pre-upgrade payloads under the new
  cohort.
- Existing snapshots stay valid. Keiki's `Keiki.Shape` changed only by adding a
  `CanonicalTypeName Natural` instance, and no Kioku register slot uses `Natural`, so
  `regFileShapeHash` and `stateShapeHash` are unchanged and there is no snapshot rebuild.
- The rest of the cohort does not move: `kiroku-store`, `shibuya-core`, `shibuya-kiroku-adapter`,
  `baikai`, `baikai-claude`, `baikai-effectful`, `shikumi` and `shikumi-trace` keep the bounds
  they had in 0.2.0.0.

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
