---
type: Improvement Request
title: Filter ranked recall by tag and memory type
description: Let a recall query restrict its candidates to memories carrying given tags or memory types before ranking, so a caller asking for the best matches within a subset gets a full result page instead of filtering an unrestricted page after the fact.
generated:
  by: claude-code/claude-fable-5-2
  at: "2026-11-19T05:58:53Z"
timestamp: 2026-11-19T05:58:53Z
requestId: IR-9
status: proposed
origin: mori://shinzui/mori-kaizen
dependencies:
  - ref: mori://shinzui/kioku/okf/improvement-requests/concepts/IR-6
    kind: soft
    reason: The tag pages and scope-kind filtering IR-6 added to the unranked reads are the precedent for the filter vocabulary.
acceptanceCriteria:
  - id: AC-1
    statement: A `RecallQuery` can carry a set of required tags and a set of allowed memory types; only active memories that carry every required tag and one of the allowed types are candidates on every channel, keyword and vector alike.
    verification: A PostgreSQL test stores memories that match the query text with and without a tag, recalls with the tag required, and asserts that only tagged memories return under keyword, vector and hybrid strategies.
  - id: AC-2
    statement: The filter applies before the result limit, so a query limited to N returns N matching memories whenever N exist.
    verification: With twenty matching memories of which five carry the tag and a limit of five, recall returns those five.
  - id: AC-3
    statement: A query with no filter behaves and performs as today, and the filtered query is served by an index.
    verification: The existing recall suites pass unchanged, and the plan of the filtered keyword query uses an index on tags.
  - id: AC-4
    statement: The CLI and the wire format expose the filters, and the recall guide documents them.
    verification: "`kioku recall --tag` and `--type` return the filtered result, and the JSON encoding of a filtered query round-trips."
---

# Improvement Request: Filter ranked recall by tag and memory type

## Status

- **Status:** proposed (2026-11-19)
- **Origin:** `mori://shinzui/mori-kaizen`, raised while planning
  `mori://shinzui/mori-kaizen/plans/3-remember-friction-observations-in-kioku-and-recall-them-across-repositories`
- **Owner of the build:** `shinzui/kioku`

## Context

mori-kaizen (`mori://shinzui/mori-kaizen`) records one memory per friction entry and tags it with
the entry's attributes: `kind:tooling`, `impact:blocked`, `status:logged`, `origin:<project>`.
To find entries that may share a cause with a new one, it recalls similar text and wants to
restrict the candidates, for example to entries still untriaged or to one kind of surface.

## What exists today

Verified on 2026-11-19 against Kioku 0.13.0.0 at `ac4393d`.

- `Kioku.Api.Recall.RecallQuery` has four fields: `target`, `query`, `strategy` and
  `maxResults`. The target selects a namespace or an exact scope; nothing selects by tag or by
  memory type.
- A caller that wants a subset recalls an unrestricted page and filters the hits itself. When
  the subset is small relative to the scope, most of the page is discarded and matching
  memories ranked below the limit are never seen, so the caller raises the limit and still has
  no guarantee.
- `mori://shinzui/kioku/okf/improvement-requests/concepts/IR-6` added tag pages and scope-kind
  filtering to the unranked reads; ranked recall was outside its scope.

## Requested change

Add the two filters to `RecallQuery` as the acceptance criteria describe.

## Non-goals

- Boolean tag expressions; all-of for tags and any-of for types covers the case.
- Filtering by confidence or recency.

## Workaround

Encode the attribute into the scope instead of a tag, which only works for one attribute, or
over-fetch and filter in the caller, which is what mori-kaizen's memory plan does.
