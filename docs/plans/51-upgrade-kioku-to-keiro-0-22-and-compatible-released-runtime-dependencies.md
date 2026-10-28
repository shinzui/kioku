---
id: 51
slug: upgrade-kioku-to-keiro-0-22-and-compatible-released-runtime-dependencies
title: "Upgrade Kioku to Keiro 0.22 and compatible released runtime dependencies"
kind: exec-plan
created_at: 2026-10-28T03:21:40Z
intention: "intention_01m6089f0dedgaz72h7ke6cg80"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-28T03:21:40Z
---

# Upgrade Kioku to Keiro 0.22 and compatible released runtime dependencies

This ExecPlan is a living document. Maintain Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective during implementation. Record implementation friction through `agents/skills/exec-plan/FRICTION.md`; distill durable findings into the relevant ADRs before completion.


## Purpose / Big Picture


Upgrade Kioku to **Keiro 0.22.0.0**, using its compatible released dependencies, while preserving memory/session commands, durable event encodings, recall, authorization, embedding delivery, and timer behavior. The source change should be small: dependency bounds, one known Shibuya test constructor change, and adoption of Kiroku's append-only migration 0016 through the existing composed runner.

This document authorizes no implementation by its creation. Implementation produces a verified candidate and an operator runbook; publishing packages and activating persistent installations are subsequent operator actions. Do not expand this upgrade into adoption of DSL services, namespace subscriptions, operations servers, PGMQ workers, or a retained Nix runtime package set.


## Progress


- [ ] M1: The released 0.22 cohort solves from identified Hackage sources under the existing bare GHC development shell; the real embedding adapter roundtrip passes after minimal API adaptation.
- [ ] M2: Fresh and previous-cohort databases converge on the exact 63-entry migration plan, preserve historical data/checkpoints, and repeat without changes.
- [ ] M3: Focused and full application validation, source-aware artifact parity, codec/catalog compatibility, and the clean-candidate generation-equivalent gate pass.
- [ ] M4: Restored-history migration, live replay, rebuild and command parity, and observed delivery pass; identified artifacts and cutover/recovery instructions are handed to operators.

Planning only. No milestone is accepted yet. Prerequisites that need operator data are explicitly identified below; synthetic migration fixtures do not substitute for restored-history evidence.


## Surprises & Discoveries



## Decision Log


2026-10-28 UTC: Keep the requested Keiro target at 0.22.0.0. Hackage lists no newer release at research time. Later publication is to be reported separately, without silently advancing this plan.

2026-10-28 UTC: Keep Kioku's small existing architecture. There is no owned Keiro DSL workspace, operations embedding, PGMQ traffic path, retained-runtime selection, Nix executable output, or Nix library extension. Preserve the bare-shell/Cabal shipping model. Apply the reference plan's evidence requirements to actual Kioku paths instead of importing Rei's infrastructure or candidate Language 6 policy.

2026-10-28 UTC: Prepare Kioku 0.12.0.0 in lockstep across its five packages, internal bounds, changelogs, and upgrade blueprint. Kioku exports upstream types and changes its composed database plan; dropping the previous dependency cohort merits this pre-1.0 compatibility boundary. Package publication remains outside implementation.


## Outcomes & Retrospective



## Context and Orientation


### Verified repository facts


Research began at `f334a7c60500e9c9624f456d9cc7f68c68879f4d`. During research, a separate change advanced the current branch to **`9cd613d5087a08d6625cb266ff09845197b1d3d4`**, upgrading the Nix module. Use this latter full commit as the fixed **pre-upgrade baseline** for compatibility reports, old package builds, and historical-payload comparisons. It still has the old runtime bounds. Do not move the baseline forward as implementation commits accumulate. Check for later unrelated changes before starting and preserve them.

The five packages are `kioku-api/kioku-api.cabal`, `kioku-core/kioku-core.cabal`, `kioku-cli/kioku-cli.cabal`, `kioku-migrations/kioku-migrations.cabal`, and `kioku-migrate/kioku-migrate.cabal`, all currently 0.11.0.0. `cabal.project` selects GHC 9.12.4. Every package uses GHC2024 and the shared warning policy; profiled core/CLI builds retain the documented `-fno-opt-coercion` workaround. Keep the current TLS exception `claude:http-client-tls`, Blake3 flags, and libpq pkg-config choice; add no new solver exception merely to force this upgrade.

The existing `dist-newstyle/cache/plan.json` reports GHC 9.12.4, Keiro/core/migrations/test-support 0.21.0.0, Store 0.11.0.0, Store migrations 0.7.1.0, Shibuya Core 0.10.0.1, and the Kiroku adapter 0.6.0.1. It also selects Keiki/codecs 0.9.1.0, pg-migrate family 1.2.0.0, Effectful 2.7.1.0/Core 2.7.1.2, Shikumi 0.4.1.1/trace 0.3.0.2, Baikai 0.8.0.0, Claude/OpenAI 0.7.1.1 and Effectful adapter 0.4.0.3. This is an observed cached solution, not proof of a fresh solve or a shipping binary's identity.

`cabal.project` constrains `keiro-pgmq`, four PGMQ packages, and `shibuya-pgmq-adapter`, but no package consumes them and they are absent from the observed closure. Keep these optional constraints compatible; do not add queue components or tests for unused queue traffic.

`kioku-core/src/Kioku/Memory/Domain.hs` and `kioku-core/src/Kioku/Session/Domain.hs` use Keiki's compile-time `deriveAggregate` (Template Haskell generates private helpers during compilation). Their event streams and codecs are handwritten in `kioku-core/src/Kioku/Memory/EventStream.hs` and `kioku-core/src/Kioku/Session/EventStream.hs`. No `.keiro`, `.keiro-workspace`, DSL wrapper, scaffold command, generated service tree, or selected Keiro DSL language exists here. `kioku-core/test/Kioku/CodecCompatSpec.hs` freezes native historical payloads, legacy attribution/defaults, and foreign-language rejection. Regeneration means recompiling these existing metaprograms, not introducing DSL code generation.

