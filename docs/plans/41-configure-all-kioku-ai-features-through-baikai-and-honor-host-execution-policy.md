---
id: 41
slug: configure-all-kioku-ai-features-through-baikai-and-honor-host-execution-policy
title: "Configure all Kioku AI features through Baikai and honor host execution policy"
kind: exec-plan
intention: intention_01m1z6mtf8erdtq9dfgncc8aw4
created_at: 2026-09-08T00:17:18Z
---


# Configure all Kioku AI features through Baikai and honor host execution policy


This ExecPlan is a living document. Update Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective during implementation. Distill durable decisions into docs/adr/ before completion.

## Purpose / Big Picture


An embedding application must be able to choose how every Kioku AI feature runs through Baikai, without Kioku registering an unwanted provider, choosing a hidden model, or requiring an unauthorized API credential. This fixes [BUG-2](../bug-reports/distillation-hardcodes-anthropic-api-in-interactive-only-hosts.md). An interactive-only host will complete distillation in an authorized interactive session, or retain visibly deferred work until such a session is available. It will never substitute an API or batch subprocess.

The scope includes extraction, consolidation, scene generation, persona generation, memory embeddings, query embeddings, and recall-based merge candidates, including CLI, worker, and embedded use. Storage, authorization, ranking, and scheduling remain Kioku concerns; “configurable through Baikai” means AI execution uses Baikai's model, transport, credential, and interactive configuration vocabulary. Non-AI memory operations remain usable with AI disabled. Future AI features must enter through the same configuration boundary.

## Progress


- [x] (2026-09-08) Read the plan, skill specification, relevant ADRs, and dependency sources discovered through Mori; created the implementation intention.
- [x] (2026-09-08) Milestone 1: implemented the explicit capability/configuration boundary, immutable distillation constructor, selected-handler snapshots, and concurrent-host/no-call tests. Core suite passed.
- [x] (2026-09-08) Milestone 2: migrated all four signatures to checked interactive handoff and completed the real authorized terminal extraction smoke run without API/database credentials.
- [x] (2026-09-08) Added cancellation, oversized/symlink/missing/mismatched results, domain-validation failures, and checked output coverage for all four signatures.
- [x] (2026-09-08) Migrated embeddings, recall/candidate lookup, and all production CLI paths to explicit runtime configuration; added parseable examples and stored-model compatibility checks.
- [x] (2026-09-08) Added versioned config rejection, explicit-file precedence over environment, credential no-enable/redaction, and model-compatibility refusal tests.
- [x] (2026-09-08) Added typed deferred/permanent/transient timer outcomes and durable parking regression: repeated worker runs retain dead state, stable reason, and one claim.
- [x] (2026-09-08) Milestone 4: implemented authorized deferred listing and renewable, token-checked resume using released Keiro 0.16.0.0; all 20 timer tests pass, including concurrent interactive execution, cancellation, expired-lease recovery, and ordinary-dead-letter refusal.
- [x] (2026-09-08) Updated the user guides, library constructor reference, and ADR-12 for the new contract.
- [x] (2026-09-08) Validated and committed the separate reporting-host integration as `b7081e39` in `mori://shinzui/rei`; its 40-test durable timer suite passed, including background interactive deferral.
- [ ] Final acceptance: implement/test authorized deferred listing and atomic resume after the Keiro release prerequisite, then prove foreground host resume and close BUG-2. No deployment or live timer replay was performed.

- [x] (2026-09-08) Verified Keiro 0.16.0.0 on Hackage and upstream package tags (`2da45585b901271d4ac19af4acf3de790c394540`); IR-35/IR-36 APIs are now released.
- [ ] (2026-09-08) Adopt released timer inspection and leased resume, finish CLI/host integration, and validate remaining acceptance.

## Surprises & Discoveries

The first real terminal prototype returned a result file with an invalid envelope. Kioku rejected it with `AIInteractiveFailed Extraction "missing, invalid, or mismatched result envelope"`. The signature's system-level output guide competed with the envelope instructions. Keeping the signature instructions/schema in the manifest and making the system prompt explicitly scope them to `result` resolved this. A second run returned a checked preference atom and exit status zero.


