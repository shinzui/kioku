# Bundle Update Log

## 2026-09-08
* **Addition**: the bundle is created, on the `coordination.capabilities` profile from
okf-profiles v0.9.0, cataloguing what Kioku provides to a consumer today.
* **Addition**: CAP-1 through CAP-16 record the released surface as of 0.5.2.0 — the memory and
session aggregates, scopes and scope identity, memory-space isolation, hybrid recall and its
vector channel, the embedding worker, the three distillation levels and their timers, workspace
mirroring, the event codecs, the migration component and its registry reconciliation, the CLI,
and the published migration test-support sublibrary.
* **Addition**: CAP-17 and CAP-18 record host-owned AI execution and leased deferred-timer
recovery as `since: unreleased` — both exist on the default branch only, after
`feat(ai): enforce host-owned execution policy through Baikai` and
`feat(timers): resume deferred work with Keiro 0.16 leased claims`.
* **Addition**: CAP-19 records the one-time Codd migration-history import as `deprecated`,
replaced by the native pg-migrate component in CAP-13.
