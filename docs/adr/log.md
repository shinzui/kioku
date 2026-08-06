# Bundle Update Log

## 2026-08-06

* **Addition**: ADR-1 records that Kioku owns memory data but never identity or authorization,
  and that it takes no build dependency on any identity service.
* **Addition**: ADR-2 records that namespaces and scopes organize memory while only an explicit
  memory space isolates it.
* **Addition**: ADR-3 records that legacy data is backfilled into the explicit `kioku_legacy`
  space, so absence of a partition never means unrestricted access.
