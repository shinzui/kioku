---
id: 8
slug: add-first-class-provenance
title: "Add first-class provenance"
kind: exec-plan
created_at: 2026-07-07T03:36:53Z
intention: intention_01kwxabxj6ewdr5fncb56nh67n
master_plan: "docs/masterplans/4-secure-and-accountable-distillation-evidence.md"
---

# Add first-class provenance

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a Kioku user can inspect a memory or consolidation decision and answer “what
caused this artifact to exist?”, or inspect a scene or persona and answer “what caused this current
materialized version?”, with one versioned, structured, partitioned record. A manual memory says
that it was recorded directly. A distilled L1 memory names its
session, the evidence-selection decision, the exact evidence-item IDs cited by that atom, and the
consolidation decision. A scene names the active memory rows used to generate it. A persona names
the scene rows used to generate it. When model-call evidence is available, the same provenance
record carries the accepted provider call IDs without embedding prompts, outputs, or provider
records.

Memory and audit provenance is creation cause, not “the last event that touched this row.” Updating
confidence or tags and later merging, superseding, or archiving a memory does not erase how the
memory was created. Those later native events already record their actor, space, and timestamp.
Scenes and personas are mutable materializations: a changed source hash replaces their content and
provenance atomically, an unchanged hash preserves both, and an empty source set deletes the row.
Kioku does not keep a stale scene or persona merely to preserve provenance.

The observable result is a partitioned library and CLI inspection path plus real pipeline tests.
A user can follow selected evidence to an L1 memory, that memory to an L2 scene, and that scene to
an L3 persona. Old native Kioku events and rows remain readable with explicit legacy-native
provenance. Foreign Rei history does not gain a permanent fallback: its decoder was retired under
ADR-11.


## Progress

- [ ] Define an exposed, versioned `Kioku.Provenance` type with a closed creation-cause vocabulary
  and JSON compatibility tests.
- [ ] Add provenance storage to the current `kioku` projection tables with a strict forward
  migration and honest legacy-native backfill.
- [ ] Preserve `RecordMemoryData` source compatibility while adding explicit
  `recordWithProvenance` and native event/read-model provenance.
- [ ] Carry the evidence decision, exact atom source citations, consolidation decision, and
  accepted call IDs through L1 memory and audit writes.
- [ ] Carry memory source sets through scenes and scene source sets through personas, including
  timer-trigger context where available.
- [ ] Keep creation provenance immutable across memory tag, confidence, merge, supersede, and
  archive changes.
- [ ] Expose authorization-aware library and CLI inspection for all four artifact kinds.
- [ ] Add native replay, migration, manual-write, L1/L2/L3, model-call integration, and two-space
  isolation tests.
- [ ] Update user documentation and distill the final provenance semantics into an ADR before
  completing the plan.


## Surprises & Discoveries

- Kioku now has the memory-space and authorization boundary this plan previously treated as future
  work. Every relevant row, query, timer, and artifact path is partitioned, and all new inspection
  must consume that contract rather than introducing another tenant key.

- Kioku-owned projections moved from `kiroku.kioku_*` to `kioku.*`. Relation names are constructed
  in `Kioku.Database.Schema` and may not depend on `search_path`.

- The active migration manifest ends at 0013, but three child plans in this MasterPlan may add
  schema. This plan must allocate the next number when implementation starts rather than claiming
  0014 now.

- Keiro 0.14's `RunCommandOptions` still exposes caller event IDs and ambient event metadata but no
  plain-command causation or correlation fields. Kiroku stores causation and correlation, but
  changing the upstream command API is not required to make artifact provenance visible in Kioku.

- A single mutable provenance JSON value cannot mean both “why this artifact exists” and “what
  changed it most recently.” Overwriting the value on confidence or lifecycle events destroys the
  origin chain. Current native events already provide the latter audit.

