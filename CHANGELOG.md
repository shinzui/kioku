# Changelog

## 0.3.0.0 — 2026-08-05

Kioku moves onto the Keiki 0.9 / Keiro 0.11 cohort. This is a bounds-only release: no Kioku source
file changed, no migration was added, and no event payload or snapshot is affected. It is a major
bump because `kioku-core` forces its consumers onto Keiki 0.9's sealed constructor API, and no
version of `kioku-core` spans the 0.4 and 0.9 cohorts.

### Breaking Changes

- **kioku-core:** Moved to `keiki ^>=0.9.0.0`, `keiro ^>=0.11.0.0`, `keiro-core ^>=0.11.0.0`. A
  consumer now links Keiki 0.9's sealed `InCtor` / `WireCtor` construction — manual behavior needs
  `unavailableInCtor` / `unavailableWireCtor`, trusted evidence needs Keiki's Generic or TH
  producers, and `mkWireCtor` / `mkWireCtor0` / `mkInCtor` / `mkInCtor0` are deprecated. Kioku's
  own aggregates already used the trusted TH path.
- **kioku-core:** Keiki 0.9's rewritten inversion-ambiguity analysis can change the warning set
  from `validateEventStream` / `mkEventStream`. Kioku's two streams still assemble clean, but
  `mkEventStreamOrThrow` fails at runtime rather than compile time, so a consumer with its own
  streams should exercise its startup path.
- **kioku-migrations / kioku-migrate:** `keiro-migrations ^>=0.11.0.0`. The bound is breaking; the
  plan is unchanged. Keiro ships the same 20 SQL files at 0.4.0.1 and 0.11.0.0, so the plan still
  carries 38 forward migrations and an existing database has nothing to apply.
- **kioku-api / kioku-cli:** No API change; released in lockstep under the shared version.

### Changed

- Existing snapshots stay valid. Keiki's `Keiki.Shape` only gained a `CanonicalTypeName Natural`
  instance and no Kioku register slot uses `Natural`, so the shape hashes are unchanged.
- The `keiki-codec-json` wire format is unchanged across 0.4 → 0.9.
- The rest of the cohort holds its existing bounds: `kiroku-store`, `kiroku-store-migrations`,
  `shibuya-core`, `shibuya-kiroku-adapter`, `baikai`, `baikai-claude`, `baikai-effectful`,
  `shikumi`, `shikumi-trace`, `pg-migrate`.

## 0.2.0.0 — 2026-07-30

Kioku moves onto the released July 2026 cohort. Before this release there was no combination of
published packages that paired Kioku with the current Keiro and Keiki: `kioku-core-0.1.0.0`
declared `keiki ^>=0.2` and `keiro ^>=0.3`, while `keiro-0.4.0.1` requires `keiki >=0.4 && <0.5`.
A downstream project that wanted both had to pass `--allow-newer` or pin raw Git commits. It no
longer does.

### Breaking Changes

- **kioku-core:** Moved to `keiki ^>=0.4.0.0`, `keiro ^>=0.4.0.1`, `keiro-core ^>=0.4.0.1`. Kioku
  no longer builds against Keiki 0.2 or Keiro 0.3. Keiro 0.4's stricter validated event-stream
  assembly applies at startup, and a consumer linking `kioku-core` links Keiro 0.4's snapshot and
  timer API changes.
- **kioku-core:** Moved to the Baikai 0.4 / Shikumi cohort — `baikai ^>=0.4.1.0`,
  `baikai-claude ^>=0.4.0.1`, `baikai-effectful ^>=0.3.0.2`, `shikumi ^>=0.3.0.1`,
  `shikumi-trace ^>=0.2.0.1`.
- **kioku-migrations / kioku-migrate:** `keiro-migrations ^>=0.4.0.1` brings two additive Keiro
  migrations into the plan — `0019-keiro-snapshots-state-shape-hash.sql` and
  `0020-keiro-workflow-children-failure-reason.sql`. An existing database picks up exactly those
  two on the next `kioku-migrate up`.

### Deprecated

- The one-time codd import bridge — `Kioku.Migrations.History.Codd`, the `kioku-migrate import`
  subcommand, and `kioku-migrations/codd-upgrade/` — is deprecated and scheduled for removal once
  the last codd-era downstream database has crossed over.

### Changed

- No Kioku source change was required by the upgrade. The connection-settings path through
  `Kioku.App.AppEnv.connectionSettings` is unchanged.
- Added `Kioku.CodecCompatSpec`, which decodes literal pre-upgrade event payloads under the new
  cohort so a codec regression cannot pass unnoticed.

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
