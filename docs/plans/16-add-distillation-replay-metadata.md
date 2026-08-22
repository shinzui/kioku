---
id: 16
slug: add-distillation-replay-metadata
title: "Add distillation replay metadata"
kind: exec-plan
created_at: 2026-07-07T20:46:37Z
intention: "intention_01kzbs5w83e36t1gjtrz516yn5"
master_plan: "docs/masterplans/4-secure-and-accountable-distillation-evidence.md"
---

# Add distillation replay metadata

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a Kioku user can inspect every real provider attempt made while distilling
L1 memories, L2 scenes, or L3 personas. Each durable record says which phase initiated the
call, which Kioku operation and Baikai retry chain it belonged to, which model was requested
and observed, where the request went, how the attempt ended, what usage was observed, and the
canonical commitments for the exact request, its content-free configuration, and the response.
The record comes from Baikai's provider boundary; Kioku never guesses these facts from its
configured model.

The same user can start from a memory, consolidation decision, scene, or persona and find the
successful provider calls that produced it, or start from a failed/orphaned call and see that no
artifact accepted it. The command-line inspection path uses the memory space selected by
`KIOKU_MEMORY_SPACE`, just like the rest of Kioku's current CLI, so an identifier from another
space does not reveal whether a row exists there.

“Replay metadata” is evidence for audit and future reconstruction. This plan does not build an
automatic replay executor, and it does not retain raw prompts, tool output, provider bodies, or
model output. Baikai's commitments allow a party that independently holds a payload to verify
the binding without turning Kioku into a second durable content store. Commitments are not
encryption or confidentiality, so they remain protected by the same memory-space authorization.
Shikumi's deterministic trace replay remains a test facility and must not be presented as evidence
that a provider call occurred.


## Progress

- [x] Consume a released Shikumi version whose bounds admit Baikai 0.5. (2026-08-22: Kioku pins
  `shikumi ^>=0.3.0.2` and `shikumi-trace ^>=0.2.0.2`; Hackage-preferred versions and upstream
  tags agree.)
- [x] Upgrade Kioku's complete Baikai cohort. (2026-08-22: `baikai ^>=0.5.0.0`,
  `baikai-claude ^>=0.5.0.0`, `baikai-effectful ^>=0.3.0.3`, `shikumi ^>=0.3.0.2`, and
  `shikumi-trace ^>=0.2.0.2` are already in both library and test bounds.)
- [ ] Land and consume a released Shikumi retry seam that requests and exposes Baikai evidence
  for every attempt before Shikumi converts a failed response into `ShikumiError` or retries it.
- [ ] Add partition-aware operation, stored-evidence, and call-to-artifact types plus the next
  pg-migrate schema migration.
- [ ] Request strict minimum evidence, persist every observed attempt before accepting typed
  output, and fail closed when persistence fails.
- [ ] Instrument L1 extraction/consolidation and L2/L3 generation with stable operation,
  invocation, phase, evidence-decision, and artifact links.
- [ ] Link successful call IDs into first-class artifact provenance without attaching failed
  attempts to artifacts.
- [ ] Add retry, pre-dispatch-refusal, parse-failure, persistence-failure, privacy,
  partition-isolation, migration, and pipeline integration tests.
- [ ] Expose partitioned library/CLI inspection and dry-run-first retention pruning, then update
  user and operator documentation.


## Surprises & Discoveries

- Baikai 0.5.0.0 was released on 2026-08-05 and already supplies the evidence schema, globally
  unique call IDs, canonical request/configuration/response commitments, requested-versus-
  observed model fields, caller-supplied retry provenance, strict pre-dispatch requirements,
  and `CallEvidence` trace events. Its preferred Hackage version and upstream tag were still
  0.5.0.0 on 2026-08-22.
- Kioku already completed the dependency work the previous revision treated as blocked.
  `kioku-core/kioku-core.cabal` pins the exact released Baikai 0.5-compatible cohort, and
  `scripts/baikai-cohort.sh` plus `scripts/upgrade-baikai.sh` now maintain that cohort after
  future releases.
- Shikumi 0.3.0.2 is compatibility-only. Its released changelog explicitly says Shikumi does
  not opt into model-call evidence. `Shikumi.LLM.runLLMResilient` sends the same `Options` on
  every retry and calls `raiseResponseError` inside the retry loop, so failed-attempt evidence
  is discarded before an outer Kioku layer can observe it. Merely setting `Options.evidence`
  around `runProgram` would expose at most the final successful response and would assign wrong
  retry metadata.
- Baikai's synchronous `Response.evidence` is not the complete collection seam. The Baikai trace
  path emits exactly one `CallEvidence` event for success, provider failure, strict
  pre-dispatch refusal, and abort; `Response.evidence` can be absent when no full response is
  assembled. The upstream Shikumi seam therefore needs the trace/attempt lifecycle, not just a
  projection from the final `Response`.
- The full `ModelCallEvidence` JSON is not safe to persist blindly. `BaikaiError.message` is
  documented as log-safe but HTTP errors currently include up to 300 characters of the provider
  response body. Kioku must retain only the error category and bounded structured hints, never
  that free-form message or the complete evidence JSON.
