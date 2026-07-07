---
id: 8
slug: add-first-class-provenance
title: "Add first-class provenance"
kind: exec-plan
created_at: 2026-07-07T03:36:53Z
intention: intention_01kwxabxj6ewdr5fncb56nh67n
---

# Add first-class provenance

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, a Kioku user can inspect any memory, scene, or persona and answer the question: "what caused this artifact to exist?" Today Kioku stores durable event streams and read-model rows, but many generated artifacts only carry indirect clues such as `session_id`, `atom_ids`, or `source_hash`. First-class provenance means Kioku records a structured, queryable explanation alongside each derived artifact: the origin kind, source session, source turn ids, source memory ids, consolidation decision id, timer id, and any model/behavior label that produced the artifact.

The observable result is not only that code compiles. A user can run a distillation pass, query the resulting `kioku_memories`, `kioku_consolidation_decisions`, `kioku_scenes`, and `kioku_personas` rows, and see structured provenance JSON that links the L1 memory back to the session turns, the L2 scene back to the atom memories, and the L3 persona back to the scene rows. Existing callers continue to work because default/manual provenance is supplied where older write paths do not know a cause.


## Progress

- [ ] Add a `Kioku.Provenance` module with a stable JSON type, constructors, and helpers for manual writes, L1 distillation, L2 scene regeneration, and L3 persona regeneration.
- [ ] Add a migration that stores provenance on the relevant Kioku read-model tables and audit table.
- [ ] Thread provenance through memory event payloads and memory write APIs without breaking existing callers.
- [ ] Update the memory read model so `MemoryRow` exposes provenance and legacy rows decode to default manual provenance.
- [ ] Thread L1 distillation provenance through extraction, consolidation, memory writes, memory merges, and consolidation audit rows.
- [ ] Thread L2 and L3 provenance into scene and persona rows.
- [ ] Add CLI or library-facing inspection for provenance, or extend existing row output used by tests so provenance is externally observable.
- [ ] Add focused tests proving a distilled memory, scene, and persona carry the expected provenance chain.
- [ ] Update docs to describe provenance semantics and run the full validation suite.


## Surprises & Discoveries

(None yet.)


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


## Outcomes & Retrospective

No implementation has started yet. The expected outcome is a Kioku-owned provenance contract visible on memories, consolidation decisions, scenes, and personas, with tests showing the chain from session turns to L1 memories to L2 scenes to L3 personas.


## Context and Orientation

Kioku is a Haskell library and CLI for durable agent memory. Its source of truth is an event log managed through Kiroku and Keiro. An event log is an append-only record of facts that happened, such as "memory recorded" or "session completed." A read model is a database table derived from those events for fast queries, such as `kiroku.kioku_memories`.

The key memory aggregate lives in `kioku-core/src/Kioku/Memory/Domain.hs`. It defines command payload types such as `RecordMemoryData` and event payload types such as `MemoryRecordedData`, `MemoryMergedData`, and `MemoryConfidenceUpdatedData`. A command is a requested state transition. An event is the durable fact appended after the transition is accepted. `kioku-core/src/Kioku/Memory/EventStream.hs` encodes and decodes memory events, including compatibility with historical Rei payloads. `kioku-core/src/Kioku/Memory.hs` is the public write API and currently calls `runCommandWithProjections defaultRunCommandOptions ...` in `runMemoryCommand`. `kioku-core/src/Kioku/Memory/ReadModel.hs` projects memory events into `kiroku.kioku_memories`.

Session events live in `kioku-core/src/Kioku/Session/Domain.hs`, and session read-model rows live in `kioku-core/src/Kioku/Session/ReadModel.hs`. Session turns are the L0 evidence for distillation. A turn is one recorded conversation/tool step with fields such as role, content, and token counts. Session lineage already records `previousSessionId`, `parentSessionId`, and `delegationDepth`, but that lineage is about session relationships, not about why a specific memory or scene exists.

