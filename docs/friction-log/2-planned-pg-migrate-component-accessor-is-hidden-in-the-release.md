---
type: Friction Entry
title: "Planned pg-migrate component accessor is hidden in the release"
description: "The source-only Types accessor prescribed by Plan 51 cannot be imported from released pg-migrate 1.2, requiring frozen archive fixtures."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-28T03:42:57Z"
frictionId: FRIC-2
status: "accepted"
impact: detour
kind: interface
origin: "mori://shinzui/kioku"
affects: "mori://shinzui/pg-migrate/packages/pg-migrate"
affectedVersion: "1.2.0.0"
plan: "docs/plans/51-upgrade-kioku-to-keiro-0-22-and-compatible-released-runtime-dependencies.md"
workaround: "Ship the published 0.7.1.0 SQL fixture, freeze all fifteen hashes, and use the public migrationComponentFromEmbeddedSql constructor."
resolution: "Use frozen Hackage SQL fixtures and public constructors with checksums rather than the released hidden Types module."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-28T04:01:27Z"
    change: "Migration tests now use the supported public interface and immutable previous-release bytes."
---
# Planned pg-migrate component accessor is hidden in the release

## Attempted

Import componentMigrationsOf from Database.PostgreSQL.Migrate.Types to filter migration 0016.

## Encountered

GHC rejects the import because Types is a hidden module.

```text
it is a hidden module in the package pg-migrate-1.2.0.0
```

## Workaround

Ship the published 0.7.1.0 SQL fixture, freeze all fifteen hashes, and use the public migrationComponentFromEmbeddedSql constructor.
