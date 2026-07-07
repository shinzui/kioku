---
id: 16
slug: add-distillation-replay-metadata
title: "Add distillation replay metadata"
kind: exec-plan
created_at: 2026-07-07T20:46:37Z
---

# Add distillation replay metadata

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, a Kioku user can inspect a distilled memory, scene, or persona and find the model-call metadata that produced it. "Replay metadata" means a durable record of each distillation model call: which phase ran, which behavior made the call, which model was used, what structured input and output were involved, and the hashes of those values. It does not mean Kioku will automatically re-run a whole agent or fork a workflow; it means Kioku can explain and later reconstruct the model-backed distillation steps without guessing.

The observable behavior is a new queryable record for every L1 extraction, L1 consolidation, L2 scene generation, and L3 persona generation. A replay-backed test can run the existing distillation pipeline, then assert that rows exist in a new `kiroku.kioku_distillation_replay_calls` table and that generated artifact provenance from `docs/plans/8-add-first-class-provenance.md`, when implemented, references those rows by `replayCallIds`.


## Progress

- [ ] Add a durable replay metadata type and schema migration for `kioku_distillation_replay_calls`.
- [ ] Add library functions to record replay-call rows and query them by id, session, scope, and artifact.
- [ ] Instrument L1 extraction and consolidation so every model call writes replay metadata.
- [ ] Instrument L2 scene and L3 persona generation so every model call writes replay metadata.
- [ ] Link replay-call ids into artifact provenance when `docs/plans/8-add-first-class-provenance.md` has been implemented; otherwise keep this plan independently useful through the replay-call table and tests.
- [ ] Add focused tests proving replay metadata is written with stable phase labels, model labels, input hashes, output hashes, and structured JSON.
- [ ] Update user documentation and run the validation suite.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Store replay metadata in a dedicated table instead of embedding full input/output JSON in provenance.
  Rationale: Provenance answers which evidence and artifacts caused a result. Replay metadata answers which model call produced a result and with what structured input/output. Keeping these separate avoids duplicating large JSON payloads in every memory, scene, and persona row while still allowing a user to follow links from an artifact to the exact model-call record.
  Date: 2026-07-07

- Decision: The first implementation records structured inputs and outputs plus hashes, but does not provide automatic replay execution.
  Rationale: Kioku already has model-backed distillation and replay-backed tests. Capturing enough metadata to audit and later build replay is valuable now. A runtime that automatically serves recorded outputs instead of calling an LLM would require a separate design around `Shikumi` execution and should not be hidden inside this metadata plan.
  Date: 2026-07-07

- Decision: Use phase labels `l1:extract`, `l1:consolidate`, `l2:scene`, and `l3:persona`.
  Rationale: These labels map directly to existing modules: `Kioku.Distill.L1`, `Kioku.Distill.L2`, and `Kioku.Distill.L3`. They are short enough for queries and precise enough for tests.
  Date: 2026-07-07


## Outcomes & Retrospective

No implementation has started yet. The expected outcome is a durable replay metadata ledger for Kioku's distillation pyramid, with tests showing that each model-backed phase writes a record and that generated artifacts can reference those records when first-class provenance is available.


## Context and Orientation

Kioku is a Haskell library for durable agent memory. It stores memories and sessions as event streams, then projects those streams into PostgreSQL read-model tables. A read model is a table optimized for queries; it is not the source of truth for memory events, but it is the user-visible surface for recall, inspection, and distillation artifacts.

Distillation is the pipeline that turns raw session evidence into compact memory. L0 is raw evidence such as session turns. L1 is atom extraction and consolidation into durable memories. L2 is scene generation from active memories. L3 is persona generation from scenes. The user-facing explanation of this pyramid lives in `docs/user/concepts.md` and `docs/user/distillation.md`.

The main runtime type is `DistillRuntime` in `kioku-core/src/Kioku/Distill/Runtime.hs`. It carries the default model and four functions:

```haskell
data DistillRuntime = DistillRuntime
  { config :: !LLMConfig
  , defaultModel :: !Model
  , runExtract :: !(ExtractInput -> IO (Either ShikumiError ExtractOutput))
  , runConsolidate :: !(ConsolidateInput -> IO (Either ShikumiError ConsolidationDecision))
  , runScene :: !(SceneInput -> IO (Either ShikumiError SceneOutput))
  , runPersona :: !(PersonaInput -> IO (Either ShikumiError PersonaOutput))
  }
```

