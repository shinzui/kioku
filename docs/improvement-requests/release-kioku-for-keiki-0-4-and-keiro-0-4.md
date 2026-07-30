---
type: Improvement Request
title: Release Kioku for Keiki 0.4 and Keiro 0.4
description: >-
  Publish a coherent Kioku release whose bounds, migrations, and runtime APIs support the released
  Keiki 0.4 and Keiro 0.4 families without downstream allow-newer overrides.
timestamp: 2026-07-30T14:36:35Z
requestId: IR-1
status: proposed
origin: mori://shinzui/shikigami
---

# Improvement Request: Release Kioku for Keiki 0.4 and Keiro 0.4

## Status

Proposed and blocking Shikigami plan 47's dependency-cohort port.

## Context

The released `kioku-core-0.1.0.0` still bounds Keiki at `^>= 0.2` and Keiro Core at
`^>= 0.3`. Current Keiro 0.4 requires Keiki 0.4, so no released solver plan can combine the
current families. Shikigami currently avoids the conflict through an old copied set of raw commit
pins, which prevents an auditable major-version upgrade.

## Requested Change

Port Kioku to the released Keiki 0.4 and Keiro 0.4 APIs, including state/codec declarations and
the current pg-migrate-based migration components. Align the Kiroku/Shikumi/Baikai bounds with the
same released cohort. Preserve or document Kioku's current connection-settings application
environment and supply migration/replay compatibility evidence for existing Kioku data.

## Acceptance

1. All Kioku packages build and test with released Keiki 0.4 and Keiro 0.4 packages.
2. Package bounds admit the cohort without `allow-newer`.
3. Existing session, memory, timer, and distillation fixtures remain readable or have an explicit
   migration path.
4. The migration package composes through released pg-migrate APIs.
5. A tagged/Hackage release and release notes identify all breaking API changes.

## Requested Deliverables

- Updated bounds and API ports across the Kioku package family.
- Replay, codec, and migration compatibility tests.
- Tagged release suitable for a reproducible downstream pin.
