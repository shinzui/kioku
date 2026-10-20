---
id: 50
slug: expose-legacy-archive-change-receipts-without-inventing-principals
title: "Expose legacy archive change receipts without inventing principals"
kind: exec-plan
created_at: 2026-10-19T23:33:45Z
intention: "intention_01m5b89rmzey4vy07z7ypf4az4"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-19T23:33:45Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-20T00:20:10Z
      mode: "implement"
      note: "Implement the legacy archive receipt bridge, database acceptance tests and migration contract."
---

# Expose legacy archive change receipts without inventing principals

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Let an existing legacy-space host learn whether its archive command appended a fact without inventing an actor to obtain an authorization context. Expose `Kioku.Memory.archiveLegacyChanged`, a deprecated, explicitly legacy-only compatibility bridge returning the same `(MemoryId, Bool)` receipt as `archiveWithContextChanged`. A receipt describes this command's append: the first archive returns `True`, an accepted repeat returns `False`, and two competing successful archives produce exactly one `True`.

This implements the validated scope of [IR-7](../improvement-requests/expose-archive-change-receipts-without-inventing-legacy-principals.md). It preserves the existing attribution, partition, error and command execution rules. The long-term API remains context-first and requires a genuinely vouched-for actor. The user authorized implementation on 2026-10-19; publication follows the repository release workflow after the local candidate is reviewable. Full IR acceptance includes publication before consumer adoption.


## Progress


- [x] Milestone 1 (2026-10-20): The public legacy bridge returns authoritative first/repeat receipts and preserves unattributed event payloads. The real PostgreSQL first/repeat test passed, checking exactly one archive, its original timestamp and serialized `kioku:unattributed` actor marker.
- [x] Milestone 2 (2026-10-20): All seven `Archive receipts` PostgreSQL tests passed. Synchronized legacy/legacy and legacy/context races each returned exactly one `True`, whose actor and timestamp matched the sole durable archive. Foreign active/archived IDs, context gates on active/archived rows, missing/terminal errors and compatibility attribution/ID parity passed without rejected writes changing streams or rows. Full regression acceptance is recorded with Milestone 3.
- [x] Milestone 3 (2026-10-20): Migration examples in all three user guides, ADR-1/ADR-5 clarifications and release notes are complete. `nix develop -c cabal build all` and `nix develop -c cabal test all --test-show-details=direct` passed: API 125, migrations 32, core 275, CLI 64 (496 total). `nix flake check`, all five `cabal check` invocations, the formatter, Haskell conventions and whitespace checks passed. Source distributions were checked for the public bridge contract and all migration SQL/manifest files. Release version selection and publication were subsequently completed in Milestone 4.
- [x] Milestone 4 (2026-10-20): Published the combined 0.11.0.0 five-package release and four library documentation archives, with the immutable tag, GitHub release, migration guidance and downloaded-source verification recorded below. IR-7 acceptance 5 is complete; no consumer source was modified.


## Surprises & Discoveries


2026-10-20: Cabal splits the original unquoted multiword Tasty patterns, causing a pattern-parse failure before tests run. Quote the pattern inside `--test-options`; the corrected unchanged baseline passed all 15 bounded-facade tests. The concrete commands below now use that quoting.

2026-10-20: The workspace initially contained staged 0.11.0.0 release preparation from ExecPlan 49, and another session committed it as `3c1c9d0` during implementation. Preserve that release and recheck upstream tags/Hackage before selecting this additive bridge's release version; do not amend a release tag or its source archive.


## Decision Log


2026-10-20: The user authorized publishing both plans together. Registry/tag preflight confirms 0.11.0.0 is unclaimed; resume that prepared version, retaining `3c1c9d0` and including the receipt bridge from `f39fe76`. Merge its Unreleased notes into the existing release notes and extend the unpublished upgrade edge. Regenerate source and documentation archives before publication. The major PVP bump is required by EP-49's exported `MemoryFilter` change and also admits EP-50's additive export.

