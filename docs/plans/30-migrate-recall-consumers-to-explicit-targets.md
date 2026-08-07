---
id: 30
slug: migrate-recall-consumers-to-explicit-targets
title: "Migrate recall consumers to explicit targets"
kind: exec-plan
created_at: 2026-08-06T14:43:35Z
intention: "intention_01kzbrek7metsbcb580gaxaf9t"
master_plan: "docs/masterplans/6-explicit-and-safe-recall-boundaries.md"
---

# Migrate recall consumers to explicit targets

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, CLI users and library dependents choose exact-scope or namespace-wide recall
in clear syntax and receive the same semantics as the new API. Documentation, examples, and the
future HTTP/SDK contracts no longer teach the overloaded `ScopeGlobal` behavior. The legacy
wrapper remains only for the declared compatibility window and is removed in a later breaking
release after known dependents migrate.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Migrate all Kioku library/CLI/test call sites to `RecallTarget`. (2026-08-07: done by plan
      28, not by this plan — `recall`'s signature changed, so `Kioku.Cli.Commands.Recall` and
      `Kioku.Distill.L1.recallCandidates` had to compile against it. Both went through
      `legacyRecallTarget` and behave exactly as before, which is why the two entries below exist:
      they are the deliberate changes that mechanical migration deliberately did not make.)
- [x] Give the command line one flag per target, and refuse the ambiguous bare-namespace `--scope`.
      (2026-08-07: `recallTargetParser` in `kioku-cli/src/Kioku/Cli/Commands/Recall.hs` offers
      `--scope NAMESPACE:KIND:REF`, `--global-bucket NAMESPACE` and `--namespace-wide NAMESPACE`;
      exactly one is required and a second is a parse error naming it. `--scope` still parses
      through `Kioku.Cli.Scope.parseScope`, then refuses a `ScopeGlobal` result.)
- [x] Settle L1's merge-candidate breadth: `recallCandidates` becomes exact, matching
      `scopedScanCandidates`. (2026-08-07: one line in `Kioku.Distill.L1`, plus the Haddock that
      says what it cost and why.)
