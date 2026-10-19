---
id: 49
slug: expose-fixed-memory-metadata-tag-pages-and-recency-queries
title: "Expose fixed Memory metadata, tag pages and recency queries"
kind: exec-plan
created_at: 2026-10-19T23:24:23Z
intention: "intention_01m5b7m4fze9qt6caq2cdy1axg"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-19T23:24:23Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-19T23:41:08Z
      mode: "implement"
      note: "Implement fixed metadata, tag pagination and recency reads with upgrade and release evidence"
---

# Expose fixed Memory metadata, tag pages and recency queries

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Follow `agents/skills/exec-plan/PLANS.md` and its ADR and provenance procedures.


## Purpose / Big Picture


Give hosts permission-checked Memory inspection without loading every tag, and let them ask for the newest active Memory or all Memories of a scope kind without loading and sorting collections themselves. A caller will page fixed-field metadata and tags separately, obtain full-population scalar counts, and distinguish an absent Memory from a failed read. Complete content and individual tag values remain intact.

This implements [IR-6](../improvement-requests/expose-fixed-memory-metadata-tag-pages-and-recency-queries.md). Validation found the request valid and consistent with Kioku's ownership boundaries, with the clarifications below. Implementation follows the milestones below. The IR's publication requirement remains a completion criterion, not a claim that a release has happened.


## Progress


- [x] 2026-10-19: Fixed metadata point/page reads select scalar fields directly, traverse 106 tied Memories forward/backward, and preserve old-catalog data through public adoption before startup. The initial bounded/catalog suite passed all 21 tests on ephemeral PostgreSQL.
- [x] 2026-10-19: Separate ordinal tag pages traverse 205 complete values forward/backward, retain large Unicode values, keep cursor size independent of tag length, and distinguish absent, foreign, empty and archived parents. Focused PostgreSQL tests pass.
- [x] 2026-10-19: Kind intersections, full counts and deterministic newest-active metadata pass the priority/recency counterexample, status/type/session/exact-target matrix, and space isolation tests. All 30 bounded/catalog/reconciliation cases and the previous-manifest upgrade case pass. Migration 0015 adds the measured active recency index.
- [ ] Failure, performance, upgrade and consumer documentation checks pass, and all five packages ship in a supported release with migration notes.

Implementation is in progress on the current branch. The exact twenty-five-query 0.10.0.0 historical fixture retains its original fingerprint independently of the expanded catalog; the older nineteen-query rehearsal remains intact.


## Surprises & Discoveries


2026-10-19: With 40,000 rows across four spaces, existing indexes made namespace recency sort 8,000 matches (9.097 ms, 1,827 shared buffers) and kind recency sort 4,000 (9.358 ms, 4,007 buffers). The added active-only index removed both sorts: namespace touched four buffers (0.028 ms), kind five (0.059 ms, one nonmatching entry skipped). Metadata paging already used the priority index (38 rows, 41 buffers). Timings are illustrative fixture measurements, not latency guarantees; no planner switches forced index choice.

2026-10-19: The current manifest does not declare a profiled ADR bundle. ADR-15 follows the established local metadata/file convention without adding a profile or inventing a cross-repository handle.


## Decision Log


2026-10-19: Accept IR-6 as a Kioku-owned library extension. Rei-specific HTTP routes, Habit vocabulary, transport cursor envelopes and dashboard composition stay with the host. A scope kind remains the existing opaque `ScopeKind`, not an enumeration of Rei entities.

2026-10-19: Interpret “fixed metadata” as a fixed set of scalar fields with no growing collection, not a constant byte-size response. Content and individual tags can be large. The contract bounds rows transferred and decoded, not all database work or payload bytes.

2026-10-19: Page tags by their existing JSON array ordinality, using Relay's `int8Key`. This gives a unique bounded-size key without truncating text, hash-collision assumptions, a new projection or a data migration. Order is stored array order. Continuation applies to an unchanged tag collection; restart after tag updates. Hosts own transport context/revision binding, as they do for existing Kioku pages. Snapshot-stable paging across concurrent tag replacements is not an added requirement.

2026-10-19: Add optional `scopeKind` to `MemoryFilter`, and apply it as an intersection with the explicit target. This deliberately changes an exported constructor and requires a PVP major version; use 0.11.0.0 if it is still the next unpublished version at release time. Do not silently reinterpret exact global scope or introduce a second filter vocabulary just to avoid that change.