- L1 now has a deterministic atom memory ID and consolidation audit key, so both can be known before
  a data atom's consolidation provider call. Plan 23 stores instruction atoms without that call.
  L2 and L3 likewise know their scope-derived artifact IDs before calling the model.

- Plan 23 now requires each extracted atom to cite an exact subset of the evidence IDs in its
  extraction lane. Data and trusted-instruction extraction are separate, so provenance must also
  retain which accepted extraction call produced the atom.

- One extraction provider call can contribute to several memories and consolidation decisions.
  Provenance may summarize the accepted call IDs on each artifact, while Plan 16 needs a separate
  many-to-many association to preserve all attempts and reverse queries.

- Rei's foreign event decoder was retired on 2026-08-22. A `LegacyNativeCause` remains necessary
  for old Kioku payloads and migrated rows; an automatic `imported:rei` cause would violate
  [ADR-11](../adr/consumers-own-one-time-foreign-event-migration-codecs.md).


## Decision Log

- Decision: Keep the first implementation inside Kioku instead of changing Keiro or Kiroku.
  Rationale: Kiroku has store-level causation and correlation fields, but the plain Keiro command
  path does not expose them. Kioku can deliver artifact-visible provenance in its native event
  payloads and projections without coupling this initiative to an upstream API change.
  Date: 2026-07-07; reverified 2026-08-22

- Decision: Use a versioned closed sum for creation cause, not a free-text kind plus many unrelated
  optional fields.
  Rationale: The allowed cause shapes are known, and a closed vocabulary prevents impossible
  combinations such as a manual memory claiming scene sources.
  Date: 2026-08-22

- Decision: A memory or consolidation audit's provenance is immutable creation cause. A scene or
  persona's provenance describes its current accepted source-hash version.
  Rationale: The feature answers why an artifact exists. Native events already answer who changed
  memory state later and when. Scenes and personas are updated in place, so their useful causal
  answer must change atomically with their content and source hash.
  Date: 2026-08-22

- Decision: Existing native rows and events receive `LegacyNativeCause` without inferring a more
  specific origin.
  Rationale: Historical cause not recorded at the time cannot be reconstructed honestly. This
  follows [ADR-5](../adr/historical-attribution-is-marked-never-invented.md).
  Date: 2026-08-22

- Decision: Preserve `RecordMemoryData` source compatibility and add an explicit
  `recordWithProvenance` API rather than adding a required field to the public record.
  Rationale: Adding a Haskell record field breaks every caller. An internal command wrapper can
  carry provenance while the existing function supplies direct/manual provenance.
  Date: 2026-08-22

- Decision: L1 provenance contains the atom's exact `sourceEvidenceIds` and accepted extraction
  call for its lane, not every item selected across the L1 operation.
  Rationale: Provenance must not claim that unrelated or merely co-present evidence caused every
  atom. Plan 23 owns citation validity.
  Date: 2026-08-22

- Decision: Provenance references accepted Baikai call IDs but never embeds provider evidence,
  prompts, or output.
  Rationale: Provenance is a compact artifact-local explanation. Plan 16 owns the complete
  provider-attempt ledger, privacy projection, reverse links, failures, and retention.
  Date: 2026-07-07; refined 2026-08-22

- Decision: Keep artifact-local call IDs and Plan 16's many-to-many association independently
  queryable.
  Rationale: The duplication is intentional: provenance answers from an artifact, while the ledger
  must also answer from a call and include attempts no artifact accepted.
  Date: 2026-08-22

- Decision: A retry never replaces the provenance of an already-created deterministic artifact or
  attaches the retry's calls to that artifact.
  Rationale: A committed artifact may outlive a later audit, scheduling, or watermark failure.
  New calls made during recovery did not create the existing row; they remain honest unlinked
  attempts unless they create another artifact.
  Date: 2026-08-22

- Decision: Every provenance record carries `MemorySpaceId` and every public inspection spends a
  `MemoryAccessContext` with `MemoryRead`.
  Rationale: Causal metadata reveals relationships and activity even without artifact content, so
  it is protected by the same boundary.
  Date: 2026-08-06; refined 2026-08-22