- A Baikai `run_id` belongs to one logical provider invocation across retries. After Plan 23, one
  L1 pass can perform a data extraction, an optional trusted-instruction extraction, and many
  data-atom consolidations, each with its own retry chain. Trusted instruction atoms bypass the
  general consolidator. Kioku therefore needs a separate operation ID to group the complete pass.
  Reusing one Baikai `run_id` for all of them would make attempt numbers ambiguous.
- One provider call can contribute to more than one artifact: a successful extraction can feed
  several memory and consolidation outcomes. A single nullable artifact column on the call row
  cannot represent that relationship; a partitioned association table is required.
- The portfolio-isolation prerequisites have landed. `MemorySpaceId`, `MemoryAccessContext`,
  partitioned timers and rows, the `kioku` PostgreSQL schema, and qualified table constants in
  `Kioku.Database.Schema` all exist. The next migration after the current manifest is 0014, not
  a migration immediately after the original partition migration.
- Current L2 and L3 avoid provider calls when their source hash is unchanged and delete stale
  artifacts without a call when all sources disappear. L1 similarly skips an up-to-date
  watermark. These paths must not fabricate a model-call row merely to make every operation
  look uniform.


## Decision Log

- Decision: Adopt `Baikai.Evidence.ModelCallEvidence` and its schema version as the provider-call
  evidence contract.
  Rationale: The provider adapter observes the outgoing request, response identifiers, reported
  model, and usage. Kioku cannot reconstruct those facts reliably after the call.
  Date: 2026-08-06

- Decision: Persist a field-by-field, storage-safe projection of Baikai evidence, not raw
  structured input/output and not the complete `ModelCallEvidence` JSON.
  Rationale: Commitments support verification without copying content, while the complete
  evidence value can contain a provider response-body snippet in its free-form error message.
  A local projection with a `FromJSON` instance also avoids pretending Baikai's intentionally
  one-way `ModelCallEvidence` JSON round-trips exactly.
  Date: 2026-08-22

- Decision: Require at least `EvidenceRequestedOnly` for live production distillation and treat
  evidence persistence failure as operation failure.
  Rationale: A generated artifact must not be accepted when its required audit record was lost.
  Deployments may demand a higher evidence strength, but they may not disable evidence on the
  live runtime.
  Date: 2026-08-06

- Decision: Keep a Kioku `DistillOperationId` distinct from Baikai's `EvidenceRequest.runId`.
  Generate one operation ID for the whole L1 pass, L2 regeneration, or L3 regeneration, and one
  Baikai run ID for each data extraction, trusted-instruction extraction, data consolidation,
  scene, or persona invocation across its retries.
  Rationale: A top-level L1 pass may contain many independent retry chains. Separate identities
  preserve both useful grouping and unambiguous one-based attempt/supersedes provenance.
  Date: 2026-08-22

- Decision: Use phase labels `l1:extract-data`, `l1:extract-instructions`,
  `l1:consolidate`, `l2:scene`, and `l3:persona`.
  Rationale: Plan 23 isolates instruction-capable extraction from untrusted data. Separate stable
  labels let audit and provenance distinguish the call that could produce each atom without
  depending on a provider or Shikumi implementation name.
  Date: 2026-07-07; refined 2026-08-22

- Decision: Represent artifact linkage in `kioku.distillation_model_call_artifacts`, not as one
  artifact field on `kioku.distillation_model_calls`.
  Rationale: Extraction is one call that can contribute to multiple memories and consolidation
  decisions, while failed calls may contribute to none. A many-to-many relation expresses both
  cases without arrays or duplicated evidence rows.
  Date: 2026-08-22

- Decision: Store each call and artifact link in its memory space and require that space on every
  query and deletion path, even though Baikai call IDs are globally unique.
  Rationale: Model identity, commitments, timings, and error/usage metadata reveal sensitive
  activity even without raw prompts. Public inspection therefore consumes a `MemoryAccessContext`
  with `MemoryRead`, pruning requires `MemoryAdmin`, and internal SQL follows the unconditional
  predicate rule in [ADR-6](../adr/the-partition-is-a-column-not-a-schema.md).
  Date: 2026-08-22

- Decision: A Shikumi cache hit or deterministic replay produces no provider evidence row.
  Rationale: No provider boundary was crossed. Reusing the original call's evidence would
  misattribute one real call to a later cache/replay operation; fabricating a fresh row would be
  worse. Live Kioku distillation does not currently install the Shikumi cache layer.
  Date: 2026-08-22

- Decision: Link only successful, typed-output-accepted call IDs to produced artifacts. Persist
  failed attempts under the same operation and Baikai run IDs without artifact links.
  Rationale: Failed attempts are part of the audit/cost history but did not produce the accepted
  artifact. The successful call's run and supersedes chain still lead to all earlier attempts.
  Date: 2026-08-22

- Decision: Automatic replay and protected raw-payload retention remain separate future work.
  Rationale: Replay execution needs a versioned program/model environment, while raw retention
  needs encryption, access control, deletion, and data-classification policy. Neither belongs in
  a metadata ledger by implication.
  Date: 2026-08-06


## Outcomes & Retrospective

