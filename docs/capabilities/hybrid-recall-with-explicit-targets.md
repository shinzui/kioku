---
title: "Hybrid recall with explicit targets and RRF ranking"
type: Capability
description: "Fuse Postgres full-text search with pgvector similarity by Reciprocal Rank Fusion, re-rank by recency, priority, and confidence, and trim to a character budget — against a target that says exactly how wide the search is, inside a memory space the request cannot widen."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-5
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-core
  - kioku-api
interface:
  - Kioku.Recall
  - Kioku.Api.Recall
  - Kioku.Recall.Capability
requires:
  - CAP-1
  - CAP-3
  - CAP-4
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/RecallSpec.hs
    proves: "RRF favors a memory present in both channels, the signal blend maps recency, priority, and confidence as documented, and the character budgets truncate and stop before the total cap."
  - kind: test
    resource: kioku-core/test/Kioku/RecallSqlSpec.hs
    proves: "Each target compiles to the rows it names and no others, archived memories are never candidates, and degenerate queries — empty, punctuation-only, unbalanced quotes — do not fail."
  - kind: test
    resource: kioku-core/test/Kioku/RecallTargetSpec.hs
    proves: "Every target and strategy returns its own rows in its own space, the public entry point answers all three targets, and each target's plan is bounded by the partition and its own scope clause."
  - kind: test
    resource: kioku-api/test/Kioku/Api/RecallSpec.hs
    proves: "The exact global bucket is neither the whole namespace nor an exact entity, the wire discriminator separates them, and an unknown or missing kind is an error rather than a default."
  - kind: guide
    resource: docs/user/recall.md
    proves: "The three targets, the scoring formula and its constants, how each target reaches SQL, and the migration from the pre-target RecallRequest."
  - kind: module
    resource: kioku-core/src/Kioku/Recall.hs
    proves: "The recall entry point, the execution planner, the fusion and budget helpers, and the unranked scope scans."
---

# Hybrid recall with explicit targets and RRF ranking

Recall answers "what does this agent know that is relevant here?" over the active
[memories (CAP-1)](event-sourced-memory-records.md) of one
[scope or namespace (CAP-3)](host-agnostic-memory-scopes.md). A call names two separate
things, and keeping them separate is the point. The **target** says what to
search and comes from the caller; the **memory space** says whose memories those are and
comes from the [access context (CAP-4)](memory-space-isolation.md). Widening a target
therefore never widens the tenancy.

```haskell
data RecallTarget
  = ExactScope MemoryScope   -- ScopeGlobal ns is the global bucket, exactly
  | NamespaceWide Namespace  -- every scope in the namespace, entity rows included
```

Three strategies run over that target: `keyword` (Postgres FTS via
`websearch_to_tsquery`), `embedding` (pgvector cosine distance), and `hybrid`, the
default, which runs both. Up to 50 candidates come from each channel; the two lists are
fused by memory id, each keeping its channel rank, and scored:

```text
score = rrf(ftsRank) + rrf(vecRank)
      + 0.10 · recencyDecay(createdAt)     -- exp decay, 30-day half-life
      + 0.15 · priorityWeight(priority)    -- priority 0 = maximum boost
      + 0.05 · confidenceWeight(confidence)
```

with `rrf(rank) = 1 / (60 + rank)`. The metadata terms can **outweigh** the fusion
terms — the two best possible RRF contributions total about `0.0328` against up to
`0.30` from recency, priority, and confidence — so they are not tie-breakers. They also
cannot conjure a candidate: a memory must enter the keyword or vector pool before
priority can affect it.

**Each target compiles to its own statement.** Every one starts from
`status = 'active'`, `memory_space_id = $2`, `namespace = $3` and then adds its own scope
clause, or none for a namespace-wide search. There are nine in all — three channels times
three clauses, generated from one template per channel. The alternative, a single
predicate in which a NULL parameter silently dropped the scope filter, made "the global
bucket" and "the whole namespace" the identical query with the identical parameters, so
the exact global bucket could not be asked for at all and no artifact could show a
reviewer which meaning a call had.

Results are trimmed to `maxResults` (1–100) and then to a character budget: 2000 per
memory, 12000 in total, applied after ranking.

## Shape

```haskell
case mkRecallQuery (NamespaceWide (Namespace "mori")) "commit style" Hybrid 8 of
  Left invalid -> ...
  Right query  -> recall embeddingModel capability context query
```

```bash
kioku recall "how do we work here" --namespace-wide mori
kioku recall "release script" --scope mori:repo:proj_01h4... --strategy keyword
```

## Limits

- The RRF constant, half-life, signal weights, candidate pool size, and character
  budgets are internal tuning constants in `Kioku.Recall`, not configuration.
- A high `--limit` does not guarantee that many hits: the character budget is applied
  after ranking and can cut the list short.
- The unranked scope scans (`getActiveByScope`, `getGlobal`, `getActiveInNamespace`) are
  a separate vocabulary with no ranking and no embedding, and `getActiveByScope` reads
  `ScopeGlobal ns` as the exact global bucket.
- `RecallRequest` and `legacyRecall` remain as a deprecated pair preserving the
  pre-target reading, in which `ScopeGlobal ns` meant namespace-wide. They are removed
  only in a later PVP-breaking release, once every known dependent compiles against
  `RecallTarget`.