## Outcomes & Retrospective

No implementation has started. The 2026-08-22 refresh narrows the plan to an honest creation-cause
contract, rebases it on the current memory-space, authorization, schema, migration, and native-codec
architecture, and reconciles it with Plan 23's exact source citations and Plan 16's many-to-many
provider evidence ledger.


## Context and Orientation

Kioku stores durable memory and session facts as Kiroku events driven through Keiro aggregates.
A Kiroku event is an immutable append-only fact. A read model is a PostgreSQL table projected from
those facts for efficient queries. Kioku shares the host's Kiroku event store but owns its
projection tables in the dedicated `kioku` schema.

Memory commands and events are defined in
`kioku-core/src/Kioku/Memory/Domain.hs`. `RecordMemoryData` is the public input record used by
manual callers and L1. `MemoryRecordedData` is the persisted native event payload. Other memory
events change tags, confidence, or lifecycle status. The native event parser is
`kioku-core/src/Kioku/Memory/EventStream.hs`. `MemoryRow`, projection SQL, version, and shape hash
are in `kioku-core/src/Kioku/Memory/ReadModel.hs`. Public writes are in
`kioku-core/src/Kioku/Memory.hs` and already require or conservatively emulate a
`MemoryAccessContext`.

The memory aggregate carries `MemorySpaceId` in its state and rejects a command for another space.
The read model also predicates every query by that column. Memory lineage targets are checked in
the source space before write. Provenance must agree with the context, command, event, and row
space; a mismatch is a write error, never a value silently rewritten to match.

L1 is in `kioku-core/src/Kioku/Distill/L1.hs`. `distillSessionL1` preflights
`MemoryDistill`, `MemoryRecord`, and `MemoryForget`, reads the session evidence, checks its
partitioned watermark, calls extraction, then calls consolidation once per accepted atom.
`recordAtom` writes a memory. `writeAudit` inserts a row into
`kioku.consolidation_decisions`. `l1AtomMemoryId` and `l1AuditKey` are deterministic. Plan 23 adds
`EvidenceDecisionId` and exact source citations to this path, and replaces instruction
consolidation with a deterministic policy audit result.

L2 is in `kioku-core/src/Kioku/Distill/L2.hs`. `regenerateScene` reads all active memories in one
space and exact scope, computes a source hash, and either skips an unchanged source, deletes the
row when the source set is empty, or calls the scene model and upserts `kioku.scenes`. `SceneRow`
already stores `atomIds`. L3 in `kioku-core/src/Kioku/Distill/L3.hs` follows the same pattern over
scenes and `kioku.personas`, but `PersonaRow` currently stores only a scene count rather than the
scene IDs. Provenance supplies the explicit causal set.

`Kioku.Distill.Runtime` currently returns only `Either ShikumiError output` for extraction,
consolidation, scene, and persona. Plan 16 changes it to expose every provider attempt plus the
accepted call ID. This plan can land first with no call IDs; after Plan 16 integrates, newly
created artifacts use the same cause vocabulary with accepted call IDs. Existing artifacts remain
honest about the evidence available when they were created and are not rewritten speculatively.

The physical relation constants live in
`kioku-core/src/Kioku/Database/Schema.hs`. Migrations are allocated by
`just new-migration` and embedded in manifest order under `kioku-migrations/migrations/`. The
current manifest ends at 0013, but the implementer must inspect it again.

The authoritative dependency source locations discovered through Mori are
`mori://shinzui/kiroku/packages/kiroku-store` and
`mori://shinzui/keiro/packages/keiro`. Kiroku's `RecordedEvent` carries event, causation, and
correlation IDs. Keiro's current `RunCommandOptions` carries event IDs and metadata, not direct
causation/correlation options for this command path. If that API changes before implementation,
inspect released source again; do not guess.

