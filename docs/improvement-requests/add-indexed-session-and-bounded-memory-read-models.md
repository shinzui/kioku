---
type: Improvement Request
title: Add indexed session and bounded memory read models
description: >-
  Provide subject-reference session lookup plus SQL-bounded recall and retention-candidate queries
  so long-lived consumers do not scan unbounded Kioku histories in application memory.
timestamp: "2026-10-20T00:16:39Z"
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-20T00:16:39Z"
requestId: IR-2
status: in-progress
origin: mori://shinzui/shikigami
---

# Improvement Request: Add Indexed Session and Bounded Memory Read Models

## Status

In progress; partially delivered. The published
[0.10.0.0 release](https://github.com/shinzui/kioku/releases/tag/v0.10.0.0)
(commit `5f4afc872b09d615d1bb8c78369d6912161c550f`) delivers permission-checked,
partitioned Session and Memory pages/counts, indexed `SessionFilter.subjectRef`
selection and documented bounded zero/one/many lookup. See
[bounded reads](../user/bounded-reads.md). The package is available on
[Hackage](https://hackage.haskell.org/package/kioku-core-0.10.0.0).

[ExecPlan 49](../plans/49-expose-fixed-memory-metadata-tag-pages-and-recency-queries.md)
and [IR-6](expose-fixed-memory-metadata-tag-pages-and-recency-queries.md) add locally
verified newest-active metadata lookup and scope-kind filtering; their publication
is still pending. A newest-active point lookup does not provide the requested
newest-first recall collection or chronological retention-candidate pages.

Do not mark this request completed: ordinary Memory pages remain priority-first
(and session-filtered pages use recency). The dedicated retention ordering
`(created_at, memory_id)`, stability under concurrent inserts and the full
query-plan/acceptance evidence still need to be delivered or explicitly resolved.
The older unbounded `Kioku.Recall.getActiveByScope` list is not a bounded substitute.

The original consumers are
`mori://shinzui/shikigami/plans/26-conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion`
and
`mori://shinzui/shikigami/plans/34-memory-lifecycle-distillation-retention-and-shared-scope`.
Their current adoption status is not established by this owner-side update.

## Context

At request time, conversation resumption needed to resolve a Kioku session from its stable
`subjectRef`, but the released session read model exposed scope-oriented queries only.
Memory lifecycle work also needs a hard operational bound. Fetching all active rows and applying `take`, sorting, or grouping in
Haskell does not bound database, transfer, or heap cost.

## Requested Change

Add an indexed `SessionsBySubjectRefQuery`/`getBySubjectRef`-equivalent API with documented
zero/one/many semantics. Add validated bounded query values and server-side SQL read models for:

- newest-first active recall by scope with `ORDER BY` and `LIMIT`; and
- retention candidates in deterministic `(created_at, memory_id)` keyset pages.

Ship the supporting indexes/migrations and keep record fields direct under
`DuplicateRecordFields`.

Coordinate this request with
`docs/masterplans/5-portfolio-compatible-memory-isolation-and-authorization.md` and
`docs/masterplans/6-explicit-and-safe-recall-boundaries.md`: every new query is partition-first,
accepts one `MemoryAccessContext`, and uses the explicit `RecallTarget` — the exact global bucket,
one exact entity scope, or namespace-wide — rather than the legacy overloaded `ScopeGlobal`. A
query whose breadth is a bounded read rather than a search should take the exact scope and say so,
as `Kioku.Recall.getActiveByScope` does. Subject-reference lookup is unique or ambiguous only
inside one memory space.

## Acceptance

1. Subject-reference lookup uses an index and deterministically reports missing, unique, and
   ambiguous results.
2. Recall never returns or scans beyond the documented bounded query shape.
3. Retention pagination is stable across equal timestamps and concurrent inserts.
4. Query plans and real-Postgres tests demonstrate index use and bounded page sizes on a large
   fixture.
5. The APIs are exported in a tagged release compatible with the current Kioku cohort.
6. Identical subject references, namespaces, and scopes in two memory spaces remain isolated in
   real-Postgres and query-plan tests.

## Requested Deliverables

- Public typed queries, migrations/indexes, and documentation.
- Real-Postgres correctness and query-plan tests.
- Tagged release.

## Revision Notes

- 2026-08-06: Made the proposed queries consume the new memory-space and explicit recall-target
  contracts so the bounded-read work does not introduce unpartitioned APIs before those
  MasterPlans land.
- 2026-10-20: Record the published 0.10.0.0 bounded-read delivery and the locally verified
  IR-6 extension; retain in-progress status because the full retention/recall acceptance
  and release evidence are not yet satisfied.
