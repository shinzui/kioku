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

After this change, an L1 distillation pass receives a deliberate evidence envelope rather than a
verbatim transcript or an unclassified fallback-memory dump. Session capture remains lossless. A
host can label the session focus, each turn's content, and its optional tool summary independently
with origin, whether it is trusted to supply instructions, and whether it is a durable candidate,
ephemeral material, or sensitive material. Existing native Kioku session/turn events remain
replayable and default conservatively to legacy-unclassified, untrusted data; an old tool summary
is additionally known to have tool-output origin but gains no trust.

A versioned deterministic policy evaluates session focus, separate turn-content/tool-summary
items, and the directly recorded memories that current L1 uses when a session has no turns. It
excludes explicit sensitive and ephemeral items, empty items, and whole items that do not fit the
configured bounds. Optional exact-literal redactions remove secrets the host explicitly supplies;
Kioku does not pretend that a regex or role name can discover every secret. The selected values are
encoded as a fixed-shape JSON evidence envelope whose content is carried as quoted values rather
than prompt directives.

Every extracted atom cites the evidence-item IDs that support it. Kioku accepts a citation only
when the item was present in that invocation's envelope. Data atoms come from one call over quoted
selected evidence whose output schema excludes `instruction`. Instruction atoms come from a
separate optional call whose envelope contains only sources explicitly captured as trusted
instruction sources and whose output schema permits only `instruction`. Citations remain useful
model-declared attribution rather than proof of semantic influence; the separate call is what
keeps untrusted content out of the instruction-capable boundary.

An accepted instruction atom bypasses the general L1 consolidation model, because that call sees
existing stored memories whose instruction trust is not established. Kioku stores or exact-dedupes
the trusted-lane atom deterministically and writes a policy audit result. Data atoms continue
through model consolidation, whose atom type cannot become `instruction`.

Operators can inspect a partitioned durable decision containing source IDs, dispositions, reason
codes, counts, the policy version, and commitments to the exact data and optional trusted-
instruction envelope bytes, but no selected or rejected content. Commitments are verification
bindings, not encryption; inspection still requires `MemoryRead` because low-entropy content can
be guessed.

If the policy selects nothing, Kioku writes the decision and advances the policy-aware L1 watermark
atomically without making an extraction or consolidation model call. A policy version change makes
unchanged L0 evidence eligible for reevaluation without rewriting it or requiring `--force`.


## Progress

- [ ] Define the versioned policy, capture metadata, source-evidence IDs, in-memory envelope, and
  content-free durable decision types.
- [ ] Add evidence-aware session-start and turn-recording APIs while preserving source
  compatibility and native event replay with conservative defaults for focus, turn content, and
  tool summaries.
- [ ] Classify session focus, turn content, tool summaries, and the no-turn stored-memory fallback;
  apply deterministic selection/redaction/bounds; and render golden-tested data and
  trusted-instruction envelopes.
- [ ] Split extraction into a data-only lane and an optional trusted-instruction-only lane, then
  enforce exact source citations within each lane and bypass untrusted consolidation for
  instruction atoms.
- [ ] Persist decisions in the `kioku` schema, extend L1 watermarks with policy version, and make
  all-filtered decision/watermark advancement atomic.
- [ ] Integrate the gate into the current permission-preflight and watermark order without
  fabricating calls on up-to-date or all-filtered paths.
- [ ] Expose partitioned library and CLI inspection and add pure, native-replay, PostgreSQL,
  authorization, idempotency, and full-pipeline tests.
- [ ] Update user and operator documentation and distill the final eligibility boundary into an
  ADR before completing the plan.


## Surprises & Discoveries

- `RecordTurnData`, `TurnRecordedData`, and `TurnRow` still carry role, content, optional tool
  summary, token counts, and time but no evidence-origin or trust metadata. Role remains an
  organizing label and cannot safely double as a trust decision.

- `Kioku.Distill.L1.buildExtractInput` still calls `renderTurns` over every turn verbatim. The
  extraction prompt asks the model to ignore secrets, but a prompt instruction is not a policy
  boundary.

- Current L1 has a second input path: when no turns exist, `fallbackMemoryText` renders memories
  found by session and then by exact scope. A turn-only gate would leave this path unclassified.

- Current extraction also passes free-text session `focus` and a rendered scope label outside
  `renderTurns`, while each rendered turn can append a separate `toolSummary`. A content-only turn
  envelope would therefore omit real model inputs and make per-atom citations incomplete.

- The general consolidator sees recalled stored-memory content and can choose rewritten result
  text. Letting an instruction atom pass through it would reintroduce untrusted text after the
  trusted-only extraction lane.

