---
type: Friction Entry
title: "Default Tasty concurrency exhausts ephemeral PostgreSQL startup"
description: "Running the complete suite at default concurrency timed out creating many ephemeral PostgreSQL clusters and required a bounded rerun."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-28T03:49:58Z"
frictionId: FRIC-3
status: "accepted"
impact: detour
kind: environment
origin: "mori://shinzui/kioku"
affects: "mori://shinzui/kioku"
plan: "docs/plans/51-upgrade-kioku-to-keiro-0-22-and-compatible-released-runtime-dependencies.md"
workaround: "Run suites sequentially with Cabal -j1 and TASTY_NUM_THREADS=4, retaining the same compiler and warning flags."
resolution: "Run complete suites sequentially with TASTY_NUM_THREADS=4; all suites pass under that bound."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-28T04:01:28Z"
    change: "Recorded the machine concurrency limit and successful full-suite workaround."
---
# Default Tasty concurrency exhausts ephemeral PostgreSQL startup

## Attempted

nix develop -c cabal test all --enable-tests --ghc-options=-Werror --test-show-details=direct

## Encountered

25 core and 2 CLI tests timed out waiting for PostgreSQL startup; no domain assertion failed.

```text
Timed out after 60s waiting for PostgreSQL on port 61306
```

## Workaround

Run suites sequentially with Cabal -j1 and TASTY_NUM_THREADS=4, retaining the same compiler and warning flags.
