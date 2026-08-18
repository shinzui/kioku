# Changelog

## Unreleased

### Changed

- **Cohort:** moved onto Baikai 0.5 — `baikai ^>=0.5.0.0`, `baikai-claude ^>=0.5.0.0`,
  `baikai-effectful ^>=0.3.0.3`, and with them `shikumi ^>=0.3.0.2` and
  `shikumi-trace ^>=0.2.0.2`, the patches that carry the Baikai 0.5 bounds.
  `baikai-effectful` has no 0.5 release and never had a 0.4 one; 0.3.0.3 is the
  patch that widened its own `baikai` bound, so its version lags the rest of the
  cohort by design. This is a bounds-only change: no Kioku source changed.

  None of Baikai 0.5's breaking changes reach Kioku. Kioku touches only
  `Baikai.Auth`, `Baikai.Embedding`, `Baikai.Model`, `Baikai.Models.Generated`,
  `Baikai.Provider.Claude.Api`, and `Baikai.Provider.Registry`, none of which
  changed. `Response` gained an `evidence` field, but Kioku only ever builds one
  in tests through the exported empty value rather than the record constructor,
  so the new field defaults in. Kioku implements no provider, so the
  `doneTerminal`/`errorTerminal` signature change is unreachable; it decodes no
  `TraceEvent`, so the hand-written `FromJSON` is not a concern; and it stores no
  Baikai call identifier, so `newCallId`'s widening from 16 to 32 characters
  crosses no schema.

## 0.4.0.0 — 2026-08-17

Kioku's projections move into a schema of their own. Kioku keeps sharing the host application's
Kiroku event store — that sharing is the integration boundary and it is unchanged — but the seven
relations Kioku alone reads and writes leave `kiroku` for a dedicated `kioku` schema, dropping the
now-redundant name prefix: `kiroku.kioku_memories` becomes `kioku.memories`, and likewise for
`sessions`, `turns`, `l1_watermarks`, `consolidation_decisions`, `scenes`, and `personas`. The
full rollout is in [docs/user/upgrading-to-the-kioku-schema.md](docs/user/upgrading-to-the-kioku-schema.md);
the reasoning is in [ADR-10](docs/adr/projections-live-in-the-kioku-schema.md).

### Breaking Changes

- **kioku-migrations:** New migration `0012-relocate-projections-to-kioku-schema.sql`. The move is
  metadata only — `ALTER TABLE ... SET SCHEMA` plus `... RENAME TO` keep every table's OID, rows,
  indexes, constraints, owner, and grants, and index and constraint names are left alone. It
  accepts exactly two catalog states and raises transactionally on any other, so a partial upgrade
  or a name collision changes nothing. The composed plan is now 53 migrations (kiroku 11, keiro 30,
  kioku 12).
- **kioku-core:** Every statement names its relation explicitly through the new internal
  `Kioku.Database.Schema` instead of resolving it through `search_path`. Read-model identities
  advance to memory v3, session v5, and turn v3 so a binary on the wrong side of the migration
  fails closed with `ReadModelStaleSchema` rather than querying relations that have moved.
- **Operational:** This is a migration-first upgrade with a short planned outage. Stop writers,
  back up, migrate, grant `USAGE ON SCHEMA kioku` if the runtime role is not the schema owner,
  reconcile the read-model registry (`kioku-migrate up` does it; library embedders must call
  `Kioku.ReadModel.reconcileReadModelRegistry` themselves), then start the new binary. There are
  no compatibility views, and restarting the old binary is not a rollback.

### Changed

- The `vector` extension is deliberately not moved: it is a database-wide object the host may
  share. pgvector capability detection probes `kioku.memories`, while the `vector` type itself
  still resolves against the connection's search path.
- **Cohort:** moved onto Keiro 0.13, Kiroku 0.8, and Shibuya 0.9 —
  `keiro`/`keiro-core` `^>=0.13.0.0`, `keiro-migrations ^>=0.13.0.0`, `kiroku-store ^>=0.8.0.0`,
  `kiroku-store-migrations ^>=0.4.0.0`, `shibuya-core ^>=0.9.0.0`, and
  `shibuya-kiroku-adapter ^>=0.5.1.1`. Kioku uses none of the surfaces Keiro 0.12 or 0.13 broke —
  it has no workflows and no `keiro-dsl` dependency, it registers no custom or mock `Store`
  interpreter that Kiroku's new effect constructors would make partial, and it only constructs
  `DeadLetterReason` rather than matching on it, so Shibuya 0.9's `ApplicationFailure` arm does not
  reach it. One classifier did have to change; see below.

### Fixed

- **kioku-core:** `Kioku.Worker.Failure.isTransientStoreError` was missing two `StoreError`
  constructors, and classified one of them wrongly by omission. `TransientTransactionFailure`
  (new in `kiroku-store` 0.8.0.0, carrying PostgreSQL's class-40 rollback codes `40001` and
  `40P01`) is now **transient**: Kiroku documents it as retryable — the transaction rolled back
  completely and nothing was committed — and until 0.8.0.0 those codes arrived as
  `UnexpectedServerError`, which this function called permanent, so a serialization failure or
  deadlock halted the embedding worker on a conflict it should have retried.
  `HistoryRetentionActive` (new in `kiroku-store` 0.7.0.0) is **not** transient: it is an
  operator-policy refusal that fails identically until the lease is released, and Kioku's workers
  never hard-delete, so it is unreachable today.

  The function deliberately carries no wildcard so that a new upstream constructor forces a
  classification decision. That only worked as a warning, and `HistoryRetentionActive` slipped
  through a whole release cycle unnoticed, leaving a partial function that would have raised a
  pattern-match failure at runtime. `kioku-core`, `kioku-api`, and `kioku-cli` therefore now build
  with `-Werror=incomplete-patterns`, which they already do cleanly.

### Deprecated

- Keiro deprecates `Keiro.ReadModel.runQueryWith`, the `Eventual` constructor of
  `ConsistencyMode`, and the `defaultConsistency` record field, in favour of
  `runQueryWithFreshness` and `QueryFreshness`/`Immediate`. Their 0.12 notices said "removed in
  0.13"; 0.13 kept them as compatibility surface, so the removal release is still ahead. Kioku
  calls the old surface at 25 sites across `Kioku.Recall`, `Kioku.Memory`, and `Kioku.Session`,
  plus 28 `defaultConsistency = Eventual` read-model fields — 135 deprecation warnings in all.
  This still builds, and still must be migrated before Keiro drops the surface.

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