2026-10-19: Add only `0015-active-memory-recency.sql`, an active-only `(memory_space_id, namespace, created_at DESC, memory_id ASC)` index. Measured namespace and kind lookups both use it without sorting; no kind-specific index is justified. The composed plan grows from 61 to 62 entries. The migration builds under a SHARE lock in the migration transaction, preserving reads while writers wait for commit. The previous fourteen-entry prefix upgrades with one additive step and unchanged Memory rows.


## Outcomes & Retrospective



## Context and Orientation


Kioku is an event-sourced library: commands append Memory events, and an inline projection updates `kioku.memories` in the same transaction. A projection is a queryable copy of event state. A read model is a named query with a registered schema identity. A projection catalog declares the tables, their owners and the queries; its persisted fingerprint prevents incompatible code from starting against a different declaration.

`kioku-core/src/Kioku/Memory/ReadModel.hs` owns `MemoryRow`, event projection SQL, `MemoryFilter`, `MemorySelection`, page/count queries and their decoding. `MemoryRow.tags` is a `Set Text` decoded from JSONB; `encodeTags` serializes the set into the stored array. `MemorySelection` is either a filtered population or a supersession chain, the connected history of memories that replaced one another. Both existing pages and point lookup select the entire tags value. Archiving changes status without removing content or tags.

`kioku-core/src/Kioku/Memory.hs` is the consumer facade. Its bounded methods use `gatedRead` and `gatedPage` from `kioku-core/src/Kioku/Pagination.hs` before invoking Keiro. `MemoryRead` must be granted before any query or registry SQL. `BoundedReadError` is flat: permission denial, a structured `ReadModelError`, or an invalid page. A `Connection` is Relay's page result containing nodes, continuation cursors and page information; `PageRequest` specifies size, direction and an optional cursor. The shared maximum is 100, and zero-size pages are supported. The lower-level read-model declarations, like existing declarations, are infrastructure seams; the permission promise applies to public facade calls.

The IR's three gap claims match the source, with one ordering qualification. Ordinary filtered Memory pages use priority ascending, creation time descending and ID ascending. Session-filtered pages already use creation time descending and ID ascending. Supersession chains use creation time ascending and ID ascending. A dedicated newest-active operation is still needed because a general list's first row is not a universal recency answer. Preserve all three list orders.

`MemoryFilter` currently contains target, optional status, optional type and optional session ID. `recallTargetSnippet` distinguishes namespace-wide, exact global bucket and exact entity scope. `MemoryCounts` already provides full scalar status counts, so extend the shared SQL predicate rather than adding a duplicate counting mechanism. “Scope-kind” means all entity scopes with the given kind within the requested target, regardless of their references.

Relevant architectural decisions were consulted: [ADR-1](../adr/kioku-owns-memory-not-identity.md) places authorization decisions in hosts and requires Kioku to consume the granted context; [ADR-2](../adr/namespace-is-not-a-security-boundary.md) makes memory space the isolation boundary; [ADR-8](../adr/an-explicit-recall-target-replaces-the-overloaded-scope.md) distinguishes exact scopes from namespace-wide targets; [ADR-9](../adr/each-recall-target-gets-its-own-statement.md) makes each target's SQL meaning explicit; [ADR-13](../adr/catalog-application-projections-not-framework-timers.md) keeps query ownership in Kioku's catalog; and [ADR-14](../adr/haskell-and-cli-conventions-are-executable-contracts.md) defines the GHC 9.12/GHC2024 and source-convention baseline. No architectural reversal is needed. ADR-13's historical nineteen-query inventory is now twenty-five; use current source and tests for the baseline.

`kioku-core/src/Kioku/ProjectionCatalog.hs` binds all queries to their existing projection owners. `kioku-core/test/Kioku/ProjectionCatalogSpec.hs` pins the current fingerprint, `catalog-v7:8cce393084799278ee21a4aba3356e1f88d34c630e8c1b97aa8743e543616956`, and rehearses a prior release's adoption. `kioku-core/src/Kioku/ReadModel.hs` reconciles query schema identities, but reconciliation alone does not adopt catalog drift. `kioku-core/src/Kioku/App.hs` registers the catalog inside `withNoopAppEnv` before calling its continuation. Consequently, an adoption recipe inside that continuation cannot repair an old catalog. `runAppIO`, the exported `AppEnv` constructor and `noopTracer` allow an explicit administrative recipe before normal startup without private registry SQL.