- L1 now preflights `MemoryDistill`, `MemoryRecord`, and `MemoryForget` before reading the
  session, and the watermark is already keyed by `MemorySpaceId` and session. This plan extends
  those contracts; it does not move or weaken them.

- The current watermark records only the maximum turn index. If policy version 2 replaces version
  1 while the session has no new turn, `watermarkCovers` would skip the pass and prevent the new
  policy from reevaluating the immutable evidence.

- The repository now has a dedicated `kioku` schema, qualified relation constants in
  `Kioku.Database.Schema`, and a migration manifest ending at 0013. The old
  `kiroku.kioku_distillation_evidence_decisions` name is obsolete.

- Kioku has no dedicated distillation-evidence metrics surface. User-visible summaries, stored
  decisions, library/CLI inspection, tests, and low-cardinality traces are sufficient for this
  plan. It must not add memory-space or principal metric labels.

- Rei's foreign event decoder was retired under
  [ADR-11](../adr/consumers-own-one-time-foreign-event-migration-codecs.md). Compatibility here
  means native Kioku payloads only; this plan must not restore a consumer-specific fallback.


## Decision Log

- Decision: Preserve raw L0 evidence and gate only the derived L1 input.
  Rationale: Deleting or rewriting turns would destroy the audit source and prevent later policy
  versions from reevaluating the same evidence.
  Date: 2026-08-06

- Decision: Trust is capture metadata, not inferred from role, keywords, or model output.
  Rationale: Assistant and tool text can contain external instructions, while a host may have a
  real control-plane source whose role label looks ordinary. The capture boundary knows more than
  a downstream heuristic.
  Date: 2026-08-06

- Decision: Existing native session focus and turn content decode as legacy-unclassified,
  untrusted, durable-candidate evidence. An old optional tool summary is a separate tool-output,
  untrusted, durable-candidate item.
  Rationale: Old sessions remain useful as quoted factual evidence without gaining the ability to
  create durable instruction atoms or letting a tool summary inherit trust from neighboring turn
  content. Native compatibility is Kioku's responsibility under ADR-11.
  Date: 2026-08-06; refined 2026-08-22

- Decision: Directly recorded memories used by L1's no-turn fallback are stored-memory, untrusted,
  durable-candidate evidence and cannot authorize instruction atoms.
  Rationale: The current fallback is a real model-input path. Treating a prior memory record as data
  preserves current usefulness without silently promoting it to control-plane authority.
  Date: 2026-08-22

- Decision: Secret handling is explicit. A sensitive evidence item is excluded as a whole; optional
  policy redactions replace exact non-empty literals before rendering. Kioku performs no broad
  secret-discovery heuristic.
  Rationale: A deterministic allow-list or caller-supplied literal can be tested and versioned.
  Claiming that a regex discovered every secret would create false security.
  Date: 2026-08-22

- Decision: Persist a content-free `EvidenceDecision` separately from an in-memory
  `EvidenceEnvelope` that holds selected content and has no `Show`, `ToJSON`, or durable
  instance.
  Rationale: The selection audit must not become a second prompt or secret store, while the renderer
  still needs the selected bytes during one pass.
  Date: 2026-08-22

- Decision: Every extracted atom cites a non-empty subset of the IDs in its invocation's envelope.
  Data extraction cannot emit instructions; instruction extraction runs separately over only
  `TrustedInstructionSource` items and cannot emit other atom kinds.
  Rationale: Citations are useful declared provenance but cannot prove which input influenced a
  model. A mixed-envelope post-filter would still let untrusted text shape an instruction. The
  instruction-capable invocation must not receive untrusted content.
  Date: 2026-08-22

- Decision: Session focus, turn content, and optional tool summary are separate evidence items;
  free-text focus and scope labels do not bypass the lane envelope.
  Rationale: They are distinct content sources with different likely origins. One turn-level trust
  bit would let an untrusted tool summary inherit a trusted control-plane classification, while an
  uncited focus could still shape every atom.
  Date: 2026-08-22

- Decision: Instruction atoms use deterministic store/exact-dedup plus an audit row, not the
  general model consolidator.
  Rationale: The consolidator sees existing memory content whose trust is not established. A
  second trusted-only consolidation vocabulary could be added later, but the first secure path
  must not expose untrusted candidates to a call that can decide durable instruction text.
  Date: 2026-08-22

- Decision: Invalid source citations and wrong-lane atom kinds are dropped deterministically and
  counted on the stored decision outcome; valid sibling atoms continue.
  Rationale: Retrying the same prompt cannot make an unknown source valid or move a data atom into
  the instruction lane, and would spend tokens until the timer dead-lettered. Dropping is
  fail-closed for the artifact while preserving unrelated valid output.
  Date: 2026-08-22

