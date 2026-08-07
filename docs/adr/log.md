# Bundle Update Log

## 2026-08-07
* **Addition**: ADR-9 records that each recall target compiles to its own SQL scope clause across nine statements rather than to one parameterised predicate with nullable scope columns, that memory_space_id leads all nine, and that the existing partition-first index serves all three bounds.
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
