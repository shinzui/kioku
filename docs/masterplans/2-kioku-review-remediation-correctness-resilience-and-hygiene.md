---
id: 2
slug: kioku-review-remediation-correctness-resilience-and-hygiene
title: "Kioku Review Remediation: Correctness, Resilience, and Hygiene"
kind: master-plan
created_at: 2026-07-07T14:58:12Z
intention: "intention_01kwyhabypepdt1mwemmf0dvqa"
---

# Kioku Review Remediation: Correctness, Resilience, and Hygiene

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

A four-area review of kioku (memory/recall, sessions, distillation, API/CLI/migrations) on
2026-07-07 confirmed the event-sourcing core is sound but found the L1 distillation pipeline
non-idempotent under its own timer regime, worker error handling that either silently drops
work or silently stops working, a forget path that never propagates to derived artifacts,
several invariants enforced only by racy read-then-write prechecks, and a set of schema,
migration, and CLI hygiene gaps. After this initiative, distillation re-fires never duplicate
memories and never amplify LLM cost; archiving a memory actually removes its content from
scenes, personas, and workspace mirror files; every worker either retries transient failures
with bounded backoff or dead-letters permanent ones, and no worker thread can die silently;
lineage and resume invariants are enforced in the aggregate or the schema rather than in
prechecks; the reconciliation migration survives the pending keiro schema relocation; and the
riskiest logic in each of these areas is covered by tests that fail before the fix and pass
after.

In scope: every finding from the 2026-07-07 review, both major and minor, plus the test
coverage gaps the reviewers identified for the logic being fixed. Out of scope: new product
features (for example enforcing awaiting deadlines with a new timer — we only document that
gap), performance work beyond the specific index and query findings, and any change to the
public API surface that is not needed to fix a finding. The recall-versus-read-model
global-scope asymmetry is resolved by decision and documentation, not by silently changing
retrieval behavior hosts may depend on.


## Decomposition Strategy

The findings were grouped by functional concern rather than by the review area that reported
them, because several findings recur across areas (for example, scope-identity string
collisions were reported independently by the distillation and schema reviewers, and the
idempotent-accept-without-payload-comparison pattern appears in both the memory and session
command layers). Each work stream produces an independently verifiable behavior change and
can be tested without the others being complete.

Seven child plans resulted. EP-1 makes L1 distillation idempotent and stops the idle-timer
cost amplification — it is first because every other distillation defect is amplified by
re-fires. EP-2 makes forgetting real by propagating archive/supersede/merge into scenes,
personas, and mirrors — a privacy-shaped gap that stands alone. EP-3 reworks worker error
handling (embedding worker ack policy, timer retry bounds, loop supervision) — one plan
because the failure taxonomy (transient/permanent/not-mine) must be designed once and applied
uniformly. EP-4 moves invariants into the aggregate and fixes the racy prechecks across both
session and memory commands — one plan because it is the same pattern in both places. EP-5
hardens the schema and recall SQL (missing indexes, NULL-blind unique constraints, vector
dimension validation, scope-identity escaping) — grouped because these are all
migration-plus-query changes verified the same way. EP-6 fixes the reconciliation and
migration machinery (keiro schema relocation, dead schema registry list, TH embed staleness) —
grouped because all three are "the migration system lies to you" defects. EP-7 sweeps the CLI
and API surface (ID parsing, scope grammar, flag conflicts, demo guards, dead API) — grouped
as low-risk polish that touches no core logic.

