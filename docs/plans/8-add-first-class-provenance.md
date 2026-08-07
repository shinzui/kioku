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


## Purpose / Big Picture

After this change, a Kioku user can inspect any memory, scene, or persona and answer the question: "what caused this artifact to exist?" Today Kioku stores durable event streams and read-model rows, but many generated artifacts only carry indirect clues such as `session_id`, `atom_ids`, or `source_hash`. First-class provenance means Kioku records a structured, queryable explanation alongside each derived artifact: the memory space, origin kind, source session, selected source turn ids, source memory ids, evidence-selection decision id, consolidation decision id, timer id, optional model-call evidence ids, and the behavior label that produced the artifact.

The observable result is not only that code compiles. A user can run a distillation pass, query the resulting `kioku_memories`, `kioku_consolidation_decisions`, `kioku_scenes`, and `kioku_personas` rows, and see structured provenance JSON that links the L1 memory to the accepted evidence decision, the L2 scene to atom memories, and the L3 persona to scene rows, all inside one memory space. If `docs/plans/16-add-distillation-replay-metadata.md` has also been implemented, the same provenance object points to Baikai model-call evidence. Existing callers continue to work because default/manual provenance is supplied where older write paths do not know a cause.


## Progress

- [ ] Add a `Kioku.Provenance` module with a stable JSON type, constructors, and helpers for manual writes, L1 distillation, L2 scene regeneration, and L3 persona regeneration.
- [ ] Make provenance partition-aware and link L1 artifacts to the evidence decision from `docs/plans/23-gate-untrusted-session-evidence-before-l1-distillation.md`.
- [ ] Add a pg-migrate migration that stores provenance on the relevant Kioku read-model tables and audit table.
- [ ] Thread provenance through memory event payloads and memory write APIs without breaking existing callers.
- [ ] Update the memory read model so `MemoryRow` exposes provenance and legacy rows decode to default manual provenance.
- [ ] Thread L1 distillation provenance through extraction, consolidation, memory writes, memory merges, and consolidation audit rows.
- [ ] Thread L2 and L3 provenance into scene and persona rows.
- [ ] Include optional model-call evidence ids in provenance so generated artifacts can link to `docs/plans/16-add-distillation-replay-metadata.md` records when that plan is implemented.
- [ ] Add CLI or library-facing inspection for provenance, or extend existing row output used by tests so provenance is externally observable.
- [ ] Add focused tests proving a distilled memory, scene, and persona carry the expected provenance chain.
- [ ] Update docs to describe provenance semantics and run the full validation suite.


## Surprises & Discoveries

- The earlier lineage review's useful lesson for Kioku is not to replace Kioku with a full reactive graph runtime. Kioku already treats event streams as source of truth for memory and sessions; the immediate gap is artifact-level lineage. The separate replay-metadata plan should capture provider-boundary commitments and observed call metadata, while this plan should keep provenance focused on causal links.
  Evidence: `docs/user/concepts.md` says memories and sessions are event-sourced projections, while current memory and distillation rows lack structured provenance fields.

- Baikai 0.5.0.0 now owns provider-boundary evidence and canonical request/response commitments.
  Provenance should reference its call IDs instead of naming a Kioku-specific replay hash format.
  Evidence: `mori://shinzui/baikai/packages/baikai` exposes `Baikai.Evidence`.

- The isolation initiative makes `MemorySpaceId` mandatory before this plan's migration lands.
  Adding unpartitioned provenance now would create an audit path able to cross the boundary later.


## Decision Log

- Decision: Keep this ExecPlan's first implementation inside Kioku instead of changing Keiro or Kiroku.
  Rationale: Kiroku already has stored-event `causationId` and `correlationId` fields plus causation-walk APIs, but the plain Keiro command runner used by Kioku currently exposes only event metadata and caller-supplied event ids through `RunCommandOptions`. A cross-repo Keiro API change would be valuable later, but Kioku can deliver user-visible provenance now by storing structured provenance in domain payloads and read models.
  Date: 2026-07-07

