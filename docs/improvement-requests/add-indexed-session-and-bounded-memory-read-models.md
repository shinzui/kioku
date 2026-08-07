---
type: Improvement Request
title: Add indexed session and bounded memory read models
description: >-
  Provide subject-reference session lookup plus SQL-bounded recall and retention-candidate queries
  so long-lived consumers do not scan unbounded Kioku histories in application memory.
timestamp: 2026-07-30T14:36:35Z
requestId: IR-2
status: proposed
origin: mori://shinzui/shikigami
---

# Improvement Request: Add Indexed Session and Bounded Memory Read Models

## Status

Proposed. The session seam blocks
`mori://shinzui/shikigami/plans/26-conversation-workflow-lifecycle-idle-timeout-journal-rotation-session-completion`;
the bounded memory seams block milestones 2 and 3 of
`mori://shinzui/shikigami/plans/34-memory-lifecycle-distillation-retention-and-shared-scope`.

## Context

Conversation resumption needs to resolve a Kioku session from its stable `subjectRef`, but the
released session read model exposes scope-oriented queries only. Memory lifecycle work also needs a
hard operational bound. Fetching all active rows and applying `take`, sorting, or grouping in
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