`kioku-core/test/Kioku/BoundedReadSpec.hs` exercises real commands and reads through migrated ephemeral PostgreSQL. Its fixture comes from `kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs`; it does not require a production database. Migration 0014, under `kioku-migrations/migrations/`, already adds priority-based namespace/scope indexes and a recency index for session reads. The current composed migration plan has 61 entries, including 14 Kioku entries; the root README's older count is not the baseline for this work.

The consumers are `mori://shinzui/rei/plans/255-expose-agent-execution-sessions-memory-schedules-and-review-workflows` and `mori://shinzui/rei/plans/254-expose-saved-views-collections-dashboards-and-bounded-reporting-apis`. Their checked-out text confirms bounded Memory resources and Today composition. Mori could identify the owning project but did not resolve these recently added plan handles during validation; keep the canonical handles rather than substituting ambiguous paths.


## Plan of Work


### Milestone 1: Fixed metadata and a real upgrade path


In `kioku-core/src/Kioku/Memory/ReadModel.hs`, add `MemoryMetadata` with every scalar field of `MemoryRow`, replacing `tags` with `tagCount :: Int64`. Select `jsonb_array_length(tags)::bigint` directly and decode that scalar. Do not fetch `MemoryRow` and strip its tags in Haskell. Add metadata-by-ID and metadata-page read models, queries and explicit SQL column lists. Factor selection SQL so rich pages and metadata pages share predicates and recursive chain semantics while selecting different columns; recursive metadata queries must not carry tags through the chain. Keep the cycle-safe `UNION` behavior and memory-space predicate on both the seed and recursive joins.

Expose `getMetadataWithContext` and `getMetadataPageWithContext` through `kioku-core/src/Kioku/Memory.hs`, with the signatures below. Point reads return `Right Nothing` for absent and foreign-space IDs and include retained archived/superseded/merged rows. Preserve existing rich APIs and their order. Register the new query models against the existing memories target and owner; no table-shape version bump is required merely to select a different set of columns.

Before expanding the remaining variants, extend `kioku-core/test/Kioku/ProjectionCatalogSpec.hs` with an exact 0.10.0.0 historical catalog, preserving its pinned fingerprint and all twenty-five baseline query declarations. The existing nineteen-query historical fixture tests an older transition and must not be mistaken for 0.10.0.0. Begin the new test with the old catalog registered on a migrated database, write a Memory through the old-compatible projection, and then prove that ordinary new startup refuses drift. Run public preview/adoption before new startup, register the new catalog, and retrieve that existing Memory through the new metadata facade. Check content, identity, timestamps and tag count survive unchanged. Keep the historical fixture exact as further query models are added.

Document an executable administrative recipe in `docs/user/bounded-reads.md` using `noopTracer`, an explicitly constructed `AppEnv`, `runAppIO`, `previewCatalogAdoption`, `adoptCatalogGroups` and `kiokuProjectionCatalog`. Preview first, select the affected Kioku rebuild groups from catalog inventory, adopt under a drained-host maintenance window, then register/start normally. Use a Kioku-only catalog only for a Kioku-only runtime; a host with a composed catalog must use its complete validated catalog and select the affected groups. Reuse the dependency's public types and retain errors. Prove the documented recipe as compiled test code. No new general-purpose migration CLI is required.

This milestone is accepted when metadata point/page tests and the upgrade test pass on real PostgreSQL, including more than 100 memories with tied timestamps and priorities and a Memory with a large tag collection. The metadata decoder must never receive the tag array.


### Milestone 2: Separate tag pages


Add `MemoryTag` with `ordinal :: Int64` and `value :: Text`, and a parent-scoped tags page query in `kioku-core/src/Kioku/Memory/ReadModel.hs`. Select the parent by both memory space and Memory ID, then expand only that parent's tags with `jsonb_array_elements_text(tags) WITH ORDINALITY`. Use ascending ordinality and Relay's `int8Key` as the unique sort key, with the existing `boundedPage` helper. The public result is `Maybe (Connection MemoryTag)`: `Nothing` means no visible parent; `Just` with zero edges means an existing parent with an empty page. Preserve archived parent visibility.