- Decision: Store provenance as structured JSON plus a few existing relational links, not as only free-form text.
  Rationale: JSON keeps the first version additive and flexible while still allowing tests and CLI output to verify exact fields. Existing columns such as `session_id`, `atom_ids`, `source_hash`, and `result_memory_id` remain useful for common queries.
  Date: 2026-07-07

- Decision: Preserve backwards compatibility for old event payloads and legacy Rei import payloads by defaulting missing provenance to manual or imported provenance.
  Rationale: Kioku already supports legacy Rei event decoding in `kioku-core/src/Kioku/Memory/EventStream.hs`; adding required provenance fields without defaults would break replaying old streams.
  Date: 2026-07-07

- Decision: Provenance will reference Baikai model-call evidence by id, not inline prompt, output, or provider evidence payloads.
  Rationale: Provenance answers "what caused this artifact?" Provider evidence answers what crossed the model boundary and what the provider reported. Keeping those contracts separate prevents every artifact row from duplicating sensitive or large data.
  Date: 2026-07-07

- Decision: L1 provenance references one evidence-selection decision and only the turn IDs that
  policy selected.
  Rationale: Referencing every raw turn would claim excluded prompt-injection or secret material
  caused the artifact and would make the security gate unauditable.
  Date: 2026-08-06

- Decision: Every provenance record carries `memorySpaceId` and all inspection queries require
  that space.
  Rationale: Causal metadata is as sensitive as the artifact and must obey the same partition.
  Date: 2026-08-06


## Outcomes & Retrospective

No implementation has started yet. The expected outcome is a Kioku-owned provenance contract visible on memories, consolidation decisions, scenes, and personas, with tests showing the chain from accepted session evidence to L1 memories to L2 scenes to L3 personas. A later or parallel implementation of `docs/plans/16-add-distillation-replay-metadata.md` can make the optional model-call evidence ID fields non-empty for generated artifacts.


## Context and Orientation

Kioku is a Haskell library and CLI for durable agent memory. Its source of truth is an event log managed through Kiroku and Keiro. An event log is an append-only record of facts that happened, such as "memory recorded" or "session completed." A read model is a database table derived from those events for fast queries, such as `kiroku.kioku_memories`.

The key memory aggregate lives in `kioku-core/src/Kioku/Memory/Domain.hs`. It defines command payload types such as `RecordMemoryData` and event payload types such as `MemoryRecordedData`, `MemoryMergedData`, and `MemoryConfidenceUpdatedData`. A command is a requested state transition. An event is the durable fact appended after the transition is accepted. `kioku-core/src/Kioku/Memory/EventStream.hs` encodes and decodes memory events, including compatibility with historical Rei payloads. `kioku-core/src/Kioku/Memory.hs` is the public write API and currently calls `runCommandWithProjections defaultRunCommandOptions ...` in `runMemoryCommand`. `kioku-core/src/Kioku/Memory/ReadModel.hs` projects memory events into `kiroku.kioku_memories`.

Session events live in `kioku-core/src/Kioku/Session/Domain.hs`, and session read-model rows live in `kioku-core/src/Kioku/Session/ReadModel.hs`. Session turns are the L0 evidence for distillation. A turn is one recorded conversation/tool step with fields such as role, content, and token counts. Session lineage already records `previousSessionId`, `parentSessionId`, and `delegationDepth`, but that lineage is about session relationships, not about why a specific memory or scene exists.

Distillation is Kioku's model-driven pipeline that turns raw evidence into compact memory. `kioku-core/src/Kioku/Distill/L1.hs` extracts atoms from session turns, consolidates each atom against existing memories, writes new memories through `Kioku.Memory.record`, merges duplicates through `Kioku.Memory.merge`, and writes audit rows into `kiroku.kioku_consolidation_decisions`. L2 scenes are generated in `kioku-core/src/Kioku/Distill/L2.hs` from active atom memories and stored in `kiroku.kioku_scenes`. L3 personas are generated in `kioku-core/src/Kioku/Distill/L3.hs` from scenes and stored in `kiroku.kioku_personas`. `kioku-core/src/Kioku/Distill/Timer.hs` schedules L1 timers from session events, and `kioku-core/src/Kioku/Distill/Timer/Worker.hs` fires due timers. This plan records causal provenance for these artifacts. `docs/plans/16-add-distillation-replay-metadata.md` records Baikai evidence for the model calls themselves and supplies the model-call evidence IDs described here when both plans are present.

