# Upgrading Kioku to the Keiro 0.24 cohort

Kioku 0.13.0.0 uses [Keiro](mori://shinzui/keiro) 0.24.0.0,
[Kiroku Store](mori://shinzui/kiroku/packages/kiroku-store) 0.13.0.1,
[Store migrations](mori://shinzui/kiroku/packages/kiroku-store-migrations)
0.7.3.0 and the [Kiroku adapter](mori://shinzui/kiroku/packages/shibuya-kiroku-adapter)
0.7.0.1. All five Kioku packages move together. Rebuild embedded hosts, CLI
and workers against this cohort; replace any `==0.7.2.0` migration constraint
in consumer projects with `==0.7.3.0`.

The composed plan contains **64 entries: 17 Kiroku, 32 Keiro and 15 Kioku**.
From a complete Kioku 0.12 installation, only `kiroku/0017` applies. It creates
one immutable store identity and an empty compaction ledger, and advances the
Kiroku schema comment through 0017. It leaves event tables, stream positions,
subscription bindings, checkpoints and Kioku projections unchanged. Historical
migration bytes and checksums are unchanged; no ledger fixup or query-catalog
adoption is required for a valid 0.12 installation. Installing the package does
not apply this migration or compact any events.

Older installations must first account for the [0.12 transition](upgrading-to-keiro-0-22.md),
including worker pauses for 0013/0014, the 0015 index build, namespace cutover
in 0016 and any earlier [catalog adoption](bounded-reads.md).

## Rehearsal and cutover

1. Record the current binaries and dependency plan. Back up the database and
   restore it into a disposable clone. Use the host's existing composed runner
   if it adds components beyond Kioku; the counts here describe Kioku alone.
2. Against the clone, inspect `status` and `verify` with the new binary. A complete
   0.12 baseline has 63 applied entries and only `kiroku/0017` pending. Investigate
   checksum mismatches or unknown migrations before proceeding.
3. Save exact snapshots of events and metadata, streams and memberships,
   subscription bindings and checkpoints, Kioku projections and old ledger rows.
   Apply the new plan and reconcile read models using the normal runner:

   ```bash
   DATABASE_URL="$CLONE_DATABASE_URL" cabal run kioku-migrate -- up
   DATABASE_URL="$CLONE_DATABASE_URL" cabal run kioku-migrate -- status
   DATABASE_URL="$CLONE_DATABASE_URL" cabal run kioku-migrate -- verify
   ```

4. Require 64 applied entries, no pending or unknown entries and successful
   checksum verification. Compare the saved data and old ledger rows exactly.
   Confirm one identity row, an empty ledger and the schema comment:

   ```sql
   SELECT * FROM kiroku.store_identity;
   SELECT count(*) FROM kiroku.event_compactions;
   SELECT obj_description('kiroku'::regnamespace, 'pg_namespace');
   ```

5. Run `up` again. Require no newly applied migration, unchanged identity and
   ledger, and unchanged application data. Exercise append/read, keyword recall
   and the host's normal worker paths against the clone.
6. Schedule the persistent cutover after accepting the rehearsal. Quiesce hosts
   and workers, take the final backup, apply and verify through the same composed
   runner, then restart the rebuilt hosts and workers together.

The automated migration suite covers the released 63-entry baseline, exact data
and checkpoint preservation, identity creation, checksum verification and repeat
no-op. A restored clone containing the deployment's real history is separate
operator evidence. The older `compare-kioku-upgrade.py` comparator is specific to
the 62-to-63 transition and must not be used to approve this transition.

## Source compatibility

Consumers with direct upstream integrations must follow the Keiro 0.22-to-0.23
and 0.23-to-0.24 upgrade edges owned by mori://shinzui/keiro (project-relative
`blueprints/keiro-upgrade/migrations/`; artifact-level URI pending). Exhaustive
Store interpreters, Store errors and Kiroku observers gain compaction cases.
Bounded projection status items expose v1 fields through `status`; direct
`AppHooks` construction supplies `durableConsumers`, while updates of
`emptyAppHooks` retain the default. Kioku's application API, wire encodings,
catalog bindings and AI capability policy are unchanged.

Compaction adoption and its privileges require a separate reviewed workflow.
This upgrade needs no destructive maintenance privileges. For rollback, retain
the new identity and ledger and do not delete migration history; if database
rollback is required, restore the validated backup into a replacement database
and restart the matching binary cohort.
