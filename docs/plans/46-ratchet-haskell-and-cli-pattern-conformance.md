---
id: 46
slug: ratchet-haskell-and-cli-pattern-conformance
title: "Ratchet Haskell and CLI pattern conformance"
kind: exec-plan
created_at: 2026-09-18T18:42:34Z
intention: "intention_01m2twr1ddexergqvtn2bqztbv"
master_plan: "docs/masterplans/8-adopt-keiro-0-17-comprehensively.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-18T18:42:34Z
---

# Ratchet Haskell and CLI pattern conformance

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Apply the Haskell conventions that govern this repository consistently across all five
packages and turn them into repeatable checks. A contributor sees the same GHC 2024 baseline,
warnings, import style, project prelude policy, strict record conventions, and test layout in
every component. CLI users get structured help at a stable width and generated shell
completion without changing existing command names or semantics. Patterns written for a
deployed six-package service are recorded as inapplicable to this reusable library rather than
forcing artificial server/client packages.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep the current five-package architecture.
  Rationale: The service-package topology in `haskell-jitsurei` governs deployed services.
    Kioku is a reusable API/runtime plus CLI and migration executable; inventing server,
    workers, and client packages would add no ownership boundary.
  Date: 2026-09-18
- Decision: Treat optional CLI patterns as applicable only where Kioku has the corresponding
    interaction.
  Rationale: Nested worker and migration commands benefit from option groups, stable help,
    and completions; configuration wizards or daemon conventions do not exist here.
  Date: 2026-09-18


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This plan starts after
`docs/plans/42-align-kioku-with-the-released-keiro-0-17-dependency-cohort.md` so its warning
and package checks target the final dependency baseline. It may audit in parallel with
`docs/plans/43-replace-deprecated-keiro-read-model-freshness-apis.md`, but must incorporate
that plan's imports and modules before the final formatting and warning pass.

`kioku-api`, `kioku-core`, and `kioku-cli` each define nearly identical `warnings` and
`shared` Cabal stanzas with `default-language: GHC2024`. `kioku-migrations` has a smaller
shared stanza and no common warning stanza. `kioku-migrate` declares extensions and warnings
directly on its executable. This makes standards drift likely even though the codebase mostly
already uses postpositive qualified imports and explicit deriving strategies.

`kioku-api/src/Kioku/Prelude.hs` is the project prelude. It correctly confines
`PackageImports` to that module and deliberately does not re-export `Data.Generics.Labels`,
matching `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`. The audit must preserve
that design. Record fields are generally strict and unprefixed; the audit should fix concrete
violations found by source inspection without renaming stable JSON or public API fields merely
for aesthetics. The governing standards are
`mori://shinzui/haskell-jitsurei/docs/core-standards` and
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`.

`kioku-cli` uses `optparse-applicative` with nested worker commands and shared readers in
`Kioku.Cli.Options`, but its bounds still admit 0.18 and its help/completion behavior is not
tested as a public interaction. Relevant references include
`mori://shinzui/haskell-jitsurei/docs/cli-overview`,
`mori://shinzui/haskell-jitsurei/docs/cli-option-groups`,
`mori://shinzui/haskell-jitsurei/docs/cli-help-width`, and
`mori://shinzui/haskell-jitsurei/docs/cli-shell-completions`.

No local ADR governs syntax or CLI rendering, and this plan should not create one unless it
changes a durable public command contract. Existing domain ADRs are not implicated.


## Plan of Work

Milestone 1 creates an audit table in the plan's Surprises section and then fixes package
baselines. Compare every library, executable, and test stanza in the five `.cabal` files to
the core standard. Add the shared warnings to `kioku-migrations` and `kioku-migrate`, retain
only component-specific options such as `-Wno-deprecations` for the intentional Codd bridge,
and align the baseline extensions without adding unused extensions blindly. Keep GHC
`>=9.12 && <9.13` wherever the package declares `tested-with` and add it where missing.

Milestone 2 audits source conventions. Keep `PackageImports` confined to `Kioku.Prelude`;
use postpositive qualified imports; import `Data.Generics.Labels` only in modules that use
labels; use strict fields for durable records; put entity identifiers first in command/event
records; and require explicit `deriving stock`, `deriving newtype`, or `deriving anyclass`.
Fix only confirmed violations and add focused serialization tests if a record declaration
changes. Do not change event tags, JSON field policy, database columns, or public record names.

Milestone 3 aligns the CLI. Verify `optparse-applicative >=0.19 && <0.20` in the configured
registry before tightening both CLI package and migration executable bounds. Group repeated
connection, memory-space, AI, and pagination options using the pattern's parser-record approach
where the same semantic group appears in multiple commands. Configure the documented stable
help width at the top-level parser and add completion entry points for bash, zsh, and fish using
optparse-applicative's supported API. Extend `kioku-cli/test/Kioku/Cli/ParserSpec.hs` with golden
or structural assertions for top-level help, nested worker help, group headings, width, and
completion generation. Preserve every existing command, option spelling, default, and error.

Milestone 4 automates the ratchet through the repository's existing formatter/check entry
points rather than a second script stack. Add checks for bare prepositive qualified imports,
`PackageImports` outside the prelude, unqualified deriving clauses, and component language
drift only if the existing formatter/compiler does not already catch them. Document intentional
exceptions next to the narrow check.


## Concrete Steps

Run from the repository root:

```sh
cabal build all --ghc-options=-Werror
cabal test kioku-api:kioku-api-test
cabal test kioku-cli:kioku-cli-test
cabal test all
nix fmt -- --check
nix flake check
```

If repository wrappers exist at implementation time, use their documented equivalents and
record the exact transcript. Exercise user-visible CLI behavior too:

```sh
cabal run -v0 kioku -- --help
cabal run -v0 kioku -- worker --help
cabal run -v0 kioku -- --bash-completion-script kioku
cabal run -v0 kioku -- --zsh-completion-script kioku
cabal run -v0 kioku -- --fish-completion-script kioku
```

Help must fit the selected width, show stable group headings, and retain all existing commands.
Each completion command must emit a non-empty script and exit zero.


## Validation and Acceptance

Every component compiles with the shared warning baseline and no broad warning suppression.
Source checks find no `PackageImports` outside `Kioku.Prelude`, no newly introduced
prepositive qualified imports, and no ambiguous deriving clauses. Existing JSON golden tests
remain unchanged.

The CLI parser suite proves all previous invocations still parse to the same command values,
help output is deterministic at the chosen width, and three completion scripts are generated.
The architecture applicability review explicitly marks deployed-service-only package patterns
as not applicable with the evidence that Kioku exposes libraries and local executables rather
than a server fleet.


## Idempotence and Recovery

Formatting, builds, and source audits are repeatable. Make import/deriving changes in small
batches and run the owning package tests. If help snapshots move, inspect the semantic diff;
never accept a golden update that drops a command or option. Preserve unrelated Nix and
Seihou worktree changes.


## Interfaces and Dependencies

The project prelude remains `Kioku.Prelude`. The CLI remains built on
`Options.Applicative`; shared option records live under `Kioku.Cli.Options` or a narrowly
named sibling, and existing `Kioku.Cli` parser/run interfaces remain stable. Use the exact
released optparse-applicative 0.19 completion API located through Mori/registry source rather
than recalling its signatures from memory. No new runtime dependency is justified by this
plan.