Relevant accepted ADRs are:

- [ADR-1](../adr/kioku-owns-memory-not-identity.md): provenance records Kioku data and consumes an
  authorization decision; it does not invent identity policy.
- [ADR-2](../adr/namespace-is-not-a-security-boundary.md): namespace and scope organize provenance
  but cannot isolate it.
- [ADR-4](../adr/the-aggregate-enforces-the-partition.md): the event and command space must agree.
- [ADR-5](../adr/historical-attribution-is-marked-never-invented.md): unknown historical origin is
  marked rather than reconstructed.
- [ADR-6](../adr/the-partition-is-a-column-not-a-schema.md): every provenance query carries an
  unconditional space predicate.
- [ADR-10](../adr/projections-live-in-the-kioku-schema.md): new columns and SQL use explicitly
  qualified `kioku` relations.
- [ADR-11](../adr/consumers-own-one-time-foreign-event-migration-codecs.md): only native Kioku
  compatibility belongs in normal codecs.

No accepted ADR yet governs creation provenance. Distill the final cause vocabulary, immutability,
and provider-ledger boundary into `docs/adr/` before closing this plan.


## Plan of Work

### Milestone 1: define the versioned provenance type and storage

Create and expose `kioku-core/src/Kioku/Provenance.hs`. Use an explicit schema version and a closed
cause type:

```haskell
data ArtifactProvenance = ArtifactProvenance
  { schemaVersion :: ProvenanceSchemaVersion
  , memorySpaceId :: MemorySpaceId
  , cause :: ProvenanceCause
  }

data ProvenanceCause
  = ManualCause
      { sourceSessionId :: Maybe SessionId
      }
  | LegacyNativeCause
  | L1Cause
      { sourceSessionId :: SessionId
      , evidenceDecisionId :: EvidenceDecisionId
      , sourceEvidenceIds :: NonEmpty EvidenceSourceId
      , consolidationDecisionId :: Text
      , acceptedModelCallEvidenceIds :: [Text]
      }
  | L2Cause
      { sourceMemoryIds :: NonEmpty MemoryId
      , sourceHash :: Text
      , triggerTimerId :: Maybe Text
      , acceptedModelCallEvidenceId :: Maybe Text
      }
  | L3Cause
      { sourceSceneIds :: NonEmpty Text
      , sourceHash :: Text
      , triggerTimerId :: Maybe Text
      , acceptedModelCallEvidenceId :: Maybe Text
      }
```

Use a literal version such as `kioku-artifact-provenance-v1`. JSON encoding must include an
explicit cause discriminator and reject unknown versions or impossible cause fields. Normalize
provider call IDs by removing duplicates while retaining causal order: extraction before
optional consolidation for L1, then the single accepted generation call for L2 or L3.

`LegacyNativeCause` is the only automatic historical fallback. Do not add an `ImportedReiCause`
default or mislabel a foreign import as manual. A consumer that needs durable foreign-import
provenance must extend the vocabulary through a separate reviewed change and provide that cause
explicitly at its migration boundary.

Allocate the next migration at implementation time. Add `provenance jsonb` to
`kioku.memories`, `kioku.consolidation_decisions`, `kioku.scenes`, and `kioku.personas`. Backfill
each existing row with versioned `LegacyNativeCause` containing that row's own memory space, then
make the column non-null. Do not use one static JSON default that cannot contain each row's space.
New writes always provide provenance explicitly.

Add only indexes used by the planned inspection paths. Artifact lookup already uses primary keys,
so a first release may need no JSON expression index. Prove fresh install, data-bearing upgrade,
invalid partial layout rejection, and rerun behavior in `kioku-migrations/test/Main.hs`.

Milestone acceptance is that JSON round trips every cause, rejects cross-version and malformed
shapes, and a migrated pre-feature row reports honest legacy-native provenance in its own space.

### Milestone 2: persist memory creation provenance without breaking public record construction

