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
application's retired wire protocol. Rei has explicitly abandoned support for its barely-used
legacy memory and session histories after preserving a verified recovery boundary, and has
removed the one-time migrator and the last parser imports. This change therefore deletes the
`agent_memory_*` and `agent_session_*` fallback arms while preserving every native Kioku
compatibility rule, including pre-partition events and `SessionResumed` payloads written before
`force` existed.

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
- [x] (2026-08-22 15:39Z) Reopen the external gate from Rei's verified abandonment evidence,
  migrator-removal commit, durable support-boundary decision, and a refreshed dependent scan.
- [x] (2026-08-22 15:50Z) Move the two native pre-`force` fixtures out of the Rei-specific test
  module and prove all 27 focused codec cases.
- [x] (2026-08-22 15:50Z) Remove the foreign fallback parsers, Rei fixtures, and test-suite
  registration; retain one negative native-parser case.
- [x] (2026-08-22 15:51Z) Record decoder ownership in ADR-11 and both Unreleased changelogs for
  the next major release.
- [x] (2026-08-22 15:58Z) Run final native compatibility, all 219 core tests, the workspace
  build, strict ADR validation, and the exact-revision dependent scan at commit `462c24ba`.


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

- 2026-08-22: Rei deliberately replaced the copy-first gate with a support-retirement gate after
  inventorying the real system database. Commit `96777dcf` records a checked-in, credential-free
  evidence report for 4 legacy memory events, 243 legacy session events, 10 native Kioku memory
  events, and 144 native Kioku session events, plus a fully restored PostgreSQL backup whose
  SHA-256 is `fbf602b623d5a902f37101d617bf496cfc5f78036c1b3e164bc38b2685b92d61`.
  The backup and all source rows remain intact; support is abandoned without deleting history.

- 2026-08-22: At `mori://shinzui/rei/repos/rei` revision
  `9928be30bbeccd108fdd88d2da214dcb99bb07de`, commit `9bef6488` has removed
  `rei-kioku-migrate`, its implementation, tests, proof driver, Cabal wiring, and both public
  parser imports. Commit `9928be30` records the durable boundary in Rei ADR 024 and revises the
  related rollout plans. A source scan finds no Kioku parser or migrator reference in deployable
  Rei code; the remaining `agent_*` names are Rei's own current identifiers, historical fixtures,
  and documentation rather than calls into Kioku's decoder.

- 2026-08-22: The final pre-edit Mori graph still reports Kikan, Mori, Rei, and Shikigami as
  dependents. Deployable-code scans at revisions `3e7fcf88` (Kikan), `752296d2` (Mori),
  `9928be30` (Rei), and `25e31709` (Shikigami) find no imports or calls to the two parser
  functions and no Rei-to-Kioku migrator. The consumer gate is therefore open.

- 2026-08-22: A direct post-edit `cabal test` shell lost the Nix-provided `libpq` pkg-config
  database and stopped during dependency resolution, before compilation. Running the same check
  through `nix develop -c` restored the repository environment: all 27 focused codec cases, all
  219 core cases, and `cabal build all` pass. This was an invocation-environment failure, not a
  decoder or test failure.

- 2026-08-22: At the committed implementation revision
  `462c24ba33436b31ffe910b8458049e592709011`, the final Mori graph still names only Kikan, Mori,
  Rei, and Shikigami. Source scans at `3e7fcf88`, `752296d2`, `9928be30`, and `25e31709`
  respectively find no parser or migrator use. Kioku's live source, tests, and Cabal wiring also
  contain none of the retired parser helpers, tags, namespace, diagnostic branch, or test module.


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

- Decision: Accept explicit support abandonment, a verified backup, and consumer-code removal as
  an alternative to copying every foreign event into native Kioku streams.
  Rationale: Kioku needs proof that no live consumer will ask it to decode the retired wire
  protocol; it does not need to dictate whether the consumer copies, deletes, or retains that
  history. Rei's evidence preserves recovery options while its explicit product decision makes a
  low-value production copy unnecessary. This supersedes the 2026-08-20 requirement that the
  real-data cutover itself must complete before decoder retirement.
  Date: 2026-08-22

- Decision: Treat the consumer's own identifiers and historical fixtures as outside Kioku's
  import-absence gate.
  Rationale: `agent_memory_*` and `agent_session_*` remain valid Rei concepts. The relevant gate
  is the absence of calls to Kioku's foreign fallback and of a migrator that depends on it, not a
  repository-wide ban on Rei's domain vocabulary.
  Date: 2026-08-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The first two external-gate audits correctly stopped without changing a decoder: Rei still