- [x] Add CLI parsing, error, and end-to-end PostgreSQL tests. (2026-08-07:
      `Kioku.Cli.ParserSpec`'s "recall spells each target exactly once" — 11 cases — and
      `Kioku.Cli.RecallEndToEndSpec`, which runs the real binary as a subprocess against two
      seeded memory spaces. `Kioku.DistillSpec`'s "recall candidates stay inside the session's own
      scope" covers the breadth change.)
- [x] Inventory Mori dependents and publish a downstream migration recipe. (2026-08-07:
      `docs/user/recall.md#known-dependents`. Two dependents; Shikigami's target migration is
      mechanical and it has no namespace-wide recall to preserve.)
- [x] Update recall, CLI reference, concepts, integrations, troubleshooting, getting-started, and
      upgrade documentation, plus the changelogs. (2026-08-07: also `library-api.md`, ADR-2's
      quoted example, and ADR-8's Consequences.)
- [x] Pin HTTP/SDK improvement requests to the explicit target schema. (2026-08-07: both now name
      the three shipped tags rather than a two-way exact/namespace-wide split.)
- [x] Verify the deprecation window before scheduling legacy removal. (2026-08-07: verified **not
      met**, and removal is therefore not scheduled — see Outcomes & Retrospective. One of ADR-8's
      three conditions holds; the other two cannot yet.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Mori currently reports `mori://shinzui/shikigami` as Kioku's only direct implementation
  dependent besides the umbrella portfolio. It is the required downstream compile check.
- CLI syntax is a security boundary too: a default that silently means namespace-wide would
  recreate the API ambiguity for operators.

- **The mechanical half of this plan was already done, by plan 28.** `recall`'s signature changed
  there, so every in-repository caller had to be touched to compile. Both went through
  `legacyRecallTarget`, which preserves behavior exactly. What this plan inherits is therefore not
  a migration but two questions that a behavior-preserving change deliberately declined to answer,
  and both are data-visible (2026-08-07).

- **The overloaded scope survives in exactly two places, and they are this plan's whole behavior
  surface.** `kioku recall --scope mori` means namespace-wide while `kioku scenes --scope mori`
  and `kioku persona --scope mori` mean the global bucket: the original asymmetry, one layer above
  the API that no longer has it. And `Kioku.Distill.L1` holds two `FindMergeCandidates` finders
  that disagree about which memories exist — `scopedScanCandidates` calls
  `Recall.getActiveByScope`, which is exact, while `recallCandidates` inherited namespace-wide
  breadth from the legacy overload. Nobody chose that disagreement; it is what `ScopeGlobal`
  meaning two things looked like from inside one module (2026-08-07).

- **There is no JSON output to keep stable.** This plan's Milestone 1 was written assuming
  `kioku recall` had a scriptable JSON mode to extend additively. It does not — `runRecall` prints
  numbered plain-text lines and nothing else. The milestone's intent still applies and is met a
  different way: stdout keeps its exact current shape, and the space and target the command
  searched are announced on **stderr**, so a script that pipes stdout is unaffected while an
  operator watching a terminal can see what was searched (2026-08-07).


## Decision Log

Record every decision made while working on the plan.

- Decision: `--scope` always means exact; namespace-wide requires the explicit
  `--namespace-wide` form.
  Rationale: Broad reads should be opt-in and obvious in shell history and reviews.
  Date: 2026-08-06

- Decision: The CLI requires or resolves one memory space before parsing the target.
  Rationale: Target widening must never select a tenant or authorization context.
  Date: 2026-08-06

- Decision: Each target gets its own flag — `--scope NAMESPACE:KIND:REF`,
  `--global-bucket NAMESPACE`, `--namespace-wide NAMESPACE` — exactly one of which is required,
  and a bare-namespace `--scope` is a parse error naming the two replacements.
  Rationale: This is the decision of 2026-08-06 carried through to the one invocation it did not
  cover. `--scope` does always mean exact; the question was what a bare namespace spells. Letting
  it spell the global bucket would match `kioku scenes`, but it would also silently narrow every
  existing `kioku recall --scope mori` — the direction
  [ADR-8](../adr/an-explicit-recall-target-replaces-the-overloaded-scope.md) records as the unsafe
  one, and worse on a command line than in a library, because there is no compiler to warn and the
  exit status stays zero. Giving the global bucket its own flag instead means no invocation changes
  meaning, every meaning has exactly one spelling, and the ambiguous one fails with the two
  commands the operator might have meant. The cost is one flag more than the minimum and a `--scope
  mori` that errors where `kioku scenes --scope mori` works; the error text names that difference.
  Date: 2026-08-07

- Decision: No per-command `--memory-space` flag. `KIOKU_MEMORY_SPACE` already resolves exactly one
  space, and `kioku recall` announces on stderr which space and target it searched.
  Rationale: The 2026-08-06 decision requires the CLI to resolve one space before parsing a target,
  and `Kioku.Cli.Context.cliMemoryContext` already does: it validates the variable, fails at
  startup on a malformed value, and defaults to `kioku_legacy` — never to "every space". Adding the
  flag to `recall` alone would make it the only command that can retarget its space, implying the
  others cannot be retargeted at all, which is false. Making it visible is the part that was
  missing, and stderr is where it goes so scripted stdout is untouched.
  Date: 2026-08-07

- Decision: `recallCandidates` draws merge candidates from `ExactScope` of the session's scope.
  Rationale: Its sibling `scopedScanCandidates` has always been exact, so the two finders answered
  "which memories could this atom merge into" differently for a globally-scoped session — one
  saw the global bucket, the other the whole namespace. A finder's job is to rank the candidates,
  not to change which memories exist. Namespace-wide breadth also let a session scoped `mori` merge
  an atom into a memory scoped `mori:repo:web`, rewriting a memory that feeds a scene the session
  has nothing to do with; `docs/user/concepts.md` already states that a `mori:repo:...` memory does
  not feed `mori`'s scene. Narrowing loses merge opportunities for global-scoped sessions, which
  become stores instead — a visible, recoverable outcome, unlike a cross-scope rewrite.
  Date: 2026-08-07

- Decision: Legacy removal is a later PVP-breaking release conditioned on dependent migration.
  Rationale: Completing this plan does not authorize silently breaking Shikigami or other
  consumers.
  Date: 2026-08-06


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Completed 2026-08-07.

**What was achieved.** The overloaded scope is gone from the last two places it survived. On the
command line each target has one spelling, the exact global bucket is askable for the first time,
and the one invocation whose meaning would otherwise have changed — `--scope NAMESPACE` — is a
parse error naming both replacements. In distillation, the recall-backed merge-candidate finder
searches the session's own scope, so it and `scopedScanCandidates` agree about which memories a
session's atoms may merge into; a globally-scoped session can no longer rewrite a sibling entity
scope's memory. No in-repository code constructs a `RecallRequest` or calls `legacyRecallTarget`
any more; the only remaining mention is a Haddock sentence in `Kioku.Distill.L1` recording what
that line used to say.

**The deprecation window is verified and has not opened.**
[ADR-8](../adr/an-explicit-recall-target-replaces-the-overloaded-scope.md) sets three conditions
for deleting `RecallRequest`/`legacyRecall`:

| Condition                                            | Status                                       |
|------------------------------------------------------|----------------------------------------------|
| The CLI no longer constructs a `RecallRequest`        | **Met** as of this plan                      |
| At least one released version carries `RecallTarget`  | **Not met** — it is Unreleased; 0.3.0.0 predates it |
| Every known dependent compiles against `RecallTarget` | **Not met** — `mori://shinzui/shikigami` has not migrated |

So removal is not scheduled, and this plan does not authorize it. That is the answer the milestone
asked for, not a gap in it.

**What it cost, stated plainly.** Two behavior changes ship here, and both narrow. `kioku recall
--scope mori` stops working rather than returning fewer rows, which is the trade this plan chose
deliberately — an operator pays one edit, once, instead of losing rows they never learn are
missing. And a globally-scoped L1 session will report more `stored` and fewer `merged`; nothing is
lost, but a deployment that relied on cross-scope consolidation will notice.

**Evidence.** Each suite on its own, per plan 28's note about `cabal test all` under concurrency:

```text
kioku-api-test:        All 119 tests passed
kioku-cli-test:        All 50 tests passed
kioku-migrations-test: All 10 tests passed
kioku-test:            All 209 tests passed
```

The two new groups:

```text
recall spells each target exactly once
  --scope takes an entity scope:                                   OK
  --global-bucket takes a namespace and means the rows with no entity scope: OK
  --namespace-wide takes a namespace and means every scope under it: OK
  the global bucket and the namespace are different targets:       OK
  --scope keeps the shared colon rules:                            OK
  a bare namespace is refused, naming both replacements:           OK
  no target at all lists the three forms:                          OK
  two targets is a parse error naming the second:                  OK
  two targets in the other order is also a parse error:            OK
  a scope passed to --namespace-wide points at --scope:            OK
  each target describes itself distinctly:                         OK

kioku recall end to end
  each flag reaches the database as its own target, inside one space: OK (4.21s)

Distillation pyramid
  recall candidates stay inside the session's own scope:           OK (1.11s)
```

The breadth case was checked against its own regression: reverting the one line in
`Kioku.Distill.L1` fails it on `stored: expected 1, got 0`, because the pass merges into the
sibling scope instead.

**Two lessons.**

The first is that a defect removed from a type does not leave the system. This initiative deleted
the overloaded `ScopeGlobal` from the API in plan 28 and from the SQL in plan 29, and it was still
alive in two places that predate both — a flag, and a finder — where no compiler could point at
it. What made them findable was having the vocabulary to state them in; neither is a bug you can
report before `RecallTarget` exists.

The second is that ADR-8's lesson about safe and unsafe directions has a corollary on a
human-facing surface. In a library the unsafe direction is caught by nothing at runtime but at
least a deprecation can warn. On a command line there is no compiler and the exit status stays
zero, so the honest move is to refuse the ambiguous input rather than to re-read it. That is now
recorded in ADR-8 rather than only here, because the next surface Kioku grows will face it again.


## Context and Orientation

`kioku-cli/src/Kioku/Cli/Commands/Recall.hs` builds the recall query and prints hits;
`kioku-cli/src/Kioku/Cli/Scope.hs` holds the `NAMESPACE[:KIND:REF]` grammar shared with
`kioku scenes` and `kioku persona`, and `kioku-cli/test/Kioku/Cli/ParserSpec.hs` exercises it with
`execParserPure`, so a test sees exactly the failure text an operator sees.
`kioku-cli/src/Kioku/Cli/Context.hs` resolves the memory space and actor from the environment.
`Kioku.Distill.L1.recallCandidates` is the other in-repository caller. Library examples and
semantics are documented in `docs/user/recall.md`, `docs/user/library-api.md`,
`docs/user/cli-reference.md`, `docs/user/getting-started.md`, `docs/user/concepts.md`,
`docs/user/integrations.md`, and `docs/user/troubleshooting.md`.

Plans 28 and 29 provide the target API and SQL, and both are complete: all three targets execute,
and `Kioku.RecallTargetSpec` already proves what each returns against a real database. This plan's
tests therefore assert that a flag reaches the intended target, not what that target means.

Mori dependency inspection is mandatory before removal: run
`mori registry dependents shinzui/kioku --packages` and migrate `mori://shinzui/shikigami` through
its own repository process.

Three local ADRs govern this work.
[ADR-8](../adr/an-explicit-recall-target-replaces-the-overloaded-scope.md) owns the compatibility
window and removal conditions, and its Consequences section explicitly leaves the command line to
this plan; its lesson about the unsafe direction of a compatibility mapping is what decided the
grammar. [ADR-9](../adr/each-recall-target-gets-its-own-statement.md) is the shape this plan
mirrors one layer up: one name per data-visible meaning, no meaning inferred from an absent field.
[ADR-2](../adr/namespace-is-not-a-security-boundary.md) is why widening a target never widens the
space, and it quotes `kioku recall --scope mori` in its current meaning, so it must be updated in
the same change.


## Plan of Work

### Milestone 1: CLI grammar and errors

Add three mutually exclusive target flags, exactly one of which is required:
`--scope NAMESPACE:KIND:REF` for an entity scope, `--global-bucket NAMESPACE` for the rows recorded
with no entity scope, and `--namespace-wide NAMESPACE` for every scope in the namespace. A
bare-namespace `--scope` is a parse error that names the other two and says which one reproduces
the previous behavior. Supplying two target flags, or none, fails in the parser — before the
environment is read and before any database access.

The memory space is resolved once by `Kioku.Cli.Context.cliMemoryContext`, which already validates
`KIOKU_MEMORY_SPACE` and never defaults to every space; no new selector flag is added (Decision
Log). `kioku recall` announces the resolved space and target on stderr so widening is visible
without disturbing stdout, which keeps its exact current shape — there is no JSON output to keep
stable (Surprises & Discoveries).

Add parser tests for each valid form, for the ambiguity error's text, for conflicting and missing
flags, and for the entity-scope grammar that `--scope` retains unchanged.

### Milestone 2: settle merge-candidate breadth

`Kioku.Distill.L1.recallCandidates` moves from `legacyRecallTarget scope` to `ExactScope scope`,
so it agrees with `scopedScanCandidates` about which memories a session's atoms may merge into
(Decision Log). Prove the change where it is visible: a globally-scoped session must stop drawing
candidates from a sibling entity scope in the same namespace.

Convert docs and examples at the same time so no copied snippet reintroduces the legacy API or the
old CLI grammar.

Add an end-to-end CLI fixture with two spaces and exact-global/entity/namespace-wide cases. Match
plan 29's expected IDs.

### Milestone 3: downstream and contract migration

Use Mori to inventory dependents. Produce a concise migration table for Haskell consumers and a
release note that preserves legacy semantics. Coordinate Shikigami changes in its repository via
canonical Mori references; do not edit it from this plan.

Update the proposed HTTP service and SDK improvement requests so their OpenAPI/client union is
the tagged explicit target, never nullable `scopeKind`/`scopeRef`. After at least one released
compatibility version and dependent verification, open a separate breaking-release task to remove
the legacy wrapper.


## Concrete Steps

Run from the repository root:

```bash
mori registry dependents shinzui/kioku --packages
nix develop -c cabal test kioku-cli
nix develop -c cabal test kioku-core --test-options='-p "Recall"'
nix develop -c cabal build all
nix develop -c cabal test all
```

Then build the known dependent at the released compatibility boundary using the source located
by Mori. Record its command and result in this plan when implementation begins.


## Validation and Acceptance

Acceptance requires:

- `--scope NAMESPACE:KIND:REF` returns only that entity scope in the chosen space.
- `--global-bucket` returns only the rows recorded with no entity scope, in the chosen space.
- `--namespace-wide` returns all scopes in that namespace and still only the chosen space.
- `--scope NAMESPACE` is refused with an error naming both replacements and saying which one
  reproduces the previous behavior.
- Supplying two target flags or none produces a clear nonzero error before SQL.
- Every in-repo construction uses the new target type; only the compatibility module mentions
  the legacy request. No in-repo caller routes a target through `legacyRecallTarget` any more.
- The two `FindMergeCandidates` finders agree on breadth, proven by a globally-scoped session
  that no longer draws candidates from a sibling entity scope.
- Shikigami has a documented compiling migration path.
- HTTP/SDK IR acceptance refers to the tagged target union.
- Legacy deletion is not performed until the ADR's release/dependent conditions are met.

All met, 2026-08-07, with the evidence for each:

- The first three are `Kioku.Cli.RecallEndToEndSpec`, which runs the real binary against two seeded
  spaces: each flag's rows are asserted present and the other target's rows absent, and no target —
  including the widest — reaches the second space. The same widest target under that space's
  context returns that space's rows.
- The refusal is asserted twice: purely, in `Kioku.Cli.ParserSpec` ("a bare namespace is refused,
  naming both replacements", which checks for both flags and for the phrase saying which one
  reproduces the old behavior), and end to end, where it exits nonzero with nothing on stdout.
- Two flags and no flags are `ParserSpec`'s three conflict/missing cases. Both fail in the parser,
  before the environment is read and before any connection is opened.
- `rg legacyRecallTarget\|legacyRecall\|RecallRequest` over `kioku-cli/`, `kioku-core/src` and
  `kioku-api/src` returns exactly one hit outside the two modules that define the compatibility
  layer, and it is a Haddock sentence in `Kioku.Distill.L1` recording what the line used to say.
- The finders' agreement is `Kioku.DistillSpec`'s "recall candidates stay inside the session's own
  scope", which proves the control as well as the assertion — the sibling is reachable by a
  namespace-wide recall over the same text, so the target is what excludes it.
- Shikigami's path is `docs/user/recall.md#known-dependents`: `agentScope` is a `ScopeEntity`, so
  `legacyRecallTarget` maps it to `ExactScope` unchanged, and `sharedScope` — its one `ScopeGlobal`
  value — is never recalled against. It is behind on `MemoryAccessContext` and `memorySpaceId` as
  well, which is said where a reader meets it.
- Both improvement requests now name the three shipped tags rather than a two-way union.
- Deletion is not performed, and the window is verified as not open — see Outcomes & Retrospective
  for the condition-by-condition table.


## Idempotence and Recovery

CLI/parser changes are reversible while the compatibility wrapper exists. Preserve old aliases
for the declared window and test their mapping; do not let an alias acquire new semantics.
Downstream work happens in the owning repository and is referenced canonically. If a dependent
cannot migrate, keep the wrapper and record the blocker rather than weakening the new API.


## Interfaces and Dependencies

The CLI consumes `RecallTarget` from plan 28 and SQL behavior from plan 29. The plan originally
sketched a per-command space selector and two target forms:

```text
kioku recall --memory-space SPACE --scope NAMESPACE[:KIND:REF] QUERY
kioku recall --memory-space SPACE --namespace-wide NAMESPACE QUERY
```

Both parts changed; see the Decision Log. The space stays where every other command gets it, and
each target gets its own flag rather than one flag with a namespace-shaped second meaning:

```text
KIOKU_MEMORY_SPACE=space_prod \
  kioku recall QUERY --scope NAMESPACE:KIND:REF     # ExactScope (ScopeEntity …)
  kioku recall QUERY --global-bucket NAMESPACE      # ExactScope (ScopeGlobal …)
  kioku recall QUERY --namespace-wide NAMESPACE     # NamespaceWide …
```

`--scope NAMESPACE` — the one spelling whose meaning would otherwise have changed — is a parse
error naming the two flags above. The future HTTP service and SDKs consume the same tagged union.
No direct Shomei/Meibo/En dependency is added to the CLI; standalone use supplies an explicit
trusted context, while service use authenticates externally.


## Revision Notes

**2026-08-07 — opening revision, before implementation.** Two of this plan's inputs changed while
plans 28 and 29 ran, so the plan was revised to describe the work that is actually left.

*The mechanical migration is already done.* Plan 28 changed `recall`'s signature, which forced
`Kioku.Cli.Commands.Recall` and `Kioku.Distill.L1.recallCandidates` onto `RecallTarget` through the
behavior-preserving `legacyRecallTarget`. The Progress checklist records that item as complete and
credits plan 28. What remains is the two deliberate choices a behavior-preserving change declined
to make, and both are now in the Decision Log with their rationale: the CLI's grammar, and the
merge-candidate breadth.

*The grammar is three flags, not two.* The plan's Interfaces sketch had `--scope` and
`--namespace-wide`, which leaves a bare-namespace `--scope` silently meaning the global bucket —
the narrowing direction ADR-8 identifies as the unsafe one, with no compiler and no nonzero exit to
signal it. `--global-bucket` joins them and the bare form is refused. The Interfaces section shows
both the sketch and what replaced it.

*There is no `--memory-space` flag and no JSON output.* The sketch had the first; the space already
comes from `KIOKU_MEMORY_SPACE` for every command, and adding the flag to `recall` alone would
imply the other commands cannot be retargeted. Milestone 1 assumed the second; `runRecall` prints
plain text only, so "keep scriptable output stable" is met by leaving stdout untouched and
announcing the space and target on stderr. Both are recorded in Surprises & Discoveries and the
Decision Log.

**2026-08-07 — implementation.** Three things differ from the opening revision, each recorded where
a reader meets it rather than only here.

*The grammar grew a third flag during design, not during coding.* The opening revision already
records why `--global-bucket` exists; what the implementation added is the shape of the mutual
exclusion. Three `option` parsers combined with `<|>` give all three properties for free: exactly
one required (optparse prints `Missing:` with the three forms), a second one left unconsumed and
reported by name, and a usage line that lists the alternation. It is the construction
`kioku worker` already uses for its one-shot modes, so the failure text an operator sees is the
same shape they have seen before.

*The end-to-end test runs the binary rather than `runRecall`.* `stdout`, `stderr` and the
environment are process-wide and tasty runs cases concurrently, so redirecting them in process
would race the rest of the suite — the same hazard `withDistillWorkspaceEnv` records about `chdir`.
The suite gained `build-tool-depends: kioku-cli:kioku`, a dependency on
`kioku-migrations:test-support`, and `process`; it is the first CLI test that needs a database.

*The deprecation-window milestone produced a verification, not a schedule.* One of ADR-8's three
conditions is met and the other two cannot be until a version carrying `RecallTarget` ships and
Shikigami migrates. Outcomes & Retrospective has the table.