The L1 pipeline in `kioku-core/src/Kioku/Distill/L1.hs` calls `runExtraction` once per session and `runConsolidation` once per extracted atom. It writes memories through `Kioku.Memory.record`, merges duplicates through `Kioku.Memory.merge`, and writes consolidation audit rows into `kiroku.kioku_consolidation_decisions`.

The L2 pipeline in `kioku-core/src/Kioku/Distill/L2.hs` calls `runSceneDistillation` from `regenerateScene`, then writes a `SceneRow` to `kiroku.kioku_scenes`. The L3 pipeline in `kioku-core/src/Kioku/Distill/L3.hs` calls `runPersonaDistillation` from `regeneratePersona`, then writes a `PersonaRow` to `kiroku.kioku_personas`.

The existing replay-backed test is `kioku-core/test/Kioku/DistillSpec.hs`. It uses `Shikumi.Trace.Replay.runLLMReplay` to provide deterministic model outputs for tests. This plan should extend that test pattern. The new feature is not the same as the test replay helper: the new feature writes production-visible metadata rows during normal distillation.

This plan complements `docs/plans/8-add-first-class-provenance.md`. That plan should keep causal artifact provenance small and queryable. This plan creates the model-call records that provenance can point to through `replayCallIds`.


## Plan of Work

### Milestone 1 - Add Replay Metadata Types And Schema

Create a new module `kioku-core/src/Kioku/Distill/ReplayMetadata.hs`. It should define a stable record type for replay-call rows and helper functions for JSON hashing. A replay call is one attempt to run a model-backed distillation program. It has a phase, a scope, a behavior label, a model label, the structured input JSON, the structured output JSON when the call succeeds, and error text when the call fails.

Use a type shaped like this:

```haskell
data DistillReplayPhase
  = ReplayL1Extract
  | ReplayL1Consolidate
  | ReplayL2Scene
  | ReplayL3Persona

data DistillReplayCall = DistillReplayCall
  { replayCallId :: !Text
  , phase :: !DistillReplayPhase
  , sessionId :: !(Maybe Text)
  , namespace :: !Text
  , scopeKind :: !(Maybe Text)
  , scopeRef :: !(Maybe Text)
  , artifactKind :: !(Maybe Text)
  , artifactId :: !(Maybe Text)
  , behavior :: !Text
  , model :: !Text
  , inputHash :: !Text
  , outputHash :: !(Maybe Text)
  , inputJson :: !Value
  , outputJson :: !(Maybe Value)
  , errorText :: !(Maybe Text)
  , createdAt :: !UTCTime
  }
```

`artifactKind` and `artifactId` are optional because an extraction call may produce several atoms and a failed call may produce no artifact. Use values such as `memory`, `consolidation-decision`, `scene`, and `persona` once an artifact id is known. If an artifact id is not known at first, the implementation can either update the replay row after writing the artifact or leave artifact fields null and rely on provenance or audit rows to link back.

Create a migration named `kioku-migrations/sql-migrations/2026-07-07-01-00-00-kioku-distillation-replay-metadata.sql`. It should be additive and idempotent:

```sql
-- codd: in-txn
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS kioku_distillation_replay_calls (
  replay_call_id text PRIMARY KEY,
  phase text NOT NULL,
  session_id text,
  namespace text NOT NULL,
  scope_kind text,
  scope_ref text,
  artifact_kind text,
  artifact_id text,
  behavior text NOT NULL,
  model text NOT NULL,
  input_hash text NOT NULL,
  output_hash text,
  input_json jsonb NOT NULL,
  output_json jsonb,
  error_text text,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS kioku_distillation_replay_session_idx
  ON kioku_distillation_replay_calls (session_id);

CREATE INDEX IF NOT EXISTS kioku_distillation_replay_scope_idx
  ON kioku_distillation_replay_calls (namespace, scope_kind, scope_ref);

CREATE INDEX IF NOT EXISTS kioku_distillation_replay_phase_idx
  ON kioku_distillation_replay_calls (phase);

CREATE INDEX IF NOT EXISTS kioku_distillation_replay_artifact_idx
  ON kioku_distillation_replay_calls (artifact_kind, artifact_id);
```

