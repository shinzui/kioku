---
type: Friction Entry
title: "Cabal all target excludes source archives"
description: "The archive-only consumer solve contained components but Cabal all selected no targets because archive packages are not local checkout packages."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-28T03:57:41Z"
frictionId: FRIC-4
status: "accepted"
impact: detour
kind: interface
origin: "mori://shinzui/kioku"
affects: "https://github.com/haskell/cabal"
plan: "docs/plans/51-upgrade-kioku-to-keiro-0-22-and-compatible-released-runtime-dependencies.md"
workaround: "Request each exported library, the migration test-support sublibrary and both executables explicitly, using --project-dir for source isolation."
resolution: "Request all seven exported library and executable archive components explicitly instead of the local-only all target."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-28T04:01:28Z"
    change: "Archive consumer builds and runtime source parity pass with explicit component selection."
---
# Cabal all target excludes source archives

## Attempted

Build an external project whose packages field names the five source archives with cabal build all.

## Encountered

Cabal reported that none of the project packages contain components although its component graph listed them.

```text
Cabal-7127: Cannot build all the packages in the project because none of them contain any components at all.
```

## Workaround

Request each exported library, the migration test-support sublibrary and both executables explicitly, using --project-dir for source isolation.