The initial released baseline, Keiro 0.15.0.0, could not atomically claim a dead timer or list dead timers through its public timer API. `mori://shinzui/keiro/packages/keiro`, project-relative `keiro/src/Keiro/Timer/Schema.hs` (source artifact URI pending), exports `lookupTimer`, `deadLetterTimer`, and recovery operations restricted to firing rows. Its public `TimerRow` also omits `last_error`, so an authorized resume cannot verify the stored deferred reason through that API. That blocked milestone 4 pending an upstream addition exposing filtered dead-timer listing and a compare-and-set claim by timer ID and expected reason, preserving payload/correlation/attempts. Kioku must not work around this by writing Keiro-owned SQL. Keiro 0.16.0.0 subsequently resolved this prerequisite; adoption is now implemented. Model configurability was already complete and never depended on this recovery addition.

The initial Hackage preferred-version check on 2026-09-08 reported Baikai 0.6.0.1, Shikumi 0.3.0.3, and Keiro 0.15.0.0. Upstream tags resolve respectively to `f71bfd7afa49bb78f77d2eef378792fb9a624ecd`, `205219f75dde9350cad9fd47b97a5e1576674123`, and `de574cdcb0add3fefbb0fdd96d820258d15f8997`. Existing bounds admit these releases; no local source pins are needed.

## Decision Log


Decision (2026-09-08): Put versioned file parsing and provider assembly in `Kioku.AI.File`, with `Kioku.Cli.AIConfig` supplying the option parser. The reporting host uses the same file boundary instead of duplicating configuration parsing or treating its existing batch transport setting as interactive authorization. Foreground availability is an explicit caller argument; background hosts pass false.

Decision (2026-09-08): Snapshot only selected handlers into runtime-private registries. Kioku does not mutate host registries, and a later host registration cannot silently replace a validated runtime's execution capability. Apply host options at the final Shikumi LLM boundary while retaining its generated schema metadata.

Decision (2026-09-08): Make provider execution an explicit host-supplied configuration, with shared defaults and per-feature overrides. Missing configuration disables AI instead of silently restoring Anthropic or OpenAI defaults. This is an intentional compatibility change, because credential presence is not authorization.

Decision (2026-09-08): Distinguish interactive sessions, batch completion subprocesses, and HTTP APIs. Baikai's interactive launch result contains only provider and exit code; an exit code cannot be decoded as a distillation result. Build and test a structured result handoff before advertising interactive completion.

Decision (2026-09-08): Include embeddings in execution policy. Baikai currently provides HTTP embeddings, not interactive embeddings. Interactive-only configuration disables semantic calls and permits explicitly documented keyword/scan behavior; it must not silently contact an embedding endpoint.

Decision (2026-09-08): Use the existing durable timer dead-letter facility as parked storage for deferred interactive work, with a distinct typed reason and an explicit authorized resume operation. This avoids inventing unsupported timer states or repeatedly rescheduling a permanent availability mismatch. The user-facing status must say deferred, not successful or ordinary failure.

Decision (2026-09-08): Include the reporting host integration as the final milestone. A library fix alone does not resolve the report while that host still calls the old constructor. Do not deploy or modify live worker state as part of implementation validation.

## Outcomes & Retrospective

Configuration and execution policy are implemented. Deferred recovery is also implemented against Keiro 0.16; final reporting-host validation is in progress. The earlier full Nix-shell run passed 229 core, 54 CLI, 125 API, and 24 migration tests, with no skipped pgvector cases. Afterward, the added embedding-model refusal regression passed in the 12-test embedding selection; final routing regression evidence is recorded below. `cabal build all` passed. A real Baikai/Claude interactive extraction passed using only synthetic evidence, with no database connection. The release prerequisite is resolved. The updated core passed 235 tests; after final recovery and authorization additions, all 20 timer tests passed. Initial migration failures were expected-count changes from Keiro migration 0032 and are corrected; all 24 migration tests passed on rerun.

The successful interactive smoke command, run from the repository root in a PTY, was:

```bash
env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u PG_CONNECTION_STRING -u DATABASE_URL \
  cabal exec -- runghc scripts/ai-interactive-smoke.hs docs/examples/ai-interactive.json
```

