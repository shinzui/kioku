# Bounded Session and Memory reads

This guide applies to Kioku 0.12.0.0. It retains the 0.10 and 0.11 source and catalog migration
steps for hosts crossing those releases. A fully migrated 0.11 host keeps the same reader API
and catalog at 0.12; only the [Keiro 0.22 cohort upgrade](upgrading-to-keiro-0-22.md) is needed.

Kioku 0.9.1.0 added compatible facades in `Kioku.Session` and `Kioku.Memory`;
0.10.0.0 gates them on `MemoryRead` and flattens their errors, which changes their
0.9.1.0 result types. 0.9.1.0 was never published to Hackage.
This closes the bounded-read portion of
`mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2`, required by
`mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract`.

Every bounded read takes a `MemoryAccessContext` and checks that it grants
`MemoryRead` before any SQL runs; a context minted only for `MemoryRecord` or
`MemoryForget` is refused with `BoundedReadNotPermitted MemoryRead`, even when the
page request is also invalid. This differs from the older space-first reads and from
`recall`, which trust the host to have requested `MemoryRead`. Every failure is one
flat `BoundedReadError` (re-exported by `Kioku.Session` and `Kioku.Memory`):
`BoundedReadNotPermitted`, `BoundedReadFailed ReadModelError` or
`BoundedReadInvalidPage BoundedPageError`.

Build a `SessionFilter` or `MemoryFilter` with an explicit `RecallTarget`:
`ExactScope (ScopeGlobal ns)` selects only the unscoped bucket; `NamespaceWide ns`
explicitly includes all scopes in that namespace. No filter can broaden the
context's memory space. `SessionFilter.status` is a typed `SessionStatus`;
`startedSince` is inclusive and `startedUntil` exclusive.

`getPageWithContext` takes a `SessionSelection` or `MemorySelection` and the shared
Relay `PageRequest`. The maximum page size is `maxBoundedPageSize` (100); negative
or larger requests return `BoundedReadInvalidPage` without running collection SQL.
A zero-size page is valid Relay and returns only page info. Partition and optional
filters apply before page bounds. Hosts bind the collection, parent, filters and
space in their transport cursor envelope; Kioku uses the existing Relay codec.

Sessions sort by started time descending and ID ascending. Continuation ancestors
(including the selected session) and direct delegation children sort ascending.
Memory lists retain native priority ascending, created time descending, ID ascending;
a session-filtered Memory list retains created time descending and ID ascending.
Supersession chains include both directions, sort by created time and ID ascending,
and terminate even for corrupt cyclic lineage. Turns sort by index and ID ascending.

`getCountsWithContext` returns complete scalar status counts over the same selection,
independently of page size. `getRelationsWithContext` returns Session existence,
complete turn count, ancestor count and direct delegation-child count. A foreign
Session is absent, with zero relation counts. `getTurnsPageWithContext` returns
separately traversable turns. `SessionFilter.subjectRef` permits bounded zero/one/many
subject resolution without claiming that a subject is globally unique.

`archiveWithContextChanged` retains existing permission, partition and input checks.
Its `(MemoryId, Bool)` receipt reports whether this command appended. A matching
repeat or losing concurrent command reports `False`; conflicting input retains `MemoryConflict`.
The old archive entry point continues returning `MemoryId`.

For an existing legacy-space host, replace `archive payload` with
`archiveLegacyChanged payload` and consume `Right (memoryId, changed)` while retaining
the payload's attribution unchanged, including `UnattributedPrincipal`. The bridge
uses the same committed append receipt: `False` means this command appended no fact
and was accepted as a repeat; typed refusals and storage failures remain failures.
It accepts only `legacyMemorySpaceId` and performs no authentication or authorization,
so hosts keep their existing trusted boundary. No schema, catalog or dependency
migration is required for this bridge.

