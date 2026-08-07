---
type: Architecture Decision Record
title: The memory-space partition is a column and a predicate, not a schema per space
description: >-
  Every Kioku read-model table carries a memory_space_id column and every statement names it,
  rather than isolating spaces by PostgreSQL schema, database, or row-level security.
timestamp: 2026-08-06T18:40:00Z
docId: ADR-6
status: accepted
date: 2026-08-06
---

# The memory-space partition is a column and a predicate, not a schema per space

## Status

Accepted, 2026-08-06. Implemented by `kioku-migrations/migrations/0011-kioku-memory-space-partition.sql`
and the read models in `kioku-core/src/Kioku`.

## Context

[ADR-2](namespace-is-not-a-security-boundary.md) fixed the rule that only an explicit memory space
isolates memory, and [ADR-4](the-aggregate-enforces-the-partition.md) put the write-side guard in
the aggregate. Neither says how PostgreSQL enforces the boundary on the read side, and the read
models had no notion of a space at all: every query returned rows from every space.

The obvious alternatives all move the boundary into the database's own tenancy machinery — a
schema per space, a database per space, or PostgreSQL row-level security with a session variable.
Each promises that a forgotten predicate cannot leak, which is a real property and the reason they
keep being proposed.

Kioku's constraints work against all three. A memory space is an opaque identifier issued by some
other system; spaces are created by that system at its own rate, and Kioku is a library embedded
in a host's database rather than the owner of a cluster. Provisioning DDL per space would make
creating a space a migration, and Kioku's read models are registered in keiro's
`keiro_read_models` registry by name — one registry, one set of projections, one subscription per
event stream.

## Decision

Every partitioned table carries a non-null `memory_space_id text` column, and every statement that
reads or writes those tables names it. There is no schema, database, or RLS policy per space.

Four rules follow from that, and they are the part worth remembering:

**The predicate is unconditional, even where the key is globally unique.** A memory id is a
globally unique TypeID, so `WHERE memory_id = $1` is already unambiguous; the statements still say
`WHERE memory_space_id = $1 AND memory_id = $2`. This is what stops a caller holding a leaked id
from reading outside its authorized space, and it makes query review mechanical: a statement over
a partitioned table that does not mention the space is wrong on sight.

**Recursive walks carry the predicate on the recursive arm, not only the anchor.** Supersession
lineage and session continuation are stored as bare ids with no foreign key, so a walk that
checked the space only at its starting row could follow one of those ids straight into another
space.

**An identity derived from a scope becomes composite.** Scene and persona primary keys are derived
from the namespace and scope alone, which two spaces are allowed to share, so those keys collide
across spaces. Their primary key is `(memory_space_id, <id>)`. The derived id strings are left
exactly as they are: re-deriving them to fold the space in would rewrite every stored row and
every workspace mirror filename for no gain the composite key does not already provide. The same
reasoning applies to timer identity, which is keyed by a scope and therefore carries the space.

**An index leads with the space only where the identity is scope-derived.** Indexes led by a
globally unique id — `memory_id`, `session_id`, `parent_session_id`, `supersedes` — keep their
shape. The space is a filter there, not an access path, and prefixing it would buy no selectivity
while costing a write on every insert.

## Consequences

Creating a memory space requires no DDL, no migration, and no privilege. That is the property that
makes spaces usable at all, given that some other system decides when they exist.

A forgotten predicate is a leak, and nothing in PostgreSQL will catch it. The mitigation is that
the predicate is uniform, visible in every statement, and covered by a test fixture
(`Kioku.SpaceIsolationSpec`) in which two spaces hold identical namespaces, scopes, content, and
derived artifact keys — so a query that ignored the partition returns the wrong row immediately
rather than in production.

The write-path idempotency precheck now looks a row up inside the command's own space, which
closed a residual [ADR-4](the-aggregate-enforces-the-partition.md) recorded: an id belonging to
another space used to answer that it existed and whether it was active. It now answers exactly as
an id that does not exist, and the refusal is `MemoryNotFound` rather than a rejection from the
aggregate.

**A partition-leading index changes which plan the query planner picks, including for vector
recall.** Rebuilding `kioku_memories_scope_idx` as `kioku_memories_space_scope_idx` made the
planner prefer an ordinary index scan of the in-scope rows plus a top-N sort over the HNSW index,
on a corpus where it had previously chosen HNSW. That is not a regression — the exact plan
returned perfect recall — but it means the filtered-ANN starvation the recall harness exists to
reproduce now needs a larger corpus, and it means any future index on
`(memory_space_id, namespace, …)` should be checked against the recall plans before it ships.

## Alternatives rejected

**A PostgreSQL schema or database per memory space.** Rejected: creating a space would become a
migration, keiro's read-model registry and subscriptions are per-deployment rather than per-space,
and Kioku does not own the cluster it runs in.

**Row-level security with the space in a session variable.** Rejected on two counts. Kioku shares
a connection pool with its host, so a policy keyed on a session GUC is only as good as every
`SET`/`RESET` pair on a pooled connection — a leaked setting is exactly the silent cross-space
read the boundary exists to prevent. And the host, not Kioku, owns the database role, so Kioku
cannot assume it may create policies or that `BYPASSRLS` is absent.

**A nullable column meaning "visible everywhere".** Rejected by
[ADR-3](legacy-data-lands-in-one-explicit-space.md): absence of a partition must never mean
unrestricted access.

## References

- `kioku-migrations/migrations/0011-kioku-memory-space-partition.sql` — the column, the backfill,
  the composite keys, and the partition-first indexes
- `kioku-core/test/Kioku/SpaceIsolationSpec.hs` — two spaces, identical everything else
- `kioku-core/test/Kioku/SchemaSpec.hs` — the constraints and indexes the migration installs
- [ADR-2](namespace-is-not-a-security-boundary.md), [ADR-3](legacy-data-lands-in-one-explicit-space.md),
  [ADR-4](the-aggregate-enforces-the-partition.md)
