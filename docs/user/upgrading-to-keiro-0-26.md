# Upgrading Kioku 0.13 to 0.14

Build hosts, CLI and workers against the five Kioku 0.14.0.0 packages together.
The runtime uses mori://shinzui/keiro/packages/keiro 0.26.0.0,
mori://shinzui/kiroku/packages/kiroku-store 0.13.0.2,
mori://shinzui/shibuya/packages/shibuya-core 0.13.0.1 and
mori://shinzui/kiroku/packages/shibuya-kiroku-adapter 0.8.0.0.

## Database cutover

1. Restore a recent backup into a disposable clone. Inspect `status` using the
   rebuilt runner. A complete Kioku 0.13 database has 64 applied migrations
   and one pending, `keiro/0033`. Hosts with additional components should use
   their composed runner and include their own migrations in the totals.
2. Run `kioku-migrate up` against the clone. Migration 0033 adds nullable
   `traceparent` and `tracestate` columns to timers and `trace_awaited_step`
   to workflows. Existing rows can carry NULL. The migration uses ordinary
   ALTER TABLE locks. Historical checksums still verify.
3. Run `kioku-migrate verify` and `kioku-migrate status`. Expect 65 applied
   entries (17 Kiroku, 33 Keiro, 15 Kioku) and zero pending or unknown entries.
   Run `up` again and check that it applies zero migrations. Exercise a pending
   timer and the embedding subscription in the clone.
4. Quiesce the deployment, take the final backup, and repeat the verified
   migration with the normal runner before starting upgraded workers.

For earlier baselines, first follow the [Kioku 0.13 runbook](upgrading-to-keiro-0-24.md).

## Tracing

The embedding subscription uses the adapter's new `LinkOnly` default.
For an event with a valid incoming traceparent, look for a new processing
trace linked to the writer. Processing span names now use `process <processor>`.
Kioku's timer requests supply absent creation context, and rescheduling a timer
carries forward any context already stored on it.
