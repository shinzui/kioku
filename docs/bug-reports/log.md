# Bundle Update Log

## 2026-08-19
* **Confirmation**: BUG-1 is confirmed in-repository: a composed Kioku-plus-host plan reproduces SQLSTATE 42P01 on PostgreSQL 17.10, release history shows the session leak exists in every kioku-migrations release, and a forward RESET search_path migration makes the same plan succeed.
* **Addition**: BUG-1 reports that migration `0011`'s bare `SET search_path` is session-scoped and never restored, so every migration a consuming host applies after it in the same run resolves unqualified names against the `kiroku` schema. Reported by Rei against `kioku-migrations` 0.4.0.0; a regression from 0.3.0.0, which had no `0011`.
* **Addition**: the bundle is created, on the `coordination.bugReports` profile from okf-profiles v0.10.0.