After the agent wrote its result, `/exit` closed the terminal session normally. The harness exited zero and printed a validated `ExtractOutput` containing one `preference` atom, `User prefers concise answers`, priority 0 and high confidence. The temporary workspace was removed. This smoke proves structured extraction, not durable timer resume.


## Context and Orientation


Kioku is a Haskell memory library with five Cabal packages. `kioku-api` holds memory/session types, `kioku-core` implements storage and derived memories, `kioku-cli` exposes commands, and `kioku-migrations`/`kioku-migrate` manage database layout. L0 is recorded session evidence; L1 is extracted memory atoms; L2 is a scene summarizing a scope; L3 is a persona summary. Consolidation chooses how a new atom relates to existing memory.

`kioku-core/src/Kioku/AI/Config.hs`, `Runtime.hs`, and `File.hs` now own explicit feature
settings, host capabilities, and versioned file assembly. `Kioku.Distill.Runtime` wraps the
validated AI runtime and optional workspace root; its constructor has no hidden provider or
model. Shikumi remains the typed prompt/program framework, preserving signature schemas in
`kioku-core/src/Kioku/Distill/Extract.hs`, `Consolidate.hs`, `Scene.hs`, and `Persona.hs`.
`Kioku.AI.Interactive` validates the private request/result handoff.

`kioku-core/src/Kioku/Memory/Embedding.hs` resolves explicit feature capabilities and checks
stored vector model compatibility before semantic execution. The shipped column has 1536
dimensions. `Kioku.Recall`, `Kioku.Memory.Embedding.Worker`, and L1 candidate search use that
boundary; changing settings never implicitly migrates or re-embeds vectors. CLI distill,
recall, and worker commands load the shared versioned AI file; stored scene/persona reads
remain ordinary database reads.

`kioku-core/src/Kioku/Distill/Timer/Worker.hs` dispatches L1/L2/L3 and applies the typed
completion, retry, permanent-failure, deferred, and unknown-owner outcomes. Ordinary transient
failures keep the eight-claim ceiling and backoff capped at 900 seconds. Interactive
unavailability parks with a stable reason. `Kioku.Distill.Timer.Deferred` provides authorized
bounded listing and foreground resume through Keiro 0.16 inspection and leased claims.

Baikai was located through Mori at `mori://shinzui/baikai`. Its guides `mori://shinzui/baikai/docs/models-and-providers` and `mori://shinzui/baikai/docs/interactive-launches` document isolated registries and genuine interactive launches. In that project, source paths `baikai/src/Baikai/Provider/Registry.hs`, `baikai/src/Baikai/Interactive.hs`, and `baikai/src/Baikai/Embedding.hs` are the inspected implementation (artifact-level source URIs pending). `newProviderRegistryFrom` builds a host-local registry; `assertRegistered` validates transport tags. Interactive launchers in its provider packages inherit terminal streams and return an `InteractiveLaunchResult`, not a completion response. Embeddings have their own `EmbeddingModel` and no chat registry tag.

In `mori://shinzui/shikumi`, project-relative `shikumi/src/Shikumi/LLM.hs` exposes `LLMConfig` with registry, retry, budget, and concurrency settings; `defaultLLMConfig` accepts an explicit registry. Project-relative `shikumi/src/Shikumi/Adapter.hs` provides schema-driven rendering and checked decoding. Artifact-level source URIs are pending. The reporting consumer is `mori://shinzui/rei`, project-relative `rei-core/src/Rei/Infrastructure/ReiTimers.hs` (artifact-level source URI pending): its dispatcher constructs `newDistillRuntime` and delegates to `fireKiokuTimer` and `applyFireOutcome` with scan candidates.

Consulted local decisions are [ADR-1](../adr/kioku-owns-memory-not-identity.md), which keeps identity and authorization decisions in the host, and [ADR-2](../adr/namespace-is-not-a-security-boundary.md), which makes memory spaces the isolation boundary. Preserve both: model execution policy never grants memory access, and deferred work retains its original space. [ADR-12](../adr/host-owned-ai-execution.md) now defines host-owned AI selection and leased recovery. `mori.dhall` does not declare a profiled ADR bundle; follow the established local ADR format when recording this decision, rather than adopting a profile incidentally.

