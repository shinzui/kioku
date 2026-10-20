---
type: Improvement Request
title: Expose fixed Memory metadata, tag pages and recency queries
description: Provide permission-checked fixed Memory metadata, separately paged tags, newest-active lookup and scope-kind filtering so Rei can expose bounded resources without private Kioku SQL or collection preloading.
requestId: IR-6
status: in-progress
origin: mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-20T00:18:15Z"
timestamp: "2026-10-20T00:18:15Z"
verified:
  - by: openai/gpt-6-astra
    at: "2026-10-19T23:30:39Z"
reviews:
  - kind: model
    reviewer: "codex (author self-review)"
    reviewed_at: "2026-10-19T22:58:18Z"
    document_timestamp: "2026-10-19T22:55:57Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: >-
      Checked the request against published Kioku 0.10.0.0 source and tags,
      current published Store versions and the selected cohort where relevant.
      This author self-review approves request accuracy only; it does not
      approve implementation, dependency adoption or publication.
  - kind: model
    reviewer: "codex (Kioku source validation and revision self-review)"
    reviewed_at: "2026-10-19T23:30:39Z"
    document_timestamp: "2026-10-19T23:30:39Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-6-astra
    effort: high
    context: >-
      Validated the gaps against Kioku's Memory read models, permission gates,
      catalog lifecycle, PostgreSQL fixtures and ADRs 1, 2, 8, 9, 13 and 14.
      Confirmed the 0.10.0.0 baseline and relevant released dependency versions
      against Hackage and upstream tags. ExecPlan 49 records the implementation
      design and acceptance proof. This review accepts project fit and the
      clarified request; implementation tests and publication remain pending.

---

# Expose fixed Memory metadata, tag pages and recency queries

## Status and implementation plan

Accepted on 2026-10-19 after validation against Kioku's source and architectural
decisions. Implementation is tracked by
[ExecPlan 49](../plans/49-expose-fixed-memory-metadata-tag-pages-and-recency-queries.md),
created in commit `77172de` and linked to intention
`intention_01m5b7m4fze9qt6caq2cdy1axg`.

In progress: implementation and local acceptance are verified in commits
`2787394` and `8cdd9c5`. The user approved committing the prepared 0.11.0.0
release changes; tagging and publication remain pending. Acceptance criteria 1–6 are
verified; criterion 7 remains open. This request is not completed or ready for
consumer adoption.

The validation confirmed that these are reusable Kioku read capabilities.
Kioku owns memory selection, SQL, projection registration and consumption of the
host's granted access context. Rei retains its HTTP resources, dashboard
composition, Habit terminology and transport cursor context binding.

The plan records these implementation clarifications:

- Fixed metadata has a fixed set of scalar fields, not a fixed byte size.
  Content and individual tags remain complete values.
- Tag pages use numeric positions in the stored tag array, keeping continuation
  keys independent of tag length. Traversal is complete for an unchanged tag
  collection; callers restart after tag replacement. Snapshot-stable traversal
  across replacements is not required.
- Scope-kind filtering intersects the explicit target and existing predicates;
  it never widens an exact global or entity scope. Adding the field to the
  exported `MemoryFilter` constructor requires a PVP major release, provisionally
  0.11.0.0 subject to release-time version checks.
- New query declarations require a supported catalog preview/adoption path
  before normal startup, which rejects catalog drift. Acceptance includes an
  upgrade rehearsal from the exact 0.10.0.0 catalog. Query-registry reconciliation
  alone is insufficient.

## Consumer and verified baseline

The consumers are
`mori://shinzui/rei/plans/255-expose-agent-execution-sessions-memory-schedules-and-review-workflows`
and
`mori://shinzui/rei/plans/254-expose-saved-views-collections-dashboards-and-bounded-reporting-apis`.
The first needs bounded Memory inspection; the second needs complete scalar
counts and the newest active Memory for Today.

This request was checked against the published `kioku-core` 0.10.0.0 source
archive and tag `v0.10.0.0`, commit
`5f4afc872b09d615d1bb8c78369d6912161c550f`, on 2026-10-19.
It supplements [IR-2](add-indexed-session-and-bounded-memory-read-models.md)
with specific Memory resource gaps; it does not reopen the bounded Session
facades delivered by that release.

