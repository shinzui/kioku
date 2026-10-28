---
type: Friction Entry
title: "Cabal project file did not isolate baseline source paths"
description: "Invoking the baseline project file from the active checkout resolved local packages into the active tree and required restarting the baseline build."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-28T03:40:28Z"
frictionId: FRIC-1
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/kioku"
affects: "https://github.com/haskell/cabal"
plan: "docs/plans/51-upgrade-kioku-to-keiro-0-22-and-compatible-released-runtime-dependencies.md"
workaround: "Run Cabal from the detached baseline worktree itself with an absolute build directory and verify all local pkg-src paths."
resolution: "Run every isolated project from its own working directory, freeze its solve, and verify local source paths before retaining binaries."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-28T04:01:27Z"
    change: "Documented exact project and artifact source isolation for baseline and archive builds."
---
# Cabal project file did not isolate baseline source paths

## Attempted

Build old artifacts with --project-file=.dev/keiro-0.22/baseline/source/cabal.project from repository root.

## Encountered

plan.json named local sources in the active checkout; after edits the build configured Kioku 0.12 instead of the baseline.

## Workaround

Run Cabal from the detached baseline worktree itself with an absolute build directory and verify all local pkg-src paths.
