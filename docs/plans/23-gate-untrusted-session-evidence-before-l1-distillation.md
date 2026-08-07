---
id: 23
slug: gate-untrusted-session-evidence-before-l1-distillation
title: "Gate untrusted session evidence before L1 distillation"
kind: exec-plan
created_at: 2026-08-06T14:43:34Z
intention: "intention_01kzbredy3ejab41f0a3vdg5be"
master_plan: "docs/masterplans/4-secure-and-accountable-distillation-evidence.md"
---

# Gate untrusted session evidence before L1 distillation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, L1 distillation receives a deliberate evidence envelope rather than a
verbatim transcript. Session capture remains lossless, but every turn has an origin and trust
classification, a versioned policy decides whether and how it may be used, and the model sees
untrusted material only as quoted data. Operators can inspect a compact evidence decision that
lists selected and excluded turn IDs with reason codes. If no turn is eligible, Kioku records a
successful no-evidence outcome and advances the watermark without calling a model.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Define evidence origin, trust, disposition, exclusion reason, and policy-version types.
- [ ] Add backward-compatible origin/trust metadata to session turn commands, events, and rows.
- [ ] Implement deterministic classification, secret redaction, and an explicitly delimited
  model-input renderer.
- [ ] Integrate selection into `buildExtractInput` and add the all-filtered success outcome.
- [ ] Persist partition-aware evidence decisions without rejected content.
- [ ] Add pure, event-replay, real-PostgreSQL, and distillation integration tests.
- [ ] Document configuration, legacy behavior, metrics, and operator inspection.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `RecordTurnData`, `TurnRecordedData`, and `TurnRow` currently carry role, content, an optional
  tool summary, token counts, and time, but no source or trust metadata. Role alone cannot tell
  whether text came from a trusted control plane or an untrusted tool response.
- `Kioku.Distill.L1.buildExtractInput` renders every turn verbatim. The extraction signature
  asks the model to ignore secrets, but that is a prompt instruction, not a trust boundary.


## Decision Log

Record every decision made while working on the plan.

- Decision: Preserve raw L0 evidence and gate only the derived L1 input.
  Rationale: Deleting or rewriting turns would destroy the audit source and prevent later policy
  versions from reevaluating the same evidence.
  Date: 2026-08-06

- Decision: Trust is capture metadata, not inferred from role or keyword heuristics.
  Rationale: Assistant and tool text can contain external instructions, while user text can
  contain legitimate durable preferences. A source boundary is more reliable than a regex.
  Date: 2026-08-06

- Decision: Legacy unclassified turns may be included only as quoted evidence and may not
  produce durable `instruction` atoms without an explicit trusted-instruction classification.
  Rationale: This preserves useful facts from old sessions without granting historical free-text
  content control-plane authority.
  Date: 2026-08-06

- Decision: Evidence decisions store identifiers, reason codes, counts, hashes, and policy
  version, never rejected content.
  Rationale: An audit record must not become a second secret or prompt-injection store.
  Date: 2026-08-06


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

No implementation has started. The expected outcome is a policy-gated L1 path whose safe and
all-filtered cases are both deterministic and observable.


## Context and Orientation

L0 is Kioku's raw session evidence. `kioku-core/src/Kioku/Session/Domain.hs` defines
`RecordTurnData` and `TurnRecordedData`; `kioku-core/src/Kioku/Session/ReadModel.hs` projects
them as `TurnRow`. These types currently have no origin or trust field. Old event payloads must
continue to decode.

L1 lives in `kioku-core/src/Kioku/Distill/L1.hs`. `distillSessionL1` loads all turns,
`buildExtractInput` calls `renderTurns`, and `runExtraction` sends the resulting `ExtractInput`
to `mori://shinzui/shikumi/packages/shikumi`. The watermark advances only after a full successful
fold. The new all-filtered path must preserve that idempotency rule while avoiding a pointless
model call.

`kioku-core/src/Kioku/Distill/Extract.hs` defines the structured output and currently permits
an `instruction` atom. The trust gate must carry enough information to reject an instruction
derived only from untrusted evidence after model decoding, even if the model ignores the prompt
boundary. The repository has no local ADR corpus. The security boundary and legacy policy must
be promoted to ADRs during implementation.


## Plan of Work

### Milestone 1: classify captured evidence

