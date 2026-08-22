---
id: 39
slug: retire-rei-legacy-event-decoders-after-consumer-cutover
title: "Retire Rei legacy event decoders after consumer cutover"
kind: exec-plan
created_at: 2026-08-20T13:57:31Z
intention: "intention_01m0fpyzp4e2kbnhyvcm00zd9t"
master_plan: "docs/masterplans/7-remediate-the-kioku-0-3-0-0-to-0-4-0-0-release-range-review.md"
---

# Retire Rei legacy event decoders after consumer cutover

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kioku's event-stream modules should decode Kioku history, not permanently embed a second
application's retired wire protocol. Once Rei has completed its one-time migration and removed
the last parser imports, this change deletes the `agent_memory_*` and `agent_session_*` fallback
arms while preserving every native Kioku compatibility rule, including pre-partition events and
`SessionResumed` payloads written before `force` existed.

The result is visible in codec tests: all captured native Kioku bytes still hydrate, a former Rei
payload now fails through the ordinary native decoder, and no Kioku source or test names Rei's
legacy event vocabulary. This is a deliberate behavior break and must ship in Kioku's next major
release, never as a 0.4 patch.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Refresh the Mori dependent graph and inspect the external gate at exact source revisions;
  the gate remains closed.
- [x] (2026-08-22 13:59Z) Recheck Rei after its migration implementation and confirm that only
  the clone proof is complete; the production proof, migrator removal, and fallback-free handoff
  remain open.
- [ ] Prove the external Rei migrator is complete and no deployable consumer imports the parsers.
- [ ] Move the two native pre-`force` fixtures out of the Rei-specific test module.
- [ ] Remove the foreign fallback parsers, Rei fixtures, and test-suite registration.
- [ ] Record decoder ownership in an ADR and stage the change for the next major release.
- [ ] Run native compatibility, full core, and cross-consumer dependency validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-08-20: `mori://shinzui/rei/packages/rei-core` already bounds `kioku-api` and `kioku-core`
  at `^>=0.4.1`, but its `rei-kioku-migrate` executable still imports `parseMemoryEvent` and
  `parseSessionEvent`. A version-bound check alone is therefore insufficient; the source/import
  and production-cutover gates below are mandatory.

- 2026-08-21: At `mori://shinzui/rei/repos/rei` revision
  `9c81561fdd7f739849238f8511276bd51f6f1c48`, the working tree still declares
  `rei-kioku-migrate` and its implementation imports and calls both Kioku parsers. The unrelated
  uncommitted Intention-module generation work adds Cabal library modules but does not touch the
  migrator stanza or implementation. The newer explicit handoff plan,
  `mori://shinzui/rei/plans/215-complete-the-rei-to-kioku-legacy-migration-and-retire-its-migrator`,
  has all six milestones unchecked, including the real-database proof, migrator deletion, and
  fallback-free Kioku build. Its owning commit is
  `c601249bb0de807ca02e52dd62a248d564a27395`; the currently released Mori CLI cannot yet resolve
  this plan URI, so the canonical project URI plus project-relative source inspection supplied
  the evidence.

- 2026-08-21: `mori registry dependents shinzui/kioku --packages` reports
  `mori://shinzui/rei`, `mori://shinzui/mori`, `mori://shinzui/kikan`, and
  `mori://shinzui/shikigami`. Source scans at revisions `9c81561f` (Rei), `aac8d330` (Mori),
  `b83e3baa` (Kikan), and `25e31709` (Shikigami) find parser imports only in Rei's migrator.
  Kikan has one historical documentation mention of the executable; Mori and Shikigami have no
  matches. The dependent graph therefore identifies no second code consumer, but it cannot
  override Rei's still-open production gate.

- 2026-08-22: Rei's migration implementation has advanced through a fail-closed migrator and a
  successful production-data clone proof, but not through the real production cutover. At
  `mori://shinzui/rei/repos/rei` revision `2ade71b8a3907da2ed2d23f766bf2ba49397aaa1`,
  `mori://shinzui/rei/plans/215-complete-the-rei-to-kioku-legacy-migration-and-retire-its-migrator`
  checks off Milestones 1 and 2 but leaves Milestones 3 through 6 open. Its Milestone 3 explicitly
  says the clone proof does not authorize appending the two missing native session events to the
  real database. All seven milestones in
  `mori://shinzui/rei/plans/210-cut-the-production-database-over-to-the-0-13-cohort-and-prove-it`
  remain unchecked. The same revision still declares the `rei-kioku-migrate` executable and its
  implementation imports and calls both `parseMemoryEvent` and `parseSessionEvent`.

