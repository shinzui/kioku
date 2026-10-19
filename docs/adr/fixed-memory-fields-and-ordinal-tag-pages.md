---
type: Architecture Decision Record
title: Fixed Memory fields and ordinal tag pages
description: >-
  Memory inspection selects scalar metadata directly, pages complete tags by stored array
  position, and keeps host cursor policy separate from permission-checked library reads.
timestamp: 2026-10-19T23:47:32Z
docId: ADR-15
status: accepted
date: 2026-10-19
---

# Fixed Memory fields and ordinal tag pages

## Status

Accepted, 2026-10-19. Implemented by `Kioku.Memory` and `Kioku.Memory.ReadModel`.

## Context

Memory content is one text value, while tags are a growing collection. Returning a bounded
number of Memory rows does not bound the number of tags decoded with those rows. Hosts also
need an unambiguous newest-active answer: the ordinary Memory list sorts by priority before
creation time. Neither concern belongs to a host-specific HTTP route or entity vocabulary.

The authoritative tag projection is a JSON array encoded from a set. There is no separate tag
revision or durable tag identity. Large complete values must survive inspection without putting
those values into continuation keys.

## Decision

`MemoryMetadata` contains the scalar fields of `MemoryRow` and a scalar `tagCount`. Its SQL
selects `jsonb_array_length(tags)::bigint` directly; the decoder never receives the array.
Recursive supersession selection carries only identity links, retains the memory-space predicate
on seed and recursive joins, and uses `UNION` to terminate cycles. Fixed fields bound rows and
collection cardinality in the result, not content bytes or all database work.

Tags have a separate parent-scoped Connection. Each `MemoryTag` exposes its stored-array
`ordinal :: Int64` and complete text `value`. Relay's numeric key codec keeps cursor size
independent of tag length. Missing or foreign parents return absence; an existing empty parent
returns an empty Connection. Archived metadata and tags remain inspectable.

A cursor names a position in the current array, not a snapshot. Restart after tag replacement.
Hosts own transport cursor binding to resource, parent, space, filters and optional revision;
Kioku neither invents host cursor envelopes nor promises concurrent snapshot traversal. A valid
cursor cannot grant read permission. Every public bounded facade checks `MemoryRead` before
Store access, including malformed pages and absent parents. Authorized page failures, read-model
failures and the outer Store failure channel remain distinct from absence.

`MemoryFilter.scopeKind` intersects its explicit target and all other filters before page bounds
or counts. It never widens an exact global or entity target. The newest-active operation adds
an active-status predicate and orders creation time descending, ID ascending, independently of
priority. A non-active status filter intersects to absence. Ordinary, session-filtered and
supersession page orders retain their existing meaning.

Additional read models bind to the existing memories owner without a table-shape identity bump.
They still change the catalog fingerprint: drain hosts, preview and adopt through the public
lifecycle before normal startup. A composed host uses its complete validated catalog. Registry
reconciliation alone cannot adopt catalog drift.

## Consequences

Hosts can compose fixed metadata, complete counts, tag pages and newest-active results without
loading unbounded collections. The exported filter constructor requires a PVP major release;
existing callers append `Nothing` to retain selection.

The measured recency path needed an active-only index on memory space, namespace, descending
creation time and ascending ID. Migration 0015 adds it transactionally, allowing reads while
writers wait for commit. Kind filtering may still scan entries before finding a match; neither
bounded output nor this index promises constant execution cost. No new tag table, tag revision
projection or kind vocabulary is introduced.

## Alternatives rejected

Fetching rich rows and stripping tags in Haskell still transfers and decodes the collection.
Tag text keys grow with tag values; truncated text or hashes require new collision semantics.
A new tag table/revision would add projection and migration obligations without an accepted
snapshot requirement. Reusing the first ordinary list row for newest-active gives the wrong
answer when an older row has a better priority.

## References

- [ExecPlan 49](../plans/49-expose-fixed-memory-metadata-tag-pages-and-recency-queries.md)
- [Bounded reads and adoption recipe](../user/bounded-reads.md)
- [ADR-1](kioku-owns-memory-not-identity.md), [ADR-2](namespace-is-not-a-security-boundary.md)
- [ADR-8](an-explicit-recall-target-replaces-the-overloaded-scope.md)
- [ADR-13](catalog-application-projections-not-framework-timers.md)
- `kioku-core/test/Kioku/BoundedReadSpec.hs`
- `kioku-core/test/Kioku/ProjectionCatalogSpec.hs`