Alternatives considered: decomposing by review area (memory, session, distill, schema) was
rejected because it would put the two halves of the worker-resilience fix and of the
idempotency-contract fix in different plans that must modify the same functions the same way.
A single "fix everything" ExecPlan was rejected as far beyond the five-milestone/ten-file
guidance. Folding EP-6 into EP-5 was rejected because EP-6's verification (fresh-database
bootstrap against both pinned and HEAD keiro) is entirely different from EP-5's
(query-plan and constraint tests).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Make L1 distillation idempotent and debounce distillation timers | docs/plans/9-make-l1-distillation-idempotent-and-debounce-distillation-timers.md | None | None | In Progress |
| 2 | Propagate memory forget operations to scenes, personas, and workspace mirrors | docs/plans/10-propagate-memory-forget-operations-to-scenes-personas-and-workspace-mirrors.md | None | EP-1 | Not Started |
| 3 | Harden worker resilience with ack policy, bounded retries, and loop supervision | docs/plans/11-harden-worker-resilience-with-ack-policy-bounded-retries-and-loop-supervision.md | None | None | Not Started |
| 4 | Enforce aggregate invariants for lineage, resume correlation, and idempotent commands | docs/plans/12-enforce-aggregate-invariants-for-lineage-resume-correlation-and-idempotent-commands.md | None | None | Not Started |
| 5 | Harden schema and recall with indexes, constraints, and scope identity fixes | docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md | None | None | Not Started |
| 6 | Align read-model reconciliation with keiro schema relocation and guard embedded migrations | docs/plans/14-align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations.md | None | None | Not Started |
| 7 | Tighten CLI and API surface validation | docs/plans/15-tighten-cli-and-api-surface-validation.md | None | EP-3 | Not Started |


## Dependency Graph

There are no hard dependencies: every plan compiles and is verifiable on its own, so all
seven can in principle proceed in parallel. The recommended order is a first wave of EP-1,
EP-3, EP-4, and EP-5 (the correctness and resilience fixes that stop active data duplication,
silent worker death, and hangable queries), followed by EP-2, EP-6, and EP-7.

The soft dependencies exist to reduce churn, not to gate work. EP-2 benefits from EP-1
landing first because both touch distillation timer scheduling (EP-1 rewrites the idle-timer
scheduling in `kioku-core/src/Kioku/Distill/Timer.hs`; EP-2 extends
`timerRequestsForEvent` in `kioku-core/src/Kioku/Distill/L2.hs` to fire on archive,
supersede, and merge events) — landing EP-1 first means EP-2 extends the final scheduling
shape instead of the one being replaced. EP-7 benefits from EP-3 landing first because both
modify `kioku-cli/src/Kioku/Cli/Commands/Worker.hs` (EP-3 restructures the worker loops and
their supervision; EP-7 only fixes flag parsing in the same file) — EP-7's change is trivial
to rebase, EP-3's is not.

Plans that add SQL migration files (EP-1 for the L1 watermark table; EP-5 for three schema
migrations) serialize trivially on migration timestamps: codd orders migrations by their
filename timestamp, so each plan mints a fresh timestamp when it creates its file and no
coordination beyond that is needed. Authoring research corrected the original assumption
here: EP-2 needs no migration (its fixes are DELETEs and code, no DDL), EP-4 needs no
migration and no read-model version bump (embedded statements only), and EP-6 edits the
existing reconciliation migration in place rather than adding one (codd keys applied
migrations by filename with no checksums, and only an in-place edit also fixes fresh
keiro-HEAD databases). EP-6's embedded-migration staleness guard, once landed, protects
every later plan that adds a migration file; landing EP-6 early in the second wave maximizes
that benefit.


## Integration Points