No feature implementation has started. Two former prerequisites are now complete: Kioku has
adopted the released Baikai 0.5-compatible cohort and completed memory-space/schema isolation.
The 2026-08-22 refresh replaces the obsolete version-bound blocker with the actual behavioral
gap in Shikumi's retry interpreter, aligns the schema and call sites with current Kioku, separates
operation identity from provider retry identity, adds many-to-many artifact links, and narrows
the privacy contract to an explicit storage-safe projection.


## Context and Orientation

Kioku's live model runtime is in `kioku-core/src/Kioku/Distill/Runtime.hs`.
`runLiveDistillProgram` currently composes `runRouting`, `runLLMResilient`, `routeLLM`, and
`runProgram`, returning only `Either ShikumiError o`. `routeLLM` turns Shikumi's private
rendering metadata into real Baikai `Context` and `Options`; `runLLMResilient` owns retry,
rate-limit, and budget policy; `runProgram` parses the final Baikai `Response` into a typed
output. The exported `DistillRuntime` stores four IO closures for extraction, consolidation,
scene generation, and persona generation. Tests replace those closures with deterministic
Shikumi replay fixtures. Plan 23 is a hard dependency and replaces the single extraction closure
with data and trusted-instruction lanes before this plan instruments the runtime.

The current released dependency cohort is declared in `kioku-core/kioku-core.cabal`:
`baikai ^>=0.5.0.0`, `baikai-claude ^>=0.5.0.0`, `baikai-effectful ^>=0.3.0.3`,
`shikumi ^>=0.3.0.2`, and `shikumi-trace ^>=0.2.0.2`. Hackage preferred exactly those versions
on 2026-08-22, and the corresponding upstream tags exist. The authoritative dependency sources
and guide are `mori://shinzui/baikai/packages/baikai`,
`mori://shinzui/baikai/docs/model-call-evidence`,
`mori://shinzui/shikumi/packages/shikumi`, and
`mori://shinzui/shikumi/packages/shikumi-trace`.

Baikai 0.5 puts an optional `EvidenceRequest` on `Options`. The request carries an opaque run ID,
strictness, a one-based attempt number, and the prior call ID in `supersedes`. A resulting
`ModelCallEvidence` carries schema/run/call/attempt identity; sanitized endpoint and transport;
requested and observed model/thinking; response and provider request identifiers; timing,
status, structured error, and observed usage; evidence strength; and request, content-free
configuration, and response commitments. Baikai has no retry loop, so Shikumi must set attempt
and supersedes as it retries.

Shikumi 0.3.0.2 admits Baikai 0.5 but deliberately does not set `Options.evidence`. More
importantly, `Shikumi.LLM.runLLMResilient` performs each `Baikai.Effectful.complete` inside its
private retry loop and turns an error-shaped response into `ShikumiError` before the response
escapes. The upstream addition must expose every attempt at that exact layer. An interposer above
the resilient interpreter is too late to see failed responses; an interposer below it sees only
one static request and cannot assign attempt/supersedes correctly.

The current Kioku call sites span several modules. `Kioku.Distill.L1.distillSessionL1` first checks
permissions and its partitioned watermark, then currently calls extraction once and consolidation
once per atom. Plan 23 replaces that extraction with a data lane and an optional trusted-
instruction lane under one L1 operation. `applyAtom`, `applyDecision`, `recordAtom`, and
`writeAudit` are the remaining L1 seams. The memory ID (`l1AtomMemoryId`) and consolidation
decision ID (`l1AuditKey`) are deterministic and can be computed before the consolidation call.
Plan 23 routes instruction atoms to deterministic store/exact-dedup and a policy audit without a
consolidation provider call.
`Kioku.Distill.L2.regenerateScene` calls the model only when active memories produce a new source
hash; its scope-derived scene ID is known before dispatch. `Kioku.Distill.L3.regeneratePersona`
does the same for its persona ID. Both timers and all queries already carry `MemorySpaceId`.

Kioku-owned projections now live in the `kioku` PostgreSQL schema. New SQL must add qualified
constants to `kioku-core/src/Kioku/Database/Schema.hs` rather than rely on `search_path`.
Migration files are allocated through `just new-migration`, embedded in manifest order under
`kioku-migrations/migrations/`, and verified by the real-PostgreSQL suite in
`kioku-migrations/test/Main.hs`. The current manifest ends at
`0013-partition-aware-fts-index.sql`, so this plan would receive 0014 if implemented against the
current tree.

[Plan 23](23-gate-untrusted-session-evidence-before-l1-distillation.md) owns evidence selection,
its policy version, and `EvidenceDecision` identifiers. [Plan 8](8-add-first-class-provenance.md)
owns `Kioku.Provenance` and the accepted call IDs inside distilled creation causes. This plan owns
the provider-call ledger and the association between calls and artifacts; it consumes the other
plans' identifiers without embedding their records.

Four accepted ADRs constrain this work. [ADR-1](../adr/kioku-owns-memory-not-identity.md) says
Kioku consumes authorization decisions rather than inventing identity policy.
[ADR-2](../adr/namespace-is-not-a-security-boundary.md) says namespace and scope organize data
but only `MemorySpaceId` isolates it. [ADR-6](../adr/the-partition-is-a-column-not-a-schema.md)
requires an unconditional memory-space predicate on every statement.
[ADR-10](../adr/projections-live-in-the-kioku-schema.md) requires Kioku-owned relations to live in
the explicitly qualified `kioku` schema. No accepted ADR yet governs model-call evidence
retention; implementation must distill the final privacy/retention contract into a new or updated
ADR before closing this plan.