imported the parsers and had not made a final product decision about its retained history. The
2026-08-22 completion attempt resumes from a different, explicit boundary. Rei Plan 215 now
records a verified backup and real-database inventory, the user's decision to retain but stop
supporting the foreign histories, the exact migrator-removal commit, and a durable ADR. This is
sufficient consumer evidence even though Plan 215's Kioku and dependency-validation milestones
remain open: those milestones depend on this plan and would otherwise make the two plans cyclic.

Implementation replaced 224 lines of private foreign parser machinery with two native parser
expressions, while leaving the public signatures and codec wiring unchanged. The two native
pre-`force` fixtures now live beside the rest of Kioku's captured history, and a negative case
proves the former consumer-specific payload fails. The focused 27-case compatibility slice, all
219 core tests, the whole workspace build, the retired-vocabulary scan, and strict validation of
all 11 ADRs pass. The remaining completion action is to repeat the dependent scan at the exact
committed implementation revision. That scan passed at `462c24ba`: every dependent is free of
the behavior, so the plan is complete. Kioku remains on Unreleased package metadata; assigning,
tagging, pushing, and publishing the lockstep 0.5.0.0 release remain owned by the explicit release
workflow and were not performed here.


## Context and Orientation

`kioku-core/src/Kioku/Memory/EventStream.hs` and
`kioku-core/src/Kioku/Session/EventStream.hs` expose `parseMemoryEvent` and `parseSessionEvent`.
Both now run the native `FromJSON` parser directly. Before this plan they fell back to private
functions that recognized Rei tags, translated Rei ids, anchors, focus values, and unattributed
actors, and thereby embedded one-time consumer migration policy in the normal event-store codec.

The deleted `kioku-core/test/Kioku/ReiCompatSpec.hs` held most foreign fixtures as well as two
native `session_resumed` cases written before the `force` field existed. Those two cases now live
in `kioku-core/test/Kioku/CodecCompatSpec.hs` beside Kioku's other native golden payloads. That
module retains one negative case showing the former foreign form fails native decoding;
`kioku-core/test/Main.hs` and `kioku-core/kioku-core.cabal` no longer register a Rei-specific
suite.

Mori identifies the former consumer package as `mori://shinzui/rei/packages/rei-core`. Rei commit
`9bef6488` removed its project-relative migrator implementation and executable stanza, so no
current component imports either parser function. The related build upgrade is complete in
`mori://shinzui/rei/plans/203-land-the-released-keiro-0-13-cohort-build-plan`, while the real-data
cutover in `mori://shinzui/rei/plans/210-cut-the-production-database-over-to-the-0-13-cohort-and-prove-it`
retains all schema-safety gates but no longer requires copying this unsupported history. The
dedicated follow-through is
`mori://shinzui/rei/plans/215-complete-the-rei-to-kioku-legacy-migration-and-retire-its-migrator`;
Its evidence report is currently addressed as `mori://shinzui/rei` plus the project-relative path
`docs/dev/testing/rei-kioku-legacy-history-abandonment-20260822.md`, because Mori has no canonical
artifact kind for testing evidence yet.
Mori may not resolve those plan artifact URIs until registry URI coverage is refreshed; they
remain the intended canonical identities.

[Kioku owns memory, not identity](../adr/kioku-owns-memory-not-identity.md) supports removing
consumer-specific translation policy. [Legacy data lands in one explicit
space](../adr/legacy-data-lands-in-one-explicit-space.md) and [historical attribution is marked,
never invented](../adr/historical-attribution-is-marked-never-invented.md) continue to govern
native Kioku replay and are not weakened. [Consumers own one-time foreign event migration
codecs](../adr/consumers-own-one-time-foreign-event-migration-codecs.md) records the long-lived
boundary: Kioku decodes its own history; a consumer owns and retires any one-time foreign
migration codec.


## Plan of Work

### Milestone 1 — Satisfy the external support-retirement gate or stop

Use Mori, not a remembered checkout path, to refresh all projects and packages that depend on
Kioku. Inspect the authoritative source of each deployable dependent for imports of
`parseMemoryEvent`, `parseSessionEvent`, `parseLegacyMemoryEvent`, or a Rei-to-Kioku migration
executable. For Rei specifically, all of these conditions must be true:

1. `mori://shinzui/rei/plans/215-complete-the-rei-to-kioku-legacy-migration-and-retire-its-migrator`
   records either a completed real-data copy or an explicit support-abandonment decision backed
   by a verified recovery boundary and credential-free inventory evidence;
