---
type: Review
title: The 0.4.0.0 release range, read since 0.3.0.0
description: >-
  The 48-commit memory-space release was read as the range since 0.3.0.0, and fifteen
  findings survived adversarial verification — seven correctness, led by the
  already-tracked 0011 search_path leak — so changes are requested.
generated:
  by: process:claude-code
  at: "2026-08-20T04:57:37Z"
reviewId: REV-1
subject: mori://shinzui/kioku
subjectKind: project
reviewedSha: 7888f2d7575a9a06bc7f1229074af8675d0d78dd
coverage: incremental
baseSha: c17ce73349e61c8d6c40191325c75a3a380b705a
reviewedAt: "2026-08-20T04:55:00Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: high
outcome: changes-requested
dimensions:
  - correctness
  - security
  - performance
  - design
context: >-
  A multi-agent /code-review sweep over the git range v0.3.0.0..v0.4.0.0: ten finder
  angles produced ~31 candidates, dedup left 18, and twenty adversarial verifiers plus a
  gap sweep confirmed 15 and refuted 9, each refutation resting on a quoted guarding or
  documenting line. Finder recall ran at the skill's xhigh setting. The review ran in the
  working repository at e1453a5, so post-release records — BUG-1 and ExecPlan 32 among
  them — were visible to verification.
---

# The 0.4.0.0 release range, read since 0.3.0.0

Coverage is incremental: only the 48 commits between the two recorded shas were read,
`baseSha` being exactly the v0.3.0.0 release commit. `previousReview` is absent because
the examination of the 0.3.0.0-era code happened in conversation and was never recorded
as an artifact; `baseSha` still records the honest starting point, and the next review of
this project can chain from this record.

Fifteen findings survived adversarial verification: seven correctness, two performance,
six design. The most severe was independently rediscovered by this review and is already
tracked in this repository as
[BUG-1](../bug-reports/migration-0011-session-search-path-leaks-into-later-migrations.md)
with [ExecPlan 32](../plans/32-restore-host-search-path-after-kioku-migrations.md); it is
restated first so this record stands alone.

## Correctness

**1. Migration 0011's session search_path leaks into every migration applied after it**
(`kioku-migrations/migrations/0011-kioku-memory-space-partition.sql:28`). The migration
opens with a session-scoped `SET search_path TO kiroku, pg_catalog;` and never restores
it, and 0012 does not either, so on the runner's dedicated connection every later
component's migration resolves unqualified names against the kiroku schema. A host that
embeds kioku-migrations in a composed pg-migrate plan with its own migration pending
fails with SQLSTATE 42P01 — or silently lands unqualified `CREATE TABLE` objects in the
kiroku schema. Already confirmed as BUG-1 on PostgreSQL 17.10 and 18.4; the fix direction
is a forward-only `RESET search_path` migration 0013, since released payload checksums
must not change.

**2. Artifact migration overwrites what a live worker just wrote**
(`kioku-core/src/Kioku/Workspace.hs:222`). `applyArtifactMigration` copies every
`MoveReady` file without re-checking the destination at copy time, so the
`MoveCollision` refusal only holds at plan time. The documented rollout keeps workers
running while `kioku migrate-artifacts --apply` runs; an L2 timer can write a freshly
regenerated scene to the exact destination between plan and copy, and `copyFile`
replaces it with the stale pre-partition snapshot, exiting 0 — precisely the overwrite
ADR-7 promises is refused. Fix: re-check or hash immediately before each copy, or use
exclusive-create plus rename.

**3. L2 and L3 timer handlers skip the permission gate entirely**
(`kioku-core/src/Kioku/Distill/L2.hs:323`, `kioku-core/src/Kioku/Distill/L3.hs:245`).
`fireL2SceneTimer` and `fireL3PersonaTimer` mint a `MemoryAccessContext` and immediately
strip it to a bare `MemorySpaceId` with zero `memoryContextAllows` checks, so scene and
persona regeneration performs reads, upserts, deletes, timer scheduling, and mirror-file
writes under any context the provider mints. A host that wires the provider to grant
only `MemoryRead` sees L1 refuse and the embedding worker dead-letter, while L2/L3
proceed to write in that space — violating the API's own invariant that a read context
cannot be spent on a write. Nothing documents an exemption; the handlers' comments claim
parity with L1 while omitting its gate.

