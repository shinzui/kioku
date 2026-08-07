---
type: Architecture Decision Record
title: Each recall target gets its own statement
description: >-
  Recall's three targets compile to three SQL scope clauses in nine statements rather than to one
  parameterised predicate with nullable scope columns, so the breadth a call asked for is visible
  in the statement it ran and in the plan PostgreSQL chose.
timestamp: 2026-08-07T12:00:00Z
docId: ADR-9
status: accepted
date: 2026-08-07
---

# Each recall target gets its own statement

## Status

Accepted, 2026-08-07. Implemented by `kioku-core/src/Kioku/Recall.hs`; proven by
`kioku-core/test/Kioku/RecallTargetSpec.hs`.

## Context

[ADR-8](an-explicit-recall-target-replaces-the-overloaded-scope.md) gave recall a `RecallTarget`
naming one of three meanings: the exact global bucket of a namespace, one exact entity scope, or
every scope in the namespace. It could not make all three executable, and said so: the exact
global bucket type-checked, round-tripped on the wire, and was refused at run time with
`RecallExactGlobalUnsupported`.

The obstruction was one line of SQL. Both candidate statements spelled the scope filter

```sql
(($4 IS NULL AND $5 IS NULL) OR (scope_kind = $4 AND scope_ref = $5))
```

and both took `scope_kind` and `scope_ref` as nullable parameters. Passing NULL made the first
disjunct unconditionally true and the scope filter vanished, which is how namespace-wide recall
was expressed. But the exact global bucket *is* the set of rows whose scope columns are NULL, so
the parameters that should have named it were already spoken for by the opposite meaning. There
was no third assignment. Worse, the two meanings that could be expressed were indistinguishable
after the fact: a caller who meant "the global bucket" and a caller who meant "the whole
namespace" would have issued the identical query with the identical parameters, so no log line, no
`pg_stat_statements` row, and no query plan could tell a reviewer which one had been asked for.

This matters more than an ordinary representation choice because the difference between the two is
*how many rows come back*. Recall is the one read that can be asked to widen, and widening is the
thing a reviewer most needs to see.

## Decision

**Each target compiles to its own SQL scope clause.** `Kioku.Recall.resolveRecall` maps a
`RecallTarget` to a `ScopeBound` with one constructor per meaning, and each bound has one spelling:

| Bound | Scope clause |
|---|---|
| `GlobalBucketOnly` | `AND scope_kind IS NULL AND scope_ref IS NULL` |
| `EntityScopeOnly` | `AND scope_kind = $4 AND scope_ref = $5` |
| `EveryScopeInNamespace` | *(none)* |

There are nine statements: three channels — full text, the approximate vector pass, the exact
vector pass — times these three clauses. They are generated from one SQL template per channel and
one clause per bound, so the space, namespace and `status` predicates are written once and cannot
drift apart between families. Which family runs is a total `case`, so a fourth target cannot be
added without deciding what SQL it means.

**Widening is unrepresentable in the parameters.** The two bounds that need no scope values share
`BoundedCandidateParams`, which has no scope fields at all; the entity bound uses
`EntityCandidateParams`, whose two scope fields are non-nullable. Neither record can express "no
scope filter" by accident, because neither record can express a scope filter's *absence* — that is
a property of the statement, not of a value passed to it.

**`memory_space_id` is the first mandatory predicate in all nine.** Namespace-wide means every
scope in one already authorized space, never every space. The scope clause is the only thing that
varies between families; the partition predicate is not a variable. This is
[ADR-2](namespace-is-not-a-security-boundary.md)'s constraint reaching the SQL, as
[ADR-6](the-partition-is-a-column-not-a-schema.md) reached the schema.

**No new index.** All three bounds are answered through the partition-first index migration 0011
installed, `kioku_memories_space_scope_idx` on
`(memory_space_id, namespace, scope_kind, scope_ref) WHERE status = 'active'`: the two exact
bounds as four-column index conditions and the namespace-wide bound as a two-column prefix. A
btree index takes `scope_kind IS NULL` as an index condition rather than as a filter, so the exact
global bucket needs no index of its own — and adding a partial one would cost a write per insert
for no gain, which is the redundancy migrations 0008 and 0011 removed twice already.