2026-10-20: Keep this implementation's notes under Unreleased while ExecPlan 49's 0.11.0.0 release is in flight. Do not alter its version preparation or reserve a competing release. Finish all local implementation checks first; select the published bridge version with the release owner once that release state is settled. This moves final cohort version selection to Milestone 4 while retaining Milestone 3's tested source candidate and migration documentation.

2026-10-19: Accept IR-7 as receipt parity for the existing legacy compatibility contract. Name the entry point `archiveLegacyChanged` and deprecate it from introduction, with removal coupled to `archive`. A permanent unattributed context constructor would contradict ADR-5; a bridge over the already-admitted write exposes information without broadening who or which space the operation accepts. Support means a documented, tested, published migration bridge, not an indefinite compatibility promise.

2026-10-19: Reuse `inLegacySpaceOnly` and `archiveInChanged` without changing `ArchiveMemoryData`, `MemoryAccessContext`, event codecs, schema, catalog or dependency bounds. Keep receipt calculation at `runMemoryCommandChanged`, where the committed command result is available. A host-side before/after comparison cannot assign append ownership during races.

2026-10-19: Preserve all `RecordedPrincipal` values accepted by the old wrapper verbatim, including `UnattributedPrincipal`; do not add a new identity restriction to this receipt-only entry point. Do not reinterpret these values as authorization. New context-first writes still require `KnownPrincipal` matching the host's context. The bridge is only for hosts already using the legacy contract, and is not a way to expose anonymous writes to arbitrary spaces.


## Outcomes & Retrospective


2026-10-20: Local implementation is complete. `archiveLegacyChanged` is one guarded call to the existing receipt worker, so it preserves the old wrapper's attribution and refusal semantics without introducing a context, actor, schema, codec or dependency change. Seven new database tests establish first/repeat behavior, serialized unattributed payloads, append ownership in synchronized legacy/legacy and mixed races, partition/context gates, terminal errors and compatibility parity. The unchanged context-first race and all regression suites pass. ADRs 1 and 5 retain the durable boundary and finite lifecycle.

The complete local checks passed on GHC 9.12.4: 496 tests across all four suites, build, Nix flake checks, five package checks, formatting, Haskell conventions and whitespace. `cabal sdist all --output-directory=/tmp/kioku-plan50-sdist` generated isolated validation archives at the working tree's existing 0.11.0.0 version; inspection confirmed the core export/deprecation/Haddock/shared-worker call/test module and the migrations archive's 15 SQL files plus manifest. Those local test artifacts preceded publication; the independently downloaded published sources are verified below.

Strict IR validation still fails only on the same five older requests' missing recommended `reviews` fields listed in Concrete Steps. IR-7 has no diagnostics and its bundle log is current. IR-7 is now `completed`: the user authorized the combined release, and publication, immutable tag and published-source verification are complete. No consumer source was modified.