`kioku-core/src/Kioku/ProjectionCatalog.hs` declares the two exact categories `kioku_memory` and `kioku_session`, three application targets (`kioku.memories`, `kioku.sessions`, `kioku.turns`), and groups `kioku-memory` and `kioku-session`. Its replay adapters use the actual codecs and inline projection functions. Command runners in `kioku-core/src/Kioku/Memory.hs` and `kioku-core/src/Kioku/Session.hs` combine catalog-derived application handlers with explicit timer callbacks in the same transaction. Keep that boundary. `kioku-core/src/Kioku/App.hs` validates both streams and the catalog before registration. `kioku-core/src/Kioku/ReadModel.hs` derives registry reconciliation from the catalog.

`kioku-migrations/src/Kioku/Migrations.hs` composes **Kiroku, Keiro, Kioku** through pg-migrate, in that order. Kioku has 15 native migrations in `kioku-migrations/migrations/manifest`; the current composed total is 62 (47 upstream plus 15 local). The target is 63 (48 upstream plus 15 local). `kioku-migrate/app/Main.hs` exposes `plan`, `verify`, `status`, `up`, and the existing deprecated Codd import; `up` subsequently reconciles read-model identities. It lives in a separate package to avoid a package-level dependency cycle. Preserve this separation, Codd history mappings, `migrations.lock`, and historical SQL bytes.

`kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs` provides `withKiokuMigratedDatabase` and `withBareDatabase` using Keiro/ephemeral-pg fixtures. `kioku-migrations/test/Main.hs` already tests fresh installations, data-bearing previous cohorts, checkpoint preservation, Codd import, native payload hashes, schema convergence, and checksum refusal. Extend these fixtures rather than replacing the harness.

`kioku-core/src/Kioku/Memory/Embedding/Worker.hs` uses the real Shibuya Kiroku adapter with an exact `Category (CategoryName "kioku_memory")`, default adapter configuration and `defaultAppConfig`. `kioku-core/test/Kioku/EmbeddingWorkerSpec.hs` already proves delivery, vector storage, durable checkpoint binding, legacy adoption, conflicting-target refusal, and graceful shutdown. Its complete `mkIngested` record is the known source adaptation. `kioku-core/src/Kioku/Distill/Timer/Worker.hs` uses Keiro timers, not PGMQ. `kioku-cli/src/Kioku/Cli/Commands/Worker.hs` supervises timer/embedding loops and preserves the timer-only degradation modes and nonzero fatal exits. Keep provider execution disabled without existing explicit host grants.

There are no `Keiro.Ops`/HTTP mounts or complete upstream `AppHooks`, `ProcessManagerInspector`, or `InspectionLimits` records. Memory/session command options update `defaultRunCommandOptions`, so new inspection provenance remains disabled. Upstream operations JSON, cursor, WebSocket, CORS and DLQ reservation changes need no application changes here.

At the fixed baseline `.seihou/manifest.json` already records `nix-haskell-flake` **0.37.0**, the latest published module verified at `mori://shinzui/seihou-modules`, commit `a5cbd51d7cd45c0a872e208f43bf6dd32eafe4fe`. `flake.nix` now pins toolchain `21933607e80ec4660a28a125a6f4c0707e358caf` and shared channel `dedd4d81589e99d97137eb36f88423c70c7d69f5`; this prerequisite is already satisfied, not a change to repeat. `nix/haskell.nix` supports optional `haskellProject.runtime` but leaves it null. `flake.module.nix` adds Git/curl development inputs and convention checks. There is no `packages.default`, shipping Nix package recipe, exported `lib.haskellExtension`, or runtime-selection file. Shipping artifacts are the Cabal-built `kioku`, `kioku-migrate`, and libraries/source distributions. Retain pgvector, PostgreSQL/libpq/OpenSSL development inputs, HLS, hooks, `.envrc`, and process-compose. Merely locking the shared channel does not mean its package sources are consumed. Do not claim Cabal/Nix runtime-package parity when there is no second runtime package set.

### Release evidence and dependency ownership


A cohort is the set of compatible dependency releases selected together. Mori was used first (`registry list`, `search`, `show --full`, `docs`) to locate sources. The registry is stale for some versions and has no curated Keiro/Kiroku documents; read source and checked-in upgrade guides, then verify publication independently.

The reference `mori://shinzui/rei/plans/286-upgrade-rei-to-keiro-0-22-and-the-latest-nix-runtime-package-integration` was unavailable through the installed Mori resolver and stale local Rei checkout. Its published contents were read through GitHub's contents API. Its useful requirements here are source-aware solves, a fixed comparison commit, a clean final generation gate, identified restored history, complementary replay/rebuild/write/delivery evidence, and separate migration/runtime identities. Rei-specific retained recipes, DSL gates, HTTP workflows, PGMQ migration, and operator scripts are absent in Kioku and must not be copied as commands that supposedly exist here.

On 2026-10-28 UTC, Hackage package JSON endpoints and published Cabal files confirmed the following target selections. Upstream annotated tags were checked with `git ls-remote --tags`; peeled commits identify the release source, not moving branch heads.

| Consumed package | Current observed | Target bound/release | Verified release source |
| --- | --- | --- | --- |
| keiro, keiro-core, keiro-migrations, keiro-test-support | 0.21.0.0 | `^>=0.22.0.0` | `mori://shinzui/keiro`, `b28201f2063fa4f6dcb724cbf474959107e36b74` |
| kiroku-store | 0.11.0.0 | `^>=0.12.0.0` | `mori://shinzui/kiroku`, `22d103e4f424caab06c6a2b76ad92b408c262bc0` |
| kiroku-store-migrations | 0.7.1.0 | `^>=0.7.2.0` | same Kiroku release commit |
| shibuya-kiroku-adapter | 0.6.0.1 | `^>=0.7.0.0` | same Kiroku release commit |
| shibuya-core | 0.10.0.1 | `^>=0.12.0.0` | `mori://shinzui/shibuya`, `14f35d8995cc3dc3e2671e4d2505abf9bf4f5a9e` |
| keiki / keiki-codec-json | 0.9.1.0 | retain 0.9.1.0; codec constraint may advance its floor to `^>=0.9.1.0` | `mori://shinzui/keiki`, tag `v0.9.1.0` → `15bc83b1eb38d78488862f24bb1d873aa32a919a` |
| pg-migrate, cli, embed, import-codd | 1.2.0.0 | retain `^>=1.2.0.0` | `mori://shinzui/pg-migrate`, tag `v1.2.0.0` → `13865052bef62688c40576ad36889221a0ba7e08` |