Add the new module to `kioku-core/kioku-core.cabal`. Add the migration file to the embedded migration list if `kioku-migrations/src/Kioku/Migrations.hs` requires any compile-time touch or module update.

Milestone 1 acceptance: `cabal build kioku-core kioku-migrations` succeeds, and a migrated test database contains the `kioku_distillation_replay_calls` table with the columns above.

### Milestone 2 - Add Recording And Query Functions

In `Kioku.Distill.ReplayMetadata`, add functions that can be used by the distillation modules without exposing SQL details everywhere. The key helper should run a model call, record the input and result, and return both the call id and the original result.

The shape can be:

```haskell
data ReplayCallContext = ReplayCallContext
  { phase :: !DistillReplayPhase
  , sessionId :: !(Maybe SessionId)
  , scope :: !MemoryScope
  , artifactKind :: !(Maybe Text)
  , artifactId :: !(Maybe Text)
  , behavior :: !Text
  , model :: !Text
  }

recordReplayCall ::
  (ToJSON input, ToJSON output, IOE :> es, Store :> es) =>
  ReplayCallContext ->
  input ->
  Either ShikumiError output ->
  Eff es Text

withReplayMetadata ::
  (ToJSON input, ToJSON output, IOE :> es, Store :> es) =>
  ReplayCallContext ->
  input ->
  IO (Either ShikumiError output) ->
  Eff es (Text, Either ShikumiError output)
```

`withReplayMetadata` should call the supplied `IO` action, record the row, and return the generated `replayCallId` with the original result. This keeps call sites small and ensures failed LLM calls still get metadata rows with `errorText`.

Generate `replayCallId` deterministically enough for idempotent retries only if the inputs and phase are the same and that does not risk collisions. The conservative first implementation can use a fresh id derived from `genMemoryId` with a prefix such as `kioku_distillation_replay:`. If an insert hits a duplicate key during a retry, treat it as success only when the existing row has the same `inputHash`, `outputHash`, phase, and scope.

For hashing, use SHA-256 over the Aeson-encoded JSON value:

```haskell
hashJson :: ToJSON a => a -> Text
```

This hash is a Kioku implementation fingerprint, not a cross-language canonical JSON promise. Record that in a code comment and in `docs/user/distillation.md`.

Add query functions:

```haskell
getReplayCallById ::
  (Store :> es) =>
  Text ->
  Eff es (Maybe DistillReplayCall)

getReplayCallsBySession ::
  (Store :> es) =>
  SessionId ->
  Eff es [DistillReplayCall]

getReplayCallsByScope ::
  (Store :> es) =>
  MemoryScope ->
  Eff es [DistillReplayCall]
```

Milestone 2 acceptance: a focused test can call `recordReplayCall` with a fake input and output, then read it back by id and observe matching `phase`, `inputHash`, `outputHash`, `inputJson`, and `outputJson`.

### Milestone 3 - Instrument L1 Extraction And Consolidation

Update `kioku-core/src/Kioku/Distill/L1.hs`. In `distillSessionL1`, wrap the `runExtraction rt input` call with `withReplayMetadata`. Use phase `ReplayL1Extract`, `sessionId = Just sid`, `scope = sessionScope session`, `artifactKind = Nothing`, `artifactId = Nothing`, `behavior = "Kioku.Distill.L1.extract"`, and `model = renderModel rt.defaultModel`.

The current `buildExtractInput` returns only `ExtractInput`. If `docs/plans/8-add-first-class-provenance.md` is being implemented at the same time, replace it with a small local evidence record that also carries source turn ids and fallback memory ids. This plan only needs the `ExtractInput` for replay metadata.

In `applyAtom`, wrap the `runConsolidation rt ConsolidateInput{...}` call with `withReplayMetadata`. Use phase `ReplayL1Consolidate`, the same session and scope, `artifactKind = Just "consolidation-decision"` when the decision id is generated before the call, or `Nothing` if that refactor has not happened yet. The better implementation is to coordinate with plan 8: generate the consolidation `decisionId` before applying the decision, pass it into `writeAudit`, and set `artifactId = Just decisionId` in the replay-call context.

