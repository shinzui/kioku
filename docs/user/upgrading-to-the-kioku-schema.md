# Upgrading to the kioku schema

Kioku's seven projection tables move out of the `kiroku` schema and into a schema of their own.
`kiroku.kioku_memories` becomes `kioku.memories`, and so on for sessions, turns, L1 watermarks,
consolidation decisions, scenes, and personas.

The event store does not move. Kioku still appends to the host application's kiroku streams,
still uses the host's connection settings, and still creates no second event store. What changes
is that the relations Kioku alone reads and writes are no longer sitting inside another
component's namespace, distinguished only by a name prefix that nothing enforces. See
[ADR-10](../adr/projections-live-in-the-kioku-schema.md) for why.

This is a **migration-first upgrade with a short planned outage**. Read the rollout below before
you start: there are no compatibility views, and restarting the old binary is not a rollback.

## Preflight an applied 0.4.x `0011`

Kioku 0.4.0.0 and 0.4.1.0 shipped migration `0011-kioku-memory-space-partition.sql` with a
session-scoped `SET search_path` that was not restored. The corrected payload resets the host's
configured default before committing, so its exact SHA-256 changes from
`eee9cd252b32b563c50f8457596347fff1b2e4d3ea4dafe5b45043e991624192` to
`6c83d3f01f784d0d9395953d5bb1763b8eea6cd9439073df42f79775a85197a9`.

After taking and verifying the backup required below, run this once if the database already
applied `kioku/0011-kioku-memory-space-partition` under either 0.4.x release, and run it before the
corrected binary's first `up` or `verify`:

```bash
psql "$PG_CONNECTION_STRING" --set=ON_ERROR_STOP=1 \
  --file=kioku-migrations/ledger-fixups/2026-08-19-rebaseline-0011-checksum.sql
```

The script matches only an applied `kioku/0011` row carrying the withdrawn checksum and is safe
to run twice. A zero-row notice means `0011` is pending, already corrected, or has an unexpected
checksum; determine which before proceeding. If pg-migrate uses a custom `LedgerConfig`, adapt the
script's explicit `pgmigrate.migrations` lookup to that ledger schema without broadening its
component, migration, status, or checksum predicate. Never delete the ledger row or mark the
migration pending.

Fresh databases and databases where `0011` is still pending need no special action. A database
following [the Codd cutover runbook](upgrading-to-pg-migrate.md) also has no `0011` row before its
first corrected `up`, because that import ends at Kioku `0010`.

## What moves

| Before | After |
| --- | --- |
| `kiroku.kioku_memories` | `kioku.memories` |
| `kiroku.kioku_sessions` | `kioku.sessions` |
| `kiroku.kioku_turns` | `kioku.turns` |
| `kiroku.kioku_l1_watermarks` | `kioku.l1_watermarks` |
| `kiroku.kioku_consolidation_decisions` | `kioku.consolidation_decisions` |
| `kiroku.kioku_scenes` | `kioku.scenes` |
| `kiroku.kioku_personas` | `kioku.personas` |

The prefix is dropped because the schema now supplies the namespace it stood in for. Index and
constraint names are deliberately **not** renamed: `kioku_memories_space_scope_idx` and its
siblings keep their names, because PostgreSQL carries them along with the table by object
identity and renaming them would churn the catalog for nothing.

Nothing else in the database changes. The kiroku event tables, the `keiro` framework tables, the
`pgmigrate` ledger, and the `vector` extension all stay exactly where they are.

## What the migration does

`kioku/0012-relocate-projections-to-kioku-schema` creates the schema if it is absent and then
moves each table with `ALTER TABLE … SET SCHEMA kioku` followed by `ALTER TABLE … RENAME TO`.
Both are catalog metadata edits: the table keeps its object id, so its rows, indexes,
constraints, owner, and table grants come with it and nothing is rebuilt or copied. A
multi-gigabyte memories table moves as fast as an empty one.

The migration accepts exactly two starting states and refuses every other one:

1. all seven `kiroku.kioku_*` tables present and no `kioku.*` target name occupied — it moves them;
2. no `kiroku.kioku_*` name occupied and all seven `kioku.*` tables present — it does nothing.

Anything else — a half-finished move, a missing source table, or a host relation already using one
of the target names — raises before a single table moves:

```text
ERROR:  refusing to relocate Kioku projections: expected either 7 ordinary kiroku.kioku_* tables
with no kioku.* target relation, or no kiroku.kioku_* relation with 7 ordinary kioku.* tables;
found 6 source relation(s) of which 6 ordinary, and 1 target relation(s) of which 1 ordinary
```

The migration runs inside pg-migrate's transaction, so after a refusal the catalog is exactly
what it was before the attempt. Fix the cause and re-run `kioku-migrate up`; never hand-edit the
ledger or the released SQL.

## Read-model identities move with the tables

Keiro's `keiro_read_models` registry stores a logical name, a version, and a shape hash — but no
physical relation name. So the only way to stop a binary from the wrong side of this migration
from issuing SQL at tables that are no longer there is to advance the declared version:

| Read-model family | Before | After |
| --- | --- | --- |
| memory | v2 / `kioku-memory-v2` | v3 / `kioku-memory-v3` |
| session | v4 / `kioku-session-v4` | v5 / `kioku-session-v5` |
| turn | v2 / `kioku-turn-v2` | v3 / `kioku-turn-v3` |