The active database history is now the numbered pg-migrate chain in `kioku-migrations/migrations/`; historical Codd reconciliation remains temporarily under plan 22. This plan adds the next numbered migration rather than editing applied files. It runs after `docs/plans/26-migrate-kioku-read-models-to-partitioned-memory-spaces.md`, or includes the same non-null `memory_space_id` contract if coordinated in one release.

The dependency lookup relevant to provenance is `mori://shinzui/kiroku/packages/kiroku-store` and `mori://shinzui/keiro/packages/keiro`. `Kiroku.Store.Types.RecordedEvent` has `eventId`, `causationId`, `correlationId`, `metadata`, and `globalPosition`; `Kiroku.Store.Causation` can walk causation descendants and ancestors. Keiro's `RunCommandOptions` currently exposes `eventIds` and `metadata`, but not a direct causation or correlation option for plain aggregate commands. For this plan, "first-class provenance" therefore means a Kioku-owned structured data type that appears in Kioku payloads, read models, tests, and user-facing inspection. A later plan can map that type into Kiroku's store-level causation fields if Keiro grows the needed options.

Use `docs/plans/3-kioku-distillation-pyramid-l0-to-l3.md` as background for the distillation pipeline. This plan must remain self-contained, so the key facts from that plan are repeated here: L1 writes atom memories from session evidence, L2 writes scene rows from atom memories, and L3 writes persona rows from scenes.


## Plan of Work

### Milestone 1 - Define the provenance type and schema storage

Add a new module `kioku-core/src/Kioku/Provenance.hs`. It should define a small stable record type:

```haskell
data Provenance = Provenance
  { memorySpaceId :: !MemorySpaceId
  , kind :: !Text
  , causedBySessionId :: !(Maybe Text)
  , causedByTurnIds :: ![Text]
  , causedByMemoryIds :: ![Text]
  , causedBySceneIds :: ![Text]
  , evidenceDecisionId :: !(Maybe Text)
  , causedByDecisionId :: !(Maybe Text)
  , causedByTimerId :: !(Maybe Text)
  , modelCallEvidenceIds :: ![Text]
  , behavior :: !(Maybe Text)
  , note :: !(Maybe Text)
  }
```

The field names should remain in lower camel case in JSON because the rest of Kioku event payloads use ordinary record field encoding through `ToJSON` and `FromJSON`. The `kind` field is a short machine-readable origin label. Use at least these values: `manual`, `imported:rei`, `distillation:l1`, `distillation:l2`, and `distillation:l3`. `modelCallEvidenceIds` links to rows from plan 16 and defaults to an empty list. `evidenceDecisionId` is present for policy-gated L1 work and absent for manual/imported writes. Provide helpers named `manualProvenance`, `importedReiProvenance`, `l1Provenance`, `l2Provenance`, and `l3Provenance`. Define compatibility parsing so old JSON defaults to the legacy memory space and empty optional links.

Add the module to `kioku-core/kioku-core.cabal` under the library's `exposed-modules` or `other-modules`, matching the surrounding convention. If the module is intended for library consumers, expose it. The recommended choice is to expose `Kioku.Provenance`, because hosts need to attach provenance to manual memory writes.

Create the next numbered migration in `kioku-migrations/migrations/`. It should add `provenance jsonb NOT NULL DEFAULT '{}'::jsonb` to `kioku_memories`, `kioku_scenes`, `kioku_personas`, and `kioku_consolidation_decisions`. Add indexes only where they support partitioned queries. A useful first set is:

```sql
CREATE INDEX IF NOT EXISTS kioku_memories_space_provenance_kind_idx
  ON kioku_memories (memory_space_id, (provenance->>'kind'));

CREATE INDEX IF NOT EXISTS kioku_consolidation_space_provenance_kind_idx
  ON kioku_consolidation_decisions (memory_space_id, (provenance->>'kind'));
```

Do not add many JSON expression indexes until a query needs them. Keep the migration additive and safe to run on an existing database.

Milestone 1 acceptance: `cabal build kioku-core kioku-migrations` succeeds, and a migrated test database has the new `provenance` columns. A direct `psql` schema inspection should show the columns with a `jsonb` type.

