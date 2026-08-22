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

Kioku keeps L0 session focus, turn content, tool summaries, and directly recorded memories as
immutable evidence, but it no longer renders every available value verbatim into L1. A versioned
deterministic policy classifies each content source independently, excludes explicitly sensitive,
ephemeral, empty, and over-budget material, renders the remaining untrusted text only as quoted
data, and records a content-free decision that contains identifiers, reason codes, counts, the
policy version, and commitments to the exact rendered envelopes. Each extracted atom cites the
selected evidence items that support it. Data atoms are extracted from the quoted-data envelope;
instruction atoms are extracted in a separate call whose envelope contains only sources explicitly
trusted to supply instructions, then stored or exact-deduped without the general consolidator. This
keeps untrusted turn fields and recalled memories out of every model invocation allowed to decide
durable instruction text.

Generated memories and consolidation decisions then carry a versioned, partitioned account of
their creation cause; scenes and personas carry the cause of their currently materialized source
version. Every real provider
attempt made during extraction, consolidation, scene generation, or persona generation is recorded
from Baikai's provider boundary, including failed, aborted, and refused attempts. The ledger stores
only a field-by-field safe projection and canonical commitments by default; successful calls are
linked to every artifact they helped create, while failed or orphaned attempts remain discoverable
without being misrepresented as artifact causes.

The current Kioku security and storage baselines are part of this initiative's starting point, not
future prerequisites. Every path already carries `MemorySpaceId` and authorization context, and
Kioku-owned projections already live in the explicitly qualified `kioku` PostgreSQL schema. This
initiative preserves those boundaries.

This initiative does not mutate or delete L0 evidence, infer trust from conversational role or
keywords, build a general content-moderation service, persist raw prompts or model output by
default, claim that provider-boundary evidence is cryptographic attestation, fabricate evidence for
cache hits or no-call paths, or implement automatic replay. It does not decide authorization:
Kioku consumes a `MemoryAccessContext` as required by
[ADR-1](../adr/kioku-owns-memory-not-identity.md).


## Decomposition Strategy

The initiative remains split at three durable ownership boundaries. EP-1 owns model-input
eligibility: capture metadata, the versioned policy, the safe rendered envelopes, the persisted
decision, policy-aware watermarks, and per-atom source citations. EP-2 owns causal artifact
provenance: immutable creation cause for memories and consolidation decisions, plus current-version
cause for regenerated scenes and personas. EP-3 owns provider-boundary evidence: the per-attempt
ledger, storage-safe projection, operation and retry identities, artifact association
table, inspection, and retention.

These concerns deliberately overlap through typed identifiers instead of one oversized JSON value.
EP-1 decides which source IDs may be cited. EP-2 summarizes the accepted causal chain on each
artifact. EP-3 retains the complete provider-attempt history and independently associates accepted
call IDs with artifacts. The duplicated call IDs in provenance and the association table serve
different queries: an artifact-local explanation versus a complete ledger that includes failed and
orphaned attempts.

The repository now has an accepted ADR corpus. The initiative consumes
[ADR-2](../adr/namespace-is-not-a-security-boundary.md),
[ADR-4](../adr/the-aggregate-enforces-the-partition.md),
[ADR-6](../adr/the-partition-is-a-column-not-a-schema.md),
[ADR-10](../adr/projections-live-in-the-kioku-schema.md), and
[ADR-11](../adr/consumers-own-one-time-foreign-event-migration-codecs.md). No accepted ADR yet
governs L0 eligibility, artifact provenance, or model-call evidence retention. Each child plan must
distill its final durable contract into a new or updated ADR before it closes; this planning refresh
does not itself supersede an accepted decision.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Integration Deps | Status |
|---|-------|------|-----------|------------------|--------|
| EP-1 | Gate untrusted session evidence before L1 distillation | docs/plans/23-gate-untrusted-session-evidence-before-l1-distillation.md | None | EP-2, EP-3 | Not Started |
| EP-2 | Add first-class provenance | docs/plans/8-add-first-class-provenance.md | EP-1 | EP-3 | Not Started |
| EP-3 | Add distillation replay metadata | docs/plans/16-add-distillation-replay-metadata.md | EP-1 | EP-2 | Not Started |