## Plan of Work


### Milestone 1: Establish one explicit AI configuration boundary


Add `kioku-core/src/Kioku/AI/Config.hs` and `kioku-core/src/Kioku/AI/Runtime.hs`. Define closed feature identifiers for the four distillation programs and the three embedding uses, an explicit execution mode, and validated settings. Reuse Baikai `Model`, `Options`, `ApiKeySource`, `EmbeddingModel`, and interactive request/provider types; do not reconstruct a vendor catalog or serialize a provider registry. Hosts provide registries and launch functions in memory. Distillation defaults may be overridden per feature; embedding settings are separate because embeddings are not chat completions. Disabled is the no-configuration default. Unknown feature names, invalid modes, missing models, unregistered transports, and forbidden overrides fail before credentials are read or processes launched.

Replace the zero-argument distillation constructor with an explicitly configured constructor returning a typed configuration failure or runtime. Hide runtime construction and eliminate writable metadata that can disagree with captured runners. Keep an explicit test constructor for controlled runners. Route `runDistillProgram` through the same runtime policy, requiring a feature identity; arbitrary programs must not recover a global registry. Represent allowed execution as host capabilities, not solely a mutable mode string, so per-feature overrides cannot widen the host's authority. Validate every selected transport and ensure registries are never mutated by Kioku. Add unit tests for two concurrent hosts with different registries and for construction without any provider side effects. Run the core test suite; these tests require no credentials.

### Milestone 2: Prove interactive structured results and migrate distillation


Add `kioku-core/src/Kioku/AI/Interactive.hs`. Prototype one extraction using Baikai's real interactive launcher, then generalize to the other three signatures. Each call creates a private temporary directory and a request manifest containing a fresh request identifier, feature, output schema, instructions, and authorized input. Pass the input and exact output-file contract through an `InteractiveLaunchRequest`; let the host approve session availability and supply safety, model, effort, and permitted working directory. The interactive agent writes a JSON result envelope carrying the request identifier and feature. After successful process exit, read only the designated bounded-size regular output file, reject symlinks and stale/mismatched envelopes, and decode through Shikumi's checked schema validation. Missing output, cancellation, nonzero exit, invalid JSON, and invalid domain values are failures, never successful empty results. Treat model output as untrusted data and persist it only through normal Kioku operations.

The temporary workspace must not carry database credentials or offer direct memory writes; Kioku applies validated results with the original memory context. Use the existing signature rendering/schema facilities so interactive mode does not maintain a second set of prompts or validators. Baikai owns launching and provider flags; Kioku owns the result envelope for its typed work. A host may supply an already-authorized interactive-session adapter implementing that same request/result contract. Do not pretend a TTY alone proves authorization or that a batch `claude -p`/`codex exec` call is interactive.

Retain Shikumi program interpretation for explicitly selected API and batch modes, using only the supplied registry and Baikai options. Apply the selected feature configuration to extraction, consolidation, scenes, personas, and the smoke program. If an upstream extension is required for options or rendering, first locate that source with Mori and record a concrete prerequisite here; do not add a direct HTTP workaround. Verify the prototype with a launcher fixture that writes a real result file and a manual authorized terminal run. Promote it only when checked extraction succeeds without API credentials and cancellation leaves no successful distillation watermark. Run all distillation tests after migration.

### Milestone 3: Apply the boundary to embeddings and every CLI path


Refactor `kioku-core/src/Kioku/Memory/Embedding.hs` to accept Baikai embedding settings through the shared runtime. Preserve injectable embedding execution for tests and explicit host adapters. Gate memory embedding, query embedding, and candidate embedding before `embedOne`, including retries and backfill. For an interactive-only policy, embeddings are disabled unless the host explicitly supplies an independently authorized compatible capability; never invent interactive embedding support. Hybrid recall can use keyword-only behavior with a visible reason; explicit embedding-only requests and backfill must report unavailable configuration rather than pretend to have embedded. Candidate search can use scan when embeddings are disabled. Validate positive dimensions and existing schema compatibility; model changes require explicit re-embedding guidance and must not mix incompatible vectors silently.

