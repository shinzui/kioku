---
type: Architecture Decision Record
title: Haskell and CLI conventions are executable contracts
description: >-
  Kioku keeps one GHC 9.12 and GHC 2024 package baseline, checks source conventions in
  pre-commit and Nix, and treats fixed-width CLI help and shell completion as tested public output.
timestamp: 2026-09-18T22:59:57Z
docId: ADR-14
status: accepted
date: 2026-09-18
---

# Haskell and CLI conventions are executable contracts

## Status

Accepted, 2026-09-18. Implemented by the common stanzas in all five package files,
`scripts/check-haskell-conventions.sh`, `flake.module.nix`, and the parser contract tests in
`kioku-cli/test/Kioku/Cli/ParserSpec.hs`.

## Context

Kioku's five packages had converged informally on the conventions documented by
`mori://shinzui/haskell-jitsurei/docs/core-standards`, but the migration library and migration
executable did not declare the same compiler and warning baseline as the other three packages.
The source was already consistent about postpositive qualified imports, explicit deriving
strategies, and confining package imports to `Kioku.Prelude`, yet nothing prevented those rules
from drifting.

The CLI also exposed help and optparse-applicative's hidden completion requests without treating
them as a versioned interaction. Its dependency bound admitted optparse-applicative 0.18, before
the option-group API used by `mori://shinzui/haskell-jitsurei/docs/cli-option-groups`, and help
width depended on the invoking terminal.

## Decision

Every package declares `tested-with: ghc >=9.12 && <9.13`, uses `default-language: GHC2024`, and
imports the shared warning policy. Component-specific suppressions remain local: only the Codd
upgrade bridge may suppress the deprecation warning it deliberately implements or rehearses.
Durable product records use strict fields; newtype fields remain unannotated because GHC forbids
strictness annotations on them.

The repository supplies one narrow convention check for rules that the compiler and formatter do
not enforce: postpositive qualified imports, package imports only in `Kioku.Prelude`, explicit
deriving strategies, and package-baseline presence. The same script runs directly, as a
pre-commit hook, and as a Nix flake check. Fourmolu and cabal-gild remain responsible for layout;
the script does not duplicate them.

The CLI depends on optparse-applicative `>=0.19 && <0.20`, renders help at a fixed 100-column
width, and groups related options under semantic headings. `Kioku.Cli` exposes its parser info and
preferences as opaque test seams while keeping the command algebra private. Tests render
top-level and nested help and execute the built-in bash, zsh, and fish completion requests.

## Consequences

A language-baseline or source-convention regression now fails before merge rather than appearing
as style drift in review. Warning-as-error builds remain viable, while an intentional suppression
has a visible owning component and rationale.

Help line wrapping and group headings are now part of Kioku's CLI compatibility surface. Changing
the selected width, removing a command or group, or breaking a completion request requires an
intentional test change and release review. Existing command names, option spellings, defaults,
and errors are unchanged by this decision.

Kioku does not adopt the deployed-service package topology described elsewhere in
`mori://shinzui/haskell-jitsurei`. It remains five reusable-library and local-executable packages;
the absence of a server fleet, public HTTP client, or independently deployed worker is evidence
that those patterns do not govern this repository.

## Alternatives rejected

**Rely only on formatter and compiler output.** Rejected because neither tool confines
`PackageImports` to the project prelude nor notices a missing Cabal baseline in a new package.

**Snapshot complete help output as a golden file.** Rejected because it would pin incidental
spacing and optparse rendering details. Structural tests instead pin the commands, semantic group
headings, maximum width, and completion behavior users rely on.

**Create server, worker-service, and client packages to match the service template.** Rejected
because Kioku has no corresponding deployment or ownership boundaries. Artificial packages would
increase dependency and release complexity without separating real responsibilities.

## References

- [ExecPlan 46](../plans/46-ratchet-haskell-and-cli-pattern-conformance.md)
- `mori://shinzui/haskell-jitsurei/docs/core-standards`
- `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`
- `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`
- `mori://shinzui/haskell-jitsurei/docs/cli-option-groups`
- `mori://shinzui/haskell-jitsurei/docs/cli-shell-completions`
