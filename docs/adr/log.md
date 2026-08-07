# Bundle Update Log

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