Thread the returned replay call ids into L1 provenance if `Kioku.Provenance` exists and has `replayCallIds`. If provenance is not implemented yet, tests should still assert the replay rows directly.

Milestone 3 acceptance: the existing replay-backed distillation test writes at least three replay rows for the fixture: one `l1:extract` row and two `l1:consolidate` rows. The rows have the test session id, the test scope, non-empty `inputHash`, non-empty `outputHash`, non-null `inputJson`, and non-null `outputJson`.

### Milestone 4 - Instrument L2 Scene And L3 Persona Generation

Update `kioku-core/src/Kioku/Distill/L2.hs`. In `regenerateScene`, build the existing `SceneInput` value in a local binding before calling `runSceneDistillation`. Wrap the call with `withReplayMetadata` using phase `ReplayL2Scene`, `sessionId = Nothing`, the scene scope, `artifactKind = Just "scene"`, `artifactId = Just sceneId`, `behavior = "Kioku.Distill.L2.regenerateScene"`, and `model = renderModel rt.defaultModel`.

Update `kioku-core/src/Kioku/Distill/L3.hs`. In `regeneratePersona`, build the existing `PersonaInput` value in a local binding before calling `runPersonaDistillation`. Wrap the call with `withReplayMetadata` using phase `ReplayL3Persona`, `sessionId = Nothing`, the persona scope, `artifactKind = Just "persona"`, `artifactId = Just personaId`, `behavior = "Kioku.Distill.L3.regeneratePersona"`, and `model = renderModel rt.defaultModel`.

If first-class provenance is available, set `SceneRow.provenance.replayCallIds = [sceneReplayCallId]` and `PersonaRow.provenance.replayCallIds = [personaReplayCallId]` when creating or updating rows. If provenance is not available, do not block this plan; replay metadata remains queryable by `artifactKind` and `artifactId`.

Milestone 4 acceptance: the replay-backed distillation test writes one `l2:scene` replay row and one `l3:persona` replay row. Both rows include the correct artifact id and a JSON output matching the deterministic replay fixture.

### Milestone 5 - Expose Inspection And Document The Contract

Expose replay metadata through library functions first. A CLI command is useful but not mandatory for the first implementation. If adding CLI support, add a `kioku replay-metadata` command group in `kioku-cli/src/Kioku/Cli.hs` and a new command module. Useful commands are:

```text
kioku replay-metadata call REPLAY_CALL_ID
kioku replay-metadata session SESSION_ID
kioku replay-metadata scope NAMESPACE[:KIND:REF]
```

Print JSON for scriptability. Keep default output concise if a row contains large `inputJson` or `outputJson`; provide a `--full` flag if needed.

Update `docs/user/distillation.md` to explain that Kioku records distillation replay metadata for audit and future replay work. Explain that the hashes are generated from Kioku's current JSON encoding and are meant for detecting drift within Kioku, not as a universal canonical JSON standard. Update `docs/user/library-api.md` if the replay metadata query functions are public.

Milestone 5 acceptance: a user can run a documented library query or CLI command after a distillation test/demo and see replay-call records with phase, model, hashes, and JSON payloads.


## Concrete Steps