Status values are Not Started, In Progress, Complete, and Cancelled. Hard dependencies prevent a
plan from starting. Integration dependencies permit independent implementation but require the
shared contracts in this MasterPlan to be reconciled before acceptance.


## Dependency Graph

EP-1 defines `EvidencePolicyVersion`, `EvidenceDecisionId`, stable source-evidence identifiers,
the exact selected-source citation rules, and the safe decision record. EP-2 and EP-3 depend on
those types rather than storing free-text substitutes. Once EP-1's contracts exist, EP-2 and EP-3
can proceed in parallel.

EP-2 and EP-3 have an integration dependency, not a hard ordering. EP-2 can ship provenance with
no accepted call IDs, and EP-3 can ship its ledger and association schema before provenance is
available. Atomic L1 memory-link population waits for both plans. When both exist, each newly
created artifact's provenance contains the same accepted call IDs that EP-3 associates with it.
Neither plan fabricates a historical backfill for older artifacts. EP-3 remains the authoritative
source for attempt status, retry chains, provider observations, and failed or orphaned attempts.

The former portfolio-isolation and dependency-cohort blockers are complete.
[MasterPlan 5](5-portfolio-compatible-memory-isolation-and-authorization.md) delivered
`MemorySpaceId`, `MemoryAccessContext`, partitioned timers and rows, and the aggregate and SQL
guards. Migration 0012 moved Kioku projections to `kioku.*`, and migration 0013 is the current end
of the manifest. Kioku now pins `baikai ^>=0.5.0.0`, `baikai-claude ^>=0.5.0.0`,
`baikai-effectful ^>=0.3.0.3`, `shikumi ^>=0.3.0.2`, and `shikumi-trace ^>=0.2.0.2`; Hackage's
preferred versions and the upstream tags agreed on 2026-08-22.

EP-3 still has one external behavioral prerequisite. Released Shikumi accepts Baikai 0.5 but does
not request evidence and does not expose every attempt from inside `runLLMResilient`. The owning
repository, `mori://shinzui/shikumi/packages/shikumi`, must release a seam that supplies a fresh
Baikai `EvidenceRequest` for each retry and delivers every resulting `ModelCallEvidence`, including
pre-dispatch refusals and failures, before the resilient interpreter discards the response. EP-3
must verify the released API and bounds again when it implements that milestone.

Migration numbers are allocated at implementation time with `just new-migration`. The manifest
currently ends at 0013, but no child plan owns 0014 in advance; whichever plan lands first takes
the next number, and later plans append after it.


## Integration Points

- **Evidence capture and policy:** EP-1 owns `CapturedEvidenceMetadata`,
  `SessionEvidenceMetadata`, `TurnEvidenceMetadata`, `DistillInputPolicy`,
  `EvidencePolicyVersion`, `EvidenceDecisionId`, source-evidence IDs, and the split between an
  in-memory data envelope, an optional trusted-instruction envelope, and a durable decision
  containing no content.
  Session focus, turn content, and optional tool summary are distinct items; an old tool summary
  never inherits neighboring turn trust. Existing native values default conservatively to
  untrusted data. Stored-memory fallback evidence is data-only and can never authorize an
  instruction atom. EP-2 and EP-3 consume the decision ID and policy version.

- **Atom source citations:** EP-1 extends extracted atoms with non-empty `sourceEvidenceIds` and
  validates that every ID was present in that call's envelope. The data extractor cannot emit
  instruction atoms; the instruction extractor sees only trusted-instruction sources and cannot
  emit other atom kinds. Instruction atoms bypass general model consolidation and receive a closed
  deterministic audit result. EP-2 records the atom's exact cited subset, not every item selected
  for the lane. EP-3 records the decision ID and policy version on both possible extraction calls
  and on data-atom consolidation calls.

- **Policy-aware idempotency:** EP-1 owns the extension of `kioku.l1_watermarks` with the policy
  version. A watermark covers a pass only when both the turn index and policy version match, so a
  policy upgrade can reevaluate unchanged evidence. A normal decision is persisted before the
  model call; an all-filtered decision and its watermark advance atomically. EP-3 may therefore
  reference a decision that already exists, and no provider row is created for the all-filtered
  path.