Keep `RecordMemoryData` unchanged. Introduce an internal record-command wrapper that pairs the
existing input with `ArtifactProvenance` before it reaches the aggregate. Adjust the
`RecordMemory` command edge to read the wrapper and emit `MemoryRecordedData` with provenance.

Add:

```haskell
recordWithProvenance
  :: MemoryAccessContext
  -> ArtifactProvenance
  -> RecordMemoryData
  -> Eff es (Either MemoryWriteError MemoryId)
```

`recordWithContext` delegates to it with `manualProvenance` built from the authorized space and
the input's optional session. Deprecated legacy-space wrappers continue through
`recordWithContext` and cannot widen the space. Reject a provenance value whose memory space
differs from either the context or `RecordMemoryData`. Also reject `LegacyNativeCause`, `L2Cause`,
or `L3Cause` on a live memory-record command; only a smart-constructed manual or L1 memory cause is
valid. Historical decoders and derived-row projectors use separate internal constructors.

Add provenance to `MemoryRecordedData` and its native JSON encoder. Refactor the custom
`FromJSON` parser so it first determines the event's partition, then defaults a missing provenance
to `legacyNativeProvenance` for that partition. Do not change the payloads for tag, confidence,
supersede, merge, or archive events.

Add provenance to `MemoryRow`, its decoder, insert statement, and memory read-model identity. The
record projection inserts provenance only on `MemoryRecorded`. Later event projections leave the
column unchanged while updating the state fields they already own. If an event stream is replayed
into an empty projection, the creation event establishes provenance before later events apply.

Milestone acceptance proves a manual write produces `ManualCause`, an explicit write preserves its
exact cause and call IDs, a space mismatch fails before append, a native old event produces
`LegacyNativeCause`, and later lifecycle changes leave the original provenance byte-equivalent.

### Milestone 3: add exact L1 creation provenance

This milestone starts only after Plan 23 has delivered `EvidenceDecisionId`,
`EvidenceSourceId`, and validated non-empty source citations on each accepted atom.

Compute `l1AuditKey` before a data atom's consolidation call or an instruction atom's deterministic
application, and pass it through `applyAtom`, `applyDecision`, `recordAtom`, and `writeAudit`. Build
one L1 cause per atom from the session ID, the persisted evidence decision ID, that atom's exact
source citations, and the consolidation/policy audit decision ID. Do not attach all selected
envelope IDs to every atom.

Use `recordWithProvenance` for the new deterministic winner recorded by `StoreAtom`, `UpdateAtom`,
or `MergeAtom`. A merge changes the loser rows' status but preserves their own creation provenance.
The new winner's provenance names the sources and decision that created it. Add the same L1 cause
to the consolidation audit row even when the applied action is skip and no memory exists; the
audit artifact still has a cause.

Before recording a deterministic winner, check for that ID in the authorized space. If no row
exists, create it with the current cause. If a substantively identical row already exists, treat
the memory as already accepted and preserve its stored provenance; do not attach the retry's calls
to it. If the existing row's substantive fields conflict, fail with the existing integrity error.
Apply the same create-or-preserve rule to a deterministic audit key. This covers a crash after an
artifact transaction but before downstream scheduling or watermark advancement without turning a
recovery call into the artifact's historical creator.

When Plan 16 is available, add the accepted data or trusted-instruction extraction call that
produced the atom. A data atom then adds its accepted consolidation call; an instruction atom adds
no fabricated consolidation call. Failed attempts and the other extraction lane's unrelated call
are absent from the artifact.
They remain discoverable through Plan 16's operation ledger. The `MemoryRecorded` inline
projection inserts the accepted memory associations from the event's provenance in the same
`runCommandWithProjections` transaction, and `writeAudit` inserts the audit associations with its
row. Do not add those links in a fallible post-write step. If Plan 16 has not landed, use an empty
list and keep the schema stable.

