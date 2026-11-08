# Kioku 0.13 consumer upgrade runbook

This reference ships with the blueprint. Paths and commands below refer to the
consuming project, which may embed Kioku without having a Kioku checkout.

## Source validation

1. Keep all directly consumed Kioku packages at 0.13.0.0. Inspect the actual
   Cabal plan after updating bounds. Require the used packages from
   mori://shinzui/keiro at 0.24.0.0,
   mori://shinzui/kiroku/packages/kiroku-store at 0.13.0.1,
   mori://shinzui/kiroku/packages/kiroku-store-migrations at 0.7.3.0 and, when used,
   mori://shinzui/kiroku/packages/shibuya-kiroku-adapter at 0.7.0.1.
2. Replace the old `kiroku-store-migrations ==0.7.2.0` project constraint with
   `==0.7.3.0`. Keep existing application-owned migration components in the plan.
3. Confirm the entailed Keiro edges have handled used exhaustive Store/error/
   observer matches, projection status wrappers and operational hooks. Follow
   the consumer's build/test commands with exhaustive-pattern checking. Use its
   Nix shell when provided so PostgreSQL and extensions match its fixtures.
4. Rebuild embedded hosts, CLI and workers against one cohort. Native Kioku
   encodings, query catalogs and AI configuration do not change for 0.12 hosts.

## Database classification and rehearsal

Inspect persistent databases read-only and hand the cutover commands to their
operator. A complete Kioku 0.12 baseline has 63 applied migrations, with only
`kiroku/0017` pending in the new plan. The target has 64 entries: 17 Kiroku,
32 Keiro and 15 Kioku. A host with extra components has additional entries;
compare component IDs rather than imposing the Kioku-only total on that host.

The operator backs up the database and restores a disposable clone. Save exact
events/envelopes, streams, memberships, subscription bindings, checkpoints,
Kioku projections and existing ledger rows before applying the new plan.
Use the consumer's existing composed runner. A host using Kioku's standalone
runner can rehearse with:

```sh
DATABASE_URL="$CLONE_DATABASE_URL" cabal run kioku-migrate -- status
DATABASE_URL="$CLONE_DATABASE_URL" cabal run kioku-migrate -- verify
DATABASE_URL="$CLONE_DATABASE_URL" cabal run kioku-migrate -- up
DATABASE_URL="$CLONE_DATABASE_URL" cabal run kioku-migrate -- status
DATABASE_URL="$CLONE_DATABASE_URL" cabal run kioku-migrate -- verify
```

Require only `kiroku/0017` newly applied from the complete 0.12 baseline, no
pending/unknown entries or checksum issues, and exact preservation of the saved
data and old ledger rows. Confirm one row in `kiroku.store_identity`, no rows in
`kiroku.event_compactions`, and schema comment
`Managed by pg-migrate component kiroku through 0017`. Repeat `up` and require
no new migration and unchanged identity, ledger and application data. Exercise
append/read, recall and normal worker paths on the clone.

Older baselines must first account for intervening migrations, worker pauses,
index builds and catalog adoption through their applicable upgrade edges.
Historical checksums do not change in this edge; do not fabricate ledger rows
or apply an unrelated checksum fixup.

## Operator handoff

Report the resolved cohort, build/test results, baseline and pending IDs,
clone rehearsal evidence and remaining cutover steps. After accepting the
rehearsal, the operator quiesces hosts/workers, takes the final backup, applies
and verifies through the same runner, then restarts rebuilt hosts and workers
together. Source completion and Seihou receipts do not establish database
completion. Compaction adoption and destructive privileges are separate work.
