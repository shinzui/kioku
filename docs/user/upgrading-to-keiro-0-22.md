# Upgrading Kioku to the Keiro 0.22 cohort

Kioku 0.12.0.0 moves its five packages together to Keiro 0.22.0.0, Kiroku
Store 0.12.0.0, Store migrations 0.7.2.0, Shibuya Core 0.12.0.0 and its
Kiroku adapter 0.7.0.0. Install released dependencies and rebuild every embedded
host. Historical events, Kioku migrations, catalog bindings, exact-category
subscriptions and explicit host AI capabilities retain their meaning.

The composed migration plan contains 63 entries: 16 Kiroku, 32 Keiro and 15
Kioku. From a fully migrated 0.11 installation, only `kiroku/0016` applies.
It replaces `kiroku.subscriptions.subscriptions_target_kind_check` and
`subscriptions_check`, permitting opt-in namespace bindings, and changes the
Kiroku schema comment through 0016. This upgrade does not enable namespaces.
Workers must stop for migration. Package installation and a source-upgrade
receipt do not apply migrations or establish operational acceptance.

The [acceptance record](../architecture/keiro-0-22-upgrade-acceptance.md)
distinguishes verified candidate evidence from the still-required actual-history
rehearsal. No production installation is activated by this repository change.

## Inventory and retain artifacts

Record the deployed PostgreSQL major, extensions and role/grant configuration;
the CLI and continuous worker's actual supervisor commands; every host embedding
Kioku; and each process's binary/library identity. Discover possible consumers
with `mori registry dependents shinzui/kioku --packages`, then inspect actual
installations. Registry dependencies alone cannot identify a running process.
A composed host must use its complete migration plan and catalog.

Keep a checksummed backup with its source identity and capture time. Supply
three explicit empty scratch database identities: an old twin, candidate twin,
and candidate rebuild clone. They must be disposable and deployment-equivalent;
never substitute the developer database. Keep provider/workspace effects isolated.
Check the archive hash against an independently recorded expected hash before
restoring. Record ownership/grants separately: `--no-owner --no-privileges`
does not prove deployment-role equivalence.

Retain old `kioku`, old `kioku-migrate`, candidate `kioku`, candidate
`kioku-migrate`, the five source archives, and their SHA256s. The fixed source
baseline is `9cd613d5087a08d6625cb266ff09845197b1d3d4`. Build the old project
from its own detached working directory, freeze its dependency solution, and
inspect every local `pkg-src.path`. A relative `--project-file` invocation from
the current checkout does not establish source isolation.

Build the same developer probe against each already-built solution. Run these
inside the corresponding development shell and project working directory:

```bash
python3 /absolute/path/to/candidate/scripts/build-kioku-upgrade-probe.py \
  /absolute/path/to/old-build /absolute/path/to/retained/old-probe
python3 scripts/build-kioku-upgrade-probe.py \
  /absolute/path/to/candidate-build /absolute/path/to/retained/candidate-probe \
  --store-dir /absolute/path/to/candidate-store
```

The helper exposes exact library units from `cache/plan.json`, compiles with
`-threaded`, and writes an adjacent `.identity.json` containing the source,
binary and plan hashes, compiler and selected units. It refuses to overwrite a
retained binary. Keep the probe's identity separate from the shipping CLI.
For interpreted development, use `cabal exec -- runghc -XGHC2024 -threaded`
with the same explicit package IDs; the retained compiled probes are the final
rehearsal instruments. A plain `cabal exec` may hide local libraries.

## Restore, classify and migrate the candidate twin

Set `KIOKU_ARCHIVE`, `KIOKU_OLD_URL`, `KIOKU_NEW_URL`, `KIOKU_REBUILD_URL`,
`KIOKU_OLD_BIN`, `KIOKU_NEW_BIN`, `KIOKU_MIGRATE_BIN`, `KIOKU_OLD_PROBE`,
`KIOKU_NEW_PROBE` and `KIOKU_EVIDENCE` explicitly. URLs must name distinct scratch
databases. Inspect `current_database()`, `current_user`, server/socket and port,
and PostgreSQL version for each before restore. Do not use `pg_restore --clean`.

```bash
shasum -a 256 "$KIOKU_ARCHIVE"
pg_restore --no-owner --no-privileges --exit-on-error \
  --dbname="$KIOKU_OLD_URL" "$KIOKU_ARCHIVE"
pg_restore --no-owner --no-privileges --exit-on-error \
  --dbname="$KIOKU_NEW_URL" "$KIOKU_ARCHIVE"
KIOKU_UPGRADE_CLI="$KIOKU_OLD_BIN" "$KIOKU_OLD_PROBE" \
  read "$KIOKU_OLD_URL" "$KIOKU_EVIDENCE/old-read"
KIOKU_UPGRADE_CLI="$KIOKU_NEW_BIN" "$KIOKU_NEW_PROBE" \
  read "$KIOKU_NEW_URL" "$KIOKU_EVIDENCE/before"
DATABASE_URL="$KIOKU_NEW_URL" "$KIOKU_MIGRATE_BIN" status --json
```

Probe report directories must be empty. `read` writes full sorted rows with
primary keys, the complete ledger and schema dump, exact subscription constraints,
public partitioned Memory/session reads and actual CLI help/keyword recall.
Library reads construct `AppEnv` directly without registering or repairing
metadata. CLI startup is measured separately in `cli-metadata-phase.json`;
its AI configuration is explicitly disabled. Quiesce scratch writers while taking
reports, since table snapshots use separate read-only transactions.