Distillation is Kioku's model-driven pipeline that turns raw evidence into compact memory. `kioku-core/src/Kioku/Distill/L1.hs` extracts atoms from session turns, consolidates each atom against existing memories, writes new memories through `Kioku.Memory.record`, merges duplicates through `Kioku.Memory.merge`, and writes audit rows into `kiroku.kioku_consolidation_decisions`. L2 scenes are generated in `kioku-core/src/Kioku/Distill/L2.hs` from active atom memories and stored in `kiroku.kioku_scenes`. L3 personas are generated in `kioku-core/src/Kioku/Distill/L3.hs` from scenes and stored in `kiroku.kioku_personas`. `kioku-core/src/Kioku/Distill/Timer.hs` schedules L1 timers from session events, and `kioku-core/src/Kioku/Distill/Timer/Worker.hs` fires due timers.

The database tables are created by SQL migrations in `kioku-migrations/sql-migrations/`. `2026-06-24-00-00-00-kioku-base.sql` creates `kioku_memories`, `kioku_sessions`, and `kioku_turns`. `2026-06-24-02-00-00-kioku-distillation.sql` creates `kioku_scenes`, `kioku_personas`, and `kioku_consolidation_decisions`. This plan adds a new migration rather than editing old migrations, because existing databases may already have applied the old files.

The dependency lookup relevant to provenance is Kiroku and Keiro. `Kiroku.Store.Types.RecordedEvent` has `eventId`, `causationId`, `correlationId`, `metadata`, and `globalPosition`; `Kiroku.Store.Causation` can walk causation descendants and ancestors. Keiro's `RunCommandOptions` currently exposes `eventIds` and `metadata`, but not a direct causation or correlation option for plain aggregate commands. For this plan, "first-class provenance" therefore means a Kioku-owned structured data type that appears in Kioku payloads, read models, tests, and user-facing inspection. A later plan can map that type into Kiroku's store-level causation fields if Keiro grows the needed options.

Use `docs/plans/3-kioku-distillation-pyramid-l0-to-l3.md` as background for the distillation pipeline. This plan must remain self-contained, so the key facts from that plan are repeated here: L1 writes atom memories from session evidence, L2 writes scene rows from atom memories, and L3 writes persona rows from scenes.


## Plan of Work

### Milestone 1 - Define the provenance type and schema storage

Add a new module `kioku-core/src/Kioku/Provenance.hs`. It should define a small stable record type:

```haskell
data Provenance = Provenance
  { kind :: !Text
  , causedBySessionId :: !(Maybe Text)
  , causedByTurnIds :: ![Text]
  , causedByMemoryIds :: ![Text]
  , causedBySceneIds :: ![Text]
  , causedByDecisionId :: !(Maybe Text)
  , causedByTimerId :: !(Maybe Text)
  , behavior :: !(Maybe Text)
  , model :: !(Maybe Text)
  , note :: !(Maybe Text)
  }
```

The field names should remain in lower camel case in JSON because the rest of Kioku event payloads use ordinary record field encoding through `ToJSON` and `FromJSON`. The `kind` field is a short machine-readable origin label. Use at least these values: `manual`, `imported:rei`, `distillation:l1`, `distillation:l2`, and `distillation:l3`. Provide helpers named `manualProvenance`, `importedReiProvenance`, `l1Provenance`, `l2Provenance`, and `l3Provenance`. Define a parser helper `parseProvenanceDefault :: Provenance -> Value -> Parser Provenance` or equivalent so old JSON payloads and old read-model rows can default safely.

Add the module to `kioku-core/kioku-core.cabal` under the library's `exposed-modules` or `other-modules`, matching the surrounding convention. If the module is intended for library consumers, expose it. The recommended choice is to expose `Kioku.Provenance`, because hosts need to attach provenance to manual memory writes.

Create a migration `kioku-migrations/sql-migrations/2026-07-07-00-00-00-kioku-provenance.sql` with `-- codd: in-txn` and `SET search_path TO kiroku, pg_catalog;`. It should add `provenance jsonb NOT NULL DEFAULT '{}'::jsonb` to `kioku_memories`, `kioku_scenes`, `kioku_personas`, and `kioku_consolidation_decisions`. Add indexes only where they support likely queries. A useful first set is:

```sql
CREATE INDEX IF NOT EXISTS kioku_memories_provenance_kind_idx
  ON kioku_memories ((provenance->>'kind'));

CREATE INDEX IF NOT EXISTS kioku_consolidation_provenance_kind_idx
  ON kioku_consolidation_decisions ((provenance->>'kind'));
```

Do not add many JSON expression indexes until a query needs them. Keep the migration additive and safe to run on an existing database.

Milestone 1 acceptance: `cabal build kioku-core kioku-migrations` succeeds, and a migrated test database has the new `provenance` columns. A direct `psql` schema inspection should show the columns with a `jsonb` type.

### Milestone 2 - Thread provenance through memory events and read models

Update `kioku-core/src/Kioku/Memory/Domain.hs`. Add a `provenance :: !Provenance` field to every memory command and event payload where an artifact changes because of a user, model, or workflow action: `RecordMemoryData`, `SupersedeMemoryData`, `ArchiveMemoryData`, `UpdateMemoryTagsData`, `UpdateMemoryConfidenceData`, `MergeMemoryData`, and the corresponding event data types. If this proves too broad for the first implementation, prioritize `RecordMemoryData`, `MemoryRecordedData`, `MergeMemoryData`, and `MemoryMergedData`, because those are the paths used by distillation.

Update the `FromJSON` instances where automatic deriving cannot default missing fields. `MemoryRecordedData` already has a custom legacy parser in `kioku-core/src/Kioku/Memory/EventStream.hs`; keep legacy Rei parsing and set `provenance = importedReiProvenance`. For native event payloads missing `provenance`, decode successfully with `manualProvenance`. This is required because old event streams and tests may replay old JSON.

Update `kioku-core/src/Kioku/Memory.hs` so existing functions remain easy to call. Preserve existing `record`, `supersede`, `archive`, `updateTags`, `updateConfidence`, and `merge` behavior by filling `manualProvenance` when callers do not provide one. Add explicit provenance variants only if the command payload approach becomes awkward. Recommended names are `recordWithProvenance` and `mergeWithProvenance`; these wrappers construct or update command data and call the same internal `runMemoryCommand`. L1 distillation should use the provenance-aware variants.

Update `kioku-core/src/Kioku/Memory/ReadModel.hs`. Add `provenance :: !Provenance` to `MemoryRow`, update decoders/encoders, and update `upsertMemoryStmt` and update statements so the row carries the provenance of the event that most recently changed the artifact. For `MemoryRecorded`, insert the event provenance. For `MemoryMerged`, update the loser row with merge provenance. For updates and archive/supersede events, update provenance to the corresponding event provenance. If tests reveal a more useful semantic, record it in the Decision Log before changing this rule.

Milestone 2 acceptance: existing memory tests still pass, legacy Rei compatibility still passes, and a direct manual memory record returns a `MemoryRow` with `provenance.kind == "manual"`.

### Milestone 3 - Add L1 distillation provenance

Update `kioku-core/src/Kioku/Distill/L1.hs`. Generate the consolidation `decisionId` before applying a decision, not after, so the memory writes and audit row share the same id. Today `writeAudit` generates an `auditKey` after `applyDecision`; move that generation into `applyAtom` and pass it into both `applyDecision` and `writeAudit`.

Build an L1 provenance value from the session and evidence:

```haskell
l1Provenance
  { causedBySessionId = Just (idText sid)
  , causedByTurnIds = (.turnId) <$> turnsUsedForExtraction
  , causedByMemoryIds = candidate memory ids or fallback memory ids
  , causedByDecisionId = Just decisionId
  , behavior = Just "Kioku.Distill.L1.distillSessionL1"
  , model = Just (render model when available)
  }
```

The exact helper should live in `Kioku.Provenance`; the record update shown above is illustrative. `buildExtractInput` currently returns only `ExtractInput`, so add a small local record such as `ExtractEvidence` that contains the input plus `sourceTurnIds` and fallback memory ids. Keep rendering functions unchanged unless they need to return ids.