- Decision: The evidence policy version participates in the deterministic decision ID and in L1
  watermark coverage.
  Rationale: A new policy must reevaluate the same L0 state. Turn index alone describes evidence
  growth, not the eligibility rule applied to it.
  Date: 2026-08-22

- Decision: Persist the decision before a real model call, but advance the watermark only after the
  full pass succeeds. Persist an all-filtered decision and its watermark in one transaction.
  Rationale: Provider-call evidence can safely reference an existing decision; a failed model or
  artifact write remains retryable; and the no-call path cannot leave half of its only durable
  outcome behind.
  Date: 2026-08-22


## Outcomes & Retrospective

No implementation has started. The 2026-08-22 refresh turns the original turn-only prompt wrapper
into a complete current-L1 contract: it includes stored-memory fallback evidence, separate data
and trusted-instruction extraction, separate focus/content/tool-summary sources, exact per-atom
citations, deterministic instruction storage without untrusted consolidation, explicit rather
than heuristic secret handling, policy-version-aware watermarks, the current partition/permission
order, the `kioku` schema, native-only compatibility, and observable all-filtered behavior.


## Context and Orientation

Kioku is a Haskell library and command-line program for durable agent memory. L0 is its raw
evidence floor. A normal host starts a session, records ordered turns while the session is running,
and later completes or fails it. A session currently contains free-text focus and structured scope.
A turn contains role, content, an optional tool summary, token counts, and a timestamp. Directly
recorded memories are also an L0 input because L1 falls back to them for sessions with no turns.

The command shapes `StartSessionData` and `RecordTurnData` and event shapes `SessionStartedData`
and `TurnRecordedData` are in `kioku-core/src/Kioku/Session/Domain.hs`. The native event parser is in
`kioku-core/src/Kioku/Session/EventStream.hs`. The projection type `TurnRow`, SQL statements,
session/turn row types, read-model version, and shape hash are in
`kioku-core/src/Kioku/Session/ReadModel.hs`. The public write path is
`Session.startWithContext` and `Session.recordTurnWithContext` in
`kioku-core/src/Kioku/Session.hs`. The context already checks `MemoryRecord`, the authorized memory
space, and the recorded actor before the aggregate runs.

Native session events written before memory spaces existed decode into the explicit legacy space,
and old actor fields use the recorded-attribution defaults in
[ADR-5](../adr/historical-attribution-is-marked-never-invented.md). Preserve those native defaults.
Do not add back the retired Rei parser; ADR-11 assigns foreign migration codecs to the consumer.

L1 is implemented in `kioku-core/src/Kioku/Distill/L1.hs`.
`distillSessionL1` currently performs the following sequence:

1. Check `MemoryDistill`, `MemoryRecord`, and `MemoryForget`, in that order.
2. Read the session and its partitioned turns.
3. Compute the maximum turn index and consult the partitioned watermark unless forced.
4. Build `ExtractInput` from free-text focus and every turn, or from focus plus
   `fallbackMemoryText` when no turns exist; the rendered turn includes optional tool summary.
5. Call `runExtraction` once.
6. For each atom, find candidates, call consolidation, apply the result, and write an audit row.
7. Advance the watermark after the entire fold succeeds.

This plan inserts eligibility after the watermark check and before step 4's rendering. It turns
focus, turn content, and tool summary into distinct candidate IDs, removes arbitrary free-text
focus/scope fields from outside the envelope, and preserves the permission preflight and up-to-date
no-call path. A policy upgrade changes the watermark check because coverage now also compares
policy version.

The typed extraction schema lives in `kioku-core/src/Kioku/Distill/Extract.hs`.
`ExtractedAtom` currently has atom type, content, priority, and confidence. This plan adds source
citations and introduces lane-specific output validation. The data program accepts fact, pattern,
preference, and constraint but not instruction. The optional instruction program accepts only
instruction. Source enforcement occurs in Kioku after decoding because it depends on the exact
envelope for that invocation. Data atoms retain the current consolidation path. Instruction atoms
use deterministic store/exact-dedup and an audit row without calling the general consolidator.

The current projection relations are `kioku.sessions`, `kioku.turns`,
`kioku.l1_watermarks`, `kioku.consolidation_decisions`, and the other tables declared in
`kioku-core/src/Kioku/Database/Schema.hs`. Every statement must use a qualified constant from
that module. The numbered pg-migrate history is in `kioku-migrations/migrations/`, and
`just new-migration` allocates the next number. At this revision the manifest ends at 0013, but
the implementer must inspect it again and never reserve a number in advance.

The accepted architectural context is:

- [ADR-1](../adr/kioku-owns-memory-not-identity.md): Kioku consumes authorization rather than
  constructing identity or policy.
- [ADR-2](../adr/namespace-is-not-a-security-boundary.md): only `MemorySpaceId` isolates data;
  scope and namespace only organize it.
- [ADR-4](../adr/the-aggregate-enforces-the-partition.md): commands and distillation preflights
  enforce the same partition and permission context.
- [ADR-6](../adr/the-partition-is-a-column-not-a-schema.md): every statement includes an
  unconditional memory-space predicate.
- [ADR-10](../adr/projections-live-in-the-kioku-schema.md): Kioku relations are explicitly
  qualified under `kioku`.
- [ADR-11](../adr/consumers-own-one-time-foreign-event-migration-codecs.md): normal codecs decode
  native Kioku history, not foreign application history.

No accepted ADR yet governs evidence eligibility. Before this plan is complete, promote the final
capture trust, policy versioning, and L0-versus-model-input boundary into `docs/adr/`.


## Plan of Work

### Milestone 1: define capture metadata and policy vocabulary

Create `kioku-core/src/Kioku/Evidence.hs` for the stable host-facing capture vocabulary. Keep this
module independent of session and distillation types so `Kioku.Session.Domain` can import it without
forming a cycle. Use closed constructors rather than free-text labels:

```haskell
data EvidenceOrigin
  = ControlPlane
  | UserInput
  | AgentOutput
  | ToolOutput
  | StoredMemory
  | LegacyUnclassified

data EvidenceTrust
  = TrustedInstructionSource
  | UntrustedData

data EvidenceUse
  = DurableCandidate
  | EphemeralEvidence
  | SensitiveEvidence

data CapturedEvidenceMetadata = CapturedEvidenceMetadata
  { origin :: EvidenceOrigin
  , trust :: EvidenceTrust
  , use :: EvidenceUse
  }

newtype SessionEvidenceMetadata = SessionEvidenceMetadata
  { focusEvidence :: CapturedEvidenceMetadata
  }

data TurnEvidenceMetadata = TurnEvidenceMetadata
  { contentEvidence :: CapturedEvidenceMetadata
  , toolSummaryEvidence :: Maybe CapturedEvidenceMetadata
  }
```

Create `kioku-core/src/Kioku/Distill/Evidence.hs` for the policy, candidate, selection, envelope,
and decision vocabulary. It may import `Kioku.Evidence`, `Kioku.Session.Domain`, and memory
identifiers; the capture module must not import it:

```haskell
newtype EvidencePolicyVersion = EvidencePolicyVersion Text
newtype EvidenceDecisionId = EvidenceDecisionId Text

data EvidenceSourceId
  = SessionFocusEvidenceId SessionId
  | TurnContentEvidenceId Text
  | TurnToolSummaryEvidenceId Text
  | MemoryEvidenceId Text
```

Encode source IDs with an unambiguous tagged JSON shape or stable rendered prefixes such as
`session-focus:`, `turn-content:`, `turn-tool-summary:`, and `memory:`; never compare raw source
identifiers or content in one namespace. Validate policy versions as non-empty bounded text.

`DistillInputPolicy` contains its explicit version, maximum item count, maximum UTF-8 bytes per
item and for the whole envelope, and a list of non-empty exact sensitive literals. Do not derive
`Show` or `ToJSON` for a policy that holds literals. Document that a host must change the policy
version whenever redactions, bounds, or classification rules change.

Separate the ephemeral value that contains content from the durable value that does not:

```haskell
data EvidenceEnvelope

data EvidenceDecision = EvidenceDecision
  { decisionId :: EvidenceDecisionId
  , memorySpaceId :: MemorySpaceId
  , sessionId :: SessionId
  , maxTurnIndex :: Int
  , policyVersion :: EvidencePolicyVersion
  , selected :: [SelectedEvidenceSummary]
  , excluded :: [ExcludedEvidenceSummary]
  , dataEnvelopeCommitment :: Maybe Text
  , instructionEnvelopeCommitment :: Maybe Text
  , validatedDataAtomCount :: Int
  , validatedInstructionAtomCount :: Int
  , rejectedUnknownCitationCount :: Int
  , rejectedWrongLaneAtomCount :: Int
  }
```

`EvidenceEnvelope` may expose safe query functions and the renderer, but it must not expose a
content-bearing `Show`, `ToJSON`, or database encoder. `EvidenceDecision` contains source IDs,
origin/trust labels, disposition or exclusion reason, before/after byte counts, and the two optional
commitments; it never contains content or redaction literals.

Milestone acceptance is a pure test suite that round-trips every public enum, rejects an empty
policy version and empty redaction literal, proves all four source kinds cannot collide, and uses
a compile-time or ordinary type-level test to ensure the durable decision has no content field.

