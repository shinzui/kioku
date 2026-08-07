---
id: 4
slug: secure-and-accountable-distillation-evidence
title: "Secure and accountable distillation evidence"
kind: master-plan
created_at: 2026-08-06T14:43:34Z
intention: "intention_01kzbredbdec1btn0pf5zrbcsa"
---

# Secure and accountable distillation evidence

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Kioku keeps L0 session turns as immutable evidence, but it no longer sends every recorded
turn blindly into L1 extraction. A versioned, deterministic evidence policy classifies each
turn, excludes untrusted instructions and low-quality material from model input, and records
why evidence was selected without copying rejected secrets into a second durable store.
Generated memories, scenes, and personas then expose a causal provenance chain and a
privacy-safe model-call evidence record that can be audited without persisting raw prompts by
default.

This initiative includes the L1 evidence gate, first-class artifact provenance, and model-call
evidence for all four distillation phases. It does not mutate or delete L0 evidence, build a
general content-moderation service, claim that model-provider evidence is cryptographic
attestation, or implement automatic offline replay. It also does not make authorization
decisions; portfolio identity and access isolation are owned by
`docs/masterplans/5-portfolio-compatible-memory-isolation-and-authorization.md`.


## Decomposition Strategy

The work is split at three durable boundaries. EP-1 decides what evidence may enter a model
call. EP-2 explains which accepted evidence and earlier artifacts caused a result. EP-3
records what the provider boundary can truthfully say about the call. This keeps a policy
decision, a causal graph, and provider evidence from collapsing into one oversized JSON
record. Each stream is independently testable, while the completed initiative links their
identifiers.

The repository has no `docs/adr/` corpus today, so no local ADR governs this design. During
implementation, the evidence-retention policy and the separation between L0 retention and
model-input eligibility are durable decisions that should become ADRs before the MasterPlan
is closed. The rejected alternative was to sanitize L0 in place: that would destroy the
audit source and make policy changes impossible to reevaluate.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Gate untrusted session evidence before L1 distillation | docs/plans/23-gate-untrusted-session-evidence-before-l1-distillation.md | None | None | Not Started |
| EP-2 | Add first-class provenance | docs/plans/8-add-first-class-provenance.md | EP-1 | EP-3 | Not Started |
| EP-3 | Add distillation replay metadata | docs/plans/16-add-distillation-replay-metadata.md | EP-1 | EP-2 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 defines the policy version, evidence-selection decision, and safe summary that EP-2 and
EP-3 must reference. EP-2 and EP-3 can then proceed in parallel: provenance remains useful
without provider evidence, and provider evidence remains queryable without artifact links.
Their final integration tests require both so artifact provenance can carry provider call IDs.

There are two external ordering constraints. Kioku currently uses Baikai 0.4.1.0 and Shikumi
0.3.0.1; Baikai 0.5.0.0 is released with the evidence vocabulary, but the current released
Shikumi bounds still require Baikai below 0.5. EP-3 must not invent a second provider-evidence
format: it waits for or contributes to a released
`mori://shinzui/shikumi/packages/shikumi` compatibility seam.
Also, the schema work in EP-2 and EP-3 must consume the partition contract from
`docs/masterplans/5-portfolio-compatible-memory-isolation-and-authorization.md` rather than
adding unpartitioned tables that immediately need another migration.


## Integration Points

For each shared artifact (type, module, configuration, database table) that multiple
child plans touch, document: which plans are involved, what the shared artifact is,
which plan is responsible for defining it, and how later plans should consume or extend
it. Identify any cross-plan decisions that should become ADRs, especially architecture
boundaries, durable integration constraints, shared interface ownership, decomposition
rationale that will matter later, and deliberate exclusions.

- **Evidence selection:** EP-1 owns `DistillInputPolicy`, `EvidenceDecision`, and policy-version
  semantics. EP-2 stores only decision IDs and selected-source IDs; EP-3 stores policy version
  and commitments, not a second copy of rejected content.
- **Artifact provenance:** EP-2 owns `Kioku.Provenance` and the provenance fields on memories,
  consolidation decisions, scenes, and personas. EP-3 contributes Baikai call IDs through
  that type without embedding provider records in every artifact.
- **Provider evidence:** EP-3 consumes the released evidence schema from
  `mori://shinzui/baikai/packages/baikai`. It stores the schema version, run/call identity,
  endpoint/model observations, status, usage, and request/response commitments. Raw input and
  output capture is opt-in, separately protected, and outside the default ledger.
- **Partition key:** all three plans consume `MemorySpaceId` from MasterPlan 5. They must not
  use namespace, agent ID, or scope as a tenant substitute.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1: define and unit-test trust-aware evidence classification.
- [ ] EP-1: enforce the gate in L1, including the all-filtered success path and audit output.
- [ ] EP-2: persist partition-aware provenance from L1 through L3.
- [ ] EP-2: expose and test the complete artifact lineage.
- [ ] EP-3: upgrade through a released Baikai/Shikumi evidence-compatible cohort.
- [ ] EP-3: persist privacy-safe evidence and link call IDs to generated artifacts.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Baikai 0.5.0.0, released on 2026-08-05, already supplies canonical request commitments,
  configuration-only digests, observed-versus-requested model fields, strict pre-dispatch
  evidence requirements, and trace events. Kioku's older replay plan should consume those
  contracts rather than recreate them.
- The released Shikumi 0.3.0.1 package still bounds Baikai to `<0.5`; the provider-evidence
  integration therefore has a real cohort prerequisite even though Baikai itself is ready.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Preserve L0 exactly and gate only the evidence rendered into L1 model input.
  Rationale: Raw evidence is required for audit, replay, and future policy reevaluation; model
  input is the security boundary that must be narrowed.
  Date: 2026-08-06

- Decision: Adopt Baikai's evidence schema and commitments instead of maintaining Kioku's
  proposed bespoke input/output hashing format.
  Rationale: The provider adapter is the only layer that knows what actually crossed the
  boundary and what the provider reported. Baikai 0.5 encodes that distinction explicitly.
  Date: 2026-08-06

- Decision: Default replay metadata stores commitments and observed metadata, not raw prompts
  or outputs.
  Rationale: The old plan would have duplicated secrets and rejected prompt-injection content
  into a second durable table. Exact payload retention must be an explicit protected mode.
  Date: 2026-08-06


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

Planning completed on 2026-08-06. The initiative reuses two existing unimplemented plans and
adds one focused evidence-gate plan. Implementation has not started.