The guard cuts both ways, which is the point. Between the migration committing and the registry
being reconciled, every read fails closed with `ReadModelStaleSchema` rather than reaching a
missing relation. And after reconciliation, an old binary still declaring session v4 is refused
by the same check — it cannot serve a single stale query.

`kioku-migrate up` calls `Kioku.ReadModel.reconcileReadModelRegistry` for you immediately after
applying migrations. **A host that applies the plan as a library must call it itself** before
serving traffic; see [Library API](library-api.md#applying-migrations-as-a-library-reconcile-the-read-model-registry). Do not
hand-write registry SQL.

## Rollout

1. **Stop every writer.** Application processes, `kioku worker`, and any other migration runner.
   Kioku inserts and upserts into these relations, so a writer that is still up during the move
   will fail, and one that comes back up on the old binary will write to the wrong place.
2. **Back up, and verify the backup restores.** Before any new writes land, restoring it is the
   only rollback available.
3. **Check the migration role can do the work**: create schema `kioku` (or it already exists and
   the role owns it), and `ALTER` all seven tables.
4. **Apply the migrations.**

   ```bash
   DATABASE_URL="$PG_CONNECTION_STRING" cabal run kioku-migrate -- up
   DATABASE_URL="$PG_CONNECTION_STRING" cabal run kioku-migrate -- status
   ```

   `status` must report all 55 migrations applied (Kiroku 11, Keiro 31, Kioku 13), with nothing
   pending or failed.
5. **Grant schema usage if your runtime role is not the owner.** Table grants moved with the
   tables; usage on a schema that did not exist before is a separate privilege.

   ```sql
   GRANT USAGE ON SCHEMA kioku TO your_runtime_role;
   ```
6. **Reconcile the registry** — automatic under `kioku-migrate up`, explicit for library
   embedders.
7. **Start the new binary**, then verify (below).

## Verify

```bash
psql "$PG_CONNECTION_STRING" --set=ON_ERROR_STOP=1 <<'SQL'
SELECT table_schema, table_name
FROM information_schema.tables
WHERE (table_schema = 'kioku' AND table_name IN
       ('memories', 'sessions', 'turns', 'l1_watermarks',
        'consolidation_decisions', 'scenes', 'personas'))
   OR (table_schema = 'kiroku' AND table_name LIKE 'kioku\_%' ESCAPE '\')
ORDER BY table_schema, table_name;
SQL
```

Expected, and only this:

```text
 table_schema |       table_name
--------------+-------------------------
 kioku        | consolidation_decisions
 kioku        | l1_watermarks
 kioku        | memories
 kioku        | personas
 kioku        | scenes
 kioku        | sessions
 kioku        | turns
```

The event store should be untouched in the same breath:

```sql
SELECT to_regclass('kiroku.events') IS NOT NULL AS events_present,
       to_regclass('kiroku.streams') IS NOT NULL AS streams_present;
```

And the registry should be at the new identities:

```sql
SELECT name, version, shape_hash, status
FROM keiro.keiro_read_models
WHERE name LIKE 'kioku-%'
ORDER BY name;
```

## Adopting Kioku into an existing Kiroku database

If your database's pg-migrate ledger contains the Kiroku component and nothing else, running
`kioku-migrate up` adopts it in place. pg-migrate identities are component-qualified, so it
recognises those rows as its own first component, verifies their checksums, and skips them — no
Kiroku migration re-executes and no ledger row is rewritten. Only the missing Keiro and Kioku
components apply, against the event store you already have.

If your ledger also contains **your own** migration component, standalone `kioku-migrate` will
refuse it as an unknown migration, and that refusal is deliberate: running an incomplete plan
against your history is worse than stopping. Compose one complete application plan instead —
import `Kioku.Migrations.kiokuMigrations` alongside Kiroku's, Keiro's, and your own component,
and run that. See [Library API](library-api.md).

## Rollback

Once `0012` commits, restarting the old binary is **not** a rollback. That binary still names
`kiroku.kioku_*`, and there are no compatibility views to catch it — Kioku writes these
relations, so a read-only alias would not serve, and a writable one would be a second physical
interface with its own migrations and its own failure modes.

- **Before any new writes:** restore the verified pre-migration backup.
- **After new writes:** prefer a reviewed forward repair that preserves them. If you must move
  the tables back, do it as a *new* migration — never by editing `0012` or the pg-migrate ledger,
  and never by marking a migration applied by hand.

Do not move the `vector` extension as a recovery shortcut. It is a database-wide object your host
may share, and this upgrade never touched it.

## See also

- [ADR-10: Kioku shares the host's event store but owns its projections in a kioku schema](../adr/projections-live-in-the-kioku-schema.md)
- [ADR-6: The memory-space partition is a column, not a schema per space](../adr/the-partition-is-a-column-not-a-schema.md) —
  one package-owned schema is not one schema per tenant
- [ADR-2: Namespace organizes memory; memory space isolates it](../adr/namespace-is-not-a-security-boundary.md) —
  `kioku` is an ownership boundary in the catalog, never an authorization one
- [Troubleshooting](troubleshooting.md)