### Milestone 2: capture metadata without breaking callers or native replay

Keep the existing public `StartSessionData` and `RecordTurnData` records source-compatible.
Introduce internal command wrappers that pair them with `SessionEvidenceMetadata` and
`TurnEvidenceMetadata`, and add:

```haskell
startWithEvidence
  :: MemoryAccessContext
  -> SessionEvidenceMetadata
  -> StartSessionData
  -> Eff es (Either SessionWriteError SessionId)

recordTurnWithEvidence
  :: MemoryAccessContext
  -> TurnEvidenceMetadata
  -> RecordTurnData
  -> Eff es (Either SessionWriteError SessionId)
```

`startWithContext` and `recordTurnWithContext` remain available and delegate with conservative
defaults; deprecate them only if project compatibility policy allows, but do not force existing
record construction sites to add fields. The explicit new functions use the same `underContext`
checks as the current functions. Validate that `toolSummaryEvidence` is present exactly when
`RecordTurnData.toolSummary` is present.

Add focus metadata to `SessionStartedData` and `SessionRow`, and per-field metadata to
`TurnRecordedData` and `TurnRow`. Their custom native `FromJSON` instances default missing focus
and turn-content metadata to legacy-unclassified, untrusted, durable-candidate; a present old tool
summary defaults separately to tool-output, untrusted, durable-candidate. Update the session and
turn projection statements, decoders, read-model version and shape hash, and inline projection.
Add an additive migration with validated closed columns on `kioku.sessions` and `kioku.turns`;
keep tool-summary metadata nullable exactly when the summary is absent. Backfill all existing rows
to those conservative defaults.

Keep aggregate invariants and idempotent duplicate comparisons correct: two otherwise identical
session-start or turn commands whose evidence metadata differs are a conflict, not the same write.
Add native old-payload fixtures, new-payload round trips, duplicate/concurrent write tests, and a
real PostgreSQL projection test.

Milestone acceptance is that old native events still replay, new session and turn rows expose exact
capture metadata, independently classified content/tool-summary values round-trip, an explicit
trusted control-plane focus round-trips, and no Rei event tag is accepted.

### Milestone 3: select and render lane-specific evidence envelopes

Convert session focus to one candidate, then turn content and each present tool summary to distinct
candidates in ascending turn index and content-before-summary order. Convert the no-turn fallback
memories to `StoredMemory`, `UntrustedData`, `DurableCandidate` candidates, ordered
deterministically by creation time and memory ID. Focus is present in both the turn and fallback
cases. The fallback remains active only when the session has no turns, exactly as today; this plan
does not mix scope memories into a session that already has captured turns.

Selection proceeds in a fixed order:

1. Exclude sensitive, ephemeral, or empty candidates with a closed reason code.
2. Replace every exact sensitive literal with `[REDACTED]`, in policy-list order, and record only
   whether redaction occurred plus byte counts.
3. Exclude an item whose redacted UTF-8 bytes exceed the per-item bound.
4. Select the newest candidates that fit the item-count and total-byte bounds, then restore source
   order for rendering. Mark the remainder `OverBudget`; never truncate a candidate silently.
5. Render the data envelope from all selected durable candidates. It may contain trusted or
   untrusted data, but its extractor's output schema cannot produce an instruction atom.
6. When at least one selected item has `TrustedInstructionSource`, render a second envelope from
   only those trusted items. Its extractor's output schema can produce only instruction atoms. If
   no trusted item exists, there is no instruction envelope or instruction model call.
7. Encode each envelope as a JSON document with a schema version and an ordered item array. Each
   item contains source ID, origin, trust, and a JSON-escaped content string. Use
   `Data.Aeson.Encoding` in fixed field order and golden-test the exact UTF-8 bytes.
8. Compute a SHA-256 commitment over each exact byte sequence. The bytes passed into the
   corresponding lane input and the bytes committed must be identical.

Both extraction signatures state that item content is quoted evidence and is not executable. The
data signature has no instruction option in its schema. The instruction signature receives no
untrusted item. Remove the current free-text `focus` and rendered `scopeLabel` fields from outside
the lane envelope; model-independent storage routing still uses the full structured scope. Replace
the single current `ExtractInput` with separate data and instruction input types whose only
caller-supplied text is the rendered lane envelope. JSON escaping, rather than an ad hoc text
delimiter, prevents a content value from closing one item and injecting a sibling field.

Derive `EvidenceDecisionId` deterministically from memory-space text, session ID, maximum turn
index, policy version, and both optional envelope commitments. A retry over unchanged inputs and
policy must produce the same ID and bytes.