Add `kioku-cli/src/Kioku/Cli/AIConfig.hs` as the single parser/assembler. Add `--ai-config FILE` to AI-using commands, accepting a versioned JSON document with distillation defaults, per-feature overrides, embedding settings, and execution permissions. `KIOKU_AI_CONFIG` supplies the file path when the flag is absent; an explicit file or host runtime is authoritative. Legacy embedding variables may fill settings only in an explicitly selected embedding API mode; they cannot enable it. Resolve credential sources with Baikai and redact diagnostics. No config means disabled AI. Provide parseable examples in `docs/examples/ai-api.json` and `docs/examples/ai-interactive.json`, with named credential variables rather than secrets. The interactive example disables embeddings. Cover all worker modes, recall strategies, distill candidate choices, and stored scene/persona readers. Register new modules and dependency use in the Cabal files. Run CLI parser and subprocess tests to demonstrate flag precedence and no-call behavior.

### Milestone 4: Park and resume work without unauthorized retries


Add typed execution refusal/deferred constructors to the distillation error path and `FireOutcome`. Check memory authorization first and execution availability second, before invoking any program or embedding finder. Propagate these outcomes through `kioku-core/src/Kioku/Distill/L1.hs`, `L2.hs`, `L3.hs`, and both timer modules. Distinguish unavailable interactive ownership from invalid configuration and transient provider failure. Transient failures keep bounded retry behavior; invalid configuration dead-letters once with an actionable reason; interactive unavailability parks once with a stable `kioku:deferred:interactive-unavailable` reason prefix plus space/feature diagnostics.

Implement parking through the existing dead-letter operation so workers cannot reclaim it on every poll. Add explicit `kioku worker deferred list` and `kioku worker deferred resume TIMER_ID --ai-config FILE` commands, with corresponding core operations in `kioku-core/src/Kioku/Distill/Timer/Deferred.hs`. Only list authorized spaces. Resume re-reads the original timer, checks the deferred reason, obtains fresh memory authorization and an interactive session, and atomically claims that work before running it. Preserve original correlation, payload, and space; concurrent resume attempts must not run twice. Repeated unavailability leaves it parked without consuming retry attempts. Do not use generic dead-letter replay to run malformed or unauthorized work. Inspect Keiro's current released timer API through Mori before implementing the compare-and-set transition; if no suitable operation exists, make its upstream addition an explicit prerequisite rather than issuing uncoordinated writes to its schema.

Database tests must show no success marker or memory mutation on deferral, stable parked state across repeated polls and process restarts, exactly one successful resume, and renewed authorization refusal after access is revoked. Preserve existing L1 watermark/idempotency and L2/L3 output behavior. Run core and CLI suites against their ephemeral databases.

### Milestone 5: Integrate the reporting host and document the contract


In `mori://shinzui/rei`, discover local instructions and use the inspected timer dispatcher source to replace construction with its host-owned runtime. Thread interactive policy and availability from the host's actual configuration; do not guess field names or infer availability from an installed executable. Route deferred status and explicit session resume through the shared core operations. Keep this cross-repository change separately reviewable and cite this plan as `mori://shinzui/kioku/plans/41-configure-all-kioku-ai-features-through-baikai-and-honor-host-execution-policy`. Add host regression evidence for an interactive-only background dispatch and an authorized foreground resume. Dependency releases needed for that consumer are prerequisites to deployment, not grounds for leaving the host on the old constructor.

Update `docs/user/configuration.md`, `docs/user/distillation.md`, `docs/user/integrations.md`, `docs/user/troubleshooting.md`, and `docs/user/getting-started.md`. Explain explicit API/batch/interactive selection, feature overrides, embedding capability limits, the disabled default, result handoff, deferred listing/resume, and migration from the zero-argument constructor. Update the bug report only after recording Kioku and host acceptance evidence; distinguish tested source changes from an unverified deployed worker. Create a local ADR for host-owned Baikai execution and durable deferral following the current ADR convention. Run complete checks and record actual commands/results here. A manual interactive smoke run and host integration are required before calling the entire bug fixed.

