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

- [ ] Add explicit CLI grammar for memory space, exact scope, and namespace-wide recall.
- [ ] Migrate all Kioku library/CLI/test call sites to `RecallTarget`.
- [ ] Inventory Mori dependents and publish a downstream migration recipe.
- [ ] Add CLI parsing, error, JSON-output, and end-to-end PostgreSQL tests.
- [ ] Update recall, library API, getting-started, and upgrade documentation.
- [ ] Pin HTTP/SDK improvement requests to the explicit target schema.
- [ ] Verify the deprecation window before scheduling legacy removal.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Mori currently reports `mori://shinzui/shikigami` as Kioku's only direct implementation
  dependent besides the umbrella portfolio. It is the required downstream compile check.
- CLI syntax is a security boundary too: a default that silently means namespace-wide would
  recreate the API ambiguity for operators.


## Decision Log

Record every decision made while working on the plan.

- Decision: `--scope` always means exact; namespace-wide requires the explicit
  `--namespace-wide` form.
  Rationale: Broad reads should be opt-in and obvious in shell history and reviews.
  Date: 2026-08-06

- Decision: The CLI requires or resolves one memory space before parsing the target.
  Rationale: Target widening must never select a tenant or authorization context.
  Date: 2026-08-06

- Decision: Legacy removal is a later PVP-breaking release conditioned on dependent migration.
  Rationale: Completing this plan does not authorize silently breaking Shikigami or other
  consumers.
  Date: 2026-08-06


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

No implementation has started. Completion means all in-repo callers and known dependents have a
tested migration path; deletion of the compatibility API remains a later release action.


## Context and Orientation

`kioku-cli/src/Kioku/Cli/Commands/Recall.hs` builds the current request and prints hits. Parser
definitions live in the CLI command surface. Library examples and semantics are documented in
`docs/user/recall.md`, `docs/user/library-api.md`, `docs/user/getting-started.md`, and
`docs/user/concepts.md`. Tests and distillation candidate lookup also construct recall requests.

Plans 28 and 29 provide the target API and SQL. Mori dependency inspection is mandatory before
removal: run `mori registry dependents shinzui/kioku --packages` and migrate
`mori://shinzui/shikigami` through its own repository process. No new local ADR is expected; the
compatibility ADR from plan 28 governs this work.


## Plan of Work

### Milestone 1: CLI grammar and errors

Add mutually exclusive exact and namespace-wide target parsers. Exact scope accepts the existing
global/entity scope syntax but is documented as exact. Namespace-wide requires an explicit
namespace flag. Require a memory-space selector or an authenticated/default context supplied by
the host; do not default to every space. Invalid combinations fail before database access with an
error that names the two supported forms.

Keep scriptable JSON output stable except for an additive target/space description where useful.
Add parser tests for valid forms, conflicts, missing space, and legacy aliases.

### Milestone 2: migrate in-repository callers

Use `rg` to find every `RecallRequest` construction in core, CLI, and tests. Convert L1 merge
candidate lookup deliberately: it should use `ExactScope` unless its documented behavior truly
requires namespace-wide candidates. Convert docs/examples at the same time so no copied snippet
reintroduces the legacy API.

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

- `--scope` returns only the exact global/entity bucket in the chosen space.
- `--namespace-wide` returns all scopes in that namespace and still only the chosen space.
- Supplying both, neither (when no documented default exists), or a missing space produces a
  clear nonzero error before SQL.
- Every in-repo construction uses the new target type; only the compatibility module mentions
  the legacy request.
- Shikigami has a documented compiling migration path.
- HTTP/SDK IR acceptance refers to the tagged target union.
- Legacy deletion is not performed until the ADR's release/dependent conditions are met.


## Idempotence and Recovery

CLI/parser changes are reversible while the compatibility wrapper exists. Preserve old aliases
for the declared window and test their mapping; do not let an alias acquire new semantics.
Downstream work happens in the owning repository and is referenced canonically. If a dependent
cannot migrate, keep the wrapper and record the blocker rather than weakening the new API.


## Interfaces and Dependencies

The CLI consumes `RecallTarget` from plan 28 and SQL behavior from plan 29. Its conceptual forms
are:

```text
kioku recall --memory-space SPACE --scope NAMESPACE[:KIND:REF] QUERY
kioku recall --memory-space SPACE --namespace-wide NAMESPACE QUERY
```

Final flag spelling must follow the existing parser conventions. The future HTTP service and
SDKs consume the same tagged union. No direct Shomei/Meibo/En dependency is added to the CLI;
standalone use supplies an explicit trusted context, while service use authenticates externally.