- 2026-08-22: The refreshed dependent scan still finds no second parser consumer. Source scans
  found no parser, migrator, or legacy-tag references in deployable code at
  `mori://shinzui/mori/repos/mori` revision `eb386a54bfb63f3fa9007943f9d6f5c55be1e2a5`,
  `mori://shinzui/kikan` revision `3e7fcf887aa3caff76f1002bfeef07e00eabaf54`, or
  `mori://shinzui/shikigami/repos/shikigami` revision
  `25e317090867ea21bc36226937c8902a720aeac3`. Rei remains the sole blocking consumer.


## Decision Log

Record every decision made while working on the plan.

- Decision: Remove only Rei's foreign wire-format fallback; retain native Kioku upcasts and
  defaulting forever under their existing compatibility policy.
  Rationale: the user explicitly chose to drop Rei legacy support because Rei is moving to the
  current Kioku line. Pre-partition Kioku events are still Kioku's own durable history and are not
  part of that retirement.
  Date: 2026-08-20

- Decision: Treat absence of parser imports and completion of the real-data cutover as a hard
  external gate.
  Rationale: Rei's current one-time migrator still invokes the public parsers. Removing their
  fallback first can make irreplaceable legacy events undecodable even though Rei compiles
  against the latest package bounds.
  Date: 2026-08-20

- Decision: Publish the removal only in the next PVP major release.
  Rationale: the Haskell types remain the same, but callers currently relying on accepted Rei
  payloads observe a failure after the change. That is a public behavioral incompatibility.
  Date: 2026-08-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The external-gate audit was refreshed on 2026-08-21 without changing any decoder, fixture,
registration, or release note. Rei still imports the parsers and has not recorded the required
clone and production proof or migrator-removal commit. Resume at Milestone 1 only after
`mori://shinzui/rei/plans/215-complete-the-rei-to-kioku-legacy-migration-and-retire-its-migrator`
records Milestones 3 through 5 complete and supplies the exact Rei revision and checked-in
cutover evidence it promises.

The 2026-08-22 recheck confirms meaningful Rei progress but does not open the gate: the finite
migrator and disposable-clone proof now exist, while the real production proof, migrator removal,
and fallback-free handoff do not. No Kioku decoder, fixture, test registration, ADR, or changelog
was changed. Resume only after Rei Plan 215 records Milestones 3 through 5 complete at an exact
revision and the corresponding checked-in production evidence is present.


## Context and Orientation

`kioku-core/src/Kioku/Memory/EventStream.hs` and
`kioku-core/src/Kioku/Session/EventStream.hs` expose `parseMemoryEvent` and `parseSessionEvent`.
Each first runs the native `FromJSON` parser, then falls back to private functions that recognize
Rei tags such as `agent_memory_recorded`, `agent_session_started`, and
`interactive_session_recorded`. Those functions also translate Rei ids, anchors, focus values,
and un-attributed actors into Kioku's model. This is one-time migration policy embedded in the
normal event-store codec.

`kioku-core/test/Kioku/ReiCompatSpec.hs` holds most foreign fixtures. It also contains two tests
that are not Rei-specific: native `session_resumed` events written before the `force` field
existed. `kioku-core/test/Kioku/CodecCompatSpec.hs` separately has a "two-arm fallback" group and
a Rei fixture in addition to the native golden payloads. Before deleting the Rei test module,
the two native resume cases must move into `CodecCompatSpec`; the fallback group and foreign
fixture there must also be removed. `kioku-core/test/Main.hs` and
`kioku-core/kioku-core.cabal` register the Rei module.

Mori identifies the current consumer package as `mori://shinzui/rei/packages/rei-core`. Its
project-relative `rei-core/kioku-migrate/Rei/KiokuMigrate.hs` still imports both parser functions,
and project-relative `rei-core/rei-core.cabal` still builds `rei-kioku-migrate`. The related build
upgrade is complete in
`mori://shinzui/rei/plans/203-land-the-released-keiro-0-13-cohort-build-plan`, while the real-data
cutover in `mori://shinzui/rei/plans/210-cut-the-production-database-over-to-the-0-13-cohort-and-prove-it`
is not yet complete. The dedicated follow-through is
`mori://shinzui/rei/plans/215-complete-the-rei-to-kioku-legacy-migration-and-retire-its-migrator`;
it owns the exact production proof, migrator removal, and fallback-free handoff this plan needs.
Mori may not resolve those plan artifact URIs until registry URI coverage is refreshed; they
remain the intended canonical identities.