Published on 2026-10-20 UTC: [Kioku v0.11.0.0](https://github.com/shinzui/kioku/releases/tag/v0.11.0.0), release commit `1375927d81eda88e3411758c62251f5117916b1f`, annotated tag object `5b5f4d3ae99d623e760c96375303a6a732beb5f1`. All five packages are published: [kioku-api](https://hackage.haskell.org/package/kioku-api-0.11.0.0), [kioku-migrations](https://hackage.haskell.org/package/kioku-migrations-0.11.0.0), [kioku-core](https://hackage.haskell.org/package/kioku-core-0.11.0.0), [kioku-cli](https://hackage.haskell.org/package/kioku-cli-0.11.0.0), [kioku-migrate](https://hackage.haskell.org/package/kioku-migrate-0.11.0.0). All four library documentation archives are published and their module pages are reachable; `kioku-migrate` has no library documentation.

Downloaded all five Hackage source archives and matched their SHA-256 digests to the verified upload artifacts. The published core archive has SHA-256 `0f63e1fdbf59511631ab52e849b1b2209a8da5945f4779bdc18135a680c337ac`; its facade exports all four fixed Memory inspection operations and `archiveLegacyChanged`, including the deprecation/Haddock contract and the unchanged guarded `archiveInChanged` call. Published Haddock exposes these APIs too. The source archives match the tagged package files, and the migrations archive includes all fifteen SQL files and the manifest. The release notes and 0.10.0.0-to-0.11.0.0 upgrade edge cover both plans. Consumer adoption remains downstream work and can now use the published API.


## Context and Orientation


Kioku is a reusable Haskell memory library. A Memory is an event-backed object: commands produce facts in a stream, and projections maintain queryable rows from those facts. A memory space is the explicit partition isolating one collection from another; `legacyMemorySpaceId` names the single `kioku_legacy` partition. A principal is a host-vouched-for identity, not a free-text process label. `UnattributedPrincipal` records that the existing attribution contract supplied no actor.

Validation on 2026-10-19 found the reported gap in the working tree at commit `469dfc4`. Hackage's `https://hackage.haskell.org/package/kioku-core.json` lists 0.10.0.0 as the highest released version, and the upstream `v0.10.0.0` tag peels to `5f4afc872b09d615d1bb8c78369d6912161c550f`. The [release record](https://github.com/shinzui/kioku/releases/tag/v0.10.0.0) identifies the same package cohort. This plan selects no new dependency bounds or compatibility workaround.

`kioku-core/src/Kioku/Memory.hs` is the public facade. `archive` gates the payload with `inLegacySpaceOnly`, calls `archiveIn`, and returns only the ID. `archiveIn` discards the flag from `archiveInChanged`. The public `archiveWithContextChanged` calls that same private worker after `underContext` requires `MemoryForget`, matching memory space and matching actor. `archiveInChanged` looks up the Memory in the requested space, returns `MemoryNotFound` for absence, accepts an already-archived row as `(id, False)`, and returns `MemoryConflict` for an incompatible terminal status. Call-time timestamps are intentionally ignored when accepting repeats. A command rejected during a race is accepted as `False` only if a subsequent scoped lookup confirms the matching archived result; other failures remain failures.

`runMemoryCommandChanged` calls `runCommandWithProjections` and derives `changed` from `receipt.eventsAppended > 0`. The owner is `mori://shinzui/keiro/packages/keiro`; the inspected source is project-relative `keiro/src/Keiro/Projection.hs` and `keiro/src/Keiro/Command.hs` under `mori://shinzui/keiro` (source-artifact URIs pending). The existing API applies inline projections in the append transaction and reports the committed command's event count. No dependency API redesign is necessary. `kioku-core/src/Kioku/Memory/Domain.hs` checks the command's space against aggregate state and copies its actor into `MemoryArchivedData`; this guard survives a concurrency retry. `kioku-core/src/Kioku/Memory/EventStream.hs` owns canonical event decoding.

`kioku-api/src/Kioku/Api/Access.hs` exports the authorization and legacy-space gates; `kioku-api/src/Kioku/Api/Access/Internal.hs` implements them. Contexts can only carry a `MemoryActor` wrapping a `PrincipalRef`, so `memoryContextRecordedActor` produces `KnownPrincipal`. A fake actor would therefore alter the recorded claim, not merely satisfy a type signature.

The relevant ADRs were read. [ADR-1](../adr/kioku-owns-memory-not-identity.md) keeps identity and authorization decisions in the host, while Kioku checks the supplied decision. [ADR-3](../adr/legacy-data-lands-in-one-explicit-space.md) makes the legacy space explicit and never a wildcard. [ADR-4](../adr/the-aggregate-enforces-the-partition.md) requires the state machine's partition guard as well as scoped facade reads. [ADR-5](../adr/historical-attribution-is-marked-never-invented.md) preserves historical attribution and explicitly rejects allowing historical principal markers through new contexts; it acknowledges that deprecated wrappers still admit them temporarily. This plan needs a narrow clarification of that compatibility exception, not reversal of the permanent context contract. [ADR-14](../adr/haskell-and-cli-conventions-are-executable-contracts.md) supplies the GHC 9.12/GHC2024 and source-convention baseline. No profiled `docs/adr` bundle is declared by the current `mori.dhall`; preserve the existing ADR format and stable IDs when amending it, and recheck that contract before implementation writes.

The consumer is `mori://shinzui/rei/plans/255-expose-agent-execution-sessions-memory-schedules-and-review-workflows`. In `mori://shinzui/rei`, project-relative `rei-core/src/Rei/Modules/Agent/Memory/KiokuAdapter.hs` sets `reiMemorySpace = legacyMemorySpaceId` and maps archive commands to `UnattributedPrincipal`; `rei-core/src/Rei/Modules/Agent/Memory/StoreHandler.hs` calls the ID-only wrapper (source-artifact URIs pending). These source claims were inspected through the Mori-discovered checkout. Mori did not yet resolve the new consumer plan handle; retain its canonical URI. Rei owns its credentials, request authorization, response shape and eventual identity migration. This plan adds no Rei-specific terminology, identity service or HTTP route to Kioku.

`kioku-core/test/Kioku/BoundedReadSpec.hs` already proves first/repeat and concurrent context-first receipts. `kioku-core/test/Kioku/MemorySpaceSpec.hs` shows real stream inspection and space/actor gate tests. `kioku-core/test/Kioku/IdempotencySpec.hs` proves terminal conflicts without extra events. `kioku-core/test/Kioku/CodecCompatSpec.hs` verifies old attribution decoding. Their PostgreSQL fixture is `kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs`, used with `withNoopAppEnv` and `runAppIO`; the Nix shell supplies PostgreSQL and pgvector. No production database or model provider is required.


## Plan of Work


### Milestone 1: Expose and exercise the shared receipt path


Add `archiveLegacyChanged` to the compatibility export group in `kioku-core/src/Kioku/Memory.hs`. Implement it by passing `cmdData.memorySpaceId` and `archiveInChanged cmdData` to `inLegacySpaceOnly`. Mark it deprecated immediately, directing consumers with real host-vouched-for actors to `archiveWithContextChanged`. Its Haddock must state that it does no authentication or authorization, accepts only the explicit legacy space, preserves the supplied attribution, and is removed with `archive`. Retain `archive` and `archiveWithContext` signatures and behavior; there is no need to route them through a newly deprecated public function or duplicate the internal logic.

Create `kioku-core/test/Kioku/ArchiveReceiptSpec.hs`, register it in `kioku-core/test/Main.hs` and `kioku-core/kioku-core.cabal`, and name its Tasty group `Archive receipts`. Exercise the public function through the real migrated database. Create a legacy-space Memory using the existing record fixture pattern; archive it with `UnattributedPrincipal`, then repeat with a later `archivedAt`. Assert `(id, True)` followed by `(id, False)`. Inspect the canonical stream through `readStreamForward` and `parseMemoryEvent`, as in `MemorySpaceSpec`, and prove exactly one archive event, its original timestamp and unchanged `UnattributedPrincipal`. Check its serialized payload carries the existing `kioku:unattributed` marker; no invented `KnownPrincipal` may appear in that archive payload. Test inspection of owner events is permitted; application code must not inspect streams to manufacture receipts.

This representative public producer/consumer roundtrip is the first acceptance gate, before expanding edge cases. A compile-only wrapper test is insufficient. Keep any deprecation-warning suppression confined to the compatibility test module, following the existing `MemorySpaceSpec` pattern; do not disable warnings across the package.


### Milestone 2: Prove races, refusal semantics and attribution parity


Extend `kioku-core/test/Kioku/ArchiveReceiptSpec.hs` with two concurrent calls sharing one real app environment and a fresh active Memory. Use the existing `concurrently` fixture pattern, coordinate the workers' start, and assert both returned IDs, sorted flags `[False, True]`, and exactly one durable `MemoryArchived` event. Compare the event actor and timestamp to the command whose receipt was `True`. Run the scenario for two legacy calls, and for one legacy call racing a context-first call authorized for the same legacy space. The latter proves both entry points use the same append owner even though their attribution differs. Preserve the existing context-first race test. Do not replace storage with a mock or infer the flag from event counts; event counts are independent test evidence only.

Prove that `archiveLegacyChanged` refuses a payload naming another space as `MemorySpaceMismatch requested legacyMemorySpaceId`. Separately, send a foreign-space Memory ID with a legacy-space payload and expect `MemoryNotFound`, identically to a missing ID. In each case assert no event was added and the existing row is unchanged. Test an existing archived foreign ID too, so the idempotent path cannot disclose it as a successful no-op.

For `archiveWithContextChanged`, test missing `MemoryForget`, payload/context space mismatch and payload/context actor mismatch, including an `UnattributedPrincipal` payload under a known-actor context. Expect the exact `MemoryNotPermitted`, `MemorySpaceMismatch` and `MemoryActorMismatch` constructors, with no appended event. Repeat a gate case against an already-archived Memory to prove the gate cannot be bypassed by idempotence. Use the existing narrow-context fixture pattern; do not loosen context construction in production.

Cover a missing legacy Memory and Memories already superseded and merged, constructing the terminal states through existing public commands. Expect `MemoryNotFound` or `MemoryConflict` respectively, preserving the status mismatch message and no-write behavior. Match the old wrapper's errors on equivalent fixtures. Test `KnownPrincipal` and `LegacyPrincipal` payload preservation as compatibility parity as well as the required unattributed case; successful repeats must never rewrite the original event actor or timestamp. Verify the existing ID-only wrappers still return the same IDs. Preserve propagation of read/store/command failures: do not add catch-all conversion of `Left` or an effect-level store error into `(id, False)`.

Acceptance is the passing `Archive receipts` group plus the existing bounded-read, space-isolation, idempotency and codec tests. Concurrent success is a tested two-request scenario using the existing retry policy, not a new guarantee of unlimited retries or success during arbitrary infrastructure failures.


### Milestone 3: Document a finite migration bridge and prepare the release


Update `docs/user/library-api.md`, `docs/user/bounded-reads.md` and `docs/user/upgrading-to-memory-spaces.md`. Show the exact replacement of legacy `archive payload` with `archiveLegacyChanged payload`, how to consume the pair, and how to leave the payload's attribution unchanged. Explain that `False` means this command appended no archive fact and is an accepted repeat, not a swallowed refusal. The bridge supplies no new request authorization; a host must keep its existing trusted boundary. New hosts and identity-migrated hosts use `archiveWithContextChanged` with a real actor and the existing permission checks. Being directory-less does not forbid a host-vouched-for stable principal, but substituting a process label solely to make this call type-check is not a migration.

Document the lifecycle explicitly: the bridge is deprecated from introduction, lives only with `archive`, and its eventual removal is a separately announced breaking change after affected consumers have a real context-based migration. Do not promise an unverified calendar date or claim this work retires legacy attribution. A permanent forward-unattributed API remains out of scope. Amend `docs/adr/historical-attribution-is-marked-never-invented.md` and, where necessary, `docs/adr/kioku-owns-memory-not-identity.md` to name this narrow receipt-parity exception and retain the rejection of historical-marker contexts. Update the comment on the local legacy gate if it needs to describe both deprecated paths. Distill only this durable boundary, not execution notes.

Add release notes to `CHANGELOG.md` and `kioku-core/CHANGELOG.md`, with any cohort changelogs required by the repository release workflow. The added export alone is an additive API change. The user authorized combining it with EP-49 in the already prepared 0.11.0.0 major release; its notes are now in that version section, and the unpublished upgrade edge was extended before tagging. Coordinate with [ExecPlan 49](49-expose-fixed-memory-metadata-tag-pages-and-recency-queries.md), which also edits `Kioku.Memory` and requires the major 0.11.0.0 release. This plan has no implementation dependency on its read APIs and must not reserve or overwrite its release version. Run the build, regression and convention commands below. Local source and migration-documentation acceptance is complete, followed by verified publication under Milestone 4.


### Milestone 4: Publish and record consumer-ready evidence


When release work is authorized, use the repository's `agents/skills/release/SKILL.md` workflow for the coherent five-package release, version selection, source-distribution checks, changelogs, tags and Hackage uploads. Recheck current Hackage versions and upstream tags immediately before selecting a version. Follow the release workflow's upgrade-guidance requirements, recording this additive facade and lack of schema/catalog migration. Do not choose a new dependency cohort merely for this wrapper.

Verify the published `kioku-core` source archive exports `archiveLegacyChanged`, contains the deprecation/Haddock contract and preserves the shared worker call. Record the actual release version, tag, commit and package URLs here and in IR-7's resolution, then mark implementation/release acceptance complete. The consumer adoption contract is the published API; a local source override does not satisfy it. Do not modify or publish the Rei consumer as part of this plan. If publication has not happened, leave this milestone and IR-7 completion open even when local tests pass.


## Concrete Steps


Run from the repository root (the directory containing `cabal.project` and `flake.nix`). Before edits, check for concurrent work and inspect the existing receipt baseline:

```bash
git status --short
rg -n 'archiveWithContextChanged|archiveInChanged|runMemoryCommandChanged' kioku-core/src/Kioku/Memory.hs
nix develop -c cabal test kioku-core:kioku-test --test-show-details=direct --test-options='-p "/Bounded facade/"'
```

The baseline group must pass. After Milestone 1, the new export must compile and the first/repeat test must pass; before the implementation the new test fails to compile because that export is absent. After Milestone 2 run:

```bash
nix develop -c cabal test kioku-core:kioku-test --test-show-details=direct --test-options='-p "/Archive receipts/"'
nix develop -c cabal test kioku-core:kioku-test kioku-api:kioku-api-test --test-show-details=direct
```

Expect `All ... tests passed` for each suite, including exactly one appending command in each race and typed refusals without appended facts. The fixture creates disposable PostgreSQL databases and supplies its own migrations. Do not point it at a host's production database or use the development database creation recipe as a prerequisite. If PostgreSQL/pgvector startup fails, fix the shell/fixture environment; do not skip database assertions or count a skipped test as acceptance.

For the locally complete change, run:

```bash
nix develop -c cabal build all
nix develop -c cabal test all --test-show-details=direct
bash scripts/check-haskell-conventions.sh
git diff --check
```

Use the repository formatter for changed Haskell/Cabal files. Expect a successful build, all test suites passing, `Haskell convention checks passed.`, and no whitespace diagnostics. The full-suite command subsumes the focused suites on an unchanged candidate; rerun them only after changes invalidate their evidence.

Validate IR updates and their log using:

```bash
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
```

At plan creation this command already failed solely for missing recommended `reviews` fields in the five older requests `add-an-authenticated-http-service`, `add-indexed-session-and-bounded-memory-read-models`, `add-versioned-learned-skills`, `publish-typescript-and-python-sdks` and `release-kioku-for-keiki-0-4-and-keiro-0-4`. Record any remaining baseline failure separately; require no new diagnostics for IR-7 and a current bundle log. Do not silently repair or invent reviews for unrelated documents.

Record provenance for later plan edits with `agents/skills/exec-plan/record-provenance.ts` following `PROVENANCE.md`. Implementation commits must use Conventional Commits and carry `ExecPlan: docs/plans/50-expose-legacy-archive-change-receipts-without-inventing-principals.md` and the active frontmatter Intention ID.


## Validation and Acceptance


IR acceptance 1 is satisfied by public-facade PostgreSQL tests for first archive, repeat and concurrent calls, with independent durable-event evidence. For a fresh active Memory `m`, the first result is `Right (m, True)`, the repeat is `Right (m, False)`, and two successful racers return the same ID with flags `[False, True]`. Mixed legacy/context calls obey the same rule. There is one archive fact and it belongs to the command reporting `True`.

IR acceptance 2 requires that the emitted archive payload remains `UnattributedPrincipal` when that is what the legacy command carried. The timestamp and actor remain unchanged on repeats. No `MemoryActor`, fabricated `PrincipalRef`, new context constructor, codec default or identity-service dependency may be introduced to satisfy the call.

IR acceptance 3 and 4 require both layers of isolation and precise typed outcomes. A non-legacy payload is refused by the legacy gate; a foreign ID hidden behind a legacy payload is absent; context-first checks run before work even on repeats. A missing ID fails and superseded/merged Memories conflict. None becomes `Right (_, False)`, and no rejected operation adds an event. Existing ID-only APIs retain their signatures and behavior. Existing storage failures remain visible through their original channels.

IR acceptance 5 is satisfied by Milestone 4's published 0.11.0.0 release containing the API and migration notes. This is independent of whether the consumer has already adopted it. Documentation-only planning validation is not evidence of implementation tests passing. No extra HTTP endpoint, read resource, schema change, general command-receipt type or permanent unattributed-write facility is required.


## Idempotence and Recovery


The operation remains idempotent: once archived, repeating it succeeds without another fact and reports `False`, including a changed call-time timestamp. The shared state machine, scoped lookup and append receipt remain the authority. Tests use fresh Memory IDs and disposable databases, so rerunning them does not change persistent host data.

This feature changes no schema, projection declaration, event representation or stored history. An earlier binary can still decode newly written archive facts; its facade simply cannot report the flag. Do not rewrite historical attribution or replay a production store to install the bridge. If an implementation unexpectedly requires a migration or dependency upgrade, investigate the accidental coupling and revise the plan explicitly before including it.

Preserve other contributors' edits when modifying shared files, especially ExecPlan 49's work. Publication is not idempotent: do not overwrite an existing Hackage version or retag a published release. Inspect partial upload state and follow the release skill's recovery procedure; record incomplete publication honestly rather than restarting blindly.


## Interfaces and Dependencies


The only new production API is exported by `Kioku.Memory` from `kioku-core/src/Kioku/Memory.hs`:

```haskell
archiveLegacyChanged ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  ArchiveMemoryData ->
  Eff es (Either MemoryWriteError (MemoryId, Bool))
archiveLegacyChanged cmdData =
  inLegacySpaceOnly cmdData.memorySpaceId (archiveInChanged cmdData)
```

`ArchiveMemoryData` remains the existing record in `kioku-core/src/Kioku/Memory/Domain.hs`, with `memoryId`, `memorySpaceId`, `actorPrincipal` and `archivedAt`. Retain the public pair rather than introducing a second receipt representation. `archiveWithContextChanged`, `archiveWithContext`, `archive`, `MemoryWriteError`, `RecordedPrincipal` and all context constructors keep their existing types.

Use the existing command result from `mori://shinzui/keiro/packages/keiro`, the existing store effects from `mori://shinzui/kiroku/packages/kiroku-store`, and the current test dependencies. No new external library, package bound or pin is selected. If a later change truly needs a dependency API, discover it with `mori registry list`, `mori registry search`, `mori registry show --full` and `mori registry docs`, then read its source and verify registry releases/tags before changing bounds. Never traverse `/nix/store` to locate source.

This is a standalone Kioku plan, not a child of the consumer's MasterPlan. It can be implemented independently of ExecPlan 49, with release coordination if their changes ship together. Consumer authentication and eventual migration to known principals remain owned by `mori://shinzui/rei`; Kioku supplies only its supported archive command and receipt.