Milestone acceptance includes golden cases for every origin/trust/use combination, independently
classified turn content/tool summary, session focus, exact redaction, quotes and control
characters, empty input, over-budget selection, reordered database input, the stored-memory
fallback, omission of the instruction lane when no trusted source exists, and two spaces sharing
session/source identifiers.

### Milestone 4: run both lanes, enforce citations, and integrate policy-aware idempotency

Add `sourceEvidenceIds :: Field ... [Text]` to the extraction output types in
`kioku-core/src/Kioku/Distill/Extract.hs`, update the schema prompts and replay fixtures, and
require a non-empty list. Use lane-specific atom types or validators so the data program cannot
decode `instruction` and the instruction program cannot decode any other atom kind. After Shikumi
decoding, normalize and validate each ID against that invocation's envelope.

Drop an atom and increment `rejectedUnknownCitationCount` when any citation is unknown, excluded,
malformed, or absent from its lane. Drop an atom and increment `rejectedWrongLaneAtomCount` if a
provider response bypasses or violates the lane validator. Do not retry these deterministic policy
failures. Return the valid sibling atoms and update the stored decision outcome counts after both
possible extraction calls.

Route valid data atoms through the existing candidate lookup and consolidation model. Its record
path retains the data atom's non-instruction type regardless of rewritten content. Route valid
instruction atoms directly to the deterministic `l1AtomMemoryId` store/exact-dedup path. Refactor
the audit input so it can record either a provider consolidation decision or a closed
`trusted-instruction-store` / `trusted-instruction-already-present` policy result; do not fabricate
a consolidation provider call or call ID for this branch.

Extend `WatermarkRow`, `selectWatermarkStmt`, and `upsertWatermarkStmt` with policy version.
`watermarkCovers` returns true only when the stored turn index covers the current maximum and the
stored policy version equals the current policy. The force path still ignores both.

Add `kioku.distillation_evidence_decisions` with primary key
`(memory_space_id, decision_id)`. Store decision ID, space, session, maximum turn index, policy
version, selected summaries, excluded summaries, both optional envelope commitments, outcome
counts, and timestamps. The deterministic decision ID is the idempotency key, including when both
optional commitments are absent; do not rely on ordinary SQL uniqueness across nullable
commitment columns. On conflict, accept the row only when its immutable input fields match, then
update the deterministic outcome counts. Add a partition-leading session/policy/index lookup for
inspection.

Change `distillSessionL1` as follows. Keep permission preflight and the policy-aware watermark
check first. Build both possible envelopes and persist their decision before the first real
extraction call. If both are empty, commit the decision and watermark in one transaction and return
a new `L1NoEligibleEvidence EvidenceDecisionSummary` outcome. Otherwise run the non-empty data
lane and optional trusted-instruction lane under one L1 operation, combine their valid atoms,
update citation outcome counts, consolidate data atoms, deterministically apply instruction atoms,
and advance the watermark only after the full fold succeeds. A model, write, or audit failure
leaves the decision but not the watermark; retry reuses the same deterministic decision.

Add qualified table constants to `Kioku.Database.Schema`. Allocate the migration with
`just new-migration` against the then-current manifest and add fresh-install and data-bearing
upgrade tests. Never edit an applied migration or assume this plan owns migration 0014.

Milestone acceptance proves that a policy upgrade at the same turn index reruns, a timer redelivery
under the same policy skips, an all-filtered pass creates one decision and watermark with zero
provider calls, untrusted content never reaches the instruction-capable invocation, a failed real
pass keeps its decision but not its watermark, an instruction atom creates no consolidation call,
and a retry creates no duplicate decision.

### Milestone 5: expose inspection and prove the complete gate

Add library queries by decision ID and by session plus policy version. Public inspection accepts a
`MemoryAccessContext`, requires `MemoryRead`, and predicates every statement by its authorized
space before decision or session identity. A denial is an error, not an empty result.

Add a CLI path under the existing `distill` command, using the memory space selected by
`KIOKU_MEMORY_SPACE`:

```bash
kioku distill evidence decision DECISION_ID
kioku distill evidence session SESSION_ID
```

Update the existing `runDistill` outcome match so `L1NoEligibleEvidence` prints a concise success
summary rather than becoming a non-exhaustive pattern.

The output is JSON containing IDs, reasons, counts, versions, and commitments only. It must not
print selected content, rejected content, configured redaction literals, or another space's
existence.