All commands below run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kioku
```

Start by confirming the current branch state and project identity:

```bash
git status --short
mori show --full
```

Expected `mori show --full` identifies the project as `shinzui/kioku` and lists dependencies including `shinzui/kiroku` and `shinzui/keiro`.

Add `kioku-core/src/Kioku/Distill/ReplayMetadata.hs`, add it to `kioku-core/kioku-core.cabal`, and run:

```bash
cabal build kioku-core
```

Add the SQL migration and run:

```bash
cabal build kioku-migrations
```

After instrumenting L1/L2/L3, run the focused distillation test:

```bash
cabal test kioku-core --test-options='-p "Distillation pyramid"'
```

Expected final output includes:

```text
Test suite kioku-test: PASS
```

When the feature is fully wired, run:

```bash
cabal test all
```

If a CLI command is added, run it against a database populated by a distillation smoke test or demo and verify it prints valid JSON. The exact ids vary, but the output should contain a `phase`, `model`, `inputHash`, and either `outputHash` or `errorText`.


## Validation and Acceptance

The implementation is accepted when all of the following are true.

First, all existing distillation behavior still works. `cabal test all` passes. The existing replay-backed test still produces one active memory, one merged memory, one scene, and one persona.

Second, a replay-call row is written for each model-backed distillation phase. Extend `kioku-core/test/Kioku/DistillSpec.hs` to load rows from `kiroku.kioku_distillation_replay_calls` for the test scope and assert:

```text
count phase == "l1:extract" is 1
count phase == "l1:consolidate" is 2
count phase == "l2:scene" is 1
count phase == "l3:persona" is 1
```

Third, replay rows carry useful metadata. The same test should assert every row has a non-empty `replay_call_id`, non-empty `model`, non-empty `behavior`, non-empty `input_hash`, non-null `input_json`, and either a successful `output_hash` plus `output_json` or an `error_text`. The normal replay-backed fixture should produce successful rows with output hashes.

Fourth, artifact linkage works where an artifact id exists. Scene rows should be findable by `artifact_kind = 'scene'` and the generated scene id. Persona rows should be findable by `artifact_kind = 'persona'` and the generated persona id. Consolidation rows should be findable by `artifact_kind = 'consolidation-decision'` if the implementation coordinates with plan 8's early decision id generation.

Fifth, if `docs/plans/8-add-first-class-provenance.md` is implemented, generated memory, scene, and persona provenance should include replay call ids. If plan 8 is not implemented yet, this acceptance point is deferred and must be recorded in this plan's Outcomes & Retrospective.


## Idempotence and Recovery

The migration must be idempotent. Use `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS`. Do not edit old migration files.

Replay-call writes are additive. Retrying a distillation pass may create new replay-call rows, just as it may create new session or memory events depending on the existing command idempotency path. This is acceptable for the first implementation because replay metadata is an audit trail, not a deduplicated cache. If deterministic replay-call ids are added later, duplicate-key handling must compare the existing row's phase, scope, input hash, and output hash before treating the duplicate as success.

If JSON encoding or hashing tests fail because field order changes, do not weaken the tests to ignore hashes entirely. Instead, assert that hashes are non-empty and that identical input values in the same process produce identical hashes. The first implementation does not promise canonical hashes across languages or all future schema versions.

If first-class provenance is not yet implemented, keep all replay metadata changes buildable and testable without importing `Kioku.Provenance`. Add the provenance linkage in a later patch and record that decision in the Decision Log.

If a cross-repo change to `Shikumi`, `Keiro`, or `Kiroku` appears necessary, stop and split it into a separate ExecPlan. This plan should be implementable inside Kioku using the existing `DistillRuntime`, `Hasql`, and migration patterns.


## Interfaces and Dependencies

New module:

```haskell
module Kioku.Distill.ReplayMetadata
  ( DistillReplayPhase(..)
  , DistillReplayCall(..)
  , ReplayCallContext(..)
  , phaseToText
  , phaseFromText
  , hashJson
  , withReplayMetadata
  , recordReplayCall
  , getReplayCallById
  , getReplayCallsBySession
  , getReplayCallsByScope
  )
```

The module depends on `Data.Aeson` for JSON encoding, `Crypto.Hash` for SHA-256 hashing, `Hasql.Encoders` and `Hasql.Decoders` for SQL, `Kiroku.Store.Transaction.runTransaction` for database access, `Kioku.Api.Scope` for scope columns, and `Kioku.Id` for session and generated identifiers.

The distillation call sites are:

```text
kioku-core/src/Kioku/Distill/L1.hs: distillSessionL1 and applyAtom
kioku-core/src/Kioku/Distill/L2.hs: regenerateScene
kioku-core/src/Kioku/Distill/L3.hs: regeneratePersona
```

The existing runtime type in `kioku-core/src/Kioku/Distill/Runtime.hs` should not need a breaking API change. Use `rt.defaultModel` to derive a model label at each call site. If the `Model` type does not have a useful `Show` instance, add a local helper that renders enough stable information for tests, and record the decision here.

The plan is intentionally compatible with `docs/plans/8-add-first-class-provenance.md`. When provenance exists, attach replay-call ids to generated artifacts. When provenance does not exist, replay metadata remains useful through direct queries.

Every commit made while implementing this plan must include:

```text
ExecPlan: docs/plans/16-add-distillation-replay-metadata.md
```