`archiveLegacyChanged` is deprecated from introduction, lives only with `archive`,
and will be removed in a separately announced breaking change after affected consumers
have a real context-based migration. New and identity-migrated hosts use
`archiveWithContextChanged` with a host-vouched-for actor. Having no directory does
not prevent that, but inventing a process principal solely to obtain a receipt changes
the attribution claim. See [the migration example](library-api.md#writing-memories-kiokumemory).

Apply additive migration 0014 before starting this reader cohort. It builds eight
indexes on `kioku.sessions`, `kioku.turns` and `kioku.memories` inside the migration
transaction, so writes to those tables wait until each build finishes; schedule it
with that in mind on a large database. Then reconcile the
read-model registry and use the supported Keiro catalog preview/adoption protocol
for the six new query registrations. They observe existing tables and projection
owners; no rebuild, private registry SQL or copied projection data is required.
Drain old hosts before changing their persisted catalog fingerprint. To roll back,
drain new hosts and adopt the old compiled catalog through the same supported
protocol. Leave additive indexes and historical migration ledger entries intact.

The 0.10.0.0 composed plan had 61 entries: 15 Kiroku, 32 Keiro and 14 Kioku.
The 0.11.0.0 plan had 62 entries: 15 Kiroku, 32 Keiro and 15 Kioku.
The current 0.12.0.0 plan has 63: 16 Kiroku, 32 Keiro and 15 Kioku.
The 0.11 reader additions themselves require no upstream migration; the 0.12 dependency upgrade
appends `kiroku/0016` without changing this catalog.

## Fixed Memory metadata (0.11.0.0)

`Memory.getMetadataWithContext context memoryId` returns `Right Nothing` for an
absent or foreign-space ID. `Memory.getMetadataPageWithContext context selection
request` returns a `Connection MemoryMetadata`. Metadata retains every scalar
field, including complete content, identity, lineage, status and timestamps, but
replaces the tag collection with `tagCount :: Int64`. SQL computes the count;
Kioku never fetches or decodes the tag array for these operations. Fixed fields
bound the number of decoded rows, not content bytes or database execution cost.
Archived, superseded and merged Memories remain inspectable.

The four added query registrations change the catalog fingerprint without
changing projection shape. Reconciliation alone does not adopt that change.
Drain old hosts and run administrative adoption **before** `withNoopAppEnv`:
its startup registration refuses the old fingerprint before its callback runs.
The following recipe uses only public APIs and retains both the outer Store
failure and the typed adoption failure. It is exercised as compiled code by
`Kioku.ProjectionCatalogSpec`.

```haskell
import Data.List.NonEmpty qualified as NonEmpty
import Keiro.Projection.Catalog (CatalogInventory (..), InventoryGroup (..))
import Keiro.ReadModel.Rebuild
  ( CatalogAdoptionPlan (..), GroupAdoptionClass (..)
  , previewCatalogAdoption, adoptCatalogGroups )
import Kioku.App (AppEnv (..), noopTracer, runAppIO, withNoopAppEnv)
import Kioku.ProjectionCatalog (kiokuCatalogInventory, kiokuProjectionCatalog)

-- settings :: ConnectionSettings, supplied by the host.
tracer <- noopTracer
let admin = AppEnv {connectionSettings = settings, tracer, metrics = Nothing}
previewResult <- runAppIO admin (previewCatalogAdoption kiokuProjectionCatalog)
-- Inspect previewResult before proceeding. Keep Left StoreError as an error.
-- Under the same drained-host maintenance window:
case previewResult of
  Left storeError -> reportStoreFailure storeError
  Right preview -> do
    let affected =
          [ group.rebuildGroupId
          | group <- kiokuCatalogInventory.inventoryGroups
          , any (\(identity, state) -> identity == group.rebuildGroupId &&
                  case state of AdoptionSliceChanged _ _ -> True; _ -> False)
                preview.groupStates
          ]
    case NonEmpty.nonEmpty affected of
      Nothing -> startNormally
      Just groups -> do
        adopted <- runAppIO admin (adoptCatalogGroups kiokuProjectionCatalog groups)
        case adopted of
          Left storeError -> reportStoreFailure storeError
          Right (Left adoptionError) -> reportAdoptionFailure adoptionError
          Right (Right _) -> startNormally
-- startNormally = withNoopAppEnv settings runHost
-- The report functions are host error handlers, never success/absence fallbacks.
```

For 0.10.0.0 to 0.11.0.0, only the `kioku-memory` group changes. Preview and
review that group selection; do not select unrelated host groups. This example
uses a Kioku-only catalog for a Kioku-only runtime. A host composing catalogs
must use its complete validated catalog for preview/adoption and derive the
corresponding inventory from it. Restrict the reviewed group selection to the
affected Kioku-owned groups; do not automatically adopt every changed host group.
Adoption preserves Memory rows and events and is safe to repeat.
On rollback drain new hosts and adopt using the old compiled catalog before
starting the old binary. Never edit registry/catalog rows to bypass drift.

The public types (effect constraints omitted here are `IOE :> es, Store :> es`):

```haskell
getMetadataWithContext :: MemoryAccessContext -> MemoryId
  -> Eff es (Either BoundedReadError (Maybe MemoryMetadata))
getMetadataPageWithContext :: MemoryAccessContext -> MemorySelection -> PageRequest
  -> Eff es (Either BoundedReadError (Connection MemoryMetadata))
getTagsPageWithContext :: MemoryAccessContext -> MemoryId -> PageRequest
  -> Eff es (Either BoundedReadError (Maybe (Connection MemoryTag)))
getNewestActiveMetadataWithContext :: MemoryAccessContext -> MemoryFilter
  -> Eff es (Either BoundedReadError (Maybe MemoryMetadata))
```

## Tags, kind selection and recency

`Memory.getTagsPageWithContext context memoryId request` returns
`Right Nothing` for an absent or foreign parent and `Right (Just connection)`
for a visible parent, including one with no tags. It retains archived tags.
`MemoryTag` contains `ordinal :: Int64` and the complete `value :: Text`.
The maximum is 100 and zero-size pages return no edges. Invalid sizes/cursors
are errors even for missing parents. Read permission is checked first.

Tags sort by stored JSON array position ascending. The projection currently
serializes a `Set Text` in ascending order; the paging contract is the array's
order, not a new locale-sensitive text order. Cursors contain the numeric
ordinal, so even very large tag values have bounded continuation keys. Restart
from the beginning after replacing tags. These cursors do not identify a snapshot
and may point at different values after mutation. Hosts that require stale-cursor
rejection must bind their own collection revision in the transport envelope.

`MemoryFilter` gains a fifth constructor argument, `scopeKind :: Maybe ScopeKind`:

```haskell
-- Before 0.11.0.0:
-- MemoryFilter target status memoryType sessionId
-- Preserve the previous selection:
MemoryFilter target status memoryType sessionId Nothing
-- Every intention reference within the namespace:
MemoryFilter (NamespaceWide (Namespace "rei")) Nothing Nothing Nothing
  (Just (ScopeKind "intention"))
```

Kind, status, type and session filters all intersect the explicit target before
pagination or counting. An exact global target plus an entity kind is empty;
an exact entity with a different requested kind is empty. Counts cover the whole
intersection, including rows beyond the first page. `ScopeKind` remains opaque
host vocabulary.

`Memory.getNewestActiveMetadataWithContext context filters` returns the newest
active metadata by creation time descending and Memory ID ascending, ignoring
priority. It intersects the optional status filter: `Nothing` and
`Just MemoryActive` can match, while an explicitly non-active status yields
`Right Nothing`. Empty selections also yield `Right Nothing`. General lists keep
their priority order, session lists their recency order, and supersession chains
their ascending creation order. All ties use ascending Memory ID.

Authorized missing data, page validation, stale/unregistered read models and
storage errors remain distinct. Read model failures use `BoundedReadFailed`;
page failures use `BoundedReadInvalidPage`. `runAppIO` retains infrastructure
failures in its outer `Either StoreError`; never turn these into absence or an
empty connection. The lower-level read-model declarations are infrastructure
seams; use the public facade for permission-checked reads.


Apply migration `0015-active-memory-recency.sql` before starting 0.11.0.0. It adds
an active-only index on memory space, namespace, creation time descending and ID
ascending. The 40,000-row multi-space fixture showed the old recency path sorting
8,000 namespace matches or 4,000 kind matches. The new index can stop in recency
order; kind filtering can still examine multiple entries before finding a match.
No kind-specific recency index is required by the measured fixture. Metadata pages
continue using the priority-first index from 0014.

The index uses ordinary `CREATE INDEX IF NOT EXISTS` inside the migration
transaction, taking a SHARE lock on `kioku.memories`: reads continue, but writes
wait until the migration transaction commits. Schedule a maintenance window sized
for the table. No event or projection data is rewritten and no ledger fixup is
needed. The exact previous fourteen-entry Kioku manifest prefix upgrades by
applying only 0015; repeating migration and catalog adoption preserves rows.