Update `AuditRow`, insert SQL, and tests. The existing `candidateContent` is model-produced atom
content, not rejected L0 content; this plan does not add raw source content to the audit.

Milestone acceptance proves that two memories produced by one lane can cite different
source-evidence subsets and share that lane's accepted extraction call, while an instruction
memory cites only the trusted-instruction lane and its call. All reference the same evidence
decision and their own audit decision; only data artifacts reference a consolidation call.
Excluded or uncited evidence IDs appear on neither.

### Milestone 4: add L2 and L3 current-version provenance

Extend `SceneRow` and the scene SQL with provenance. When `regenerateScene` reaches the changed
source-hash branch, construct `L2Cause` from the exact active memory IDs already used to render the
prompt and the same source hash, then replace content, source hash, and provenance in one
transaction. The list is non-empty by construction. An unchanged-source skip returns the existing
row and provenance unchanged. An empty-source path deletes the scene and its provenance with the
row.

Extend `PersonaRow` and persona SQL with provenance. Construct `L3Cause` from the exact scene IDs
used to render the prompt and the same source hash, then replace it atomically with the changed
persona version. An unchanged-source skip preserves it; an empty-source path deletes it.

Timer handlers currently receive a `TimerRow` and then call regeneration with only space and scope.
Add internal regeneration variants that accept an optional trigger timer ID, while preserving the
existing direct-library functions with `Nothing`. Timer fires pass their real timer ID. The timer
is operational trigger context, not a substitute for the source set.

When Plan 16 is available, put the one accepted scene or persona generation call ID in the
corresponding cause. The model-call ledger independently associates the same ID with the artifact.
Insert that association in the same transaction as the scene or persona upsert; deletion removes
the row and its associations together. Best-effort mirror writes do not change provenance: the
database row is authoritative, and model evidence says nothing about whether a convenience file
write succeeded.

Milestone acceptance proves exact memory and scene source sets, accepted call IDs when integrated,
unchanged-source provenance stability, no-call deletion behavior, and correct optional timer
attribution.

### Milestone 5: expose inspection and prove the causal chain

Add library queries for memory, consolidation decision, scene, and persona provenance. Each public
function accepts `MemoryAccessContext`, checks `MemoryRead`, derives the space only from that
context, and returns denial distinctly from absence. Every SQL predicate begins with
`memory_space_id` even when the artifact ID is globally unique.

Add a CLI command using the current `KIOKU_MEMORY_SPACE` selection:

```bash
kioku provenance memory MEMORY_ID
kioku provenance consolidation-decision DECISION_ID
kioku provenance scene SCENE_ID
kioku provenance persona PERSONA_ID
```

Print versioned JSON. Do not include raw evidence, model prompts, model output, or inlined provider
records.

Extend `Kioku.DistillSpec` with a complete Plan-23-aware pipeline. Assert that an L1 memory points
to the persisted evidence decision and only its exact cited source IDs; its consolidation audit
points to the same cause; the scene names the active memory IDs; and the persona names the scene
IDs. When Plan 16 is integrated, assert the accepted call IDs match its association table. Run the
same artifact identifiers in two spaces and prove all queries remain disjoint.

Add focused tests that a confidence update triggers scene regeneration without rewriting the
memory's creation provenance, and that merge/supersede/archive leave it unchanged. Add a native
old-event fixture and a migration test for legacy-native backfill. Do not add a Rei compatibility
fixture; ADR-11 requires that input to fail.

Update `docs/user/concepts.md`, `docs/user/distillation.md`,
`docs/user/library-api.md`, and `docs/user/cli-reference.md`. Explain creation-versus-mutation
semantics, source citation, legacy-native unknowns, provider-call links, and partitioned
inspection.

Before completing the plan, create or update an ADR for the versioned cause vocabulary,
memory/audit creation-time immutability, scene/persona current-version semantics, historical
unknown handling, and the boundary between artifact provenance and provider evidence.


## Concrete Steps