## Plan of Work

### Milestone 1: close the released Shikumi attempt-evidence seam

The Baikai 0.5 version cohort is already solved. Begin by reproducing the remaining gap against
the released tags: setting one `EvidenceRequest` outside `runLLMResilient` cannot number retries,
and a transient first response's evidence is lost when Shikumi calls `raiseResponseError` and
retries. Keep this as a focused upstream test so a later Shikumi change cannot silently regress
the lifecycle.

In the owning Shikumi project, add a policy-neutral, call-scoped seam to the resilient interpreter.
The caller supplies the base run ID, evidence strictness, and an effectful attempt observer whose
successful return acknowledges durable handling. Shikumi owns incrementing the one-based attempt
and threading the prior Baikai call ID into `supersedes`, because Shikumi owns the retry loop. Each
attempt must dispatch through Baikai's trace/evidence lifecycle or an equivalent API that delivers
the exact provider-built `ModelCallEvidence` to the observer before Shikumi maps the response to
`ShikumiError`, retries, or returns typed output. It must work for both blocking and streaming
`LLM` operations even though Kioku currently uses blocking programs.

The observer runs exactly once per evidence-bearing attempt, including success, provider failure,
strict pre-dispatch refusal, and consumer abort. Shikumi waits for its acknowledgement before a
retry or successful return. An observer failure is terminal and must not be classified as a
transient provider failure that causes another paid provider call. Budget refusal before any
Baikai dispatch and cache/replay hits are not provider attempts and emit no evidence.
If the clean implementation requires a trace-enabled interpreter in
`mori://shinzui/baikai/packages/baikai-effectful`, release that package coherently too rather than
adding a Kioku registry wrapper or copying Shikumi's retry loop.

Do not pin an arbitrary source commit in Kioku. Release the upstream package or packages, verify
their Hackage-preferred versions and exact upstream tags, then raise Kioku's lower bounds to the
first release carrying the seam in both library and test stanzas. The milestone is complete when
an upstream fake-provider test shows two attempts with attempts 1 and 2, the second superseding
the first call ID, and when an observer failure proves the provider was invoked only once.

### Milestone 2: add the partitioned storage-safe ledger

Create `kioku-core/src/Kioku/Distill/ReplayMetadata.hs` and expose it from
`kioku-core/kioku-core.cabal`. Define `DistillReplayPhase`, `DistillOperationId`, call context,
the stored evidence projection, artifact kind/reference, query filters, and a replay-metadata
error type. Generate opaque, globally unique operation and provider-run IDs; do not derive either
from prompt content. The operation ID groups one actual L1 pass, L2 regeneration, or L3
regeneration. The provider run ID is passed to Baikai and groups exactly one typed invocation
across its retries.

The stored projection must copy fields explicitly from `ModelCallEvidence`. Keep schema version,
run/call/attempt/supersedes, every endpoint identity field, requested model, the typed thinking
translation, separately optional observed fields, response/provider/client request IDs, timestamps,
latency, call status, evidence strength, all three commitments, and an allow-listed usage object.
For errors, retain category, HTTP status, retry-after seconds, and process exit code only. Do not
retain `BaikaiError.message`. Do not add a raw JSON evidence column, prompt/output column, provider
body, or generic metadata map. Tests must construct a failure containing a unique secret marker
and prove that marker is absent from every encoded storage value and CLI result.

Allocate the next migration with `just new-migration distillation-model-call-evidence`. In the
current tree this creates `kioku-migrations/migrations/0014-distillation-model-call-evidence.sql`;
if another migration lands first, accept the next manifest number rather than renumbering history.
Create `kioku.distillation_model_calls` and `kioku.distillation_model_call_artifacts`, then add
`distillationModelCallsTable` and `distillationModelCallArtifactsTable` to
`Kioku.Database.Schema`.

`kioku.distillation_model_calls` has a non-null `memory_space_id`, globally unique `call_id`,
Kioku `operation_id`, Baikai `run_id`, phase, optional session and evidence-decision IDs, scope
columns, the storage-safe evidence fields, and `recorded_at`. Make `call_id` the primary key and
also make `(memory_space_id, call_id)` unique so the child table can enforce same-space
referential integrity. Check that attempt is positive, phase/status/strength values are closed,
and commitments required by the Baikai schema are non-empty. Make
`(memory_space_id, run_id, attempt)` unique and give a non-null `supersedes` a composite self-
reference to `(memory_space_id, call_id)`. The insert validates that evidence run ID matches the
call context, attempt 1 has no predecessor, and each later attempt names the immediately preceding
stored attempt from the same run. Add partition-leading indexes for operation, Baikai run, session,
scope, and start time. Do not lead an index by memory space when the globally unique call ID is
already the access path, but still predicate every call lookup on the space.

`kioku.distillation_model_call_artifacts` has `memory_space_id`, `call_id`, `artifact_kind`, and
`artifact_id`. Its primary key is all four columns, and its composite foreign key references the
parent's `(memory_space_id, call_id)` with `ON DELETE CASCADE`. Closed artifact kinds are `memory`,
`consolidation_decision`, `scene`, and `persona`. Add an index on
`(memory_space_id, artifact_kind, artifact_id)` so inspection can start from an artifact. The
association stores only successful, typed-output-accepted calls; it is intentionally empty for
failed attempts and parse failures.