## Gaps in the 0.10.0.0 baseline

The following gaps motivated the request and are addressed by the local implementation.

- `MemoryRow` contains a growing `Set Text` of tags. Bounding the number of
  Memories does not bound the embedded tag collection. Existing rich point
  reads have the same issue for a fixed HTTP metadata resource.
- Ordinary Memory listing orders priority before creation time. Session-filtered
  listing already orders by creation recency, but the ordinary list's first row
  cannot answer which active Memory was created most recently. Fetching all
  rows and sorting in Rei would defeat the bounded-read contract.
- `MemoryFilter` supports an exact scope or a namespace-wide target, but cannot
  select every Memory of one scope kind, such as Habit anchors, without a
  particular scope reference. Rei needs that predicate before page bounds and
  over the same population used for counts.

## Requested behavior

Expose public fixed Memory metadata pages and point lookup with a scalar tag
count instead of an embedded tag set. Keep each complete content value intact.
Expose the tags as a separate Relay Connection scoped to the parent Memory and
memory space. Continuation keys must not grow with the tag text; large individual
tags remain complete values, not truncated approximations.

Provide a dedicated newest-active metadata lookup, ordered by creation recency
with documented deterministic ties. Respect the explicit `RecallTarget` and
memory space, and return absence for an empty selection. Preserve existing list
orders independently, including priority-based ordinary lists, recency-based
session lists and ascending supersession chains.

Support a scope-kind predicate in metadata paging and scalar counts, composed
with the existing type, status and session predicates. Exact global scope must
remain distinct from namespace-wide scope. Kioku owns the public API shape,
query declarations and any measured index requirement.

Every new read must preserve the 0.10.0.0 contract: check `MemoryRead` before
SQL, return the flat `BoundedReadError`, use the shared maximum page size and
retain structured source/cursor/permission failures. Do not restore the old
nested error protocol or weaken the new authorization checks.

## Acceptance

1. Real PostgreSQL tests traverse more than 100 tags in both directions,
   including tied Memory ordering and a large Unicode tag. Counts describe the
   complete filtered population, not the first page.
2. Metadata contains no growing collection. Archived Memory metadata and tags
   remain inspectable according to the owner's existing retention semantics.
3. A newer active Memory wins the recency query even when an older one has
   higher listing priority; archived and foreign-space rows cannot win.
4. Scope-kind filters apply in SQL before pagination and agree with counts.
   Identical namespaces/scopes in different spaces remain isolated.
5. Permission-denied reads execute no SQL. Missing parents, invalid cursors,
   unavailable models and storage failures remain distinguishable.
6. Any new migration documents its locking behavior; any catalog change ships
   a supported public preview/adoption path from 0.10.0.0.
7. Publish a correctly versioned supported release and consumer migration
   notes before Rei adopts it. An unpublished prototype or local dependency
   override is not completion evidence.

## Implementation evidence and remaining release work

The subsequently authorized implementation provides `getMetadataWithContext`,
`getMetadataPageWithContext`, `getTagsPageWithContext` and
`getNewestActiveMetadataWithContext`, plus SQL-intersected `MemoryFilter.scopeKind`.
Metadata uses a direct scalar decoder rather than loading rich rows and removing tags.
Migration 0015 adds the measured active-recency index and documents its locking.
The exact 0.10.0.0 catalog upgrade is rehearsed through public preview/adoption,
including refusal before adoption and repeated adoption afterward.

All 489 tests pass across the four suites, including real PostgreSQL tag traversal,
ordering, isolation, permission gates, typed failures and the exact schema upgrade.
The build, conventions, migration checks, flake checks, source distributions and
Haddock preparation also pass. ExecPlan 49 records the detailed evidence.

Publish the coherent five-package release and migration notes, verify its immutable
source/tag evidence, and record the actual release here before closing criterion 7.
The prepared 0.11.0.0 candidate is not a published dependency. Rei must not copy
Kioku tables or projections.
