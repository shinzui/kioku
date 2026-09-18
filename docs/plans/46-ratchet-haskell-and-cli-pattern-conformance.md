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
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-18T22:48:26Z
      mode: "implement"
      note: "Started EP-5 Haskell and CLI conformance implementation"
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

- [x] (2026-09-18 22:59Z) Milestone 1: audited and aligned all five Cabal package
  language, warning, extension, and compiler baselines.
- [x] (2026-09-18 22:59Z) Milestone 2: audited source imports, prelude use,
  deriving strategies, and durable record fields; corrected only the confirmed
  strictness violations.
- [x] (2026-09-18 22:59Z) Milestone 3: stabilized CLI help structure at 100
  columns, tightened optparse-applicative to 0.19, and proved bash/zsh/fish
  completion generation.
- [x] (2026-09-18 22:59Z) Milestone 4: integrated repeatable source and package
  ratchets with the existing pre-commit and flake-check entry points.
- [x] (2026-09-18 22:59Z) Warning-as-error build, 467 repository tests,
  formatter CI check, convention check, and user-visible help/completion probes
  pass. After staging the new convention script, all four flake outputs and all
  three applicable checks pass.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

| Package | Baseline and source audit | Result |
|---|---|---|
| `kioku-api` | GHC 2024, GHC 9.12, shared warnings, prelude boundary | Already conforming; cabal-gild normalized layout only. |
| `kioku-core` | Same package baseline; imports, deriving, durable records | Imports and deriving already conformed; AI and distillation product records now use strict fields. Newtype fields remain necessarily unannotated. |
| `kioku-cli` | Same package baseline; optparse 0.19; help and completion | Bound tightened; public parser preferences fix help at 100 columns; semantic groups and all three completion scripts are tested. |
| `kioku-migrations` | GHC 9.12 declaration and shared warnings | Missing baselines added to all components; the Codd deprecation suppression remains only on its deliberate bridge test. |
| `kioku-migrate` | GHC 2024 shared stanza, GHC 9.12, warnings, optparse 0.19 | Missing baselines added; the bridge executable alone retains `-Wno-deprecations`; shadowed bindings found by `-Werror` were renamed. |

- Hackage publishes optparse-applicative 0.19.0.0 and its released source exposes
  `parserOptionGroup`, fixed-column parser preferences, and built-in bash/zsh/fish
  completion requests. The upstream repository does not publish a matching 0.19
  Git tag, so Hackage is the authoritative release artifact for this bound.
- GHC rejects strictness annotations on newtype fields. The record audit therefore
  applies bangs to product records and preserves newtype representation semantics.
- The installed treefmt uses `--ci` for fail-on-change validation; the planned
  `nix fmt -- --check` spelling is not supported by this version.
- A flake evaluated from a dirty Git worktree omits an untracked script from its
  source snapshot. The convention derivation is valid once the script is staged;
  this is a validation-order constraint, not a check implementation failure.


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
- Decision: Expose the top-level parser description and fixed parser preferences
  as opaque test seams while keeping command constructors private.
  Rationale: Parser tests can exercise exactly the public help and completion path
    without exporting the internal command algebra or spawning a subprocess.
  Date: 2026-09-18
- Decision: Add one narrow repository convention script and wire it into the
  existing pre-commit and flake-check systems.
  Rationale: Fourmolu and GHC cover formatting and compilation but do not reject
    package imports outside the prelude or detect Cabal baseline drift. A single
    script supplies only those missing assertions and is not a parallel check stack.
  Date: 2026-09-18


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

All five packages now declare a consistent GHC 9.12/GHC 2024 baseline and share
the warning policy, with the one intentional deprecation suppression confined to
the Codd bridge. Source inspection found the import and deriving conventions already
healthy; the durable AI and distillation records were the concrete strictness gap.

The CLI now treats help and completion as a tested public interaction. It renders at
100 columns, labels target/query/output/AI/execution groups without changing an option
or default, and generates non-empty bash, zsh, and fish scripts through the released
optparse-applicative 0.19 API. The parser suite grew from 58 to 64 tests.

The convention ratchet is available directly, in pre-commit, and as a flake check.
`cabal build all --ghc-options=-Werror`, all 467 repository tests, `nix fmt -- --ci`,
`nix flake check`, and direct CLI probes passed. The flake rerun was intentionally
performed after staging because Nix excludes untracked files from a dirty flake source snapshot.
The deployed-service-only package topology remains inapplicable: Kioku still consists
of reusable libraries plus local CLI/migration executables and gained no artificial
server, worker service, or client package.


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