The insert path is idempotent by call ID. If the call already exists, read it inside the same
transaction and accept it only when every stored field is identical; a mismatch is a fatal
integrity error rather than “last write wins.” Artifact links use `ON CONFLICT DO NOTHING` because
their complete primary key defines identity and they contain no mutable payload.

### Milestone 3: persist every observed attempt before retry or output acceptance

Change `Kioku.Distill.Runtime` so each live program invocation supplies the new Shikumi seam with
an effectful `DistillAttemptSink`. The sink receives the invocation's `DistillCallContext` and one
typed Baikai `ModelCallEvidence`, projects only the storage-safe fields, and commits that attempt
before acknowledging it. Keep the callback in the caller's Effectful stack, or expose an
equivalent scoped interpreter, so it can use Kioku's ordinary `Store` transaction without an
unsafe detached IO collector. Shikumi may retry or return only after the sink acknowledges the
attempt. The runtime result contains the typed result and accepted call ID; it does not carry a
second in-memory copy of the durable retry ledger.

The live runtime created by `newDistillRuntime` always supplies
`EvidenceRequired EvidenceRequestedOnly` or the higher configured minimum. A deterministic replay
runtime used by tests must be marked explicitly as replay/no-provider mode and returns no provider
evidence; there must be no silent evidence-disabled live constructor. Keep the configured minimum
on `DistillRuntime` or a dedicated `DistillEvidencePolicy`, not in provider-specific code.

At each Kioku call site, construct the context before dispatch and let the sink persist each
attempt independently before the retry loop proceeds. If persistence raises `StoreError` or an
integrity conflict, return failure and do not retry, accept typed output, write an artifact, write
a consolidation audit row, schedule downstream work, or advance the L1 watermark. A provider or
strict pre-dispatch failure is already durable before the phase returns its existing domain error.
A successful provider response whose typed Shikumi parse fails remains a provider `succeeded` row
with no artifact link; do not rewrite Baikai's status to make Kioku's later parse failure look like
a provider failure.

If a later artifact transaction fails after evidence persistence, leave the call row in place.
It truthfully records work that happened but was not accepted into an artifact. A retry creates a
new operation/invocation identity and new call IDs; it must not overwrite or attach the orphaned
attempt retroactively.

### Milestone 4: instrument L1, L2, and L3 and link accepted artifacts

Generate the operation ID only after each phase's existing no-call checks. An up-to-date or
all-filtered L1 decision, an unchanged L2/L3 source hash, or an empty-source deletion path produces
no operation or model-call row. For a real L1 pass, create one operation ID before its first
non-empty extraction lane. Give the data lane and optional trusted-instruction lane separate
provider run IDs, and give each data atom's consolidation another provider run ID under the same
operation. An instruction atom has no consolidation provider run.

Update `Kioku.Distill.L1.applyAtom` to compute `l1AtomMemoryId` and `l1AuditKey` before a data
consolidation call or instruction policy application, then pass the operation, provider-run, phase,
memory space, session, scope, evidence-decision, extraction lane, memory, and consolidation-
decision context into the runtime only for the data branch.

After the sink has stored the attempts, accept the typed output. Write each artifact and its links
in the artifact's own acceptance transaction: Plan 8's `MemoryRecorded` payload carries the
accepted call IDs and its inline projection inserts the memory links in the same
`runCommandWithProjections` transaction; `writeAudit` inserts the audit row and its links together.
A provider-consolidated skip has only its consolidation-decision links. A deterministic instruction
audit links only the accepted trusted-instruction extraction call. Failed attempts and the other
lane's unrelated call remain discoverable through operation and provider run, not through artifact
links.

If Plan 8 has not landed, this plan may ship the attempt ledger but cannot claim L1 artifact-link
acceptance or populate post-hoc memory links.

For L2, create the operation ID, provider run ID, and context only after `regenerateScene` proves
the source hash changed. The scene ID is already known before dispatch. After the sink commits the
attempt and typed output is accepted, upsert the scene and insert its successful-call link in one
transaction, then schedule L3 exactly as today. For L3, apply the same order around the
already-known persona ID. Mirror-file writes remain best-effort and outside the database
transaction; evidence describes the model call, not whether the plaintext convenience mirror
succeeded.

When [Plan 8](8-add-first-class-provenance.md) is available, put the same successful call IDs in
the corresponding distilled creation cause. An L1 memory gets the accepted extraction ID from its
own data or trusted-instruction lane, plus its consolidation ID only for a data atom; a scene or
persona gets its one accepted generation ID. Keep provenance and the association table
independently queryable: provenance is the artifact's causal summary, while the ledger retains
failed/orphan attempts and provider detail. Consume the evidence-decision ID and policy version from
[Plan 23](23-gate-untrusted-session-evidence-before-l1-distillation.md) rather than
inventing a second L1 selection record.

### Milestone 5: expose inspection, safe pruning, and end-to-end proof