- **Artifact provenance:** EP-2 owns `Kioku.Provenance`, its versioned closed cause vocabulary,
  and the `provenance` JSONB columns. A memory or audit row's creation provenance does not get
  overwritten by later lifecycle work or a retry. A scene or persona replaces provenance only in
  the same transaction that accepts a genuinely changed source-hash version. EP-3 supplies
  accepted call IDs; it does not embed provider records into provenance.

- **Provider evidence:** EP-3 consumes `mori://shinzui/baikai/packages/baikai` and
  `mori://shinzui/baikai/docs/model-call-evidence`. It stores a field-by-field safe projection,
  never the complete `ModelCallEvidence` JSON or its free-form error message, and owns
  `kioku.distillation_model_calls` plus the many-to-many
  `kioku.distillation_model_call_artifacts` relation. One extraction may contribute to several
  memories and consolidation decisions; failed calls contribute to none.

- **Runtime and acceptance ordering:** EP-3 adds an effectful attempt sink to
  `Kioku.Distill.Runtime`. Shikumi waits for each attempt's durable acknowledgement before retrying
  or returning; typed output carries the accepted call ID but not a second in-memory ledger.
  Artifact rows/events and their accepted-call associations commit in the same artifact acceptance
  transaction. One L1 operation may contain a data extraction run, a trusted-instruction extraction
  run, or both, followed by consolidation runs for data atoms. Trusted instruction storage creates
  no consolidation call. L1's up-to-date path, L2/L3 unchanged-source paths, and L2/L3 empty-source
  deletion paths remain real no-call outcomes and must not fabricate operation or call rows.

- **Retention:** EP-3's initial prune path deletes only complete old operations with no artifact
  association. It never silently deletes a linked retry chain and leaves immutable provenance
  unexplained. A broader linked-evidence retention policy requires the final retention ADR and an
  explicit tombstone or coordinated artifact contract.

- **Partition and authorization:** All plans use `MemorySpaceId` as the first storage predicate and
  consume `MemoryAccessContext`; namespace and scope never substitute for the partition. Public
  inspection requires `MemoryRead`, pruning requires `MemoryAdmin`, and internal distillation
  writes occur only after the existing L1/L2/L3 permission preflights. No metric label may contain
  a space or principal.

- **Schema and migrations:** New relations live in the `kioku` schema and every statement uses a
  constant from `kioku-core/src/Kioku/Database/Schema.hs`. Child plans allocate the next migration
  dynamically, preserve the released manifest, bump affected read-model identities, and prove
  fresh install and upgrade behavior in real PostgreSQL.

- **Native history:** ADR-11 removed Rei's foreign decoders from normal Kioku replay. EP-1 and EP-2
  must continue to decode older native Kioku payloads, including pre-partition payloads, but must
  not restore an `imported:rei` fallback or another consumer-specific codec.


## Progress

- [x] Shared prerequisite: memory-space partitioning, authorization contexts, partitioned timers,
  rows, and workspace artifacts are implemented. (2026-08-06,
  [MasterPlan 5](5-portfolio-compatible-memory-isolation-and-authorization.md).)
- [x] Shared prerequisite: Kioku projections live in the explicitly qualified `kioku` schema and
  the migration manifest currently ends at 0013. (2026-08-21 baseline.)
- [x] Shared prerequisite: Kioku consumes the released Baikai 0.5-compatible cohort and maintains
  it with checked-in upgrade automation. (2026-08-18 baseline, reverified 2026-08-22.)
- [ ] EP-1: add conservative focus/content/tool-summary capture metadata without breaking native
  history.
- [ ] EP-1: select and render deterministic data and trusted-instruction envelopes, enforce exact
  atom citations and deterministic instruction storage, and persist policy-version-aware decisions
  and watermarks.
- [ ] EP-2: add versioned immutable creation provenance to memories and L1 audit rows.
- [ ] EP-2: carry source sets and accepted call IDs through L2/L3 and expose partitioned
  inspection.