**4. Merge and supersede lineage never validates the winner**
(`kioku-core/src/Kioku/Memory.hs:344`). `mergeWithContext`'s contract says both memories
must live in the authorized space, but `mergeIn` looks up only the loser space-scoped;
the winner — and `supersedeWithContext`'s `supersededBy`, and `recordIn`'s `supersedes`
— is never validated for space or existence. Any caller other than Distill.L1 (which
pre-validates) can permanently record a cross-space or dangling id in `MemoryMerged` and
`MemorySuperseded` events, and the space-joined recursive supersession chain silently
dead-ends. The fix shape already exists in-repo: move L1's winner precheck into
`mergeIn`/`supersedeIn` and `recordIn`.

**5. L1's gate checks only MemoryDistill though its writes need more**
(`kioku-core/src/Kioku/Distill/L1.hs:187`). `distillSessionL1` gates on `MemoryDistill`
alone, but its write path exercises `MemoryRecord` and `MemoryForget`. A host that mints
exactly the permission the upgrade guide names passes the gate, spends the LLM
extraction and consolidation calls, then fails on the first `recordAtom` with
`MemoryNotPermitted` — and the timer re-runs full extraction on each of up to 8 backoff
attempts (roughly an hour, ~16 paid LLM calls) before dead-lettering. The comment's
guarantee that an unauthorized pass fails before spending a single LLM token is false.
Fix: gate on every permission the pass exercises.

**6. The watermark upsert conflicts on session_id alone**
(`kioku-core/src/Kioku/Distill/L1.hs:728`). `upsertWatermarkStmt` conflicts on
`(session_id)` and its `DO UPDATE` never touches `memory_space_id`, while
`selectWatermarkStmt` filters by space and session. A watermark row whose space diverges
from the running pass is invisible to reads but silently updated by writes: the pass
re-runs full LLM extraction on every fire, forever, while `writeWatermark` succeeds into
a row it cannot read. No runtime constraint ties watermark space to session space after
0011's one-shot validation. Minimal fix: conflict on `(memory_space_id, session_id)` or
add the space column to the `DO UPDATE` so the row self-heals.

**7. The "unknown" space label is unreachable for the case it names**
(`kioku-core/src/Kioku/Distill/Timer/Worker.hs:195`). `spaceQualified`'s docstring
promises `unknown` covers a malformed payload or a foreign process manager's, calling
that more useful than silently claiming the legacy space — but `timerPayloadSpace`
decodes objects via `parsePartitionSpace`, whose `.!= legacyMemorySpaceId` default never
fails on a missing field. Malformed object payloads and foreign managers' payloads are
therefore attributed to `kioku_legacy` in dead-letter errors and fire spans, steering
operators at the wrong tenant. Fix: parse `memorySpaceId` with `.:?` and no default at
this call site.

## Performance

**8. Full-text recall scans every tenant's corpus** (`kioku-core/src/Kioku/Recall.hs:828`).
Every FTS statement now filters `memory_space_id = $2 AND namespace = $3`, but the only
FTS index is 0001's single-column GIN on `content_tsv` — 0011 rebuilt every relevant
btree partition-first yet left the GIN untouched. The tsquery bitmap scan enumerates
matches across all tenants and the space cut happens on the heap, with the `ts_rank`
ORDER BY defeating any LIMIT bound, so each recall's cost grows with other tenants'
data — the exact shape memory spaces exist to prevent. Cheaper: a composite GIN via
btree_gin, using 0002's create-extension-with-graceful-skip idiom.

**9. The embedding backfill ships every row's full content to skip it**
(`kioku-core/src/Kioku/Memory/Embedding/Worker.hs:438`). `selectEmbeddingCandidatesStmt`
and its per-space variant fetch the full content of every active row with no skip
predicate, then Haskell recomputes sha256 per row just to skip already-embedded rows —
and `startupBackfill` runs the every-space scan on every continuous-worker start. On a
settled 100k-memory corpus each worker start ships the whole content column to conclude
nothing needs embedding. The predicate pushes into SQL unchanged, since `sha256Hex` is
exactly PostgreSQL's `encode(sha256(convert_to(content,'UTF8')),'hex')` and
`content_hash` is only ever written by the same function.