### Milestone 2 - Thread provenance through memory events and read models

Update `kioku-core/src/Kioku/Memory/Domain.hs`. Add a `provenance :: !Provenance` field to every memory command and event payload where an artifact changes because of a user, model, or workflow action: `RecordMemoryData`, `SupersedeMemoryData`, `ArchiveMemoryData`, `UpdateMemoryTagsData`, `UpdateMemoryConfidenceData`, `MergeMemoryData`, and the corresponding event data types. If this proves too broad for the first implementation, prioritize `RecordMemoryData`, `MemoryRecordedData`, `MergeMemoryData`, and `MemoryMergedData`, because those are the paths used by distillation.

Update the `FromJSON` instances where automatic deriving cannot default missing fields. `MemoryRecordedData` already has a custom legacy parser in `kioku-core/src/Kioku/Memory/EventStream.hs`; keep legacy Rei parsing and set `provenance = importedReiProvenance`. For native event payloads missing `provenance`, decode successfully with `manualProvenance`. This is required because old event streams and tests may replay old JSON.

Update `kioku-core/src/Kioku/Memory.hs` so the context-aware functions fill `manualProvenance` when callers do not provide a more specific cause, while still using the caller's required memory-space context. Deprecated legacy wrappers may preserve the old signatures only by targeting the configured legacy space from plan 25. Add explicit provenance variants only if the command payload approach becomes awkward. Recommended names are `recordWithProvenance` and `mergeWithProvenance`; these wrappers construct or update command data and call the same internal `runMemoryCommand`. L1 distillation should use the provenance-aware variants.

Update `kioku-core/src/Kioku/Memory/ReadModel.hs`. Add `provenance :: !Provenance` to `MemoryRow`, update decoders/encoders, and update `upsertMemoryStmt` and update statements so the row carries the provenance of the event that most recently changed the artifact. For `MemoryRecorded`, insert the event provenance. For `MemoryMerged`, update the loser row with merge provenance. For updates and archive/supersede events, update provenance to the corresponding event provenance. If tests reveal a more useful semantic, record it in the Decision Log before changing this rule.

Milestone 2 acceptance: existing memory tests still pass, legacy Rei compatibility still passes, and a direct manual memory record returns a `MemoryRow` with `provenance.kind == "manual"`.

### Milestone 3 - Add L1 distillation provenance

Update `kioku-core/src/Kioku/Distill/L1.hs`. Generate the consolidation `decisionId` before applying a decision, not after, so the memory writes and audit row share the same id. Today `writeAudit` generates an `auditKey` after `applyDecision`; move that generation into `applyAtom` and pass it into both `applyDecision` and `writeAudit`.

Build an L1 provenance value from the session and evidence:

```haskell
l1Provenance
  { memorySpaceId = access.memorySpaceId
  , causedBySessionId = Just (idText sid)
  , causedByTurnIds = selectedTurnIds evidenceDecision
  , causedByMemoryIds = candidate memory ids or fallback memory ids
  , causedByDecisionId = Just decisionId
  , evidenceDecisionId = Just (decisionIdOf evidenceDecision)
  , modelCallEvidenceIds = extractCallId : consolidateCallIds
  , behavior = Just "Kioku.Distill.L1.distillSessionL1"
  }
```

The exact helper should live in `Kioku.Provenance`; the record update shown above is illustrative. Consume `EvidenceDecision` from plan 23 instead of inventing a second `ExtractEvidence` type. `causedByTurnIds` is exactly the decision's selected IDs. If plan 16 has not been implemented, set `modelCallEvidenceIds = []` and keep this plan independently deliverable.

When `applyDecision` stores a memory, pass L1 provenance into `Memory.record` or `recordWithProvenance`. When `applyDecision` merges target memories into the winner, pass merge provenance into `Memory.merge` or `mergeWithProvenance`. Update the `AuditRow` type and `insertAuditStmt` in `L1.hs` to write the same provenance JSON into `kioku_consolidation_decisions.provenance`.

