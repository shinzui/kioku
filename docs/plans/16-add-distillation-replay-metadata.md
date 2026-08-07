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

After this change, a Kioku user can inspect a memory, scene, or persona and find a durable,
privacy-safe record of each model call that contributed to it. The record says which distillation
phase ran, which logical run and retry attempt it belonged to, which model was requested and
observed, which endpoint/transport served it, how it ended, what usage was observed, and the
canonical commitments for the exact request, its configuration, and the response. It uses
Baikai's provider-boundary evidence rather than guessing from Kioku's configured model.

“Replay metadata” remains metadata for audit and future reconstruction. This plan does not build
an automatic replay executor and does not store raw prompt or output JSON by default. A user can
query one partitioned ledger row per L1 extraction, L1 consolidation, L2 scene, and L3 persona
call, then follow the call ID from first-class provenance in
`docs/plans/8-add-first-class-provenance.md`.


## Progress

- [ ] Land or consume a released Shikumi version compatible with Baikai 0.5 model-call evidence.
- [ ] Upgrade Kioku's Baikai/Shikumi dependency cohort using released bounds and tags.
- [ ] Add partition-aware distillation run/call types and a pg-migrate ledger schema.
- [ ] Request strict minimum evidence and persist successful, failed, aborted, and refused calls.
- [ ] Instrument L1 extraction/consolidation and L2/L3 generation with stable phase/artifact links.
- [ ] Link Baikai call IDs into artifact provenance and L1 evidence-selection decisions.
- [ ] Add retry, sink-failure, privacy, partition-isolation, and pipeline integration tests.
- [ ] Expose inspection, retention configuration, and documentation.


## Surprises & Discoveries

- Baikai 0.5.0.0 was released on 2026-08-05 and already supplies the evidence schema, globally
  unique call IDs, canonical request/configuration/response commitments, requested-versus-
  observed model fields, retry provenance, strict pre-dispatch requirements, and evidence trace
  events. Reimplementing those features in Kioku would be less accurate because only the provider
  adapter knows what crossed the boundary.
- Kioku currently bounds `baikai ^>=0.4.1.0`, `baikai-claude ^>=0.4.0.1`,
  `baikai-effectful ^>=0.3.0.2`, and `shikumi ^>=0.3.0.1`. The released Shikumi 0.3.0.1 package
  requires Baikai `<0.5`, so simply widening Kioku's bounds cannot work.
- Baikai commitments bind exact content without retaining it, and its configuration projection
  removes content by allow-list. This is a better default than the original plan's durable
  `input_json` and `output_json`, which would have duplicated secrets and rejected evidence.


## Decision Log

- Decision: Adopt `Baikai.Evidence.ModelCallEvidence` and its schema version as the provider-call
  evidence contract.
  Rationale: The provider adapter observes the outgoing request, response identifiers, reported
  model, and usage. Kioku cannot reconstruct those facts reliably after the call.
  Date: 2026-08-06

- Decision: Persist commitments and evidence metadata by default, not raw structured input/output.
  Rationale: Commitments support later verification by someone who independently holds the
  payload while avoiding a second durable secret/prompt-injection store.
  Date: 2026-08-06

- Decision: Require at least `EvidenceRequestedOnly` for distillation and treat evidence-sink
  failure as call failure.
  Rationale: A generated artifact must not be accepted when the audit record the caller required
  was dropped. Higher evidence strength remains configurable per provider/deployment.
  Date: 2026-08-06

- Decision: Use phase labels `l1:extract`, `l1:consolidate`, `l2:scene`, and `l3:persona`.
  Rationale: These labels map directly to existing Kioku modules and remain stable across model
  providers.
  Date: 2026-07-07

- Decision: Store each call in its memory space and require that space on all query paths.
  Rationale: Model identity, commitments, timings, and error/usage metadata can reveal sensitive
  activity even without raw prompts.
  Date: 2026-08-06

- Decision: Automatic replay and opt-in raw payload retention are separate future work.
  Rationale: Replay execution needs a versioned program/model environment, while raw retention
  needs encryption, access control, deletion, and data-classification policy. Neither should be
  smuggled into an audit-ledger plan.
  Date: 2026-08-06


## Outcomes & Retrospective

No implementation has started. The 2026-08-06 revision replaces the original bespoke JSON/hash
design with Baikai 0.5 evidence, adds the real Shikumi cohort prerequisite, makes the ledger
partition-aware, and changes raw payload retention from default to out of scope.


## Context and Orientation

