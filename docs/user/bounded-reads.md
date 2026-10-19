# Bounded Session and Memory reads

Kioku 0.9.1.0 adds compatible facades in `Kioku.Session` and `Kioku.Memory`.
The candidate is not published yet. This closes the bounded-read portion of
`mori://shinzui/kioku/okf/improvement-requests/concepts/IR-2`, required by
`mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract`.

Every new read takes an authorized `MemoryAccessContext`. Build a `SessionFilter`
or `MemoryFilter` with an explicit `RecallTarget`: `ExactScope (ScopeGlobal ns)`
selects only the unscoped bucket; `NamespaceWide ns` explicitly includes all scopes
in that namespace. No filter can broaden the context's memory space.

`getPageWithContext` takes a `SessionSelection` or `MemorySelection` and the shared
Relay `PageRequest`. The maximum page size is 100; negative or larger requests
return `BoundedPageError` without running collection SQL. Partition and optional
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

Apply additive migration 0014 before starting this reader cohort, reconcile the
read-model registry and use the supported Keiro catalog preview/adoption protocol
for the six new query registrations. They observe existing tables and projection
owners; no rebuild, private registry SQL or copied projection data is required.
Drain old hosts before changing their persisted catalog fingerprint. To roll back,
drain new hosts and adopt the old compiled catalog through the same supported
protocol. Leave additive indexes and historical migration ledger entries intact.

The current composed plan has 61 entries: 15 Kiroku, 32 Keiro and 14 Kioku.
No new upstream migration or dependency-cohort adoption is required.