- [ ] EP-3: land and consume a released Shikumi seam that observes every Baikai attempt.
- [ ] EP-3: persist the storage-safe ledger and many-to-many artifact links for every distillation
  call site.
- [ ] Initiative: prove the complete source-evidence → decision → provider-attempt → artifact chain
  across two memory spaces and distill the final retention and provenance contracts into ADRs.


## Surprises & Discoveries

- The old plan's two largest prerequisites are already part of Kioku. MasterPlan 5 completed the
  partition and authorization boundary, and the later schema-relocation work moved all seven
  projections from `kiroku.kioku_*` to `kioku.*`. New plans must consume those decisions instead of
  recreating them.

- Kioku already moved to the complete Baikai 0.5-compatible cohort. The remaining provider-evidence
  blocker is lifecycle visibility inside Shikumi's retry interpreter, not a Cabal version bound.

- `runLLMResilient` owns retries and converts error-shaped responses to `ShikumiError` inside its
  loop. Baikai itself does not own retries. An outer Kioku wrapper can observe at most the final
  result and cannot assign correct attempt and `supersedes` provenance.

- Current L1 preflights `MemoryDistill`, `MemoryRecord`, and `MemoryForget` before any read or model
  call, and its watermark is already partitioned. The evidence plan must extend that working
  contract with policy version, not replace its space ownership or permission ordering.

- Current L1 falls back to directly recorded memories when a session has no turns. A turn-only
  gate would leave an unreviewed input path. EP-1 therefore classifies fallback memories as
  stored-memory, data-only evidence and includes them in the same envelope and decision vocabulary.

- Current extraction also passes free-text session focus and scope labels outside `renderTurns`,
  and `renderTurns` appends an optional tool summary. The general consolidator later sees recalled
  memory content. EP-1 must therefore separate focus/content/tool-summary sources, remove free-text
  fields from outside the lane envelope, and keep instruction atoms out of general consolidation.

- A turn-index-only watermark silently suppresses reevaluation after a policy change. The policy
  version must participate in coverage and in the deterministic decision identity.

- The model must cite source IDs per atom, but a citation is still a model-declared attribution,
  not semantic proof. Recording every selected evidence item on every memory would overstate
  causality.
  More importantly, merely checking citations or whether any trusted instruction existed in one
  mixed envelope would let untrusted content influence an instruction. The instruction-capable
  call therefore receives only trusted-instruction sources.

- A complete Baikai evidence JSON value is not automatically storage-safe. The structured error's
  free-form message can contain a bounded provider response-body excerpt, so EP-3 persists only an
  explicit safe projection.

- One extraction call can contribute to many memories and consolidation decisions. A nullable
  artifact column on the call row cannot represent that relationship; a partitioned association
  table is required.

- Rei's foreign decoder was retired on 2026-08-22. Backward compatibility in this initiative now
  means native Kioku payloads only; consumer-specific import provenance must be supplied explicitly
  at the consumer boundary.


## Decision Log

- Decision: Preserve L0 exactly and gate only the evidence rendered into L1 model input.
  Rationale: Raw evidence is required for audit and future policy reevaluation; model input is the
  boundary that needs a narrower eligibility contract.
  Date: 2026-08-06

- Decision: Adopt Baikai's evidence schema and commitments instead of maintaining a Kioku-specific
  request/response hashing format.
  Rationale: The provider adapter is the only layer that knows what crossed the boundary and what
  the provider reported. Baikai keeps requested, translated, and observed facts distinct.
  Date: 2026-08-06

- Decision: Persist commitments and an explicit storage-safe evidence projection, not raw prompts,
  model output, the full Baikai JSON value, or free-form provider errors.
  Rationale: Commitments support later verification by a party that independently holds a payload
  without creating a second durable content or secret store. They are not encryption or
  confidentiality and remain protected by `MemoryRead` because low-entropy content can be guessed.
  Date: 2026-08-06; refined 2026-08-22

- Decision: Treat memory-space isolation, the `kioku` schema, and the Baikai 0.5 cohort as completed
  baselines rather than child-plan blockers.
  Rationale: They are implemented, released or checked into the current tree, covered by accepted
  ADRs and tests, and no child plan should duplicate them.
  Date: 2026-08-22