Kioku's model-driven distillation has four call sites. `Kioku.Distill.L1` runs extraction once
per session pass and consolidation once per extracted atom. `Kioku.Distill.L2` generates a scene
from active memories. `Kioku.Distill.L3` generates a persona from scenes. The runtime in
`kioku-core/src/Kioku/Distill/Runtime.hs` hides these behind four functions returning typed
Shikumi outputs. The existing `Kioku.DistillSpec` uses Shikumi replay fixtures for deterministic
tests; that test helper is not production model-call evidence.

The authoritative dependency sources are `mori://shinzui/baikai/packages/baikai` and
`mori://shinzui/shikumi/packages/shikumi`. Baikai 0.5 adds
`Baikai.Evidence.ModelCallEvidence`, `EvidenceRequest`, strictness/strength types, and a
`CallEvidence` trace event. A record contains schema/run/call/attempt identity, sanitized
endpoint and transport, requested and observed model/thinking, provider/client response IDs,
timing/status/error/usage, evidence strength, and three commitments. It deliberately does not
pretend unobserved fields equal requested values.

Shikumi currently renders typed programs into Baikai `Context` and `Options`, runs the Baikai
effect through resilient retry/routing layers, parses the `Response`, and returns only the typed
program result to Kioku. The required upstream seam is a released version that both accepts
Baikai 0.5 and lets the caller supply an `EvidenceRequest` plus durably consume the in-process
evidence before the typed response is discarded. This plan must verify the actual released API;
the signatures below are requirements, not a guess at its final names.

Plan 23 owns evidence selection and policy version. Plan 8 owns artifact provenance. MasterPlan
5 owns `MemorySpaceId` and the partitioned schema. The repository has no local ADR corpus yet;
the default evidence-retention decision should become an ADR during implementation.


## Plan of Work

### Milestone 1: release-compatible Baikai/Shikumi cohort

Use Mori to inspect both sources, then verify Hackage versions and upstream tags. Do not choose
bounds from stale local registry metadata. If Shikumi still lacks the seam, request in its owning
repository a minimal policy-neutral extension that:

- widens its released Baikai cohort to 0.5;
- lets a caller add an `EvidenceRequest` to each rendered `Options` value;
- exposes each `ModelCallEvidence` in process or through a caller-supplied trace sink;
- preserves attempt/supersedes information across Shikumi's retry/fallback loop;
- fails a strict call when the evidence sink fails.

After that release exists, update `kioku-core/kioku-core.cabal` as a coherent cohort. Compile and
run Shikumi/Baikai surface tests before changing persistence. Do not pin an arbitrary source
commit as a substitute for a release unless a separate decision explicitly authorizes it.

### Milestone 2: partitioned run and evidence ledger

Add `kioku-core/src/Kioku/Distill/ReplayMetadata.hs`. Define the four stable phases, a
`DistillRunId`, artifact link, and a storage projection of `ModelCallEvidence`. Preserve the
full evidence as JSON only after a field-by-field privacy review; at minimum materialize indexed
columns for schema version, run/call/attempt/supersedes, phase, memory space, session/scope,
artifact, requested/observed model, strength, status, and three commitments. Free-form raw
provider bodies, prompts, and outputs are forbidden.

Add the next pg-migrate file in `kioku-migrations/migrations/` after the partition migration.
Create `kioku_distillation_model_calls` with `call_id` as the Baikai globally unique primary key
and partition-leading indexes for run, session, scope, phase, and artifact queries. Include
`evidence_decision_id` for L1 and `retention_mode` so a later protected payload feature can be
distinguished without changing existing row meaning.

### Milestone 3: request, persist, and retry evidence

At the start of one L1/L2/L3 operation, generate a logical `DistillRunId`. For each provider
attempt, construct `EvidenceRequest` with that run ID, one-based attempt, and the prior Baikai
call ID in `supersedes`. Use strictness `EvidenceRequired EvidenceRequestedOnly` by default;
allow a higher configured minimum, never a lower “no evidence” mode for production distillation.

Install a sink/callback that writes the evidence row before accepting the typed result. A sink
failure returns a distillation error and prevents artifact writes/watermark advancement. A model
failure or pre-dispatch refusal still writes an evidence row with the honest status. If the model
call succeeds and the later artifact transaction fails, the evidence row may remain orphaned;
that is an accurate record of a call that occurred and the retry will produce a new attempt.

### Milestone 4: instrument phases and link artifacts

Instrument L1 extraction and each consolidation with session, scope, evidence-decision, and
future artifact identifiers. Generate the consolidation decision ID before the call so the call,
audit row, memory provenance, and merge outcome share it. Instrument L2/L3 with scene/persona IDs
known before dispatch.

Thread Baikai `callId` values into `Provenance.modelCallEvidenceIds`. Keep provenance and evidence
independently queryable: a failed call may have no artifact, and a manual artifact may have no
model call.