## Concrete Steps


Run commands from the Kioku repository root. Discover dependencies before implementing their APIs:

```bash
mori registry list
mori registry show shinzui/baikai --full
mori registry docs shinzui/baikai
mori registry show shinzui/shikumi --full
mori registry search keiro
mori registry show shinzui/keiro --full
mori registry docs shinzui/keiro
mori registry show shinzui/rei --full
mori path mori://shinzui/baikai/docs/interactive-launches
```

Use the returned local project paths for reading source. Never traverse the filesystem root or `/nix/store`. Current Kioku bounds name Baikai 0.6, Shikumi 0.3.0.3, and Keiro 0.16.0.0. The Keiro runtime/core/migrations bounds now require the verified released recovery API; the optional PGMQ constraint tracks that cohort. Before choosing any bound, new package, pin, or compatibility workaround, verify Hackage package metadata and upstream release tags and record the comparison. Preserve the released-package build model in `cabal.project`.

Build and test after each relevant milestone, with the development toolchain available:

```bash
cabal build all
cabal test kioku-core:kioku-test --test-show-details=direct
cabal test kioku-cli:kioku-cli-test --test-show-details=direct
cabal test all --test-show-details=direct
git diff --check
```

Use `nix develop` if the required GHC/PostgreSQL tools are missing. Existing database tests use `kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs` to provision migrated ephemeral PostgreSQL databases; they must actually run, not skip due to absent database tools. Expect exit status zero and Tasty's passing summary. Register new tests in `kioku-core/test/Main.hs` and the respective Cabal test module lists.

After implementation, these are the new operator commands to exercise against a disposable migrated database and a test-created eligible session/timer; replace the uppercase identifiers with values printed by the fixture:

```bash
cabal run kioku -- distill session SESSION_ID --candidates scan --ai-config docs/examples/ai-interactive.json
cabal run kioku -- worker --timers-once --ai-config docs/examples/ai-interactive.json
cabal run kioku -- worker deferred list
cabal run kioku -- worker deferred resume TIMER_ID --ai-config docs/examples/ai-interactive.json
```

The foreground command launches an authorized interactive session and reports stored extraction results after validated output. The background invocation has no interactive-session capability and reports deferred work. Listing includes its timer, feature, space, reason, and resume instruction. Resume completes that original work once. Record the exact fixture setup command added by the tests or smoke harness here during implementation; do not use production session data for the smoke run.

## Validation and Acceptance


Add `kioku-core/test/Kioku/AIRuntimeSpec.hs` for policy and routing, and extend `kioku-core/test/Kioku/DistillSpec.hs`, `TimerWorkerSpec.hs`, `EmbeddingWorkerSpec.hs`, and `RecallSpec.hs`. Add a CLI configuration/subprocess suite alongside `kioku-cli/test/Kioku/Cli/ParserSpec.hs`. Use fake provider handlers with call counters and subprocess fixtures; normal tests must not need API credentials or launch a real agent.

With both API keys absent, an interactive-only host must make zero HTTP-provider and batch-provider calls through extraction, consolidation, scene, persona, query embedding, candidate lookup, and embedding worker paths. Prove this with failing sentinels for forbidden handlers and an injectable embedding executor, including unavailable-session and cancellation cases. Merely stubbing the four output callbacks does not prove production routing. Exercise the real runtime assembly and result-file decoder with the launcher fixture.

Explicit API and batch configurations must dispatch the chosen Baikai models and options, including per-feature overrides, through the selected isolated registry. Two runtimes in one process cannot change each other's handlers. Disabled AI permits storage and keyword recall while refusing explicit generation/backfill with actionable messages. Invalid config fails before provider invocation; credentials must not appear in printed config or errors.

Interactive results must pass the same output validation as other modes. Cover missing output, mismatched request identifiers, stale files, nonzero exit, invalid schema, and cancelled sessions. Verify stored atoms/scenes/personas and successful watermarks only after valid results. Timer tests must demonstrate persisted deferral, restart survival, concurrent resume exclusion, authorization rechecking, and retention of existing retry behavior for actual transient failures. Include the reporting host's default worker path in acceptance, with no API key provisioned.

