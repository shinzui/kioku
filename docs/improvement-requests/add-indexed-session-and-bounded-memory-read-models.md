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

Proposed. The session seam blocks Shikigami plan 26; the bounded memory seams block plan 34
milestones 2 and 3.

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

## Acceptance

1. Subject-reference lookup uses an index and deterministically reports missing, unique, and
   ambiguous results.
2. Recall never returns or scans beyond the documented bounded query shape.
3. Retention pagination is stable across equal timestamps and concurrent inserts.
4. Query plans and real-Postgres tests demonstrate index use and bounded page sizes on a large
   fixture.
5. The APIs are exported in a tagged release compatible with the current Kioku cohort.

## Requested Deliverables

- Public typed queries, migrations/indexes, and documentation.
- Real-Postgres correctness and query-plan tests.
- Tagged release.
