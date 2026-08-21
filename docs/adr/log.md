# Bundle Update Log

## 2026-08-21
* **Update**: ADR-4 records that distillation validates the supplied decision before work: L1 preflights distill, record, and forget permissions, while L2/L3 require a context for the requested timer space with distill permission; provider success cannot retarget work or bypass the action check.

## 2026-08-19
* **Update**: ADR-10 records the narrow exception to released-migration immutability: a payload whose successful execution is itself unsafe may be corrected as an explicit breaking change only with known withdrawn/corrected checksums, equivalent or converged durable outcomes, and a guarded operator re-baseline. ExecPlan 32 applies the rule to migration `0011`'s leaked session `search_path` while preserving the Codd evidence for `0001` through `0010`.

## 2026-08-18
* **Update**: ADR-5 records that `LegacyPrincipal` and `UnattributedPrincipal` are decode-side only and unreachable through the memory-space write API, that `KnownPrincipal` asserts a principal was vouched for rather than that a directory vouched — the embedded-host escape hatch makes the host itself accountable for the ref it supplies — and that a deployment needing to tell a host-asserted principal from a directory-resolved one carries that in the `PrincipalRef` kind prefix rather than in `RecordedPrincipal`. Rejects a trusted context constructor carrying a whole `RecordedPrincipal`, because it would make both historical constructors writable forward and misdescribe new events as pre-memory-space or unattributed.

## 2026-08-07
* **Update**: ADR-10 records what the acceptance run proved and the trap it leaves behind: the relocation preserves every table OID, so "where the table is" and "where the `vector` type resolves from" stay two separate questions, and a suite run outside the dev shell skips every case that would notice them being conflated.
* **Addition**: ADR-10 records that Kioku keeps sharing the host's Kiroku event store while every relation it owns moves into a dedicated `kioku` schema, that the seven tables drop their now-redundant name prefix but keep their index and constraint names, that the qualification is explicit rather than a search-path effect, and that the read-model version bump is what makes an old binary fail closed instead of querying relations that moved.
* **Update**: ADR-2's recall example is restated in the explicit vocabulary: the documented return-everything target is --namespace-wide, not a bare global scope.
* **Update**: ADR-8's last two consumers of the overloaded scope are migrated: the command line gives each target its own flag and refuses the ambiguous bare-namespace --scope rather than re-reading it, and L1's recall-backed merge-candidate finder now targets the exact session scope so it agrees with the scan-based finder beside it.
* **Addition**: ADR-9 records that each recall target compiles to its own SQL scope clause across nine statements rather than to one parameterised predicate with nullable scope columns, that memory\_space\_id leads all nine, and that the existing partition-first index serves all three bounds.
* **Update**: ADR-8's intermediate state is over — the exact global bucket executes, RecallExactGlobalUnsupported is gone, and its consequences now point at ADR-9.
* **Update**: ADR-2's requirement that recall never span memory spaces is now carried by the type: ADR-8's RecallTarget names breadth while the memory space comes from the authorizing context.
* **Addition**: ADR-8 records that an explicit RecallTarget replaces the overloaded scope, that the memory space comes from the authorizing context rather than the target, and that the pre-target request survives one release as a deprecated wrapper.

## 2026-08-06
* **Addition**: ADR-7 records that the memory-space partition reaches the filesystem as a sanitised digest rather than the space id, that the pre-partition mirror tree becomes read-only history, and that a space belongs on a trace and never on a metric label.
* **Addition**: ADR-6 records that the memory-space partition is a column and an unconditional predicate on every read-model statement, not a schema, database, or row-level-security policy per space.
* **Update**: ADR-3's backfill and ADR-4's read-side gap are both closed by the read-model partition migration; their status and consequences now say so.
* **Addition**: ADR-5 records that a pre-memory-space agent label is kept legacy-marked and an event that named no actor stays unattributed, so Kioku never manufactures a principal.
* **Addition**: ADR-4 records that the memory-space partition is enforced by the aggregate's own guard rather than a read-model precheck, and that reads stay unpartitioned until the projections carry the column.
* **Addition**: ADR-1 records that Kioku owns memory data but never identity or authorization,
and that it takes no build dependency on any identity service.
* **Addition**: ADR-2 records that namespaces and scopes organize memory while only an explicit
memory space isolates it.
* **Addition**: ADR-3 records that legacy data is backfilled into the explicit `kioku_legacy`
space, so absence of a partition never means unrestricted access.