Check parent existence without calling the rich point reader or decoding its content/tags; perform the existence/page work within the read-model transaction. Validate the page request before returning an absence so malformed requests do not become apparent success. Permission denial takes precedence over all of these steps. Keep `gatedPage`'s flattening by placing the `Maybe` result inside the inner page result. Register the tags model under the existing memories owner; the JSON array remains the authoritative tag projection.

Extend `kioku-core/test/Kioku/BoundedReadSpec.hs` with 205 distinct tags, an empty tag set and a large Unicode tag, created through Memory commands. Traverse forward and backward with sizes below 100, verify no omissions/duplicates on an unchanged collection, and compare full values to the written set. Show that a cursor for a long tag is the same length as one for a short tag at a comparable ordinal. Cover empty, missing, foreign-space and archived parents and zero/negative/oversized pages. Replace tags through the existing command and demonstrate that a fresh traversal and metadata tag count reflect the replacement. Document the restart-after-update contract explicitly.


### Milestone 3: Scope-kind counts and newest active metadata


Add `scopeKind :: Maybe ScopeKind` to `MemoryFilter` in `kioku-core/src/Kioku/Memory/ReadModel.hs`. Update constructor call sites and examples, using `Nothing` to retain prior selection. Share the `scope_kind = parameter` predicate among rich pages, metadata pages and counts, before ordering and page bounds. It intersects with the target: an exact global bucket plus a requested entity kind is empty; an exact entity scope with a different kind is empty. Neither mismatch widens the target. Keep type/status/session conjunctions and return the existing `MemoryCounts` over the full selected population.

Add `getNewestActiveMetadataWithContext` with a dedicated read model using the same filter predicate plus `status = 'active'`, ordered by `created_at DESC, memory_id ASC LIMIT 1`. It accepts `MemoryFilter`; its active predicate intersects the optional status filter, so `Nothing` or `Just MemoryActive` can match and an explicitly non-active status yields absence. This avoids an undocumented override or a second near-identical filter type. It never uses priority, never sorts a fetched collection, and returns `Right Nothing` for an empty selection. Add its query binding to the memories owner.

Prove that an older priority-1 Memory wins the ordinary list while a newer priority-100 Memory wins recency; an even newer archived Memory and a foreign-space Memory win neither recency query. Equal creation times resolve by ascending Memory ID. Cover exact global, namespace-wide, exact entity and kind-only populations with multiple references of the same kind, combinations with type/status/session, and counts larger than a page. Preserve session-filtered and supersession list orders.

Inspect `EXPLAIN (ANALYZE, BUFFERS)` for namespace-wide and scope-kind recency plus metadata pages on a representative multi-space fixture. Existing priority-first indexes do not automatically satisfy recency ordering. If the measured access path warrants an index, add an active-only partition/namespace/creation-time/ID index, with a scope-kind variant only when supported by evidence. Use `just new-migration <slug>` to allocate and append a migration; document transaction and locking behavior in `docs/user/bounded-reads.md` and test the old-to-new migration path. Do not prescribe a new table, index or upstream upgrade without evidence. A bounded result is not a promise of constant database execution cost.


### Milestone 4: Failure contracts, release and consumer handoff


Complete the failure matrix in `kioku-core/test/Kioku/BoundedReadSpec.hs` and catalog/reconciliation suites. For each new public read and extended count path, use a Store interpreter that fails if invoked to prove permission-denied reads execute zero Store operations, including malformed pages and missing-parent inputs. Add authorized cases distinguishing absence, malformed cursor, page-size failure, unavailable/stale read model and storage failure. Preserve the existing outer Store failure channel where applicable; do not catch infrastructure failures and turn them into absence or an empty Connection. Within the read result, keep the existing flat `BoundedReadError` protocol.

Finalize `docs/user/bounded-reads.md` and `docs/user/library-api.md` with complete consumer examples, filter migration, order/tie rules, retained archive visibility, parent absence, page maximum, tag mutation limits and upgrade/recovery instructions. Update `docs/user/README.md` where necessary. Distill durable decisions about fixed-field reads and tag cursor semantics into the relevant ADRs or a new ADR using `agents/skills/exec-plan/ADR.md`, inspecting the current profile contract before writing. Do not change unrelated historical decisions just to refresh counts.