- Decision: Keep EP-1 as the hard dependency of EP-2 and EP-3, then let EP-2 and EP-3 proceed in
  parallel with an integration dependency.
  Rationale: Both downstream plans need stable decision, policy-version, and source-ID semantics.
  Provenance and provider evidence can otherwise ship independently and reconcile accepted call
  IDs later.
  Date: 2026-08-22

- Decision: Require per-atom source citations, split L1 extraction into a quoted-data lane and an
  optional trusted-instruction-only lane, and store trusted instruction atoms without general
  model consolidation.
  Rationale: Citations provide useful declared provenance but cannot prove which input influenced
  a model. Neither the instruction extractor nor any downstream invocation allowed to decide
  instruction text may see untrusted turn fields or recalled memory; a whole-call Boolean or
  citation check over a mixed envelope cannot provide that boundary.
  Date: 2026-08-22

- Decision: A policy version participates in both the evidence-decision identity and L1 watermark
  coverage.
  Rationale: A changed policy must be able to reevaluate unchanged L0 evidence without requiring a
  forced pass or rewriting the raw turns.
  Date: 2026-08-22

- Decision: Memory and consolidation-audit provenance records immutable creation cause; scene and
  persona provenance records the cause of the current source-hash version.
  Rationale: Memory lifecycle mutations must not replace origin history, while scenes and personas
  are deliberately regenerated in place. Their unchanged-source paths preserve provenance and a
  changed generation replaces content, source hash, and provenance atomically.
  Date: 2026-08-22

- Decision: EP-3 owns a many-to-many call/artifact association in addition to artifact-local call
  IDs in provenance.
  Rationale: One extraction can feed several artifacts, and the complete ledger must also retain
  failed and orphaned calls that no artifact may claim.
  Date: 2026-08-22

- Decision: No-call paths create no provider operation or call evidence.
  Rationale: Up-to-date watermarks, unchanged source hashes, empty-source deletions, cache hits, and
  deterministic test replays do not cross a provider boundary. Fabricating a row would turn
  absence of a call into a false claim that one occurred.
  Date: 2026-08-22


## Outcomes & Retrospective

Planning began on 2026-08-06 with three unimplemented child plans. No child feature has been
implemented as of 2026-08-22, but the surrounding repository changed substantially: portfolio
isolation completed, projections moved to the `kioku` schema, Baikai 0.5 landed, permission and
timer/watermark behavior was hardened, and foreign Rei decoders were retired.

The 2026-08-22 refresh keeps the three-boundary decomposition and removes obsolete prerequisite
work. It adds the current partition, authorization, schema, migration, and runtime contracts;
closes the turn-only gap by covering stored-memory fallback evidence; makes policy version part of
watermark idempotency; defines immutable memory/audit creation cause and current-version
scene/persona cause; classifies focus, turn content, and tool summaries separately; splits data and
trusted instruction extraction while retaining per-atom citations; removes general consolidation
from trusted instruction storage; and replaces a single provider/artifact link with a storage-safe
attempt ledger plus a many-to-many association. The remaining external blocker is precise: Shikumi
must expose the attempt lifecycle it currently owns.


## Revision Notes

- 2026-08-22: Refreshed the MasterPlan and all three child-plan integration contracts against the
  current Kioku tree and released dependency sources. Marked memory-space isolation, the dedicated
  `kioku` schema, and the Baikai 0.5 cohort as completed baselines; replaced the obsolete Shikumi
  version-bound blocker with the per-attempt evidence lifecycle seam; added policy-aware
  watermarks, complete current-L1 content gating, separate data and trusted-instruction extraction,
  deterministic instruction storage, per-atom citations, immutable memory/audit creation
  provenance, current-version scene/persona provenance, dynamic migration allocation, no-call
  semantics, synchronous durable attempt acknowledgement, atomic artifact links, storage-safe
  evidence projection, conservative unlinked-operation pruning, and many-to-many artifact links.
  The registry statuses remain Not Started because this revision changes plans, not feature
  implementation.
