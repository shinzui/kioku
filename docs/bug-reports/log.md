# Bundle Update Log

## 2026-09-08
* **Addition**: BUG-2 reports that the default distillation runtime hardcodes the Anthropic API in an interactive-only embedding host, causing missing-key failures and repeated retries. Records the operator policy, current documentation discrepancy, and required regression evidence.

## 2026-08-21
* **Fix**: BUG-1 is fixed by correcting migration 0011, shipping its exact-checksum ledger re-baseline, and adding a composed-plan regression.

## 2026-08-19
* **Confirmation**: BUG-1 is confirmed in-repository: a composed Kioku-plus-host plan reproduces SQLSTATE 42P01 on PostgreSQL 17.10, release history shows the session leak exists in every kioku-migrations release, and a forward RESET search\_path migration makes the same plan succeed.
* **Addition**: BUG-1 reports that migration `0011`'s bare `SET search_path` is session-scoped and never restored, so every migration a consuming host applies after it in the same run resolves unqualified names against the `kiroku` schema. Reported by Rei against `kioku-migrations` 0.4.0.0; a regression from 0.3.0.0, which had no `0011`.
* **Addition**: the bundle is created, on the `coordination.bugReports` profile from okf-profiles v0.10.0.