Expose partitioned library queries by call ID, Kioku operation ID, Baikai run ID, session, scope,
and artifact. Public inspection functions take `MemoryAccessContext`, require `MemoryRead`, and
derive their one `MemorySpaceId` from the accepted authorization decision. The pruning function
requires `MemoryAdmin`. Internal storage functions take the derived `MemorySpaceId` explicitly,
and every SQL statement predicates on it. Return the local storage-safe projection, never
Baikai's full evidence JSON.

Prune only whole operations whose every call is older than the cutoff and whose calls have no
artifact association. This preserves complete retry chains for every artifact that still names an
accepted call ID, and avoids turning immutable provenance into an unexplained dangling reference.
The query reports eligible operations/calls separately from protected linked operations/calls.
Deletion runs in one transaction and lets `ON DELETE CASCADE` remove any defensive association
rows. A broader retention policy that redacts linked evidence into tombstones or coordinates
artifact deletion belongs in the retention ADR, not in a time-only delete flag.

Extend `kioku distill` with this exact `evidence` command family:

```text
kioku distill evidence call CALL_ID
kioku distill evidence operation OPERATION_ID
kioku distill evidence run PROVIDER_RUN_ID
kioku distill evidence session SESSION_ID
kioku distill evidence artifact memory|consolidation-decision|scene|persona ARTIFACT_ID
kioku distill evidence prune --before TIMESTAMP [--apply]
```

Build the command's trusted in-process context through `Kioku.Cli.Context.cliMemoryContext`,
which reads `KIOKU_MEMORY_SPACE` and matches current CLI behavior. Inspection prints one JSON
object or a JSON array. Pruning reports the count and time range it would remove but writes
nothing unless `--apply` is present. A call ID from another space prints the same not-found
result as an unknown call ID. An under-permissioned context is an explicit authorization refusal,
never an empty result.

Add pure projection/privacy tests, fake-provider retry and refusal tests, a persistence-failure
test proving no artifact or watermark advances, real-PostgreSQL migration/idempotence/isolation
tests, and an end-to-end pyramid test with genuine Baikai evidence from a local fake provider.
Keep the existing Shikumi replay-backed pyramid test and assert that it creates no provider
evidence rows, because replay does not cross a provider boundary.

Update `docs/user/distillation.md`, `docs/user/library-api.md`, and
`docs/user/cli-reference.md`. Explain evidence strength, requested-versus-observed fields,
commitments, operation versus provider-run identity, retry chains, why failed calls lack artifact
links, why replay/cache hits lack evidence rows, the absence of raw payloads and error messages,
memory-space isolation, and the dry-run-first retention command.


## Concrete Steps

Run dependency discovery from the Kioku repository root and read the resolved sources before
changing an API:

```bash
mori registry show shinzui/baikai --full
mori registry docs shinzui/baikai
mori registry show shinzui/shikumi --full
mori path mori://shinzui/baikai/packages/baikai
mori path mori://shinzui/shikumi/packages/shikumi
```

Verify current Hackage-preferred releases and upstream tags. On 2026-08-22 the first command
prints the versions already recorded in Progress; after the upstream seam is released it must
show the new release or releases before Kioku changes its bounds.

```bash
for package in baikai baikai-claude baikai-effectful shikumi shikumi-trace; do
  printf '%s ' "$package"
  curl -fsS --max-time 30 -H 'Accept: application/json' \
    "https://hackage.haskell.org/package/${package}/preferred" \
    | jq -r '."normal-version"[0]'
done

git ls-remote --tags --refs https://github.com/shinzui/baikai.git
git ls-remote --tags --refs https://github.com/shinzui/shikumi.git
```

After consuming the released seam, prove the cohort solves before editing Kioku runtime code:

```bash
nix develop -c cabal build all --enable-tests --dry-run
nix develop -c cabal build kioku-core kioku-cli
```

Create the migration through the repository's pg-migrate scaffold rather than hand-editing the
manifest:

```bash
nix develop -c just new-migration distillation-model-call-evidence
```

After adding the schema and storage module, start the development database if needed, apply the
composed plan, and run focused suites:

```bash
nix develop -c just create-database
nix develop -c cabal test kioku-migrations --test-options='-p "distillation model-call evidence"'
nix develop -c cabal test kioku-core --test-options='-p "Distillation replay metadata"'
nix develop -c cabal test kioku-core --test-options='-p "Distillation pyramid"'
nix develop -c cabal test kioku-cli --test-options='-p "distillation evidence"'
```

The replay-metadata suite must show a transient failure followed by success with attempts 1 and
2, a valid supersedes link, two durable call rows, and artifact links only for the accepted call.
It must also show that a unique secret marker placed in a provider error body is absent from the
database projection and CLI JSON.

Run the complete repository validation before finishing:

```bash
nix develop -c cabal build all --enable-tests
nix develop -c cabal test all --test-show-details=direct
nix flake check
```

Every Kioku implementation commit must use a Conventional Commit message and include both active
trailers:

```text
MasterPlan: docs/masterplans/4-secure-and-accountable-distillation-evidence.md
ExecPlan: docs/plans/16-add-distillation-replay-metadata.md
Intention: intention_01kzbs5w83e36t1gjtrz516yn5
```