Add `kioku-core/src/Kioku/Distill/Evidence.hs` with `EvidenceOrigin`, `EvidenceTrust`,
`EvidenceDisposition`, `EvidenceExclusionReason`, `DistillInputPolicy`, and pure selection
functions. Origins should distinguish control-plane input, user-provided text, agent output,
tool output, imported memory, and legacy-unclassified evidence. Trust must be an explicit
closed type. The policy has a stable textual version and bounded input limits.

Extend turn command/event/read-model types with additive metadata. Custom decoders default old
events to legacy-unclassified. Add provenance-aware recording functions while preserving a
deprecated compatibility wrapper. Pure tests must cover every origin/trust combination.

### Milestone 2: render a safe extraction envelope

Replace `renderTurns` with a renderer that returns both `ExtractInput` and an
`EvidenceDecision`. Delimit each item, escape delimiter collisions, label its origin/trust, and
state in the system instruction that enclosed text is evidence, never executable instructions.
Apply deterministic redaction before rendering; record only a commitment hash for excluded or
redacted content.

Add a post-decode guard in L1: an extracted `instruction` is accepted only if the decision says
trusted-instruction evidence was present. Other atom kinds remain subject to existing schema
validation. If no eligible evidence remains, write the decision, advance the watermark, and
return `L1NoEligibleEvidence summary` without calling `runExtraction`.

### Milestone 3: persist and observe decisions

After MasterPlan 5 supplies `MemorySpaceId`, add a migration for
`kiroku.kioku_distillation_evidence_decisions`. Store decision ID, memory space, session ID,
turn-index watermark, policy version, selected turn IDs, exclusions as `{turnId, reason}`, input
commitment, counts, and time. Do not store content. Link the decision ID into the provenance
contract in `docs/plans/8-add-first-class-provenance.md`.

Add counters for selected, excluded-by-reason, redacted, all-filtered, and rejected-untrusted-
instruction outcomes through Kioku's existing metrics surface. Document the policy and a
library/CLI inspection path in `docs/user/distillation.md`.


## Concrete Steps

Run from the repository root:

```bash
nix develop -c cabal test kioku-core --test-options='-p "Distillation evidence"'
nix develop -c cabal test kioku-core --test-options='-p "Distillation pyramid"'
nix develop -c cabal test all
```

The focused suite must report passing cases for trusted input, untrusted tool injection,
legacy evidence, secret redaction, delimiter escaping, untrusted instruction rejection, and the
all-filtered no-call path. The full suite must end with all package tests passing.


## Validation and Acceptance

Acceptance requires all of the following behavior:

- A turn marked external-untrusted containing “ignore previous instructions” remains intact in
  L0, but either is excluded or appears only inside the labelled evidence envelope.
- The same turn cannot create an `instruction` memory. A trusted control-plane instruction can.
- Rejected content never appears in the evidence-decision table, logs, metrics labels, or replay
  metadata; only IDs, reasons, counts, and commitments appear.
- A session with only excluded turns produces no provider call, writes one decision, advances
  the L1 watermark, and is skipped on redelivery.
- Old turn events replay successfully as legacy-unclassified evidence.
- Two memory spaces with identical session/turn identifiers cannot observe each other's
  evidence decisions after MasterPlan 5 lands.


## Idempotence and Recovery

The migration is additive and follows the current `pg-migrate` chain. Reprocessing a session at
the same watermark and policy version must upsert the same decision or detect an identical
commitment; it must not multiply audit rows on timer redelivery. A failure before the decision
and watermark transaction commits leaves the old watermark and is safe to retry. Rolling back
application code leaves the additive metadata/table unused; raw L0 evidence is unaffected.


## Interfaces and Dependencies

The new public core seam should be equivalent to:

```haskell
data DistillInputPolicy
data EvidenceDecision

selectEvidence :: DistillInputPolicy -> [TurnRow] -> EvidenceDecision
renderSelectedEvidence :: EvidenceDecision -> ExtractInput
allowsInstructionAtoms :: EvidenceDecision -> Bool
```

`EvidenceDecision` exposes selected IDs and exclusion reasons but keeps selected content behind
the renderer. The implementation uses existing Aeson, hashing, metrics, and Hasql facilities.
It depends on `MemorySpaceId` from MasterPlan 5 and integrates with `Kioku.Provenance` from plan
8. It does not depend on Shomei, Meibo, En, or an external moderation API.