When `applyDecision` stores a memory, pass L1 provenance into `Memory.record` or `recordWithProvenance`. When `applyDecision` merges target memories into the winner, pass merge provenance into `Memory.merge` or `mergeWithProvenance`. Update the `AuditRow` type and `insertAuditStmt` in `L1.hs` to write the same provenance JSON into `kioku_consolidation_decisions.provenance`.

Milestone 3 acceptance: the replay-backed distillation test in `kioku-core/test/Kioku/DistillSpec.hs` proves that the stored L1 memory row has `provenance.kind == "distillation:l1"`, `causedBySessionId` set to the test session id, a non-empty `causedByTurnIds`, and `causedByDecisionId` equal to the audit row's decision id. It should also prove the loser merged row carries merge provenance rather than losing the chain.

### Milestone 4 - Add L2/L3 artifact provenance

Update `kioku-core/src/Kioku/Distill/L2.hs`. Add `provenance :: !Provenance` to `SceneRow`, read it from and write it to `kioku_scenes`, and construct it in `regenerateScene` from the active atom memories used as input. `causedByMemoryIds` should be `(.memoryId) <$> atoms`, `behavior` should be `Just "Kioku.Distill.L2.regenerateScene"`, and `kind` should be `distillation:l2`. When `fireL2SceneTimer` calls `regenerateScene`, pass the timer id when practical so `causedByTimerId` is set. If threading timer id through the whole call complicates the first implementation, set timer id only for timer-triggered calls and leave it `Nothing` for direct library calls.

Update `kioku-core/src/Kioku/Distill/L3.hs`. Add `provenance :: !Provenance` to `PersonaRow`, read it from and write it to `kioku_personas`, and construct it in `regeneratePersona` from the scene rows used as input. `causedBySceneIds` should be the scene ids, `behavior` should be `Just "Kioku.Distill.L3.regeneratePersona"`, and `kind` should be `distillation:l3`.

Update mirror output only if it helps users. The safest first version is to leave `.kioku/scenes/*.md` and `.kioku/persona/*.md` unchanged so generated context remains clean for agents. If a visible provenance view is desired, add a separate CLI command in a later milestone rather than mixing metadata into context files.

Milestone 4 acceptance: the existing distillation pyramid test verifies `SceneRow.provenance.kind == "distillation:l2"` with atom ids in `causedByMemoryIds`, and `PersonaRow.provenance.kind == "distillation:l3"` with scene ids in `causedBySceneIds`.

### Milestone 5 - Expose provenance for inspection and document it

Choose one user-visible inspection path. The minimal path is to expose provenance in row-returning library APIs and add focused tests; the better path is to add CLI support. If adding CLI support, extend `kioku-cli` with a command such as:

```text
kioku provenance memory MEMORY_ID
kioku provenance scene --scope NAMESPACE[:KIND:REF]
kioku provenance persona --scope NAMESPACE[:KIND:REF]
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

All commands below run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kioku
```

Start by confirming the tree and project identity:

```bash
git status --short
mori show --full
```

Expected `git status --short` output is empty or contains only files intentionally related to this ExecPlan. `mori show --full` should identify the project as `shinzui/kioku`.

Create the provenance module and add it to the cabal file. After the module compiles, run:

```bash
cabal build kioku-core
```

Expected final output includes a successful build and no `Failed to build` line:

```text
Building library for kioku-core-0.1.0.0...
```

Add the migration file:

```bash
ls kioku-migrations/sql-migrations/*kioku-provenance.sql
cabal build kioku-migrations
```

Then update memory event payloads and read models. Run the focused tests after each chunk:

```bash
cabal test kioku-core --test-options='-p "Rei legacy codec compatibility"'
cabal test kioku-core --test-options='-p "Distillation pyramid"'
```

When the full feature is wired, run:

```bash
cabal test all
```

Expected final test summary:

```text
All ... tests passed
Test suite kioku-test: PASS
```

If adding CLI inspection, run a smoke command after creating test data through an existing demo or distillation flow:

```bash
cabal run kioku -- provenance memory MEMORY_ID
```

Expected output is valid JSON containing a `kind` field. The exact ids vary by run.


## Validation and Acceptance

The implementation is accepted when all of the following are true.

First, all existing behavior remains compatible. `cabal test all` passes. The Rei legacy compatibility tests continue to decode historical memory payloads without requiring provenance fields. Existing library callers that use `Kioku.Memory.record` and `Kioku.Memory.merge` still compile or have mechanical defaults documented in the plan's Decision Log.

Second, a manual memory write produces default provenance. A focused unit or integration test records a memory through `Kioku.Memory.record`, reads it through `getMemoryRowById`, and asserts:

```text
provenance.kind == "manual"
provenance.causedBySessionId == Nothing
provenance.causedByMemoryIds == []
```

Third, L1 distillation produces linked provenance. Extend `kioku-core/test/Kioku/DistillSpec.hs` so the existing replay-backed scenario asserts that the generated memory row has:

```text
provenance.kind == "distillation:l1"
provenance.causedBySessionId == Just <test session id>
provenance.causedByTurnIds is not empty
provenance.causedByDecisionId == Just <audit decision id>
```

The same test should assert that the `kioku_consolidation_decisions.provenance` JSON has `kind = "distillation:l1"` and references the same session.

Fourth, L2 and L3 artifacts expose their source sets. The distillation pyramid test or a new focused test asserts:

```text
scene.provenance.kind == "distillation:l2"
scene.provenance.causedByMemoryIds contains the atom memory id
persona.provenance.kind == "distillation:l3"
persona.provenance.causedBySceneIds contains the scene id
```

Fifth, if CLI inspection is included, `kioku provenance memory MEMORY_ID` prints parseable JSON and includes the expected `kind` and cause fields. This proves the feature is visible to users without direct SQL access.

The validation commands are:

```bash
cabal build all
cabal test all
```

If the migration is changed, also run a migration-backed test through the existing test suite, because `withKiokuMigratedDatabase` applies the SQL migrations before tests. No separate production database migration command is required for the automated test path.


## Idempotence and Recovery

The SQL migration must be idempotent. Use `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS`. Do not mutate old migration files. If the migration fails during development on a disposable test database, rerun `cabal test all`; the test support creates fresh migrated databases.

The Haskell changes should preserve decoding of old events by supplying default provenance when JSON lacks the new field. If a test fails with a JSON parse error mentioning `provenance`, fix the `FromJSON` instance or legacy parser rather than editing old event fixtures.

If row decoder changes break unrelated read models, isolate the change by adding provenance to row-returning models first and only then to public record types. Keep each intermediate state buildable. If a direct CLI provenance command proves too large, defer it and satisfy first visibility through library row fields plus tests; record that decision in the Decision Log.

If a cross-repo Keiro/Kiroku change becomes necessary, stop and split that work into a separate ExecPlan. Do not opportunistically edit `/Users/shinzui/Keikaku/bokuno/keiro` or `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` from this plan. This plan's scope is Kioku-owned provenance in payloads and read models.


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

`Kiroku.Store.Types.RecordedEvent` contains store-level event id, causation id, correlation id, metadata, and global position. `Kiroku.Store.Causation` can query causation chains. These are not the first implementation target because the Kioku command path goes through Keiro.

`Keiro.Command.RunCommandOptions` currently exposes `eventIds`, `metadata`, and tracing, but not plain command causation/correlation fields. Use `metadata` only for ambient context if needed. Do not rely on metadata for the core Kioku provenance contract; store the core contract in event payloads and read-model columns.

`Data.Aeson` is the JSON library to use for `Provenance` encoding. `Hasql.Encoders` and `Hasql.Decoders` are already used in `Kioku.Memory.ReadModel`, `Kioku.Distill.L1`, `Kioku.Distill.L2`, and `Kioku.Distill.L3`; extend the existing JSONB patterns there.

Every commit made while implementing this plan must include:

```text
ExecPlan: docs/plans/8-add-first-class-provenance.md
```