Fire-outcome contract (EP-1, EP-3). Both plans touch how a distillation timer fire reports
failure in `kioku-core/src/Kioku/Distill/Timer/Worker.hs` (today: `Maybe EventId` — the
review text said `Maybe UTCTime`, corrected during plan authoring — where `Nothing` conflates
"transient failure", "permanent failure", and "not my timer", producing unbounded 300-second
requeues). EP-3 owns the replacement: `FireOutcome` in a new module
`kioku-core/src/Kioku/Distill/Timer/Outcome.hs` with constructors for completed /
retry-later / permanently-failed / not-mine, which the worker maps onto keiro's timer states
(`maxAttempts = Just 8`, dead-letter via keiro's terminal `dead` status). EP-1 consumes it:
its fire handlers classify LLM extraction and consolidation errors into that taxonomy. EP-1's
idempotency changes (deterministic atom identity, watermark staleness guard) are deliberately
correct under unbounded re-fires, so EP-1 does not need EP-3's contract to land first; if
EP-1 lands first it keeps returning `Maybe EventId` and EP-3 migrates its handlers
(mechanical by design).

Scope-identity rendering (EP-2, EP-5). `sceneRowId`, `personaRowId`, and the mirror-file
slugs derive row identity from unescaped namespace/kind/ref strings
(`kioku-core/src/Kioku/Distill/L2.hs` `renderScope`/slug logic and the same pattern in
`L3.hs`). EP-5 owns fixing the derivation (escaping or validation so distinct scopes cannot
collide). EP-2 must compute the rows and mirror paths it blanks or deletes by calling those
same functions — never by re-implementing the string format — so the two plans compose in
either order.

Distillation timer scheduling (EP-1, EP-2). Both extend timer-request emission driven by
projections: EP-1 changes L1 session-timer scheduling (`kioku-core/src/Kioku/Distill/Timer.hs`)
and EP-2 adds scene/persona regeneration triggers for archive/supersede/merge events
(`kioku-core/src/Kioku/Distill/L2.hs` `timerRequestsForEvent`). The shared artifact is the
set of timer IDs and process-manager names; both plans must keep timer IDs deterministic
(UUIDv5 over stable inputs) so re-projection never double-schedules, and neither may rename
an existing process-manager name (EP-3's dispatcher and EP-6's reconciliation both key on
them).

Migration directory and embed guard (EP-1, EP-5, EP-6). EP-1 and EP-5 add files under
`kioku-migrations/sql-migrations/` (EP-2 and EP-4 turned out to need none; EP-6 edits an
existing file in place). EP-6 owns the guard that the TH-embedded migration list
(`kioku-migrations/src/Kioku/Migrations.hs`) cannot silently go stale; until it lands, every
plan adding a migration must touch `Migrations.hs` (per the existing "Last touched" comment
convention) to force recompilation. No plan may hand-write registry-bump SQL: EP-6's
code-side reconciler (driven by `kiokuReadModelSchemas`) covers read-model version bumps
made by any sibling plan.

Worker CLI wiring (EP-1, EP-3, EP-7). `kioku-cli/src/Kioku/Cli/Commands/Worker.hs` is where
EP-1 swaps the L1 candidate lookup from `scopedScanCandidates 5` to recall-based candidates,
EP-3 restructures loop supervision, and EP-7 fixes the `--timers-once`/`--backfill` flag
conflict. EP-3 owns the file's structure; the other two make local edits and rebase.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1 M1: deterministic identity and honest failure inside the L1 pass
- [ ] EP-1 M2: per-session watermark and debounced timers (kioku_l1_watermarks migration)
- [ ] EP-1 M3: recall-based merge candidates in the worker
- [ ] EP-1 M4: real validation for distillation LLM outputs
- [ ] EP-1 M5: end-to-end verification and evidence
- [ ] EP-2 M1: forget events schedule scene-regeneration timers
- [ ] EP-2 M2: emptied scopes delete scene/persona rows and mirror files without the LLM
- [ ] EP-2 M3: end-to-end — the timer worker propagates forgetting to every artifact
- [ ] EP-3 M1: embedding worker ack policy (retry/dead-letter/halt classification)
- [ ] EP-3 M2: FireOutcome taxonomy for distillation timers, bounded attempts, unknown-PM handling
- [ ] EP-3 M3: loop supervision, drain-before-sleep, startup backfill
- [ ] EP-4 M1: resume correlation becomes an aggregate invariant (plus explicit forceResume)
- [ ] EP-4 M2: lineage validation at start and a cycle-proof chain query
- [ ] EP-4 M3: honest idempotent accepts for session and memory commands
- [ ] EP-4 M4: turn identity contract
- [ ] EP-4 M5: legacy decoder coverage and documentation truth
- [ ] EP-5 M1: schema-hardening migration (indexes, NULLS NOT DISTINCT, scope CHECKs)
- [ ] EP-5 M2: pgvector in the dev shell plus self-healing embedding-schema migration
- [ ] EP-5 M3: vector recall query fix (ORDER BY, ef_search) with EXPLAIN evidence
- [ ] EP-5 M4: embedding dimension validation at capability detection
- [ ] EP-5 M5: collision-free scope identity with legacy-id stability
- [ ] EP-5 M6: global-scope semantics documentation and haddocks
- [ ] EP-6 M1: location-agnostic reconciliation migration proven against both keiro layouts
- [ ] EP-6 M2: code-side read-model registry reconciler wired into kioku-migrate
- [ ] EP-6 M3: embed-staleness guard and just new-migration convention
- [ ] EP-6 M4: end-to-end sweep and library-api docs update
- [ ] EP-7 M1: strict ids at the CLI boundary, explicit lenient parser in the API
- [ ] EP-7 M2: scope grammar that can express colons
- [ ] EP-7 M3: bounded --limit options
- [ ] EP-7 M4: demo guard (--yes-write-events, demo-only scope, preflight print)
- [ ] EP-7 M5: worker --backfill/--timers-once mutual exclusion
- [ ] EP-7 M6: remove embedBatched and dead kioku-api dependencies, docs sweep


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

Discoveries made while authoring the child plans (2026-07-07), each verified against the
working tree or the pinned framework sources by the authoring pass:

- The distillation fire functions return `Maybe EventId`, not `Maybe UTCTime` as the review
  stated; all plan text was written against the real type.
- The embedding-worker failure mode is worse than reviewed but inverted: `AckHalt` makes
  shibuya exit the processor gracefully, `waitApp` returns, and the whole process exits 0
  silently — taking the forked timer loop with it. EP-3's supervision milestone fixes both
  the "process dies silently" and the "thread dies while process lives" directions.
- codd (v0.1.8) keys applied migrations by filename only, with no checksums — so EP-6 fixes
  the reconciliation migration by editing its body in place, the only approach that also
  works on fresh keiro-HEAD databases where the old body would fail before any new
  migration could run.
- The repository's own dev database is in the degraded no-pgvector state EP-5's finding 7
  describes (the Nix shell ships plain `pkgs.postgresql`), which makes EP-5's self-healing
  migration directly demonstrable — and means no vector-path test currently touches a real
  vector column. Also, `hnsw.ef_search` defaults to 40 while the candidate pool is 50, so
  the ORDER BY fix alone would not have filled the pool.
- EP-4's research invalidated one planned index: `getChain`'s recursive join resolves
  through the `kioku_sessions` primary key, and lineage validation is pure command-time
  checking, so the `previous_session_id` index EP-5 had staged was removed as write
  amplification. Likewise the memory supersession CTE needs no cycle guard (its `UNION`
  deduplicates and terminates); the session chain's `UNION ALL` is the only infinite loop.
- Deterministic L1 atom identity introduces a self-merge hazard (a re-run's MergeAtom
  target can equal the winner's own id, which would archive the only active copy); EP-1
  guards it by filtering targets equal to the winner id.
- keiki guards are re-run during replay and `TLit` event fields are not recovered by
  `solveOutput`, so EP-4's force-resume must be a real event payload field; old
  `SessionResumed` events decode with `force = isNothing correlationKey`. One deployment
  consequence: once new-format events exist, older library versions cannot decode them —
  no rollback across that boundary.
- Adjacent gap discovered by EP-2 and deferred: `MemoryConfidenceUpdated` changes scene
  source content but never triggers regeneration. Same mechanism as the forget events;
  candidate for a follow-up plan.
- The next keiro pin bump is a full cohort-migrate event (keiro HEAD renamed all migration
  filenames sentinel→timestamp and relocated its tables), not just the schema move EP-6
  handles; `Justfile`'s `CODD_SCHEMAS=kiroku` and TestSupport's `namespacesToCheck` will
  need `keiro` added then.
- Downstream consumers kikan and shikigami use neither `parseIdAnyPrefix` nor
  `embedBatched` (verified via `mori registry dependents shinzui/kioku --packages`), so
  EP-7's renames/removals are safe; hosts calling `runKiokuMigrations` as a library must
  adopt EP-6's `reconcileReadModelRegistry` (documented in EP-6 M4).


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Group findings by functional concern (seven plans) rather than by the review
  area that reported them.
  Rationale: Several findings recur across review areas — scope-identity collisions were
  reported by both the distillation and schema reviewers, and the idempotent-accept pattern
  appears in both memory and session command layers. Grouping by concern keeps each fix in
  one plan; grouping by area would force two plans to edit the same functions the same way.
  Date: 2026-07-07

- Decision: No hard dependencies between child plans; use soft and integration dependencies
  only, with a recommended two-wave order (EP-1/EP-3/EP-4/EP-5, then EP-2/EP-6/EP-7).
  Rationale: Every plan compiles and verifies independently. Hard dependencies would
  serialize work for no correctness benefit; the wave order simply prioritizes active data
  duplication, silent worker death, and hangable queries over hygiene.
  Date: 2026-07-07

- Decision: EP-3 owns the fire-outcome taxonomy (succeed / retry-later / dead-letter) for
  distillation timers; EP-1 is written to be correct under unbounded re-fires regardless.
  Rationale: The retry policy must be designed once and applied to all three timer handlers
  plus the embedding worker, which is EP-3's whole subject. Making EP-1's idempotency
  independent of retry policy means neither plan blocks the other.
  Date: 2026-07-07

- Decision: Resolve the recall-versus-read-model global-scope asymmetry by decision and
  documentation (in EP-5), not by silently changing recall behavior.
  Rationale: The plan document docs/plans/2-kioku-hybrid-retrieval-pgvector-fts-rrf.md
  records the broad recall semantics as intentional; hosts (rei, mori, shikigami) may depend
  on it. The defect is that two public APIs give the same MemoryScope value different
  meanings without saying so.
  Date: 2026-07-07

- Decision: Enforcing awaiting deadlines (a new expiry sweep or timer) is out of scope;
  EP-4 only corrects the documentation that currently implies deadlines are enforced.
  Rationale: The review found the deadline is stored and never read. Building enforcement
  is a feature with real design questions (who resumes, with what input), not a remediation.
  Date: 2026-07-07

- Decision: The dead `generic-lens`/`uuid` dependencies in kioku-api.cabal are removed by
  EP-7 only; EP-5 was revised to drop its duplicate claim.
  Rationale: Both plans independently claimed the cleanup during parallel authoring. EP-7
  is the surface-hygiene plan and gates the removal on an implementation-time re-grep
  (EP-5's scope-validator work could conceivably introduce a use of one of them).
  Date: 2026-07-07

- Decision: No `kioku_sessions.previous_session_id` index; EP-5 was revised to remove it
  from its migration.
  Rationale: EP-4's research showed the chain CTE joins through the primary key and its
  lineage validation is pure command-time checking — the index would be write amplification
  with no reader, the same defect class EP-5 fixes by dropping `kioku_turns_session_idx`.
  Date: 2026-07-07

- Decision: EP-6 keeps `kiokuReadModelSchemas` and makes it load-bearing (a code-side
  registry reconciler wired into kioku-migrate) instead of generating per-bump SQL.
  Rationale: keiro's registry statements are compiled into whatever keiro version kioku
  links, so the reconciler finds the table wherever that version puts it — pin-bump-proof
  by construction — and sibling plans' future read-model version bumps are covered without
  hand-written migrations (the failure mode that caused the original outage).
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)

## Revision Notes

- 2026-07-07: Post-authoring reconciliation pass after all seven child plans were written.
  Corrected the fire-outcome integration point to the real type (`Maybe EventId`, replaced
  by EP-3's `FireOutcome`); corrected the migration-coordination note (only EP-1 and EP-5
  add migration files; EP-2 and EP-4 need none; EP-6 edits one in place); resolved two
  cross-plan conflicts found during authoring (duplicate kioku-api.cabal cleanup → EP-7;
  `previous_session_id` index → dropped) with matching revisions to
  docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md;
  filled the Progress section from the actual 32 child milestones; and recorded the
  authoring discoveries in Surprises & Discoveries.