Milestone 3 acceptance: the replay-backed distillation test in `kioku-core/test/Kioku/DistillSpec.hs` proves that the stored L1 memory row has `provenance.kind == "distillation:l1"`, the test memory space and session, `causedByTurnIds` exactly equal to the evidence decision's selected IDs, `evidenceDecisionId` equal to that decision, and `causedByDecisionId` equal to the audit row's decision id. It should also prove excluded turn IDs are absent and the loser merged row carries merge provenance rather than losing the chain.

### Milestone 4 - Add L2/L3 artifact provenance

Update `kioku-core/src/Kioku/Distill/L2.hs`. Add `provenance :: !Provenance` to `SceneRow`, read it from and write it to `kioku_scenes`, and construct it in `regenerateScene` from the active atom memories used as input. `causedByMemoryIds` should be `(.memoryId) <$> atoms`, `behavior` should be `Just "Kioku.Distill.L2.regenerateScene"`, and `kind` should be `distillation:l2`. When `fireL2SceneTimer` calls `regenerateScene`, pass the timer id when practical so `causedByTimerId` is set. If threading timer id through the whole call complicates the first implementation, set timer id only for timer-triggered calls and leave it `Nothing` for direct library calls.

Update `kioku-core/src/Kioku/Distill/L3.hs`. Add `provenance :: !Provenance` to `PersonaRow`, read it from and write it to `kioku_personas`, and construct it in `regeneratePersona` from the scene rows used as input. `causedBySceneIds` should be the scene ids, `behavior` should be `Just "Kioku.Distill.L3.regeneratePersona"`, and `kind` should be `distillation:l3`.

Update mirror output only if it helps users. The safest first version is to leave `.kioku/scenes/*.md` and `.kioku/persona/*.md` unchanged so generated context remains clean for agents. If a visible provenance view is desired, add a separate CLI command in a later milestone rather than mixing metadata into context files.

Milestone 4 acceptance: the existing distillation pyramid test verifies `SceneRow.provenance.kind == "distillation:l2"` with atom ids in `causedByMemoryIds`, and `PersonaRow.provenance.kind == "distillation:l3"` with scene ids in `causedBySceneIds`.

### Milestone 5 - Expose provenance for inspection and document it

Choose one user-visible inspection path. The minimal path is to expose provenance in row-returning library APIs and add focused tests; the better path is to add CLI support. If adding CLI support, extend `kioku-cli` with a command such as:

```text
kioku provenance memory --memory-space SPACE MEMORY_ID
kioku provenance scene --memory-space SPACE --scope NAMESPACE[:KIND:REF]
kioku provenance persona --memory-space SPACE --scope NAMESPACE[:KIND:REF]
```

The command should print JSON so scripts can consume it. For a memory created by L1 distillation, expected output should include at least:

```json
{
  "kind": "distillation:l1",
  "causedBySessionId": "session_...",
  "causedByTurnIds": ["turn-1", "turn-2"],
  "causedByDecisionId": "kioku_consolidation_decision:..."
}
```

Update `docs/user/distillation.md` to explain that L1, L2, and L3 artifacts carry provenance. Update `docs/user/library-api.md` if `MemoryRow`, `SceneRow`, or `PersonaRow` changes are documented there. Add a short troubleshooting note explaining that legacy/imported rows may show `manual` or `imported:rei` provenance because the original event did not carry structured cause data.

Milestone 5 acceptance: a user can run a documented command or library query and see provenance without reading raw database rows.


## Concrete Steps

Start by confirming the tree and project identity:

```bash
git status --short
mori show --full
mori registry show shinzui/kiroku --full
mori registry show shinzui/keiro --full
mori registry show shinzui/baikai --full
```

Expected `git status --short` output is empty or contains only files intentionally related to this ExecPlan. `mori show --full` should identify the project as `shinzui/kioku`.

Create the provenance module and add it to the cabal file. After the module compiles, run:

```bash
nix develop -c cabal build kioku-core
```

Expected final output includes a successful build and no `Failed to build` line.

Add the migration file:

```bash
ls kioku-migrations/migrations/*kioku-provenance.sql
nix develop -c cabal build kioku-migrations
```

Then update memory event payloads and read models. Run the focused tests after each chunk:

```bash
nix develop -c cabal test kioku-core --test-options='-p "Rei legacy codec compatibility"'
nix develop -c cabal test kioku-core --test-options='-p "Distillation pyramid"'
```

When the full feature is wired, run:

```bash
nix develop -c cabal test all
```

Expected final test summary:

```text
All ... tests passed
Test suite kioku-test: PASS
```

If adding CLI inspection, run a smoke command after creating test data through an existing demo or distillation flow:

```bash
nix develop -c cabal run kioku -- provenance memory --memory-space SPACE MEMORY_ID
```

Expected output is valid JSON containing a `kind` field. The exact ids vary by run.


## Validation and Acceptance

The implementation is accepted when all of the following are true.

First, all existing behavior remains compatible. `cabal test all` passes. The Rei legacy compatibility tests continue to decode historical memory payloads without requiring provenance fields. Existing library callers that use `Kioku.Memory.record` and `Kioku.Memory.merge` still compile or have mechanical defaults documented in the plan's Decision Log.

Second, a manual memory write produces default provenance. A focused unit or integration test records a memory through `Kioku.Memory.record`, reads it through `getMemoryRowById`, and asserts:

```text
provenance.kind == "manual"
provenance.memorySpaceId == <request memory space>
provenance.causedBySessionId == Nothing
provenance.causedByMemoryIds == []
```

Third, L1 distillation produces linked provenance. Extend `kioku-core/test/Kioku/DistillSpec.hs` so the existing replay-backed scenario asserts that the generated memory row has:

```text
provenance.kind == "distillation:l1"
provenance.memorySpaceId == <test memory space>
provenance.causedBySessionId == Just <test session id>
provenance.causedByTurnIds == <evidence decision selected turn ids>
provenance.evidenceDecisionId == Just <evidence decision id>
provenance.causedByDecisionId == Just <audit decision id>
```

The same test should assert that the `kioku_consolidation_decisions.provenance` JSON has `kind = "distillation:l1"` and references the same session.

Fourth, L2 and L3 artifacts expose their source sets. The distillation pyramid test or a new focused test asserts:

```text
scene.provenance.kind == "distillation:l2"
scene.provenance.causedByMemoryIds contains the atom memory id
scene.provenance.modelCallEvidenceIds is [] before model-call evidence is implemented, or contains the scene call id after it is implemented
persona.provenance.kind == "distillation:l3"
persona.provenance.causedBySceneIds contains the scene id
persona.provenance.modelCallEvidenceIds is [] before model-call evidence is implemented, or contains the persona call id after it is implemented
```

Fifth, two spaces with identical namespace/scope fixtures cannot inspect each other's provenance.
Every library and CLI inspection accepts memory space before artifact identity.

Sixth, if CLI inspection is included, `kioku provenance memory --memory-space SPACE MEMORY_ID`
prints parseable JSON and includes the expected `kind`, `memorySpaceId`, and cause fields. This
proves the feature is visible to users without direct SQL access.

The validation commands are:

```bash
nix develop -c cabal build all
nix develop -c cabal test all
```

If the migration is changed, also run a migration-backed test through the existing test suite, because `withKiokuMigratedDatabase` applies the SQL migrations before tests. No separate production database migration command is required for the automated test path.


## Idempotence and Recovery

The SQL migration must be idempotent. Use `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS`. Do not mutate old migration files. If the migration fails during development on a disposable test database, rerun `nix develop -c cabal test all`; the test support creates fresh migrated databases.

The Haskell changes should preserve decoding of old events by supplying default provenance when JSON lacks the new field. If a test fails with a JSON parse error mentioning `provenance`, fix the `FromJSON` instance or legacy parser rather than editing old event fixtures.

If row decoder changes break unrelated read models, isolate the change by adding provenance to row-returning models first and only then to public record types. Keep each intermediate state buildable. If a direct CLI provenance command proves too large, defer it and satisfy first visibility through library row fields plus tests; record that decision in the Decision Log.

If a change to `mori://shinzui/keiro/packages/keiro` or
`mori://shinzui/kiroku/packages/kiroku-store` becomes necessary, stop and split that work into
the owning repository. This plan's scope is Kioku-owned provenance in payloads and read models.


## Interfaces and Dependencies