Run from the repository root,
`/Users/shinzui/Keikaku/bokuno/kioku`.

Verify the current tree, project registration, and migration tail:

```bash
git status --short
mori show --full
tail -n 5 kioku-migrations/migrations/manifest
```

Create `Kioku.Provenance`, expose it in `kioku-core/kioku-core.cabal`, and run its focused tests:

```bash
nix develop -c cabal test kioku-core --test-options='-p "Provenance"'
```

Allocate the migration only when ready to implement it:

```bash
just new-migration kioku-artifact-provenance
```

After memory event and projection work:

```bash
nix develop -c cabal test kioku-core --test-options='-p "native codec compatibility"'
nix develop -c cabal test kioku-core --test-options='-p "memory space"'
nix develop -c cabal test kioku-migrations
```

After L1/L2/L3 and inspection work:

```bash
nix develop -c cabal test kioku-core --test-options='-p "Distillation pyramid"'
nix develop -c cabal test kioku-cli
nix develop -c cabal test all --test-show-details=direct
nix flake check
```

Expected success is every named suite reporting `PASS` with no `Failed to build` line. Do not pin
the case count because other plans may land first.

Every implementation commit uses a Conventional Commit message and includes:

```text
MasterPlan: docs/masterplans/4-secure-and-accountable-distillation-evidence.md
ExecPlan: docs/plans/8-add-first-class-provenance.md
Intention: intention_01kwxabxj6ewdr5fncb56nh67n
```


## Validation and Acceptance

A manual memory write through the existing `recordWithContext` API produces versioned
`ManualCause` in the authorized space without requiring the caller to add a Haskell record field.
An explicit provenance write round-trips every cause field. A provenance-space mismatch is a loud
write error before append, and a non-memory or legacy cause is rejected before append.

A native Kioku `MemoryRecorded` payload from before this feature replays and projects as
`LegacyNativeCause`. No code claims it was manual, distilled, or imported from Rei. A retired Rei
tag remains a decode error.

A confidence or tag update and a merge, supersede, or archive operation leave the memory's
creation provenance unchanged. The ordinary native events continue to show the later mutation's
actor and time.

An L1 memory and consolidation decision carry one evidence decision ID and the atom's exact cited
source IDs. Different atoms from one lane can carry different source subsets; an instruction
artifact cites only the trusted-instruction lane. Excluded, unknown, cross-lane, and uncited
evidence IDs do not appear. A scene carries exactly the active memory IDs used for its changed
source hash and repeats that hash in its cause; a persona does the same for its scene IDs and
source hash.

When Plan 16 is integrated, artifact provenance carries only accepted call IDs. The same IDs exist
in `kioku.distillation_model_call_artifacts`. Failed and orphaned attempts remain absent from
provenance and present in the ledger.

An up-to-date L1 pass, unchanged L2/L3 source hash, empty-source deletion, or deterministic replay
does not invent new provenance or provider-call IDs. Deleting a scene or persona deletes the row
and its provenance rather than preserving stale causal metadata.

Two spaces with identical artifact IDs, namespace, scope, source IDs, and call IDs cannot inspect
or mutate each other's provenance. Denial remains distinct from no row.

The full validation commands are:

```bash
nix develop -c cabal build all --enable-tests
nix develop -c cabal test all --test-show-details=direct
nix flake check
```


## Idempotence and Recovery

Provenance constructors normalize call IDs deterministically and preserve source order. Repeating
the same L1/L2/L3 pass preserves byte-equivalent provenance. Existing deterministic artifact IDs
and upserts remain the idempotency keys; this plan does not create a second artifact identity. If a
prior attempt already committed an artifact, a retry reads and retains its provenance. Provider
calls unique to the retry remain unlinked rather than being appended to the creation cause.