The unused optional constraints become `keiro-pgmq ^>=0.22.0.0`, PGMQ core/effectful/hasql/migration `>=0.7.0.0 && <0.8`, and `shibuya-pgmq-adapter ^>=0.18.0.0`. Hackage confirms these releases; `mori://shinzui/pgmq-hs` tag `v0.7.0.0` peels to `88afb93802f790c1ecfbd3ed8bcce196c4430d13`, and `mori://shinzui/shibuya-pgmq-adapter` tag `v0.18.0.0` peels to `e549451978f93f28ccb39912404be9a8a3fea4d7`. If a future consumer enables PGMQ, upstream migration 0007 suppresses partition notifications, durable polling remains necessary, and DLQ envelopes add `original_queue`. Those are host obligations, not changes to Kioku's three-component plan. Do not include PGMQ 0007 in the 63-entry expectation.

All eight Keiro release tags align at 0.22.0.0, but Kioku consumes only four packages; do not add DSL, ops, ops-http, or PGMQ dependencies. Hackage showed no newer Keiro release. Effectful/Core, Shikumi/trace, ephemeral-pg and the existing AI cohort already have compatible released choices within present bounds; avoid gratuitous changes. Capture their exact final solution and investigate unrelated solver movement.

Primary release metadata: [Keiro versions](https://hackage.haskell.org/package/keiro.json), [Store versions](https://hackage.haskell.org/package/kiroku-store.json), [Shibuya versions](https://hackage.haskell.org/package/shibuya-core.json), and [published Keiro Cabal bounds](https://hackage.haskell.org/package/keiro-0.22.0.0/keiro.cabal). The source guides are `mori://shinzui/keiro` plus `blueprints/keiro-upgrade/migrations/0.21.0.0-to-0.22.0.0.md`, and `mori://shinzui/kiroku` plus `blueprints/kiroku-upgrade/migrations/0.11.0.1-to-0.12.0.0.md` (artifact-level source URIs pending). The module is `mori://shinzui/seihou-modules/templates/nix-haskell-flake`.

### ADR constraints and prerequisites


Consulted [ADR-4](../adr/the-aggregate-enforces-the-partition.md): partition enforcement belongs in aggregate state and survives retries. [ADR-5](../adr/historical-attribution-is-marked-never-invented.md) and [ADR-11](../adr/consumers-own-one-time-foreign-event-migration-codecs.md) require native old payloads to remain readable, historical attribution to remain marked, and foreign codecs to remain consumer-owned. [ADR-10](../adr/projections-live-in-the-kioku-schema.md) assigns Kioku projections to `kioku`, forbids rewriting history, and distinguishes source upgrade guidance from operator migration. [ADR-12](../adr/host-owned-ai-execution.md) keeps AI capabilities explicit and preserves deferred timer leases. [ADR-13](../adr/catalog-application-projections-not-framework-timers.md) keeps application projections and shared framework timer callbacks separate but atomic. [ADR-14](../adr/haskell-and-cli-conventions-are-executable-contracts.md) fixes GHC2024/GHC 9.12 conventions and tested CLI output. These decisions remain in force.

Implementation prerequisites are a working GHC 9.12.4 development shell, Hackage access, PostgreSQL with pgvector for the delivery lane, and sufficient space for an isolated Cabal store and disposable databases. No tests were run to accept the upgrade during planning.

M4 additionally needs an operator-supplied, checksummed pre-upgrade archive, provenance for that archive, a PostgreSQL major matching the deployment, two explicitly disposable database identities, and old/candidate provider/workspace configuration isolated from real effects. None was supplied during planning. If absent, complete M1–M3 and the reusable rehearsal/runbook work, but leave M4's restored-history acceptance pending. Never silently use the development database or invent production credentials. The actual deployed hosts, embedded library consumers, database age/Codd state, supervisor command, and deployment PostgreSQL major remain inventory questions to resolve before activation; they do not block coding the small dependency upgrade.


## Plan of Work


### M1 — Resolve the cohort and prove the real worker first


Update all occurrences of the consumed bounds in the five Cabal files, including tests and the public migration test-support library. Update optional constraints and their explanatory comments in `cabal.project`. Move all five Kioku versions and their internal bounds to 0.12.0.0. Preserve other package compatibility choices unless the fresh solver demonstrates a required adjustment. Do not import the shared runtime's complementary `kioku` selection into Kioku itself: it would substitute a published application package for this repository's owned library.

In `kioku-core/test/Kioku/EmbeddingWorkerSpec.hs`, import `DeliveryStatus (DeliveryCurrent)` from `Shibuya.Core.Ingested` and add `deliveryStatus = pure DeliveryCurrent` to `mkIngested`. Production constructors already use defaults. Inspect exhaustive error/target matches, especially `kioku-core/src/Kioku/Worker/Failure.hs`; preserve typed SQLSTATE/decode error classification. Kiroku's new target mismatch belongs to its subscription error, so do not invent a StoreError branch unless the released type actually adds one. Preserve exact-category subscriptions; do not select `CategoryNamespace` or supply a fake notifier registry.

Before broad application work, run the existing `real adapter delivers, checkpoints, and shuts down` test. It must execute the real command/store/adapter, invoke a deterministic fake embedding provider once, store the vector, persist the `$all` checkpoint and exact-category binding, and drain on shutdown. Run its legacy adoption and wrong-target refusal companions next. Add a restart/second-event assertion only if necessary to close missing delivery evidence; reuse the same fixture. A successful compile alone does not accept M1.

Retain module 0.37.0 and the existing bare shell. Recheck latest publication before implementation; if the module is already current, record the no-change result. A newer module may be applied with Seihou's recorded-update workflow after a dry run, preserving project-owned configuration; it still does not select an optional retained runtime. Do not add Nix shipping packages, OCI images, or exported recipe interfaces.


### M2 — Advance the native migration chain without changing history


Migration 0016 from Store migrations 0.7.2.0 changes only the two subscription target constraints and the Kiroku schema comment. It adds `category_namespace` as a permitted target kind and requires a category for either category kind. It does not change events, stream indexes, append behavior, or existing subscription values. Keep all existing bindings unchanged and stop affected workers around its application.

Extend `kioku-migrations/test/Main.hs` with a **62-entry previous-0.21 fixture**. Build the old component by filtering Kiroku 0016 from `componentMigrationsOf` in `Database.PostgreSQL.Migrate.Types` and using the public `migrationComponent` constructor; verify every retained SQL payload/checksum against the 0.7.1.0 Hackage archive/tag before using it. The test already uses pg-migrate internals for checksum evidence; `migrationSqlBytes` supplies the payload when needed. Do not import Kiroku's private embedding module. Keep the existing 0.6 fixture and its SHA256SUMS unchanged. Seed existing exact-category, all, and unbound subscriptions, event/junction rows and checkpoints, then apply the current composed plan. Require exactly `kiroku/0016` applied, all original ledger rows/checksums unchanged, and every seeded row/checkpoint preserved. Re-run and require 63 AlreadyApplied entries and no writes.

Update genuine whole-plan totals from 62 to 63 and the older 0.6 upgrade delta from 0013–0015 to 0013–0016; keep its 59-entry starting state and its frozen 12-entry historical Kiroku fixture. Do not mechanically replace unrelated literals, Codd's 30 imported rows, or Kioku's 15-entry manifest. The old `kioku` schema checksum must stay unchanged. Add a refusal case for an unexpected ledger checksum and verify failure before new migration or reconciliation writes. Use `withBareDatabase`/existing seed and snapshot helpers; no new database harness.

Acceptance is the migration suite passing on fresh, 62-entry, earlier supported and Codd fixtures, with a 63-entry candidate plan whose only delta from a complete 0.21 database is `kiroku/0016`. No historical SQL, manifest order, lock checksum or Codd evidence changes.


### M3 — Qualify the candidate and its artifacts


Run focused codec, projection catalog, reconciliation, recall, isolation, timer and CLI suites, then full tests and warnings-as-errors build. Preserve wire tags, payload defaults, event schemas, stream names, source identities, catalog ownership and transaction atomicity. Create a concise compatibility report in `docs/architecture/keiro-0-22-upgrade-acceptance.md` against the fixed baseline, including source/package identities and changed versus inapplicable surfaces.

There is no Keiro DSL regeneration or DSL compatibility report to run. Instead require a full compilation in a fresh build directory (which re-expands `deriveAggregate`), both handwritten stream validations, the unchanged codec fixtures, catalog inventory/registration/rollback tests, and a second build that changes no tracked source. Record DSL/language qualification as inapplicable, not as a successful invocation of nonexistent `just keiro-gate`. Keep GHC2024; there is no reason to introduce either DSL Language 5 or 6.

Use a fresh bare-compiler Cabal plan with an empty task-specific store. Compare **source origin, source SHA256, revised Cabal SHA256, flags, compiler/ABI, platform, and build options**, not just versions. Every non-boot dependency must have configured source evidence; a pre-existing runtime dependency is a failure of evidence even if versions match. Boot packages supplied with GHC are the only explained exception. Build the final artifacts from that identified solution and retain it. If a normal cached build is also used, compare its source-bearing solution to the fresh plan or use the fresh artifacts as shipping candidates; do not infer an installed unit's origin from its version. With this project's bare shell there is no retained Nix manifest to compare. Verify Nix's compiler/native tools and document that Nix supplies the environment, while Cabal supplies runtime sources. Any later decision to add a second runtime package scope requires an explicit plan revision and actual source comparison.

Run `cabal sdist all` and build an external throwaway project from the five generated archives to cover exported libraries and the public test-support sublibrary. The external project must retain the same compiler, flags and constraints as the candidate, contain only these source archives as local packages, and have no `../kioku-*` escape back to the checkout. Require both executables and all exposed libraries to build. Inspect the resulting source-aware plan against the candidate for non-local dependency parity.

Append a `kioku-upgrade` 0.11.0.0 → 0.12.0.0 edge in `blueprints/kioku-upgrade/blueprint.dhall` and a matching migration prompt, entailing exactly Keiro 0.21.0.0 → 0.22.0.0; let upstream entail the Kiroku edge. Preserve historical edges. Update all five changelogs and the relevant library/migration/worker upgrade documentation. Do not publish the package set or blueprint during implementation.

After reviewing and committing the candidate on the current branch, require a clean tree and repeat the complete fresh-build/stream-codec-catalog checks as the **generation-equivalent final gate**. Keep baseline `9cd613d...` fixed. Tests during editing are useful but do not replace this clean-candidate gate. Record the exact candidate commit and artifact hashes, separately for `kioku-migrate`, `kioku`, and the five source archives.


### M4 — Rehearse actual history and prepare operator cutover


Keep the rehearsal small and out of the product CLI. Add `scripts/kioku-upgrade-probe.hs` as a developer-only probe run through `cabal exec -- runghc`, reusing public Kioku APIs and existing fixture conventions. Its modes are `read`, `write`, `replay`, `rebuild`, and `delivery`; require an explicit database connection argument and report directory. It must refuse any mutating mode unless `KIOKU_UPGRADE_DISPOSABLE=1` and the database identity matches the separately recorded scratch identity. It must not create/drop databases, migrate implicitly, enable AI providers, or reset shared checkpoints. Keep domain behavior in Kioku modules, not a second implementation inside the probe.

`read` captures deterministic, sorted application rows and selected public recall/session reads, plus the full migration ledger, schema/constraint definitions, event/junction facts, timers, subscriptions/checkpoints and catalog/query metadata needed for the exact migration comparison. It must not register/reconcile the catalog or repair stale metadata; construct the existing `AppEnv` for `runAppIO` without calling the startup-registration wrapper. Write `read.json`, `ledger.json`, `schema.sql`, and `protected.json` under its report directory. Use ordered row JSON from PostgreSQL (including explicit primary keys), not aggregate row counts as preservation evidence. `write` uses fixed fixture IDs/times/space/principal and runs record/start/turn/await/resume/archive plus an idempotent retry and cross-space refusal through the public library, then compares event tags/payloads, final rows, timers and command outcomes in `commands.json`. Invoke the actual retained `kioku` executable supplied by `KIOKU_UPGRADE_CLI` for read/help parity using the process pattern in `kioku-cli/test/Kioku/Cli/RecallEndToEndSpec.hs`; treat any CLI startup metadata writes as a separate measured phase. Normalize only documented volatile fields (generated event UUIDs, wall-clock timestamps, timer lease tokens); do not normalize content, space, principal, event types, tags, relative ordering, results or refusal classes.

`replay` inventories and fully audits all native `kioku_memory`/`kioku_session` streams using `Keiro.ReplayAudit.auditTargets AuditFull defaultAuditBudget`, `SomeAuditTarget`, and `streamInCategory` wired directly to `memoryEventStream`/`sessionEventStream`. These streams use `Never` snapshots and `stateCodec = Nothing`; the audit reports no state digest, and must not be described as a digest comparison. There is no DSL-generated replay catalog. Require every inventoried native stream accounted for, zero rejected/skipped native streams, and zero decode/stall failures. Record counts and explicit exclusions of foreign or framework streams; never silently skip unsupported native events. `read` and write parity remain separate because successful replay alone proves neither projected state nor future delivery.

`rebuild` uses `startCatalogRebuild kiokuProjectionCatalog` with `defaultRebuildOptions`, a unique `RebuildRequest` per run, `replayFrom = GlobalPosition 0`, and the actual `kioku-memory` and `kioku-session` groups. The catalog orders sessions before turns. Keep the runner's write fence/default refusal behavior. Rebuild on a separate disposable candidate restore twice, capturing before/run1/run2 rows and completion states. Do not run timer-scheduling command handlers during projection replay. The runner truncates declared targets: memory replay reconstructs event-derived columns but does not regenerate `embedding`, `embedding_model`, `dimensions`, or `content_hash`. Save those four enrichment fields with memory ID, space and content before reset; on the clone restore them only when all three identity/content fields still match. Fail on any mismatch. This is rehearsal-only preservation, not a new production rebuild capability. L1 watermarks, consolidation decisions, scenes and personas live outside the three targets and must remain untouched. Session `created_at`/`updated_at` are database-clock projection fields; explicitly exclude those from semantic replay comparison while checking event-derived timestamps unchanged. Require event-derived rows to match baseline, full rows after declared enrichment restoration to agree between run1/run2, and authoritative events, timers, subscriptions and all non-target rows unchanged. A failure remains a rebuild-parity failure; do not waive it as expected enrichment loss. No rebuild is needed during the production dependency cutover.

`delivery` reuses the actual embedding processor with deterministic provider callbacks and the timer-worker test seam. Append a dedicated fixture event, observe stored embedding and checkpoint, restart and deliver a second event; require an effect, not merely a started process. Exercise a due timer and observe its final status. Isolate the fixture subscription name and provider/workspace effects. Follow existing refusal/retry/graceful shutdown tests instead of introducing queue infrastructure.

Build the same probe source against old and candidate libraries in separate build directories/worktrees; retain its hash with each binary/library identity. Run old reads and writes on the old restore, candidate equivalents on a twin restore of the same archive after migration. For the old probe, use only APIs present in both releases; candidate-only audit/rebuild behavior can be kept behind a separate module/mode if compilation requires it. Record old-linked probe provenance explicitly; it is test instrumentation, not the old shipping CLI. Keep the old shipping CLI identified separately.

Write the final acceptance record with archive hash/source time, database identities/major, source and candidate commits, old/candidate library and CLI identities, migration-runner identity, exact plan/allowance, protected-row comparisons, replay denominator, rebuild classification, command parity and observed delivery. Update `docs/user/upgrading-to-keiro-0-22.md` with the operator sequence below. M4 passes only with actual restore evidence; lack of an archive remains a named prerequisite.


## Concrete Steps


All project commands run from the repository root. Commands in this section describe implementation, not work performed while creating this document. New probe/report interfaces are to be implemented in M4; other named paths and commands already exist.

Freeze the comparison identity and retain baseline evidence before edits:

```bash
cd /Users/shinzui/Keikaku/bokuno/kioku
export KIOKU_BASELINE=9cd613d5087a08d6625cb266ff09845197b1d3d4
export KIOKU_EVIDENCE="$PWD/.dev/keiro-0.22"
mkdir -p "$KIOKU_EVIDENCE/baseline"
git status --short
git show "$KIOKU_BASELINE:cabal.project" > "$KIOKU_EVIDENCE/baseline/cabal.project"
cp dist-newstyle/cache/plan.json "$KIOKU_EVIDENCE/baseline/cached-plan.json"
git worktree add --detach "$KIOKU_EVIDENCE/baseline/source" "$KIOKU_BASELINE"
```

No feature branch is needed. Build/retain old CLI and migration runner from that detached worktree before changing bounds, using its shell and task-specific build directory. Copy the `cabal list-bin` results to stable evidence paths; do not retain only mutable `dist-newstyle` symlinks. Record SHA256 hashes and the build plan. Do not replace old artifacts with candidate files on a rerun.

Refresh publication evidence without changing the target:

```bash
mori registry list
mori registry search keiro
mori registry search kiroku
mori registry search shibuya
mori registry search pgmq
mori registry show shinzui/keiro --full
mori registry docs shinzui/keiro
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
mori registry show shinzui/seihou-modules --full
curl -fsSL https://hackage.haskell.org/package/keiro.json
curl -fsSL https://hackage.haskell.org/package/kiroku-store.json
curl -fsSL https://hackage.haskell.org/package/shibuya-core.json
git ls-remote --tags https://github.com/shinzui/keiro.git 'refs/tags/*0.22.0.0*'
git ls-remote --tags https://github.com/shinzui/kiroku.git 'refs/tags/*0.12.0.0*' 'refs/tags/*0.7.2.0*' 'refs/tags/shibuya-kiroku-adapter-v0.7.0.0*'
seihou update nix-haskell-flake --dry-run --json --include-shared-owners
```

Repeat package JSON/Cabal/tag verification for every selected sibling in the dependency table and any changed AI/transitive release. Save concise evidence with the final report. Expected Keiro tags peel to the recorded commit; all consumed packages must be available, non-deprecated compatible releases. If Hackage revisions change bounds, record both archive and revised Cabal identity. The module preview should confirm 0.37.0 is already adopted at this baseline; no upgrade is needed unless a newer publication is verified. Never search `/nix/store` or filesystem root.

For source-aware solving, enter the existing shell and choose a **new empty** evidence store/build directory. Do not reuse a prior failed or installed-package plan as the fresh evidence:

```bash
nix develop -c bash
cabal update
export KIOKU_COMPILER="$(command -v ghc-9.12.4)"
"$KIOKU_COMPILER" --numeric-version
ghc-pkg list --global --simple-output
cabal --store-dir="$KIOKU_EVIDENCE/fresh-store" build all \
  --project-file=cabal.project --builddir="$KIOKU_EVIDENCE/fresh-build" \
  --with-compiler="$KIOKU_COMPILER" --package-db=clear --package-db=global \
  --constraint='keiro ==0.22.0.0' --constraint='keiro-core ==0.22.0.0' \
  --constraint='keiro-migrations ==0.22.0.0' --constraint='keiro-test-support ==0.22.0.0' \
  --enable-tests --ghc-options=-Werror --dry-run
cp "$KIOKU_EVIDENCE/fresh-build/cache/plan.json" "$KIOKU_EVIDENCE/fresh-plan.json"
jq -S '{compiler:."compiler-id",abi:."compiler-abi",os,arch,packages:[."install-plan"[] | {type,name:."pkg-name",version:."pkg-version",component:."component-name",source:."pkg-src",sourceHash:."pkg-src-sha256",cabalHash:."pkg-cabal-sha256",flags}]}' \
  "$KIOKU_EVIDENCE/fresh-plan.json" > "$KIOKU_EVIDENCE/source-identities.json"
```

Expected compiler is 9.12.4, Keiro's four consumed packages exactly 0.22.0.0, and the target dependencies above. Runtime rows must be `configured` with source/Cabal hashes, not unexplained pre-existing units. Optional PGMQ packages remain absent. Save the chosen Hackage index timestamp and generate an evidence freeze file for repeat solves; use the identical index/constraints for the archive consumer. Preserve relevant flags including Blake3/libpq and the local profiling workaround. A new store is necessary to rule out installed-package reuse; its initial solve need not compile the world.

Build and run the early integration check before broad tests:

```bash
nix develop -c cabal build all --enable-tests --ghc-options=-Werror
nix develop -c cabal test kioku-test \
  --test-options='-p /real adapter/' --test-show-details=direct
nix develop -c cabal test kioku-migrations-test --test-show-details=direct
nix develop -c cabal run kioku-migrate -- plan --json
```

Expect all real adapter tests to pass with pgvector available (no skipped delivery proof), and plan output to contain 63 entries including exactly one `kiroku/0016`, no PGMQ component, and the same 15 Kioku migrations.

Run focused and full checks, archive the packages, and verify the source-distribution consumer described in M3:

```bash
nix develop -c cabal test kioku-test \
  --test-options='-p /pre-upgrade event payloads still decode/||/ProjectionCatalog/||/Timer worker/' \
  --test-show-details=direct
nix develop -c cabal test all --enable-tests --test-show-details=direct
nix develop -c bash scripts/check-haskell-conventions.sh
nix develop -c bash -c 'for package_dir in kioku-api kioku-core kioku-cli kioku-migrations kioku-migrate; do (cd "$package_dir" && cabal check) || exit; done'
nix develop -c cabal sdist all --output-directory=.dev/keiro-0.22/sdist
seihou validate-blueprint blueprints/kioku-upgrade
nix fmt -- --ci
nix flake check --no-write-lock-file
git diff --check
```

Confirm Tasty's actual group names with `cabal test kioku-test --test-options=--list-tests` if a focused selector matches no tests; zero selected tests is not acceptance. The full suites have no such ambiguity. No test counts from earlier releases are acceptance expectations.

For the archive-only consumer, create `.dev/keiro-0.22/archive-consumer/cabal.project` by copying the candidate's `cabal.project`, replacing just its initial `packages:` block with the absolute paths of the five `.dev/keiro-0.22/sdist/*.tar.gz` archives. Copy the candidate's exact evidence freeze as that project's freeze file; adjust only the five local package entries if Cabal encodes their source locations. Retain all constraints, flags and compiler choice. Then run:

```bash
nix develop -c cabal build all --enable-tests \
  --project-file=.dev/keiro-0.22/archive-consumer/cabal.project \
  --builddir=.dev/keiro-0.22/archive-consumer/build
```

Expect all five archives to provide their components without source paths outside the archives. Inspect its `build/cache/plan.json` and compare every non-local source/Cabal hash and flag to the fresh candidate plan. A different runtime solve fails parity even when both builds pass.

After a clean candidate commit, build the **shipping** artifacts and generation-equivalent gate from the identified fresh plan/store. Use the same options as the solved plan, retaining the index/constraints; do not add ad hoc flags between solve and build:

```bash
test -z "$(git status --porcelain)"
git rev-parse HEAD > "$KIOKU_EVIDENCE/candidate-commit.txt"
cabal --store-dir="$KIOKU_EVIDENCE/fresh-store" build all \
  --project-file=cabal.project --builddir="$KIOKU_EVIDENCE/fresh-build" \
  --with-compiler="$KIOKU_COMPILER" --package-db=clear --package-db=global \
  --constraint='keiro ==0.22.0.0' --constraint='keiro-core ==0.22.0.0' \
  --constraint='keiro-migrations ==0.22.0.0' --constraint='keiro-test-support ==0.22.0.0' \
  --enable-tests --ghc-options=-Werror
cabal --store-dir="$KIOKU_EVIDENCE/fresh-store" test all \
  --builddir="$KIOKU_EVIDENCE/fresh-build" \
  --with-compiler="$KIOKU_COMPILER" --package-db=clear --package-db=global \
  --enable-tests --ghc-options=-Werror --test-show-details=direct
cabal list-bin kioku-cli:exe:kioku --builddir="$KIOKU_EVIDENCE/fresh-build"
cabal list-bin kioku-migrate:exe:kioku-migrate --builddir="$KIOKU_EVIDENCE/fresh-build"
git diff "$KIOKU_BASELINE" -- kioku-migrations/migrations kioku-migrations/migrations.lock
nix develop -c cabal build all --enable-tests --ghc-options=-Werror
test -z "$(git status --porcelain)"
```

Expect an empty historical-migration diff, all tests passing, both streams/catalog valid, and no generated tracked changes after the second build. Compare the post-build source identities to `fresh-plan.json` and retain the candidate binaries and SHA256s under distinct `shipping/kioku` and `migration-runner/kioku-migrate` paths. Repeat only when a relevant subsequent change invalidates this evidence. The full generation gate is this clean build/test/identity sequence, not an invented DSL command.

For M4, the operator must set explicit `KIOKU_ARCHIVE`, `KIOKU_OLD_URL`, `KIOKU_NEW_URL`, `KIOKU_REBUILD_URL`, `KIOKU_OLD_BIN`, `KIOKU_NEW_BIN`, and `KIOKU_MIGRATE_BIN`. URLs must identify dedicated disposable databases; rebuild may use a fresh recreation of the candidate twin after retaining the other evidence. Supply archive provenance and a known SHA256 separately, and verify it before restore:

```bash
shasum -a 256 "$KIOKU_ARCHIVE"
psql "$KIOKU_OLD_URL" -XAtc 'SELECT current_database(), current_user, inet_server_addr(), inet_server_port(), version()'
psql "$KIOKU_NEW_URL" -XAtc 'SELECT current_database(), current_user, inet_server_addr(), inet_server_port(), version()'
pg_restore --no-owner --no-privileges --exit-on-error --dbname="$KIOKU_OLD_URL" "$KIOKU_ARCHIVE"
pg_restore --no-owner --no-privileges --exit-on-error --dbname="$KIOKU_NEW_URL" "$KIOKU_ARCHIVE"
"$KIOKU_MIGRATE_BIN" plan --json > "$KIOKU_EVIDENCE/candidate-migration-plan.json"
DATABASE_URL="$KIOKU_NEW_URL" "$KIOKU_MIGRATE_BIN" status --json
```

Use empty operator-designated scratch databases; do not use `pg_restore --clean` against an arbitrary URL. Refuse identical old/new identities. `--no-owner --no-privileges` means ownership/grant equivalence is not proved by this data restore; record source roles/grants separately and validate them under a deployment-equivalent role before cutover. Match PostgreSQL major and extension versions; do not silently use a schema-only dump.

Before `up`, save the source ledger, full schema-only dump, all protected table snapshots, subscriptions/checkpoint values, catalog/query metadata, read results, and schema comment/constraint definitions. The **exact allowance** for an already-current 0.21 source is one ledger addition `kiroku/0016`, replacement definitions of `kiroku.subscriptions.subscriptions_target_kind_check` and `kiroku.subscriptions.subscriptions_check`, and the Kiroku schema comment through 0016. New tables, event data, subscription target values/positions, existing ledger checksums, Kioku schema and catalog/query identities are not allowed to change. If the archive is behind 62 entries, classify it and enumerate the full reviewed missing migration IDs/effects before proceeding; do not reuse this one-migration allowance. Do not automatically learn allowances from a failed diff.

The existing runner has no `ALLOW_*` environment switches or clone wrapper. Implement these comparisons in the small probe/report workflow; do not pretend Rei's allowance variables apply. An unexpected change must exit nonzero and retain the evidence. Reconciliation from `up` should be a no-op for a valid 0.21 database; any registry repair needs a separately explained, exact allowance.

```bash
KIOKU_UPGRADE_CLI="$KIOKU_OLD_BIN" nix develop "$KIOKU_EVIDENCE/baseline/source" -c cabal exec \
  --project-file="$KIOKU_EVIDENCE/baseline/source/cabal.project" -- \
  runghc "$PWD/scripts/kioku-upgrade-probe.hs" read "$KIOKU_OLD_URL" "$KIOKU_EVIDENCE/old-read"
nix develop -c cabal exec -- runghc scripts/kioku-upgrade-probe.hs \
  read "$KIOKU_NEW_URL" "$KIOKU_EVIDENCE/candidate-before"
DATABASE_URL="$KIOKU_NEW_URL" "$KIOKU_MIGRATE_BIN" up
DATABASE_URL="$KIOKU_NEW_URL" "$KIOKU_MIGRATE_BIN" verify --json
DATABASE_URL="$KIOKU_NEW_URL" "$KIOKU_MIGRATE_BIN" up
nix develop -c cabal exec -- runghc scripts/kioku-upgrade-probe.hs \
  read "$KIOKU_NEW_URL" "$KIOKU_EVIDENCE/candidate-after"
nix develop -c cabal exec -- runghc scripts/kioku-upgrade-probe.hs \
  replay "$KIOKU_NEW_URL" "$KIOKU_EVIDENCE/replay"
```

Expected: first `up` applies only 0016, verification has no issues/pending/unknown entries, second `up` changes nothing, replay accounts for every native stream, and delivery proves effects/checkpoints after restart. Compare the old/before/after reports using exactly the reviewed migration allowance. Set `KIOKU_UPGRADE_CLI` for each read invocation that exercises CLI parity. The old-linked invocation must select only the baseline project; inspect its plan rather than relying on the shell's working directory. Compile and retain the probe executables for the final run so each report names the exact linked library solution.

Run paired `write` modes before `delivery`, so unrelated delivery fixture events do not enter the command comparison, and use the same old-linked invocation above for the old database:

```bash
KIOKU_UPGRADE_DISPOSABLE=1 KIOKU_UPGRADE_CLI="$KIOKU_NEW_BIN" \
  nix develop -c cabal exec -- runghc scripts/kioku-upgrade-probe.hs \
  write "$KIOKU_NEW_URL" "$KIOKU_EVIDENCE/new-write"
KIOKU_UPGRADE_DISPOSABLE=1 nix develop -c cabal exec -- runghc scripts/kioku-upgrade-probe.hs \
  delivery "$KIOKU_NEW_URL" "$KIOKU_EVIDENCE/delivery"
KIOKU_UPGRADE_DISPOSABLE=1 nix develop -c cabal exec -- runghc scripts/kioku-upgrade-probe.hs \
  rebuild "$KIOKU_REBUILD_URL" "$KIOKU_EVIDENCE/rebuild-1"
KIOKU_UPGRADE_DISPOSABLE=1 nix develop -c cabal exec -- runghc scripts/kioku-upgrade-probe.hs \
  rebuild "$KIOKU_REBUILD_URL" "$KIOKU_EVIDENCE/rebuild-2"
```

The rebuild URL must first receive a fresh restore and the same identified migration runner. Require `commands.json` equality after the declared normalization, two successful rebuild reports with distinct run IDs, and the preservation results defined in M4. Probe modes exit nonzero on any failed invariant and print counts plus report paths on success. Pin final invocations to retained binaries/libraries rather than mutable `cabal run` output.


## Validation and Acceptance


M1 is independently verifiable through the fresh source-bearing solution and the existing real adapter tests. M2 is independently verifiable through the migration suite, exact plan delta, unchanged historical checksums and idempotent rerun. M3 is independently verifiable through a clean source commit, unchanged event fixtures/catalog bindings, passing full suites/conventions/Nix checks, identified shipping artifacts and an archive-only external library build. M4 is independently verifiable through the checksummed actual restore, explicit schema/ledger allowances, live native replay, explained deterministic rebuild results, public command/read parity and observed embedding/timer delivery.

Successful acceptance preserves exact-category filtering, native old payload parsing, marked historical principals, rejection of foreign event vocabulary, aggregate/read memory-space isolation, transactional event/projection/timer writes, deferred claims, host-owned AI capability policy, CLI help/completion behavior, FTS-only degradation, worker retry/fatal exit semantics, and public migration composition. Namespace targets, DSL candidate features, PGMQ partition delivery, new ops/HTTP/WebSocket endpoints and retained-runtime adoption are explicitly inapplicable or out of scope, not missing test coverage to add.

Acceptance evidence must distinguish commands actually run, facts observed in source, operational prerequisites, and unresolved limitations. Mark no skipped pgvector lane, absent restored archive, unexplained enrichment loss or source-less installed unit as passing. Record native architecture coverage honestly; a Darwin flake check does not prove Linux execution. Keep production activation pending even after all candidate checks pass.


## Idempotence and Recovery


Inspection, source solves, baseline comparisons and verification can be repeated. Use fresh task-specific solve directories and preserve immutable old/candidate evidence; never delete the user's ordinary Cabal store. Historical migration payloads, lock files, old fixtures and recorded checksums are immutable. Do not repair a ledger, reset a subscription, weaken schema validation or enable schema drift merely to make tests pass. Failed disposable rehearsals retain reports and restart from the same archive in a newly designated empty scratch database.

The operator runbook must inventory the actual CLI, continuous worker and every embedded host using Kioku libraries (discover dependents with `mori registry dependents shinzui/kioku --packages`, then inspect actual deployments). Record the command/supervisor for each; package dependency bounds alone do not establish which process is running. Before activation, verify backup restoration, artifact hashes and the exact migration allowance. Stop affected workers and pause affected writers/embedded hosts. Apply the retained `kioku-migrate up`, verify ledger/live schema and no-op reconciliation, start new Store 0.12-linked hosts, then resume traffic and observe embedding/timer delivery through the real supervisor. Keep namespace subscriptions disabled. No automatic production migration is part of implementation.

Before new writes, recovery may restore the tested pre-cutover archive and old identified artifacts after assessing the downtime/data boundary. After new writes, source rollback alone may lose state or mismanage newer bindings; prefer forward repair or an explicitly reviewed restore with a known write-loss boundary. Older Store binaries must never manage `category_namespace` bindings. No down migration, direct checkpoint rebinding, queue clearing, or ledger rewrite is prescribed. Because this upgrade does not enable namespaces, record their absence as evidence rather than assuming downgrade safety.

Commit implementation directly on the current branch at cohesive boundaries using Conventional Commits and these trailers:

```text
ExecPlan: docs/plans/51-upgrade-kioku-to-keiro-0-22-and-compatible-released-runtime-dependencies.md
Intention: intention_01m6089f0dedgaz72h7ke6cg80
```


## Interfaces and Dependencies


Kioku owns its five package recipes, public Haskell APIs, handwritten event codecs/transducers, projection catalog, schema migrations, worker behavior, and host authorization/AI boundaries. Keiro 0.22 owns command/replay/projection/timer APIs; Kiroku 0.12 owns subscriptions and migration 0016; Shibuya 0.12 owns delivery admission and application defaults. Consume released packages, preserve defaults, and avoid local forks or new `allow-newer` workarounds.

The developer-only probe must call live `Kioku.Memory`, `Kioku.Session`, `Kioku.ProjectionCatalog`, `Kioku.ReadModel`, embedding and timer implementations. Upstream audit and rebuild APIs were located through Mori in `mori://shinzui/keiro` (project-relative `keiro/src/Keiro/ReplayAudit.hs` and `keiro/src/Keiro/ReadModel/Rebuild/{Group,Runner}.hs`; artifact-level source URIs pending). `startCatalogRebuild` accepts the validated catalog, group ID and options and returns a typed error or run report. Use defaults and explicit unique run IDs; preserve failure details. Do not copy transducers, projection SQL or timer scheduling into the probe.

There is no shared-runtime application scope or Nix library export to align here. Preserve that absence while aligning the existing bare shell, Cabal solution, shipping CLI/migration binaries, five library source distributions and downstream upgrade guidance. If later implementation evidence requires a broader architecture, revise this plan with the reason before adopting it.