An upstream Shikumi or Baikai commit refers back to this plan with the intended canonical URI,
even if the current Mori release cannot yet resolve the `plans` artifact kind:

```text
ExecPlan: mori://shinzui/kioku/plans/16-add-distillation-replay-metadata
Intention: intention_01kzbs5w83e36t1gjtrz516yn5
```


## Validation and Acceptance

Acceptance requires a released dependency cohort. Hackage and upstream tags must contain the
Shikumi attempt-evidence seam; no unreleased commit, source-repository override, or copied retry
loop may be necessary for Kioku to build.

When the effectful attempt sink and Kioku store succeed, every Baikai attempt made by live
distillation, including a strict pre-dispatch refusal and each transient retry, has exactly one
row in `kioku.distillation_model_calls`. Attempt numbers are one-based within one Baikai run,
every retry's `supersedes` names the preceding call ID, and all invocations belonging to one
top-level pass share the Kioku operation ID without sharing their Baikai run IDs. Budget refusal,
unchanged-source skips, empty-source deletion, cache hits, and deterministic replay create no
provider-call row. If observation or storage itself fails, Kioku fails closed and makes no claim
that the unrecorded attempt is auditable.

A required evidence observer or database persistence failure prevents typed output acceptance,
artifact writes, downstream scheduling, consolidation audit writes, and L1 watermark advancement.
The observer-failure test proves Shikumi does not mistake that failure for a transient provider
error and make a second paid call. A later artifact transaction failure may leave an unlinked
call row; inspection reports it honestly rather than deleting or fabricating an artifact link.

The ledger contains no raw turn content, prompt, tool output, provider body, model output,
`BaikaiError.message`, or unreviewed generic evidence JSON. Request and configuration commitments
are non-empty. Response commitment remains explicitly unobserved when Baikai says it is
unobserved. Requested and observed model/thinking fields remain distinct; no query fills an
unobserved value from the request.

A data extraction, a trusted-instruction extraction, and two data-atom consolidations produce four
independent Baikai runs under one L1 operation when both lanes are non-empty and the data lane emits
two accepted atoms. A data memory links to the accepted data extraction and its own accepted
consolidation call. An instruction memory links only to the accepted trusted-instruction
extraction; it has no consolidation run or call. Neither links failed attempts, the other lane, or
another atom's consolidation. If the trusted-instruction lane is empty, it produces no run. Scene
and persona rows link to their accepted generation calls. The same IDs are returned by
`provenanceModelCallIds` once Plan 8 is integrated.

Two memory spaces containing identical sessions, scopes, operation IDs supplied by a deterministic
fixture, artifact IDs, and query filters cannot read, link, count, or prune each other's rows.
Queries by globally unique call ID still include the memory-space predicate and return the same
not-found behavior for a foreign-space ID and an unknown ID after `MemoryRead` authorization has
succeeded for the selected space. Missing permission remains a distinct refusal.

The CLI prints only the storage-safe JSON projection. Its prune command is a dry run by default,
requires `--apply` to delete, is limited to `KIOKU_MEMORY_SPACE`, and deletes only complete
unlinked operations. It reports protected linked operations without changing them and is
idempotent when repeated. The documented example lets a user inspect an accepted artifact, follow
its call to the complete retry chain, and distinguish provider success from an unlinked/failed
attempt without reading raw database tables.


## Idempotence and Recovery

The pg-migrate change is additive and allocated through the manifest; never edit an applied
migration. The migration runner records successful application and does not execute that body a
second time. Follow the repository's strict expected-state checks rather than adding broad
`IF EXISTS` guards that accept an unknown partial layout. If another migration claims 0014 before
implementation starts, generate the next number instead of renaming committed history.

Evidence insertion is keyed by Baikai `call_id`. An identical duplicate is accepted; a duplicate
whose stored projection or context differs is a fatal integrity error. Each attempt is committed
before Shikumi may retry, so a later process failure cannot erase an already acknowledged earlier
attempt. Artifact-link insertion is idempotent on its full composite key and shares the artifact's
acceptance transaction.

If the Shikumi seam is not released, stop at Milestone 1. Do not revive the old raw-JSON design,
wrap a provider registry, copy Shikumi's retry loop into Kioku, or pin a source commit. If a
provider cannot meet a configured evidence strength, Baikai's strict refusal is the expected
queryable outcome; operators may lower the requirement only to `EvidenceRequestedOnly`.

Evidence is written before artifact acceptance. Retrying after a database failure can therefore
make another provider call whose own evidence receives new IDs; the failed operation does not
overwrite a prior call. If an artifact write fails after evidence committed, leave the row
unlinked for audit. Recovery is a normal retry, not manual deletion.

The pruning command reports its exact partition, cutoff, eligible operation/call counts,
protected linked counts, and oldest/newest eligible timestamps before deletion. Without `--apply`
it changes nothing. With `--apply`, it deletes only whole unlinked operations in one transaction.
Repeating it returns zero eligible rows once the selected window is empty. Operators who need
archival backup must export the storage-safe JSON before applying the prune; raw prompts cannot be
recovered because this plan never stored them.


## Interfaces and Dependencies

The exact released Shikumi API is owned by `mori://shinzui/shikumi/packages/shikumi`, but it must
provide the behavior described in Milestone 1. Kioku must not infer failed attempts from
`ShikumiError` or rebuild evidence from a typed program result.