## Idempotence and Recovery


Planning changes only this file. Implementation changes are incremental; keep tests passing and update Progress with timestamped checkboxes as work begins. Re-running configuration resolution does not register providers globally or change credentials. Private interactive workspaces are removed after completion/failure; never reuse a prior result as a new request. A failed model call cannot advance success watermarks. Existing idempotent memory writes protect partial L1 progress on retry.

Parked timers are durable and resume only through an authorized atomic transition. Failure during resume returns work to a visible parked or bounded-retry state; never leaves it firing indefinitely. Preserve old payload decoding and ordinary dead letters. If persistence changes become necessary, use a new checksummed migration and test rollback/recovery on an ephemeral database; do not edit applied migrations. Switching embedding models requires explicit vector compatibility/re-embedding handling, not silent reuse. Do not roll an interactive-only host back to the old Anthropic default; disable execution until a compatible runtime is restored.

## Interfaces and Dependencies


The new `Kioku.AI.Config` interface must expose `AIFeature`, an execution policy distinguishing disabled/API/batch/interactive, and validated per-feature settings built from Baikai values. `Kioku.AI.Runtime` owns host capabilities and immutable dispatch. Its configuration builder returns `Either AIConfigurationError AIRuntime`; errors identify feature and remedy without secrets. `newDistillRuntime` consumes that validated runtime and optional workspace root. Distillation execution errors must preserve typed configuration refusal and interactive deferral separately from Shikumi program failures. Test runners get an explicit constructor rather than modifying captured runtime fields.

`Kioku.AI.Interactive` accepts Baikai interactive settings plus an authorized launch function, renders an existing signature, and returns checked typed output or an execution error. `Kioku.Distill.Timer.Outcome` adds `FireDeferred` carrying a stable reason; `Kioku.Distill.Timer.Deferred` exposes authorized listing and atomic resume without manufacturing an access context. Final signatures should follow existing Effectful/store conventions and be recorded here when implemented. These are proposed Kioku interfaces, not claims about existing dependency APIs.

Use `mori://shinzui/baikai/packages/baikai` for common model/configuration, registry, embedding, and interactive types; the Claude and OpenAI provider packages supply explicitly chosen provider implementations and interactive launchers. Use `mori://shinzui/shikumi/packages/shikumi` for typed programs, schema validation, and resilient completion. Baikai is the AI execution abstraction, not a database or identity configuration framework. Any necessary upstream change must have a specific canonical reference, released-version verification, and acceptance evidence before the dependent milestone is complete.

Revision (2026-09-08): Recorded implementation, released dependency verification, real interactive smoke evidence, shared host file assembly, and the specific Keiro prerequisite. Kept resume and final bug acceptance open rather than advertising commands the released timer API cannot support.

Validation (2026-09-08): `nix develop -c cabal test all --test-show-details=direct` passed 432 tests across four suites (229 core + 54 CLI + 125 API + 24 migrations), with no `[skipped]` vector cases. The plain-shell run had exercised ephemeral PostgreSQL but lacked pgvector; the Nix-shell rerun supplied the extension. `nix develop -c cabal test kioku-core:kioku-test --test-show-details=direct --test-options='-p /Embedding/'` then passed all 12 selected tests, including the added model-mismatch/no-provider-call regression. Formatting and `git diff --check` passed.

Host validation (2026-09-08): in `mori://shinzui/rei`, copy its `cabal.project` to a temporary `.plan41-validation.project` and append a `packages:` stanza containing the local paths returned by `mori path` for `mori://shinzui/kioku/packages/kioku-api`, `mori://shinzui/kioku/packages/kioku-core`, and `mori://shinzui/kioku/packages/kioku-migrations`. Run `nix develop -c cabal test rei-core:rei-core-test --project-file=.plan41-validation.project --test-options='-p /durable/'`. All 40 tests passed, including `interactive-only Kioku timers park without provider credentials`. The temporary project was removed; the committed project retains released-package resolution and requires a new Kioku release before building these source changes without the validation overlay.

