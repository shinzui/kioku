# Bundle Update Log

## 2026-08-06
* **Addition**: ADR-5 records that a pre-memory-space agent label is kept legacy-marked and an event that named no actor stays unattributed, so Kioku never manufactures a principal.
* **Addition**: ADR-4 records that the memory-space partition is enforced by the aggregate's own guard rather than a read-model precheck, and that reads stay unpartitioned until the projections carry the column.
* **Addition**: ADR-1 records that Kioku owns memory data but never identity or authorization,
and that it takes no build dependency on any identity service.
* **Addition**: ADR-2 records that namespaces and scopes organize memory while only an explicit
memory space isolates it.
* **Addition**: ADR-3 records that legacy data is backfilled into the explicit `kioku_legacy`
space, so absence of a partition never means unrestricted access.