[Kioku owns memory, not identity](../adr/kioku-owns-memory-not-identity.md) supports removing
consumer-specific translation policy. [Legacy data lands in one explicit
space](../adr/legacy-data-lands-in-one-explicit-space.md) and [historical attribution is marked,
never invented](../adr/historical-attribution-is-marked-never-invented.md) continue to govern
native Kioku replay and are not weakened. The long-lived ownership boundary is new and should be
recorded in an ADR: Kioku decodes its own history; a consumer owns and retires any one-time
foreign migration codec.


## Plan of Work

### Milestone 1 — Satisfy the external cutover gate or stop

Use Mori, not a remembered checkout path, to refresh all projects and packages that depend on
Kioku. Inspect the authoritative source of each deployable dependent for imports of
`parseMemoryEvent`, `parseSessionEvent`, `parseLegacyMemoryEvent`, legacy `agent_*` tags, or a
Rei-to-Kioku migration executable. For Rei specifically, all of these conditions must be true:

1. `mori://shinzui/rei/plans/210-cut-the-production-database-over-to-the-0-13-cohort-and-prove-it`
   is complete, including replay against the real production history, and Milestones 3 through 5
   of
   `mori://shinzui/rei/plans/215-complete-the-rei-to-kioku-legacy-migration-and-retire-its-migrator`
   record the dedicated migration proof and handoff;
2. `rei-kioku-migrate` has been run everywhere it is required and is then removed, or rewritten
   so it owns its legacy decoder without importing the Kioku event-stream parsers;
3. Rei's library, executable, and test components build and pass without relying on the foreign
   fallback; and
4. `mori registry dependents shinzui/kioku --packages` reveals no other deployable consumer that
   relies on it.

Record exact commands, source revisions, and evidence in this plan's Progress and Discoveries.
If any condition fails, stop without editing a decoder. Coordinating the Rei-side removal is
outside this Kioku plan's write scope; refer to it only by canonical `mori://` identity.

### Milestone 2 — Preserve native compatibility before removing foreign tests

Move the two `SessionResumed` fixtures from `Kioku.ReiCompatSpec` into the native session section
of `Kioku.CodecCompatSpec`. Keep both semantics: an omitted `force` with no correlation key
decodes as `force = True`, while one with a key decodes as `force = False`. Run those cases before
any production edit so they prove the native `FromJSON SessionResumedData` path already owns the
upcast.

Remove the Rei-specific fallback tests and fixture from `CodecCompatSpec`, and update its module
comment so the suite promises native Kioku compatibility only. Do not remove the pre-partition
space/principal tests; their payloads use Kioku's native tags and remain durable history.

### Milestone 3 — Delete the Rei fallback from normal codecs

In both EventStream modules, simplify the public parser to the native parse only:

```haskell
parseMemoryEvent = first Text.pack . parseEither parseJSON
parseSessionEvent = first Text.pack . parseEither parseJSON
```

Import `Data.Bifunctor.first` and remove imports used only by the foreign parser. Delete all
`parseLegacyMemory*`, `parseLegacySession*`, Rei anchor/focus normalization, lenient Rei id
translation, and the private `reiNamespace`. Keep `memoryCodec.decode` and `sessionCodec.decode`
pointing at the public functions. Do not change domain `FromJSON` instances, `Kioku.Partition`,
`legacyMemorySpaceId`, or native id parsing.

Delete `kioku-core/test/Kioku/ReiCompatSpec.hs` and remove its import/registry entry from
`kioku-core/test/Main.hs` and `kioku-core/kioku-core.cabal`. Add one negative native-codec case
asserting an old `agent_memory_recorded` fixture now returns `Left`; assert only failure, not the
entire Aeson diagnostic.

### Milestone 4 — Record the boundary and release impact

Create an accepted ADR following the existing `docs/adr` frontmatter convention, titled
"Consumers own one-time foreign event migration codecs." Re-scan allocated `docId`s at execution;
use `ADR-11` only if it is still the next unused id. The ADR must distinguish native Kioku history
from foreign consumer history, state the cutover evidence required before retirement, and reject
permanent consumer-specific fallbacks in normal codecs.