2. `rei-kioku-migrate` is removed, or rewritten so it owns its legacy decoder without importing
   the Kioku event-stream parsers;
3. Rei's library, executable, and test components build and pass without relying on the foreign
   fallback; and
4. `mori registry dependents shinzui/kioku --packages` reveals no other deployable consumer that
   relies on it.

Record exact commands, source revisions, and evidence in this plan's Progress and Discoveries.
Do not treat Rei's continued use of its own `agent_*` identifiers as a decoder dependency. If any
condition fails, stop without editing a decoder. Coordinating the Rei-side removal is outside
this Kioku plan's write scope; refer to it only by canonical `mori://` identity.

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
rg -n 'parseMemoryEvent|parseSessionEvent|parseLegacyMemoryEvent|rei-kioku-migrate' \
  "$rei_source" --glob '!dist-newstyle/**' --glob '!result*'
```

The 2026-08-21 and early 2026-08-22 attempts stopped because the Rei scan still named
`rei-core/kioku-migrate/Rei/KiokuMigrate.hs`. The final 2026-08-22 recheck is expected to find no
parser or migrator reference after Rei commit `9bef6488`; record the exact revision before
editing production code.

Before production edits, pin the native cases:

```bash
rg -n 'pre-force|SessionResumed|legacy Rei|legacy decode failed|ReiCompatSpec' \
  kioku-core/src kioku-core/test kioku-core/kioku-core.cabal
cabal test kioku-core:kioku-test --test-options='-p "pre-force"'
```

After removal, format only this plan's Haskell files so unrelated work in the shared checkout is
not rewritten, then validate:

```bash
nix develop -c fourmolu -i \
  kioku-core/src/Kioku/Memory/EventStream.hs \
  kioku-core/src/Kioku/Session/EventStream.hs \
  kioku-core/test/Kioku/CodecCompatSpec.hs \
  kioku-core/test/Main.hs
nix develop -c cabal test kioku-core:kioku-test --test-options='-p "event payloads"'
nix develop -c cabal test kioku-core:kioku-test
nix develop -c cabal build all
rg -n 'parseLegacyMemory|parseLegacySession|agent_memory_|agent_session_|legacy decode failed|ReiCompatSpec' \
  kioku-core/src kioku-core/test kioku-core/kioku-core.cabal
mori registry dependents shinzui/kioku --packages
git diff --check
```

The post-removal `rg` is expected to print nothing. Historical changelogs, reviews, plans, and
the new ADR may still name the retired behavior and are intentionally outside that scan.


## Validation and Acceptance

Do not accept the change on Kioku tests alone. The recorded external gate must show that Rei
either migrated or explicitly abandoned support with a verified recovery boundary, removed its
dependency on the fallback, and that every current dependent is free of the parser fallback.
With that evidence present, every captured native memory and session event still decodes, including
pre-partition space/principal defaults and both pre-`force` resume forms. Native codec round trips
remain unchanged.

An `agent_memory_recorded` or `agent_session_started` object now returns `Left` from the public
parser. There are no foreign parsing functions or Rei-specific test module in the build. The new
ADR and breaking changelog note make the ownership and release boundary explicit. The full core
suite, whole workspace build, and final dependent scan pass.


## Idempotence and Recovery

The inspection and test steps are read-only and repeatable. Decoder deletion mutates no database,
but releasing it before the consumer gate is irreversible for a consumer that then encounters an
unsupported event. That is why the plan stops before editing rather than relying on rollback after
publication. Rei's verified backup and retained raw events remain the recovery boundary if its
support decision is revisited.

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

The external hard dependencies are the verified support decision and consumer-code handoff at
`mori://shinzui/rei/plans/215-complete-the-rei-to-kioku-legacy-migration-and-retire-its-migrator`,
and an empty consumer-import scan rooted through Mori. These are evidence dependencies, not
authorization to edit the Rei repository. The Kioku package containing the behavior must advance
to the next PVP major line before release.


## Revision Notes

- 2026-08-22: Replaced the copy-only consumer gate with a migration-or-explicit-abandonment gate
  after Rei preserved a verified recovery boundary, documented the support decision, and removed
  its migrator. Recorded the exact Rei evidence and dependent revisions that open implementation.
- 2026-08-22: Recorded the native-only implementation, narrow formatting command, ADR-11, and
  passing focused/full/build evidence. The final exact-revision dependent scan remains before
  completion.
- 2026-08-22: Closed the plan after committing the implementation at `462c24ba` and confirming
  the final Mori graph and every dependent source scan. Left lockstep package versioning and
  publication to the separately authorized release workflow.
