---
type: Architecture Decision Record
title: Legacy data is backfilled into one explicit memory space
description: >-
  Data written before memory spaces existed is assigned the named kioku_legacy space rather than
  left unpartitioned, so absence of a partition never means unrestricted access.
timestamp: 2026-08-06T19:10:00Z
docId: ADR-3
status: accepted
date: 2026-08-06
---

# Legacy data is backfilled into one explicit memory space

## Status

Accepted, 2026-08-06. The migration that applies it landed the same day:
`kioku-migrations/migrations/0011-kioku-memory-space-partition.sql` backfills every partitioned
table into `kioku_legacy` and then makes the column `NOT NULL`, exactly as the last paragraph of
the Consequences below requires.

## Context

Kioku is in production use with data written before memory spaces existed. Every existing memory,
session, turn, scene, persona, watermark, and decision predates the partition and has no space to
belong to.

When the partition column arrives, those rows need a value. The path of least resistance is a
nullable column where `NULL` means "not partitioned", and the queries treat an unpartitioned row
as visible from any space. Every existing deployment then keeps working with no migration at all.

That convenience is a security failure waiting for its first multi-space deployment. It makes
absence of a partition equivalent to universal access, so any row that misses a backfill — a
replayed old event, a worker that forgot to set the column, a table added later — silently becomes
visible to every space in the database. The failure is silent, it is invisible in a passing test
suite, and it fails open.

## Decision

Legacy data is backfilled into one explicit memory space, `kioku_legacy`, exposed as
`legacyMemorySpaceId` in `Kioku.Api.Access`.

A missing or unknown memory space is never treated as "visible everywhere". Nothing in Kioku may
interpret absence of a partition as permission; the partition predicate is unconditional.

Old event streams replay into this same explicit space, so an aggregate rebuilt from history lands
where the backfill put it and the two paths cannot disagree.

`kioku_legacy` is an ordinary memory space in every other respect. It is not privileged, not
implicit, and not a wildcard. A newly created space never inherits from it.

## Consequences

An upgraded single-space deployment keeps working: all of its rows land in one space, all of its
callers are authorized for that space, and behaviour is unchanged. What changes is *why* it works
— because everything shares one explicit space, not because unpartitioned rows are special.

A row that escapes the backfill becomes inaccessible rather than universally accessible. That is
the failure direction worth having: it is loud, it surfaces immediately, and it is repairable.

Anyone splitting a legacy deployment into several spaces must move rows out of `kioku_legacy`
deliberately. There is no automatic reinterpretation, which is the point.

The migration must therefore be a genuine backfill with a `NOT NULL` partition column at the end,
not a nullable column with a defaulting read path.

## Alternatives rejected

**Nullable partition column where `NULL` means globally visible.** Rejected: it makes a missing
value mean maximum access, so every future bug in that column fails open.

**Refuse to start until an operator names a space.** Rejected: it turns a library upgrade into an
outage for every existing deployment, to no benefit — the operator's answer would be
"whatever I had before", which is exactly what `kioku_legacy` names.

## References

- `kioku-api/src/Kioku/Api/Access/Internal.hs` — `legacyMemorySpaceId`
- `kioku-api/test/Kioku/Api/AccessSpec.hs` — the legacy space is a real, explicit identifier
- `kioku-migrations/test/Main.hs` — the backfill, proved against a genuinely pre-partition database
- [ADR-1](kioku-owns-memory-not-identity.md), [ADR-2](namespace-is-not-a-security-boundary.md),
  [ADR-6](the-partition-is-a-column-not-a-schema.md)