Extend `Kioku.DistillSpec` with a real pipeline scenario containing trusted control focus/content,
an independently untrusted tool summary with prompt injection, explicit sensitive content,
ephemeral chatter, and a valid factual user item. Assert the raw session and turn rows remain
unchanged, both applicable envelopes and the decision contain the right IDs, the data call receives
the quoted untrusted item but cannot emit an instruction, the instruction call receives only
trusted sources, a trusted instruction survives without a consolidation call, and every accepted
atom cites only sources from its own lane. Run the same identifiers in two spaces and prove all
inspection and watermark behavior remains disjoint.

Update `docs/user/distillation.md`, `docs/user/library-api.md`,
`docs/user/cli-reference.md`, and `docs/user/troubleshooting.md`. Explain that capture metadata
is a host assertion, exact-literal redaction is not automatic secret discovery, policy upgrades
reevaluate unchanged evidence, decisions store no content, and no-call outcomes have no provider
evidence.

Before completing the plan, create or update an ADR for the durable L0-versus-model-input boundary,
capture trust semantics, and policy-version-aware reevaluation. Follow
`agents/skills/exec-plan/ADR.md` and the repository's current ADR convention.


## Concrete Steps

Run all commands from the repository root,
`/Users/shinzui/Keikaku/bokuno/kioku`.

Before editing, verify the current tree and migration tail:

```bash
git status --short
mori show --full
tail -n 5 kioku-migrations/migrations/manifest
```

Create the evidence module and wire it into `kioku-core/kioku-core.cabal`. Run pure tests while
building the policy and renderer:

```bash
nix develop -c cabal test kioku-core --test-options='-p "Distillation evidence"'
```

When allocating the migration, use the repository helper and then inspect the path it prints:

```bash
just new-migration kioku-distillation-evidence
```

After turn projection and migration work, run the native codec and migration suites:

```bash
nix develop -c cabal test kioku-core --test-options='-p "native codec compatibility"'
nix develop -c cabal test kioku-migrations
```

After integrating L1 and inspection, run:

```bash
nix develop -c cabal test kioku-core --test-options='-p "Distillation pyramid"'
nix develop -c cabal test kioku-core --test-options='-p "memory space"'
nix develop -c cabal test kioku-cli
nix develop -c cabal test all --test-show-details=direct
nix flake check
```

Expected success ends with each named test suite reporting `PASS` and no `Failed to build` line.
The exact case count is intentionally not pinned because other plans may add tests first.

Every implementation commit uses a Conventional Commit message and includes all active plan
trailers:

```text
MasterPlan: docs/masterplans/4-secure-and-accountable-distillation-evidence.md
ExecPlan: docs/plans/23-gate-untrusted-session-evidence-before-l1-distillation.md
Intention: intention_01kzbredy3ejab41f0a3vdg5be
```


## Validation and Acceptance

Acceptance requires observable behavior, not only new types.

A native pre-feature session/turn stream replays into the established memory space. Its focus and
turn content appear as legacy-unclassified, untrusted, durable-candidate evidence, while a present
tool summary appears separately as tool-output, untrusted, durable-candidate. Newly captured focus,
content, and tool-summary metadata round-trip independently. A Rei event tag still fails to decode.

An untrusted tool item containing prompt injection remains byte-for-byte intact in
`kioku.turns`. Its content is either excluded by explicit use metadata or appears only in a JSON
content string labelled untrusted in the data envelope. It never appears in the instruction
envelope, and the data extractor cannot emit an instruction memory. A trusted control-plane item
can produce one through the separate instruction lane. That atom is stored or exact-deduped without
calling the general consolidator, so recalled untrusted memory cannot rewrite it.

A mixed-content decision stores source IDs, labels, exclusion reasons, byte counts, version,
the two optional commitments, and post-decode rejection counts. Direct SQL, library output, CLI
output, logs, and test failure messages do not contain selected content, rejected content, or
policy redaction literals.

A session with only excluded evidence writes exactly one decision, advances its watermark with the
current policy version, makes no extraction or consolidation call, and skips on redelivery. The
same session and turn index under a new policy version runs selection again. A failed real pass
keeps a reusable decision but leaves the old watermark.

A no-turn session uses its existing memory fallback through the same policy. Its memory source IDs
are distinguishable from focus, turn-content, and tool-summary IDs, and no fallback memory can
authorize an instruction atom.

Two spaces with identical session IDs, focus/turn/memory source IDs, policy version, and decision
query inputs cannot read, overwrite, count, or infer each other's decisions or watermarks.

The full validation commands are:

```bash
nix develop -c cabal build all --enable-tests
nix develop -c cabal test all --test-show-details=direct
nix flake check
```


## Idempotence and Recovery

Selection and rendering are pure functions of the policy and ordered candidates. Running them
twice yields the same data and optional instruction envelope bytes, commitments, decision ID,
selected IDs, and exclusion reasons. Database input order cannot change the result because the
candidate order is normalized first.