Use the repository release workflow in `agents/skills/release/SKILL.md` when implementation reaches publication. All five packages share a version; the proposed exported `MemoryFilter` change requires a major PVP bump. Update each package's changelog and Cabal version/internal bounds, root release notes and relevant manifest version metadata. Recheck the registry and upstream tags to avoid colliding with an intervening release. Verify source distributions and publish all five packages, the matching tag and release notes through the supported workflow. Record registry URLs and the release commit as completion evidence. Rei adoption remains downstream work and must use the published release, not a local override.


## Concrete Steps


Run commands from the repository root, `/Users/shinzui/Keikaku/bokuno/kioku`. Use the existing Nix development shell when compiler/PostgreSQL tools are not already available:

```bash
nix develop
cabal build all
cabal test kioku-core:kioku-test --test-show-details=direct --test-options='-p "Bounded facade"'
cabal test kioku-core:kioku-test --test-show-details=direct --test-options='-p "ProjectionCatalog"'
```

Verify the runner reports the intended cases rather than zero selected tests. Focused tests must report all selected cases passed and exercise ephemeral PostgreSQL. The first representative proof is an old-catalog Memory write followed by public adoption and new metadata read; perform it before finishing tag and recency variants.

After implementation, run the repository-wide gates once on the final candidate:

```bash
cabal test all --test-show-details=direct
bash scripts/check-haskell-conventions.sh
nix fmt
git diff --check
cabal sdist all
```

If formatting changes source, rerun affected checks. Tests require PostgreSQL binaries and extensions supplied by the development environment and must use disposable fixtures. Do not run migration or adoption experiments against the user's live database.

For dependency evidence, use Mori first; current project handles include:

```bash
mori registry search relay-pagination
mori registry show shinzui/relay-pagination --full
mori registry docs shinzui/relay-pagination
mori registry show shinzui/keiro --full
mori registry docs shinzui/keiro
```

Read the returned sources rather than guessing APIs. Before changing bounds, compare registry metadata with Hackage and upstream release tags. This plan needs no dependency-bound change based on the verified baseline.

Every implementation commit uses Conventional Commits and includes both trailers:

```text
ExecPlan: docs/plans/49-expose-fixed-memory-metadata-tag-pages-and-recency-queries.md
Intention: intention_01m5b7m4fze9qt6caq2cdy1axg
```


## Validation and Acceptance


IR acceptance 1 and 2 are satisfied by complete forward/backward traversal of 205 tags and more than 100 tied Memories, unchanged full content/Unicode values, scalar tag counts, and retained archived metadata/tags. Inspect the public metadata type and SQL decoder to establish that no growing collection is selected or returned; a rich row followed by projection in Haskell fails acceptance even if the output looks right.

IR acceptance 3 and 4 are satisfied when the recency/priority counterexample and deterministic ties pass, the filter combinations agree across pages and counts, and identical scopes in different memory spaces cannot leak. Include a fixture where matching kind rows occur beyond the first unfiltered page so filtering after pagination would fail observably. Counts must describe the complete intersection, including zero counts for incompatible exact-scope/kind requests.

IR acceptance 5 requires a zero-Store-operation denial test in addition to real database behavior. For authorized reads, prove missing parent (`Right Nothing`), empty tag collection (`Right (Just connection)`), malformed cursor, unavailable model and storage failure are distinct. Add negative, 101-row and zero-row requests to every new paged surface. Hosts retain their existing responsibility to bind opaque Relay cursors to resource, parent, filters and space; a syntactically valid cursor is not an authorization credential.

IR acceptance 6 requires the pinned 0.10.0.0 catalog test, public preview/adoption before startup, repeated adoption/registration without data changes, and read success afterwards. Keep the old-startup refusal as a test. If a migration is added, test upgrade from the previous manifest prefix and document actual lock behavior; otherwise record that no schema migration is required. Do not equate query-registry reconciliation with catalog adoption.

IR acceptance 7 requires published source archives for all five packages, matching release/tag evidence and migration notes that show the changed `MemoryFilter` constructor and the four new facade operations. A passing local build alone does not complete this plan. There is no additional requirement to implement Rei routes in this repository.