Final routing validation (2026-09-08): `nix develop -c cabal test kioku-core:kioku-test --test-show-details=direct --test-options='-p /AI/'` passed all 10 tests, including the added per-feature batch override with separate registries, selected model/options, all interactive signatures, and adversarial result files. Core now contains 231 tests after these two final regression additions; the full-suite count above is the actual earlier full run, not a claim that all 231 were rerun together.

The formerly blocked recovery implementation now uses released Keiro 0.16.0.0. `Kioku.Distill.Timer.Deferred`, CLI listing/resume, authorization/refusal/concurrency/recovery tests, and Rei foreground entry points are implemented. Final reporting-host validation remains before closing the plan and BUG-2. All independent configuration, interactive handoff, embedding policy, background parking, host-source integration, and documentation work is included in this implementation. The Rei integration is committed as `b7081e39` in `mori://shinzui/rei`.

Final embedding validation (2026-09-08): reran the 12 embedding tests successfully after adding a backfill-wide stored-model compatibility preflight, including the case where there are no missing vectors to backfill. This prevents a changed configured model from silently accepting an existing incompatible vector set.

Upstream requests (2026-09-08): filed `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-35` for reason-bearing dead timer reads/listing and `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-36` for atomic guarded resume, attempt accounting, and recovery. Both are proposed and require released public APIs; the dependent milestone remains open. Keiro bundle validation with profile and log enforcement passed for all 36 concepts. Strict validation reports missing recommended reviews for these unreviewed proposals and eight existing requests.

Resumed implementation (2026-09-08): the previously recorded upstream blocker is resolved by Keiro 0.16.0.0. The released API adds bounded UUID-cursor inspection, exact owner/reason claims, token-checked renewable leases, completion/parking, and expired-lease recovery. Kioku will renew during foreground execution, preserve the eight-attempt ceiling, and re-park unsuccessful foreground outcomes for explicit retry rather than send interactive work into the background queue. Earlier blocker statements record the prior baseline, not the current dependency state.

Recovery interfaces (2026-09-08): `listDeferredTimers` takes a current `MemoryContextProvider`
and a Keiro `DeadTimerPageRequest`, returning either the page error or `DeferredPage` with
authorized entries and a continuation cursor. Follow the cursor even when a page is empty after
authorization. `resumeDeferredTimer` takes the provider, `DistillRuntime`, candidate finder,
and original timer ID; it returns typed eligibility/access/execution/claim/ownership outcomes
or `DeferredFinished FireOutcome`. L1 preflights distill, record, and forget permissions;
L2/L3 preflight distill permission. Every claim uses exact owner/reason, an eight-attempt ceiling,
and a 120-second lease renewed every 30 seconds through finalization. Failure and cancellation
re-park with the original reason and accumulated attempts. Recovery precedes listing/resume.
The released migration adds Keiro 0032; the composed plan now has 56 migrations.

Recovery validation (2026-09-08): the initial `nix develop -c cabal test all
--test-show-details=direct` passed all 235 core and 125 API tests with no vector skips; it
exposed three old migration expectations (55 total/44 newly adopted, before Keiro 0032).
After correcting those to 56/45 and including 0032 in the expected forward sequence,
`nix develop -c cabal test kioku-cli:kioku-cli-test kioku-migrations:kioku-migrations-test
--test-show-details=direct` passed all 24 migration tests. The CLI fixture initially omitted
its required `workingDir`; after correction and isolation of its working directory,
`nix develop -c cabal test kioku-cli:kioku-cli-test --test-show-details=direct` passed all
58 CLI tests. Its subprocess test lists deferred work, refuses disabled execution without
consuming attempts, and completes the original empty-scope scene timer once. Core's
`nix develop -c cabal test kioku-core:kioku-test --test-show-details=direct --test-options='-p /Timer/'`
passed all 20 tests after the final recovery and preflight changes, including a real runtime
interactive result-file fixture with competing callers, cancellation cleanup, expired-claim
recovery, and stale-token completion refusal. Core now has 237 tests; the earlier full run
covered 235 before the final two recovery additions. These are ephemeral database fixtures,
not live timers or API calls.