Use the repository's ordinary forward-only pg-migrate contract. Do not make a new migration
idempotent with broad `IF EXISTS` guards that accept unknown partial layouts; follow the strict
state transitions in the current migration suite. A failed disposable test database can be
recreated by rerunning the tests. A production failure is recovered by fixing forward or restoring
the documented backup, never by editing a migration already recorded in the ledger.

A crash after decision persistence and before the model call leaves a harmless unconsumed decision;
retry reuses it. A crash during a real pass leaves the old watermark and retries the whole pass. A
crash on the all-filtered path cannot split decision from watermark because they share one
transaction. An instruction memory or audit row already committed before a later failure is
exact-deduped on retry and keeps its original creation provenance; new retry calls are not
retroactively credited with creating it.

If a policy configuration changes without a version change, Kioku cannot detect the operator
mistake. Tests and documentation must make the version obligation explicit. Do not hash or persist
redaction literals as a substitute; low-entropy secrets remain vulnerable to guessing even when
hashed.

If CLI inspection is deferred, the library query and a real database integration test must still
make decisions externally observable. Record the deferral in the Decision Log and revision notes
rather than weakening the acceptance silently.


## Interfaces and Dependencies

The main pure seam should be equivalent to:

```haskell
selectEvidence
  :: DistillInputPolicy
  -> MemorySpaceId
  -> SessionId
  -> Int
  -> [EvidenceCandidate]
  -> EvidenceSelection

evidenceDecision :: EvidenceSelection -> EvidenceDecision

dataEvidenceEnvelope :: EvidenceSelection -> Maybe EvidenceEnvelope

instructionEvidenceEnvelope :: EvidenceSelection -> Maybe EvidenceEnvelope

renderEvidenceEnvelope :: EvidenceEnvelope -> Text

validateAtomSources
  :: EvidenceEnvelope
  -> [ExtractedAtom]
  -> AtomSourceValidation
```

The two model inputs should be equivalent to abstract wrappers around one rendered envelope:

```haskell
newtype DataExtractInput = DataExtractInput Text
newtype TrustedInstructionExtractInput = TrustedInstructionExtractInput Text
```

Neither type has a separate free-text focus or scope-label field. The program signatures and
output types remain distinct so a data response cannot decode an instruction atom and an
instruction response cannot decode a data atom.

`EvidenceCandidate`, `EvidenceSelection`, and `EvidenceEnvelope` are internal or abstract because
they contain content.
`EvidenceDecision`, `EvidenceDecisionId`, `EvidencePolicyVersion`, `EvidenceSourceId`,
`CapturedEvidenceMetadata`, `SessionEvidenceMetadata`, and `TurnEvidenceMetadata` are stable types
consumed by the provenance and model-call evidence plans.

The L1 outcome extends the current vocabulary:

```haskell
data L1Outcome
  = L1Distilled L1Summary
  | L1SkippedUpToDate
  | L1NoEligibleEvidence EvidenceDecisionSummary
```

The public inspection seam should be equivalent to:

```haskell
getEvidenceDecision
  :: MemoryAccessContext
  -> EvidenceDecisionId
  -> Eff es (Either EvidenceReadError (Maybe EvidenceDecision))

listEvidenceDecisionsForSession
  :: MemoryAccessContext
  -> SessionId
  -> Eff es (Either EvidenceReadError [EvidenceDecision])
```

Plan 8, `docs/plans/8-add-first-class-provenance.md`, consumes the decision ID and each atom's
exact source IDs. Plan 16, `docs/plans/16-add-distillation-replay-metadata.md`, consumes decision
ID and policy version for model-call context. Neither downstream plan may reconstruct selection
from raw turns or invent a second policy version.

The implementation uses existing Aeson, crypton, Hasql, pg-migrate, Effectful, Kioku access types,
and Shikumi output validation. Dependency APIs must be inspected through Mori before use. No
external moderation service, identity package, or new secret manager is required.


## Revision Notes

- 2026-08-22: Rebased the plan on current Kioku. Added the stored-memory fallback path and every
  other current L1 content input; preserved source compatibility with explicit session-focus and
  per-field turn-capture APIs; kept tool summaries separate from turn-content trust; replaced
  implicit secret heuristics with explicit sensitive use and exact-literal redaction; separated
  content-bearing envelopes from the durable decision; split data extraction from trusted-
  instruction extraction and deterministic instruction storage; required exact per-atom citations;
  made policy version part of watermark coverage and decision identity; moved storage into the
  qualified `kioku` schema; consumed current permission/partition ADRs; removed the nonexistent
  metrics-surface assumption; and limited compatibility to native Kioku history after Rei decoder
  retirement.