Kioku's core vocabulary should be equivalent to:

```haskell
data DistillReplayPhase
  = ReplayL1ExtractData
  | ReplayL1ExtractInstructions
  | ReplayL1Consolidate
  | ReplayL2Scene
  | ReplayL3Persona

newtype DistillOperationId = DistillOperationId Text
newtype DistillProviderRunId = DistillProviderRunId Text

data DistillCallContext = DistillCallContext
  { memorySpaceId :: MemorySpaceId
  , operationId :: DistillOperationId
  , providerRunId :: DistillProviderRunId
  , phase :: DistillReplayPhase
  , sessionId :: Maybe SessionId
  , scope :: MemoryScope
  , evidenceDecisionId :: Maybe Text
  }

newtype DistillAttemptSink es = DistillAttemptSink
  { persistAttempt
      :: DistillCallContext
      -> ModelCallEvidence
      -> Eff es ()
  }

data DistillProgramResult a = DistillProgramResult
  { result :: Either ShikumiError a
  , acceptedCallId :: Maybe Text
  }

data DistillArtifactKind
  = DistillMemoryArtifact
  | DistillConsolidationDecisionArtifact
  | DistillSceneArtifact
  | DistillPersonaArtifact

data DistillArtifactRef = DistillArtifactRef
  { kind :: DistillArtifactKind
  , artifactId :: Text
  }
```

The storage and query seams should be equivalent to:

```haskell
recordDistillAttempt
  :: DistillCallContext
  -> ModelCallEvidence
  -> Eff es ()

linkAcceptedModelCallTx
  :: MemorySpaceId
  -> Text
  -> DistillArtifactRef
  -> Tx.Transaction ()

getDistillModelCall
  :: MemoryAccessContext
  -> Text
  -> Eff es (Either ReplayMetadataError (Maybe StoredModelCallEvidence))

listDistillModelCallsByOperation
  :: MemoryAccessContext
  -> DistillOperationId
  -> Eff es (Either ReplayMetadataError [StoredModelCallEvidence])

listDistillModelCallsByProviderRun
  :: MemoryAccessContext
  -> DistillProviderRunId
  -> Eff es (Either ReplayMetadataError [StoredModelCallEvidence])

listDistillModelCallsByArtifact
  :: MemoryAccessContext
  -> DistillArtifactRef
  -> Eff es (Either ReplayMetadataError [StoredModelCallEvidence])

listDistillModelCallsBySession
  :: MemoryAccessContext
  -> SessionId
  -> Eff es (Either ReplayMetadataError [StoredModelCallEvidence])

listDistillModelCallsByScope
  :: MemoryAccessContext
  -> MemoryScope
  -> Eff es (Either ReplayMetadataError [StoredModelCallEvidence])

pruneDistillModelCallsBefore
  :: MemoryAccessContext
  -> UTCTime
  -> Eff es (Either ReplayMetadataError PruneSummary)
```

`recordDistillAttempt` and `linkAcceptedModelCallTx` are internal seams used only after the caller's
distillation context has already passed `MemoryDistill` and write permissions. The attempt sink
runs `recordDistillAttempt` synchronously in the caller's Effectful stack and acknowledges only
after commit. Artifact projections call `linkAcceptedModelCallTx` in the same transaction that
accepts the artifact. The public query functions require `MemoryRead`; pruning requires
`MemoryAdmin`. All use Kioku's existing `Store`/transaction effects and propagate failure.

Kioku depends on `mori://shinzui/baikai/packages/baikai` for `EvidenceRequest`,
`ModelCallEvidence`, evidence strength, and commitments. It depends on
`mori://shinzui/shikumi/packages/shikumi` for typed program execution and the released
attempt-evidence seam. `shikumi-trace` remains the deterministic program replay facility used by
existing tests and is not the production evidence ledger. Plan 23 supplies evidence-selection
IDs and policy versions; Plan 8 supplies artifact provenance; the already-implemented memory-space
ADRs supply partition identity and SQL rules.


## Revision Notes

- 2026-08-06: Reworked the unimplemented 2026-07-07 plan after Baikai 0.5 shipped model-call
  evidence. Replaced bespoke raw input/output JSON and non-canonical hashes with provider-boundary
  evidence and commitments; added the released Shikumi cohort prerequisite, strict sink failure,
  retry provenance, memory-space isolation, and default no-raw-payload retention.
- 2026-08-22: Refreshed the plan against the released Baikai/Shikumi sources and current Kioku.
  Marked the Baikai 0.5 cohort and memory-space prerequisites complete; identified Shikumi's
  attempt-observation lifecycle as the remaining upstream blocker; aligned the migration with the
  `kioku` schema and current 0013 manifest; separated Kioku operations from Baikai retry runs;
  replaced a single artifact link with a many-to-many association; required synchronous durable
  acknowledgement of each attempt and artifact/link atomicity; excluded free-form provider errors
  and full evidence JSON from storage; limited pruning to whole unlinked operations; and made
  inspection, validation, local ADR context, and commit trailers concrete. The MasterPlan refresh
  also added the required `MasterPlan:` trailer and aligned L1 evidence with Plan 23's separate
  data and trusted-instruction extraction lanes.