New Kioku module:

```haskell
module Kioku.Provenance
  ( Provenance(..)
  , manualProvenance
  , importedReiProvenance
  , l1Provenance
  , l2Provenance
  , l3Provenance
  )
```

The exact helper signatures may vary, but the exported type must have `ToJSON`, `FromJSON`, `Eq`, `Show`, and `Generic` instances. If the implementation needs PostgreSQL JSONB encoders/decoders in multiple modules, add helper functions in this module rather than duplicating Aeson boilerplate.

Updated memory interfaces in `kioku-core/src/Kioku/Memory/Domain.hs`:

```haskell
data RecordMemoryData = RecordMemoryData
  { ...
  , provenance :: !Provenance
  }

data MemoryRecordedData = MemoryRecordedData
  { ...
  , provenance :: !Provenance
  }

data MergeMemoryData = MergeMemoryData
  { ...
  , provenance :: !Provenance
  }

data MemoryMergedData = MemoryMergedData
  { ...
  , provenance :: !Provenance
  }
```

If other memory event payloads gain provenance in the same implementation, mirror the same pattern for the command and event type.

Updated write APIs in `kioku-core/src/Kioku/Memory.hs` should preserve current call ergonomics. If explicit variants are added, they should have signatures similar to:

```haskell
recordWithProvenance ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  Provenance ->
  RecordMemoryData ->
  Eff es (Either MemoryWriteError MemoryId)

mergeWithProvenance ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  Provenance ->
  MemoryId ->
  MemoryId ->
  Eff es (Either MemoryWriteError MemoryId)
```

Updated read-model row types:

```haskell
data MemoryRow = MemoryRow
  { ...
  , provenance :: !Provenance
  }

data SceneRow = SceneRow
  { ...
  , provenance :: !Provenance
  }

data PersonaRow = PersonaRow
  { ...
  , provenance :: !Provenance
  }
```

Updated `AuditRow` in `kioku-core/src/Kioku/Distill/L1.hs`:

```haskell
data AuditRow = AuditRow
  { ...
  , provenance :: !Provenance
  }
```

External dependencies and how they shape this plan:

`mori://shinzui/kiroku/packages/kiroku-store` exposes `Kiroku.Store.Types.RecordedEvent` with store-level event id, causation id, correlation id, metadata, and global position. `Kiroku.Store.Causation` can query causation chains. These are not the first implementation target because the Kioku command path goes through Keiro.

`mori://shinzui/keiro/packages/keiro` exposes `Keiro.Command.RunCommandOptions` with `eventIds`, `metadata`, and tracing, but not plain command causation/correlation fields. Use `metadata` only for ambient context if needed. Do not rely on metadata for the core Kioku provenance contract; store the core contract in event payloads and read-model columns.

`Data.Aeson` is the JSON library to use for `Provenance` encoding. `Hasql.Encoders` and `Hasql.Decoders` are already used in `Kioku.Memory.ReadModel`, `Kioku.Distill.L1`, `Kioku.Distill.L2`, and `Kioku.Distill.L3`; extend the existing JSONB patterns there.

The provenance type should include this replay link field when implemented:

```haskell
data Provenance = Provenance
  { ...
  , modelCallEvidenceIds :: ![Text]
  }
```

This field points to Baikai-derived distillation evidence rows from `docs/plans/16-add-distillation-replay-metadata.md`. It must default to `[]` for old events, manual writes, imported rows, and deployments where that plan has not been implemented.

Every commit made while implementing this plan must include:

```text
ExecPlan: docs/plans/8-add-first-class-provenance.md
```

## Revision Notes

- 2026-07-07: Updated the plan after the earlier log-primary lineage review. The change kept first-class provenance focused on causal artifact links and delegated detailed model-call capture to `docs/plans/16-add-distillation-replay-metadata.md`. The field proposed then was renamed by the 2026-08-06 revision.
- 2026-08-06: Incorporated the secure-evidence and portfolio-isolation MasterPlans. Provenance is
  now memory-space scoped, references evidence-selection decisions, and uses Baikai model-call
  evidence IDs instead of a Kioku-specific replay hash vocabulary. Migration instructions now
  target the active pg-migrate chain.
