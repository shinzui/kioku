# Bounded Session and Memory reads

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
repeat or concurrent winner reports False; conflicting input retains `MemoryConflict`.
The old archive entry point continues returning `MemoryId`.

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

The current composed plan has 61 entries: 15 Kiroku, 32 Keiro and 14 Kioku.
No new upstream migration or dependency-cohort adoption is required.