Add an Unreleased breaking-change note to `kioku-core/CHANGELOG.md`. State that the public parser
types are unchanged but Rei `agent_*` values are no longer accepted, and that native pre-partition
Kioku events remain supported. Coordinate the eventual package version through the repository's
release plan/skill; do not publish this behavior under `0.4.x`.

### Milestone 5 — Prove native history and the dependent graph

Format and run the focused compatibility suite, the full core suite, and the repository build.
Repeat the Mori dependent scan at the final revision and inspect new results before declaring the
plan complete. A source scan over Kioku must find no Rei tag, parser, namespace, fixture, test
module, or `legacy decode failed` branch outside historical review/plan/changelog documents.


## Concrete Steps

Run the external read-only gate from `/Users/shinzui/Keikaku/bokuno/kioku`:

```bash
mori registry dependents shinzui/kioku --packages
mori registry show shinzui/rei --full
rei_source="$(mori path mori://shinzui/rei)"
rg -n 'parseMemoryEvent|parseSessionEvent|rei-kioku-migrate|agent_memory_|agent_session_' \
  "$rei_source" --glob '!dist-newstyle/**' --glob '!result*'
```

The first implementation attempt is expected to stop today because the Rei scan still names
`rei-core/kioku-migrate/Rei/KiokuMigrate.hs`. Resume only after the gate conditions are recorded
as satisfied.

Before production edits, pin the native cases:

```bash
rg -n 'pre-force|SessionResumed|legacy Rei|legacy decode failed|ReiCompatSpec' \
  kioku-core/src kioku-core/test kioku-core/kioku-core.cabal
cabal test kioku-core:kioku-test --test-options='-p "pre-force"'
```

After removal, format and validate:

```bash
nix fmt
cabal test kioku-core:kioku-test --test-options='-p "event payloads"'
cabal test kioku-core:kioku-test
cabal build all
rg -n 'parseLegacyMemory|parseLegacySession|agent_memory_|agent_session_|legacy decode failed|ReiCompatSpec' \
  kioku-core/src kioku-core/test kioku-core/kioku-core.cabal
mori registry dependents shinzui/kioku --packages
git diff --check
```

The post-removal `rg` is expected to print nothing. Historical changelogs, reviews, plans, and
the new ADR may still name the retired behavior and are intentionally outside that scan.


## Validation and Acceptance

Do not accept the change on Kioku tests alone. The recorded external gate must show the Rei
production cutover completed and every current dependent free of the parser fallback. With that
evidence present, every captured native memory and session event still decodes, including
pre-partition space/principal defaults and both pre-`force` resume forms. Native codec round trips
remain unchanged.

An `agent_memory_recorded` or `agent_session_started` object now returns `Left` from the public
parser. There are no foreign parsing functions or Rei-specific test module in the build. The new
ADR and breaking changelog note make the ownership and release boundary explicit. The full core
suite, whole workspace build, and final dependent scan pass.


## Idempotence and Recovery

The inspection and test steps are read-only and repeatable. Decoder deletion mutates no database,
but releasing it before the consumer gate is irreversible for a consumer that then encounters an
unmigrated event. That is why the plan stops before editing rather than relying on rollback after
publication.

If a native fixture fails after removal, restore only the native upcast/defaulting path in the
domain codec and diagnose it; do not restore the entire Rei fallback as a shortcut. If a new
dependent appears in the final Mori scan, leave the plan incomplete and coordinate its one-time
migration first. A source revert before release is safe because parser signatures do not change.


## Interfaces and Dependencies

The public interfaces remain:

```haskell
parseMemoryEvent :: Value -> Either Text MemoryEvent
parseSessionEvent :: Value -> Either Text SessionEvent
```

Their accepted language narrows to native Kioku JSON. `Codec.decode`, all domain event types, and
the native Aeson instances retain their signatures. Use existing `aeson`, `text`, and `base`
only; no Haskell dependency changes.

The external hard dependencies are the completed real-data cutover at
`mori://shinzui/rei/plans/210-cut-the-production-database-over-to-the-0-13-cohort-and-prove-it`,
the completed migration/handoff at
`mori://shinzui/rei/plans/215-complete-the-rei-to-kioku-legacy-migration-and-retire-its-migrator`,
and an empty consumer-import scan rooted through Mori. These are evidence dependencies, not
authorization to edit the Rei repository. The Kioku package containing the behavior must advance
to the next PVP major line before release.