The migration follows Kioku's strict forward-only pg-migrate convention. Backfill reads each row's
actual memory space and writes an explicit versioned legacy-native value before the column becomes
non-null. It must reject unknown partial layouts instead of hiding them behind broad
`IF EXISTS` guards. Disposable test failures recover by recreating the database; production
recovery follows the documented backup or forward-repair path.

A replay into an empty read model recreates provenance from the native creation event. Later
events cannot erase it. If a native old event lacks provenance, the decoder supplies
`LegacyNativeCause` in memory; no historical event rewrite is required.

If Plan 16 lands later, a forward application change may populate call IDs only for newly created
artifacts. Do not infer provider calls for historical artifacts. A separate evidenced backfill
would need independently retained ledger links and is outside this plan.

If CLI inspection proves too large, library inspection plus real integration tests may ship first,
but record the deferral in the Decision Log and revision notes. Do not weaken the authorization or
observable-outcome requirements.


## Interfaces and Dependencies

The exposed module should be equivalent to:

```haskell
module Kioku.Provenance
  ( ArtifactProvenance
  , ProvenanceCause(..)
  , ProvenanceSchemaVersion
  , manualProvenance
  , legacyNativeProvenance
  , l1Provenance
  , l2Provenance
  , l3Provenance
  , provenanceMemorySpace
  , provenanceModelCallIds
  )
```

`ArtifactProvenance` has `Eq`, `Show`, `ToJSON`, and `FromJSON`. Its smart constructors enforce
non-empty source sets and normalize call IDs. Consumers cannot construct a value whose wrapper
space and cause disagree.

The memory write seam is:

```haskell
recordWithProvenance
  :: MemoryAccessContext
  -> ArtifactProvenance
  -> RecordMemoryData
  -> Eff es (Either MemoryWriteError MemoryId)
```

The existing `recordWithContext` remains and supplies `ManualCause`. Other memory mutations do
not accept provenance because they do not replace creation cause.

Public inspection is equivalent to:

```haskell
getMemoryProvenance
  :: MemoryAccessContext
  -> MemoryId
  -> Eff es (Either ProvenanceReadError (Maybe ArtifactProvenance))

getConsolidationDecisionProvenance
  :: MemoryAccessContext
  -> Text
  -> Eff es (Either ProvenanceReadError (Maybe ArtifactProvenance))

getSceneProvenance
  :: MemoryAccessContext
  -> Text
  -> Eff es (Either ProvenanceReadError (Maybe ArtifactProvenance))

getPersonaProvenance
  :: MemoryAccessContext
  -> Text
  -> Eff es (Either ProvenanceReadError (Maybe ArtifactProvenance))
```

Plan 23 supplies `EvidenceDecisionId`, `EvidenceSourceId`, and validated atom citations. It is a
hard dependency. Plan 16 supplies accepted Baikai call IDs and owns the reverse association and
attempt ledger. It is an integration dependency; an empty call-ID list is valid before it lands.

Kioku depends on `mori://shinzui/kiroku/packages/kiroku-store` for native stored events and
`mori://shinzui/keiro/packages/keiro` for aggregate command execution. This plan does not change
either dependency. Inspect their released source through Mori again before relying on an API; the
local corpus may lag the package registry.


## Revision Notes

- 2026-07-07: Kept first-class provenance focused on causal artifact links and delegated detailed
  model-call capture to Plan 16.
- 2026-08-06: Added the planned memory-space partition and evidence-selection decision link.
- 2026-08-22: Rebased the plan on current Kioku. Replaced free-text provenance with a versioned
  closed cause sum, immutable for memory/audit creation and replaced only with an accepted changed
  scene/persona version; preserved public record construction through an explicit write API;
  consumed the completed partition, authorization, and `kioku` schema contracts; made L1 use exact
  Plan 23 citations; reconciled artifact-local call IDs with Plan 16's atomic many-to-many ledger;
  removed automatic Rei provenance after decoder retirement; added dynamic migration allocation,
  retry preservation, current no-call behavior, authorization-aware inspection, and full commit
  trailers.