## Idempotence and Recovery


Tests create disposable databases, and repeated read calls have no mutation effect. Preserve all shipped migration files and checksums. New migrations are append-only and must tolerate rerunning through the migration runner. Failed transactions should leave the prior state intact; retain failure evidence and retry the failing focused check after correction.

Catalog adoption is an explicit maintenance operation. Drain old hosts, preview with the new compiled catalog, adopt the affected groups through the public lifecycle, then start new hosts. Rerunning preview/adoption/registration must preserve Memory rows and events. If the deployment must roll back, drain new hosts and use the old compiled catalog's supported adoption operation before restarting the old binary; leave any additive indexes and migration ledger entries intact. Never delete or hand-edit catalog/registry rows to bypass a refusal.

A tag cursor identifies a position in the current stored array, not a snapshot. Restart paging after tag replacement; hosts that need rejection of stale transport cursors must bind their own collection revision as documented by their API policy. Do not promise that an old ordinal will still identify the same tag after mutation.


## Interfaces and Dependencies


Add the following facade operations in `kioku-core/src/Kioku/Memory.hs`, with `MemoryMetadata` and `MemoryTag` declared in and re-exported from `kioku-core/src/Kioku/Memory/ReadModel.hs`:

```haskell
getMetadataWithContext :: (IOE :> es, Store :> es)
  => MemoryAccessContext -> MemoryId
  -> Eff es (Either BoundedReadError (Maybe MemoryMetadata))

getMetadataPageWithContext :: (IOE :> es, Store :> es)
  => MemoryAccessContext -> MemorySelection -> PageRequest
  -> Eff es (Either BoundedReadError (Connection MemoryMetadata))

getTagsPageWithContext :: (IOE :> es, Store :> es)
  => MemoryAccessContext -> MemoryId -> PageRequest
  -> Eff es (Either BoundedReadError (Maybe (Connection MemoryTag)))

getNewestActiveMetadataWithContext :: (IOE :> es, Store :> es)
  => MemoryAccessContext -> MemoryFilter
  -> Eff es (Either BoundedReadError (Maybe MemoryMetadata))
```

`MemoryMetadata` retains `memorySpaceId`, `memoryId`, `agentId`, optional `sessionId`, `namespace`, optional `scopeKind` and `scopeRef`, `memoryType`, complete `content`, `priority`, `confidence`, `status`, optional `supersededBy` and `supersedes`, `createdAt` and `updatedAt` with the existing `MemoryRow` field types, plus `tagCount :: Int64`. `MemoryTag` has only the numeric ordinal and complete text value. Use strict record fields and explicit deriving strategies. The new `MemoryFilter.scopeKind` uses the existing `Kioku.Api.Scope.ScopeKind`; update positional constructions explicitly.

Use four new registered read models, with names `kioku-memory-metadata-by-id`, `kioku-memory-metadata-page`, `kioku-memory-tags-page` and `kioku-memory-newest-active-metadata`. They observe the existing memories target. Update the catalog inventory assertion from twenty-five to twenty-nine once all four are present, calculate the new fingerprint from the validated catalog and preserve the historical fingerprint independently. Existing count and rich page models retain their names.

The pagination dependency is `mori://shinzui/relay-pagination/packages/relay-pagination-hasql`; its `SortSpec`, `KeyColumn`, `int8Key` and `paginate` support ordinal keyset paging. A keyset page selects rows before or after the last sort key, rather than materializing the collection in Haskell. The lifecycle dependency is `mori://shinzui/keiro/packages/keiro`, whose public `Keiro.ReadModel.Rebuild` exports preview/adoption and typed failures. No new dependency is proposed.

On 2026-10-19, direct Hackage preferred-version checks and upstream tags confirmed Kioku 0.10.0.0, Relay Hasql 0.1.1.2 (tag commit `4f8cfbaf0bc82394482df9e30233a5eafca1ddf7`) and Keiro 0.21.0.0 (tag commit `e6ef560b0a8db0dc091d0f8d7da1bb08c29155be`). These match the relevant current Cabal bounds. Mori's Keiro registry still showed older dependency constraints, so those were not used to choose versions. Revalidate releases at implementation time if any compatibility decision changes.
