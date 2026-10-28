---
type: Architecture Decision Record
title: Catalog application projections, not framework timers
description: >-
  Kioku's validated Keiro projection catalog owns the memories, sessions, and turns tables,
  while timer scheduling remains an explicit framework-owned side effect in the same append
  transaction.
timestamp: 2026-10-28T03:59:31Z
docId: ADR-13
status: accepted
date: 2026-09-18
---

# Catalog application projections, not framework timers

## Status

Accepted, 2026-09-18. Implemented by `kioku-core/src/Kioku/ProjectionCatalog.hs` and the
memory and session command runners.

## Context

[ADR-10](projections-live-in-the-kioku-schema.md) assigns Kioku's application projections to
the `kioku` PostgreSQL schema. Keiro 0.17 adds a closed-world projection catalog in which each
`TargetDeclaration` names one application-owned table and validation requires exactly one
projection owner for that target.

Kioku's memory and session handlers update three such tables: `kioku.memories`,
`kioku.sessions`, and `kioku.turns`. The same command transactions also schedule L1 and L2
timers in `keiro.keiro_timers`. That table is a Keiro framework table shared by both event
families and by any other timer user in the host. It is not a Kioku projection target and it
does not have one truthful Kioku owner.

The Keiro 0.17 catalog has no declaration for a shared framework-owned transactional callback.
Assigning the timer table to either Kioku projection would therefore make catalog inventory
false; assigning it to both would correctly fail duplicate-ownership validation.

## Decision

Kioku's validated catalog declares only the three application-owned projection tables. The
memory projection owns `kioku.memories`. The session projection owns `kioku.sessions` and
`kioku.turns`, with turns depending on sessions for rebuild ordering. All nineteen query models
bind to those authoritative owners.

Memory and session command runners derive their application handlers with Keiro's
`typedInlineProjections` and then append the existing timer scheduling handler explicitly. The
combined list still runs through `runCommandWithProjections`, so event append, Kioku projection
writes, and timer scheduling commit or roll back in one PostgreSQL transaction. The timer handler
is adjacent and named at the command boundary; it is not hidden in the catalog and
`keiro.keiro_timers` is never declared as a Kioku target.

Startup validates both hand-written event streams and the catalog, then registers the catalog
before exposing the application environment. Catalog fingerprint drift fails startup. Migration
application remains host-owned and precedes this runtime handshake.

## Consequences

The catalog is an honest inventory of Kioku-owned read state and can derive registrations,
query suppliers, handler lists, rebuild groups, and a stable fingerprint without claiming
ownership of a framework table.

Timer scheduling retains the existing atomicity guarantee. A timer cannot commit without the
event and application projection it accompanies, and an application projection failure cannot
leave an orphan timer.

The command path continues to use Keiro's compatibility transaction runner rather than the
catalog-fenced command runner. Moving to the catalog-fenced runner requires Keiro to represent
framework-owned callbacks in the same transaction without treating their tables as
application-owned targets. Until that capability exists, inventing ownership would be worse than
keeping the boundary explicit.

Offline rebuilds replay only the declared application projections. Memory event
replay cannot recreate provider-owned enrichment (`embedding`, `embedding_model`,
`dimensions`, `content_hash`), so a disposable upgrade rehearsal saves those fields
and restores them only after memory ID, memory space and content match. A failed
match is a failed rehearsal. This is developer instrumentation, not an automatic
production rebuild facility. Session projection `created_at`/`updated_at` are
database clocks; event-derived timestamps remain part of semantic comparison.

Catalog registration through the released Keiro 0.22 public API upserts cursor
authority even when unchanged. The `kioku-memory` and `kioku-session` append cursor
rows may therefore advance `updated_at` during CLI/migration-runner startup.
Operational comparison records that narrow clock effect separately from schema
migration, and never treats it as permission to change cursor authority, reset
subscriptions, repair registry drift, or alter query/catalog identities.

## Alternatives rejected

**Declare `keiro.keiro_timers` as a memory or session target.** Rejected because the table is
framework-owned and receives writes from both projections; either owner would be false.

**Declare the timer table twice.** Rejected because Keiro correctly treats multiple owners as a
catalog error, and duplicate declarations would make rebuild semantics unsafe.

**Move timer scheduling to a later transaction.** Rejected because an append or projection could
commit without its required timer, weakening the existing delivery contract.

**Hide timer scheduling inside a catalog application handler.** Rejected because catalog
inventory would imply that all handler effects are represented by the declared Kioku targets,
while the handler actually mutates framework state outside that inventory.

## References

- `kioku-core/src/Kioku/ProjectionCatalog.hs` — authoritative targets, owners, query bindings,
  rebuild groups, replay adapters, and catalog fingerprint
- `kioku-core/src/Kioku/Memory.hs` and `kioku-core/src/Kioku/Session.hs` — catalog-derived
  application handlers plus explicit timer callbacks
- `kioku-core/test/Kioku/ProjectionCatalogSpec.hs` — inventory, validation, event-stream, and
  persisted-fingerprint evidence
- [ADR-10](projections-live-in-the-kioku-schema.md)
- `mori://shinzui/keiro-runtime-patterns/docs/keiro-projection-catalogs`
- `mori://shinzui/keiro-runtime-patterns/docs/keiro-runtime-assembly`
- `mori://shinzui/keiro/packages/keiro`