## Design

**10. The write-authorization gate exists twice** (`kioku-core/src/Kioku/Session.hs:124`,
`kioku-core/src/Kioku/Memory.hs:125`). `underContext` and `inLegacySpaceOnly` — the
permission/space/actor gate on every write — are duplicated verbatim, differing only in
the three injected error constructors; the Session copy's Haddock itself points at the
Memory copy. A hardening change applied to one leaves the other silently divergent.
Consolidation is verified cycle-free: one gate parameterized over error injectors in
kioku-api's `Kioku.Api.Access`, which both modules already import.

**11. The vector-capability probe hardcodes the catalog names**
(`kioku-core/src/Kioku/Recall/Capability.hs:98`). `detectVectorCapabilityStmt` embeds
`'kioku'` and `'memories'` as literals in ten places instead of splicing the
`Kioku.Database.Schema` constants this same release created so declarations and SQL
cannot drift — the file is the only holdout. If the schema moves again, the probe
misdiagnoses a healthy database as `VectorColumnsUnavailable` and every recall silently
degrades to keyword-only.

**12. Three verbatim duplications between Distill.L2 and Distill.L3**
(`kioku-core/src/Kioku/Distill/L3.hs:272`). The `PartitionedScope` record and its
partition-first Params encoder (field order fixes SQL parameter positions), the 30-line
fire-timer pipeline with identical payload types and hand-written FromJSON, and a
byte-identical `removeIfPresent`. The L2/L3 permission-gate omission (finding 3) is
already an instance of this pair diverging from L1. Consolidation targets are verified
cycle-free: `Kioku.Partition`, a shared helper beside `FireOutcome`, and
`Kioku.Workspace` respectively.

**13. The Rei legacy parsers restate Partition's defaults inline**
(`kioku-core/src/Kioku/Memory/EventStream.hs:109` and Session/EventStream.hs, ~18
sites). Nine legacy-payload parsers hand-roll `pure legacyMemorySpaceId` and the legacy
principal defaults instead of calling `Kioku.Partition`'s parse helpers, although
Partition's docstring declares itself the single place that decides what an older
payload means. A refined legacy rule would update ordinary event decoders while the Rei
path replays the same history into a different space or actor. If freezing the Rei
interpretation is intended, that wants a comment and a pinning test; neither exists.

**14. The workspace slug recipe is a second copy of ScopeIdentity's**
(`kioku-core/src/Kioku/Workspace.hs:110`). `spaceDirectoryName` re-implements the
sanitize-plus-truncated-SHA256 recipe of `Kioku.Distill.ScopeIdentity`, byte-identical
for every valid space id — and the charset is the load-bearing defense neutralizing
path traversal from untrusted space ids, now maintained in two private copies. Export a
shared `slugWithDigest` primitive from ScopeIdentity and call it from Workspace.

**15. The CLI hand-rolls the recall-strategy table**
(`kioku-cli/src/Kioku/Cli/Commands/Recall.hs:185`). `parseStrategy` restates the
keyword/embedding/hybrid table that this release made canonical as
`Kioku.Api.Recall.parseRecallStrategy`, whose docstring explicitly claims the CLI flag.
A fourth strategy would flow to JSON and the library error message but be silently
rejected by the flag. Drop-in fix:
`option (eitherReader (first Text.unpack . parseRecallStrategy . Text.pack))`.

## Refuted candidates

Nine candidates were refuted in verification, each against a quoted guarding or
documenting line: cross-space upsert re-homing, the recall read-gate, a backfill
authorization bypass, owner attribution, space-id decode strictness, freshness tokens,
L1 scope narrowing, legacy-mirror retention, and digest truncation. Several
plausible-looking authorization findings among them turned out to be explicitly
documented design decisions — the recall read-gate exception, host-asserted owner
attribution, and the embedding backfill's work-identity boundary.

## Disposition

Finding 1 is already BUG-1 with ExecPlan 32 in flight, so this review produced no new
records. Findings 2–7 are defect-shaped and worth promoting into the bug-reports bundle;
findings 8–15 are improvement-shaped. The commit-hygiene pass found all 48 commits in
the range Conventional-Commits compliant and no CLAUDE.md violations.