For a complete 62-entry source the reviewed allowance is exactly one applied
ledger row `kiroku/0016`, the two constraint definitions and the Kiroku schema
comment described above. All previous checksums, protected data and source/query
identities must agree. Released catalog registration additionally upserts
`updated_at` on the `kioku-memory` and `kioku-session` rows of
`keiro.keiro_projection_group_cursors`; their `position_basis='append'` and
empty `subscription_names` must remain exact. This is the only startup clock
allowance; it permits no registry repair. The comparator checks the declared
constraint definitions and the remaining full schema, and fails on other changes.
Older archives need an enumerated, separately reviewed allowance for every missing
migration; the one-entry comparator deliberately refuses them.

```bash
DATABASE_URL="$KIOKU_NEW_URL" "$KIOKU_MIGRATE_BIN" up
DATABASE_URL="$KIOKU_NEW_URL" "$KIOKU_MIGRATE_BIN" verify --json
DATABASE_URL="$KIOKU_NEW_URL" "$KIOKU_MIGRATE_BIN" up
KIOKU_UPGRADE_CLI="$KIOKU_NEW_BIN" "$KIOKU_NEW_PROBE" \
  read "$KIOKU_NEW_URL" "$KIOKU_EVIDENCE/after"
python3 scripts/compare-kioku-upgrade.py migration \
  "$KIOKU_EVIDENCE/before" "$KIOKU_EVIDENCE/after"
"$KIOKU_NEW_PROBE" replay "$KIOKU_NEW_URL" "$KIOKU_EVIDENCE/replay"
```

Save both `up` reports: the second applies zero migrations and changes no ledger
or protected data, with only the declared registration-clock effect. Replay
fully audits every native memory/session stream using its real codec/transducer;
zero skipped/rejected native streams or failures are required. These streams
have no state codec or snapshots: there is no state-digest comparison. Foreign
and framework categories are explicitly excluded.

## Paired commands, rebuild and delivery

For every mutation, `KIOKU_UPGRADE_DISPOSABLE=1` and
`KIOKU_UPGRADE_IDENTITY=/path/to/previous-read/identity.json` are mandatory.
The probe compares database name/OID, user, server/socket, port and major against
that separately retained identity. It never creates/drops databases or migrates.
Use a fresh twin for each repeated write rehearsal: the fixed fixture space must
be empty before the write mode starts.

```bash
KIOKU_UPGRADE_DISPOSABLE=1 KIOKU_UPGRADE_CLI="$KIOKU_OLD_BIN" \
  KIOKU_UPGRADE_IDENTITY="$KIOKU_EVIDENCE/old-read/identity.json" \
  "$KIOKU_OLD_PROBE" write "$KIOKU_OLD_URL" "$KIOKU_EVIDENCE/old-write"
KIOKU_UPGRADE_DISPOSABLE=1 KIOKU_UPGRADE_CLI="$KIOKU_NEW_BIN" \
  KIOKU_UPGRADE_IDENTITY="$KIOKU_EVIDENCE/after/identity.json" \
  "$KIOKU_NEW_PROBE" write "$KIOKU_NEW_URL" "$KIOKU_EVIDENCE/new-write"
python3 scripts/compare-kioku-upgrade.py commands \
  "$KIOKU_EVIDENCE/old-write" "$KIOKU_EVIDENCE/new-write"
```

Write mode exercises record/retry, start, turn, await, resume, archive and a
cross-space refusal through public APIs. Compare event types/payloads/metadata,
relative event order, outcomes, rows, timers and CLI output. Only the two session
projection database clocks and explicitly recorded timer scheduling clocks/tokens
are volatile; content, attribution, partition, tags and event payload clocks remain
exact. Failed comparisons retain their reports and require investigation.

Restore the same archive into the rebuild database, migrate with the retained
runner, and capture its `read` report. Then run `rebuild` twice with that
identity and distinct empty report directories. Compare them with
`compare-kioku-upgrade.py rebuild FIRST_REPORT SECOND_REPORT`. The real catalog
runner rebuilds both groups from position zero with distinct run IDs and normal
fences. It records and checks event-derived rows, restores only the four enrichment
fields (`embedding`, `embedding_model`, `dimensions`, `content_hash`) after
matching memory ID, space and content, and preserves authoritative events,
timers, checkpoints and non-target rows. Session projection `created_at` and
`updated_at` are database-clock fields, excluded from semantic rebuild equality.
Rebuild lifecycle/registry clocks are reported separately. No production rebuild
is needed for this dependency cutover.

Run `delivery` on a separate designated candidate clone with pgvector and no
pre-existing due timers; the probe refuses that lane otherwise. It creates one
isolated subscription at the captured head, appends two fixture memories across
an adapter restart, requires exactly two deterministic provider effects plus
stored vectors/checkpoints, then schedules and observes a due timer fire through
the real timer worker's controlled test seam. It never opens the production
embedding subscription, clears shared checkpoints or enables a real provider.
Retain `delivery.json`. This lane's fixture space is separate from host effects;
run paired commands first so delivery events do not enter their comparison.

## Cutover and recovery

The operator signs off the archive/provenance, deployment-major and grants checks,
exact migration diff, old/new probe and shipping identities, paired commands,
replay denominator, two rebuilds and observed delivery. Missing evidence leaves
activation pending. Stop affected workers, pause writers and embedded hosts,
apply the retained composed runner, verify, repeat, start every new Store-linked
host, then resume traffic and observe delivery through the actual supervisor.
Keep namespace subscriptions disabled.

Before new writes, assess the downtime boundary and restore the tested backup
with the identified old artifacts if needed. After new writes, prefer forward
repair or an explicitly reviewed restore with a declared write-loss boundary.
Older Store binaries must not manage `category_namespace` bindings. Do not
rewrite ledgers, reset subscriptions, clear queues or prescribe a down migration.