### Milestone 5: inspection, retention, and validation

Expose partitioned library queries by call, run, session, scope, and artifact. If CLI inspection
is included, require `--memory-space` and print the storage-safe evidence projection as JSON.
Document evidence strength, observed-versus-requested fields, commitments, retry chains, the
absence of raw payloads, and retention/deletion expectations in `docs/user/distillation.md` and
`docs/user/library-api.md`.


## Concrete Steps

Run dependency discovery and release verification from the repository root:

```bash
mori registry show shinzui/baikai --full
mori registry show shinzui/shikumi --full
curl -fsSL https://hackage.haskell.org/package/baikai/preferred.json
curl -fsSL https://hackage.haskell.org/package/shikumi/preferred.json
```

After the compatible cohort is released and bounds are updated:

```bash
nix develop -c cabal build kioku-core
nix develop -c cabal test kioku-core --test-options='-p "model-call evidence"'
nix develop -c cabal test kioku-core --test-options='-p "Distillation pyramid"'
nix develop -c cabal test kioku-migrations
nix develop -c cabal test all
```

The focused suite must show one extraction call, the expected consolidation calls, one scene
call, and one persona call, with run/call identity, phase, partition, status, and commitments.


## Validation and Acceptance

Acceptance requires all of the following:

- Released dependency bounds solve as one Baikai 0.5-compatible Shikumi cohort; no unreleased
  commit or local source override is silently required.
- Every live distillation provider attempt produces exactly one durable evidence row, including
  success, provider failure, pre-dispatch refusal, stream abort, and retry/fallback.
- A strict evidence-sink failure prevents artifact writes and L1 watermark advancement.
- Rows store no raw turn content, prompt, tool output, or model output by default. Request and
  response commitments are non-empty and use Baikai's evidence schema.
- Requested and observed model fields remain distinct; unobserved is never filled from requested.
- Retry rows form a valid attempt/supersedes chain under one run ID.
- Artifact provenance contains the corresponding Baikai call IDs; failed/orphan calls remain
  queryable without fabricated artifact links.
- Two spaces with identical sessions/scopes/artifact IDs cannot query each other's call rows.
- Existing deterministic Shikumi replay tests continue to pass; they remain test fixtures rather
  than being mislabeled production evidence.


## Idempotence and Recovery

The pg-migrate file is additive and never edits applied migrations. Insert by Baikai `call_id`.
A duplicate is accepted only when schema version, run, attempt, phase, space, status, and
commitments match; otherwise it is a fatal integrity error. Evidence writes happen before
artifact acceptance, so retrying after a sink failure is safe and visible as another attempt.

If the Shikumi prerequisite is unavailable, keep this plan blocked at Milestone 1; do not revive
the old raw-JSON design. If a higher strict evidence strength is unsupported by a provider, the
pre-dispatch refusal is expected and queryable. Operators can lower the configured requirement
only to the plan's minimum `EvidenceRequestedOnly`, not disable evidence for production
distillation.


## Interfaces and Dependencies

Kioku's storage-facing interface should be equivalent to:

```haskell
data DistillReplayPhase
  = ReplayL1Extract
  | ReplayL1Consolidate
  | ReplayL2Scene
  | ReplayL3Persona

data DistillCallContext = DistillCallContext
  { memorySpaceId :: MemorySpaceId
  , phase :: DistillReplayPhase
  , runId :: DistillRunId
  , sessionId :: Maybe SessionId
  , scope :: MemoryScope
  , evidenceDecisionId :: Maybe Text
  , artifact :: Maybe ArtifactRef
  }

recordModelCallEvidence
  :: DistillCallContext
  -> ModelCallEvidence
  -> Eff es ()
```

The exact Shikumi seam is determined in its owning repository, but it must carry Baikai's
`EvidenceRequest` and return/deliver `ModelCallEvidence` without rebuilding it from a typed
Shikumi output. Kioku depends on `mori://shinzui/baikai/packages/baikai` for the evidence
vocabulary, `mori://shinzui/shikumi/packages/shikumi` for typed program execution, plan 23 for
evidence-selection IDs, plan 8 for artifact provenance, and MasterPlan 5 for `MemorySpaceId`.

Every implementation commit must include:

```text
ExecPlan: docs/plans/16-add-distillation-replay-metadata.md
```


## Revision Notes

- 2026-08-06: Reworked the unimplemented 2026-07-07 plan after Baikai 0.5 shipped model-call
  evidence. Replaced bespoke raw input/output JSON and non-canonical hashes with provider-boundary
  evidence and commitments; added the released Shikumi cohort prerequisite, strict sink failure,
  retry provenance, memory-space isolation, and default no-raw-payload retention.