## Consequences

The exact global bucket executes. `RecallExactGlobalUnsupported` is gone, and `resolveRecall`
became total: every target has a predicate and the limit was validated into a `RecallLimit` before
the request was built. `RecallError` is down to `RecallSpaceMismatch`, which only the deprecated
`legacyRecall` can produce, and `recall` keeps returning `Either` anyway so that adding a refusal
later is not a breaking change at every call site.

**Which meaning ran is now an observable artifact.** `Kioku.RecallTargetSpec` reads the access
paths back out of PostgreSQL and asserts that the three bounds are three plans — the global
bucket's `Index Cond` tests `scope_kind` for NULL, the entity's compares it, and the
namespace-wide plan constrains no scope at all — and that every one of them is led by
`memory_space_id`. Its fixture holds two memory spaces with byte-identical rows under identical
names, so a statement that lost the partition predicate returns six rows where it should return
one.

**The nine statements are a real cost, and prepared-statement cache pressure is the honest form of
it.** Three channels times three bounds is nine entries per connection instead of three. That is
the price of the widening being visible, and it is bounded: the families do not multiply with
namespaces, scopes, or spaces, only with meanings, and there are three meanings.

**The filtered-ANN fallback is now dispatched per family.** The two-pass vector channel from
[the recall-quality work](../plans/19-fix-filtered-ann-starvation-in-vector-recall.md) is shared
code that picks a family, so a regression can be family-local — dropping the `OFFSET 0`
optimisation fence from the exact-scope statement alone would leave the namespace-wide starvation
case passing. `Kioku.RecallHarness.exactEntityStarvationCorpus` exists for that reason.

**The recall harness stopped keeping its own copy of the vector SQL.** It used to restate the
statement so it could `EXPLAIN` it, and the copy went wrong twice — once selecting one column
instead of thirteen, which made the top-N sort look cheap and reported a plan the real query never
took; once omitting the memory-space predicate, which reported an access path no live query can
produce. Three families would have meant three copies. `Kioku.Recall.explainVectorAnnCandidates`
and its siblings build the `EXPLAIN` from the same SQL text and parameters as the statement they
describe, so there is nothing left to drift.

## Alternatives rejected

**One statement with `scope_kind IS NOT DISTINCT FROM $4`.** This expresses exact-global and
exact-entity in one predicate and reads well. Rejected on two counts: PostgreSQL does not treat
`IS NOT DISTINCT FROM` as an indexable clause, so the exact bounds would lose the partition-first
index and fall back to a filter; and it still cannot express namespace-wide, so a nullable
third meaning would have had to come back somewhere.

**Two families, exact and namespace-wide, with the exact one carrying a `MemoryScope`.** This is
what `docs/plans/29-enforce-exact-and-namespace-wide-recall-in-postgresql.md` originally sketched.
Rejected: a Hasql encoder for a `MemoryScope` needs nullable scope parameters again for the global
case, which reintroduces exactly the representation this decision removes, one layer further down
where it is harder to see.

**Reinterpret the existing predicate so NULL means the global bucket.** Rejected for the reason
ADR-8 rejected the same move at the type level: it is a data-visibility change with no compiler
signal, and every namespace-wide caller would silently start receiving a fraction of their rows.

**A dedicated partial index for the global bucket.** Rejected on measurement rather than on
principle: the existing partition-first index already answers `scope_kind IS NULL` as an index
condition, so a partial index would be smaller but no more selective, and would cost a write on
every insert.

## References

- `kioku-core/src/Kioku/Recall.hs` — `ScopeBound`, the three SQL templates, the nine statements
- `kioku-core/test/Kioku/RecallTargetSpec.hs` — the target matrix and the plan evidence
- `kioku-core/test/Kioku/RecallSqlSpec.hs` — the per-family filtered-ANN regressions
- [Recall & Hybrid Retrieval](../user/recall.md#how-a-target-reaches-sql)
- [ADR-8](an-explicit-recall-target-replaces-the-overloaded-scope.md) — the vocabulary this
  decision makes executable
- [ADR-2](namespace-is-not-a-security-boundary.md) — why the partition predicate is not a variable
- [ADR-6](the-partition-is-a-column-not-a-schema.md) — the column and index this sits on
