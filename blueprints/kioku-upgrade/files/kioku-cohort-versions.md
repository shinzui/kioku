# Kioku release cohort map

Which upstream releases each Kioku version pairs with. Kioku's five published
packages share one version and are released together, so a row describes the
whole set.

Use this to answer "what else moves when I move Kioku?" — not to decide what to
edit. What to edit is in the edge prompt.

## Runtime cohort

| Kioku | `keiro` / `keiro-core` | `kiroku-store` | `keiki` | `shibuya-core` | `shibuya-kiroku-adapter` | `baikai` |
|---|---|---|---|---|---|---|
| 0.5.1.0 | `^>=0.14.0.0` | `^>=0.8.0.0` | `^>=0.9.0.0` | `^>=0.9.0.0` | `^>=0.5.1.1` | `^>=0.6.0.0` |
| 0.5.0.0 | `^>=0.14.0.0` | `^>=0.8.0.0` | `^>=0.9.0.0` | `^>=0.9.0.0` | `^>=0.5.1.1` | `^>=0.5.0.0` |
| 0.4.1.0 | `^>=0.13.0.0` | `^>=0.8.0.0` | `^>=0.9.0.0` | `^>=0.9.0.0` | `^>=0.5.1.1` | `^>=0.5.0.0` |
| 0.4.0.0 | `^>=0.13.0.0` | `^>=0.8.0.0` | `^>=0.9.0.0` | `^>=0.9.0.0` | `^>=0.5.1.1` | `^>=0.4.1.0` |
| 0.3.0.0 | `^>=0.11.0.0` | `^>=0.3.0.1` | `^>=0.9.0.0` | `>=0.8.0.1 && <0.9` | `^>=0.4.0.0` | `^>=0.4.1.0` |

## Migration cohort

| Kioku | `keiro-migrations` | `kiroku-store-migrations` | `pg-migrate` |
|---|---|---|---|
| 0.5.1.0 | `^>=0.14.0.0` | `^>=0.4.0.0` | `^>=1.1.0.0` |
| 0.5.0.0 | `^>=0.14.0.0` | `^>=0.4.0.0` | `^>=1.1.0.0` |
| 0.4.1.0 | `^>=0.13.0.0` | `^>=0.4.0.0` | `^>=1.1.0.0` |
| 0.4.0.0 | `^>=0.13.0.0` | `^>=0.4.0.0` | `^>=1.1.0.0` |
| 0.3.0.0 | `^>=0.11.0.0` | `^>=0.3.0.0` | `^>=1.1.0.0` |

Bounds are what the published `.cabal` files declare, not the exact versions a
given project resolved. To read what *this* project actually resolved, prefer
its own build plan:

```sh
jq -r '."install-plan"[] | select(."pkg-name"=="keiro") | ."pkg-version"' \
  dist-newstyle/cache/plan.json | sort -u
```

## Composed migration plan

Kioku's migration component composes after Kiroku's and Keiro's. A project that
asserts on migration counts or ids needs the right row for its release.

| Kioku | Total | Kiroku | Keiro | Kioku |
|---|---|---|---|---|
| 0.5.0.0 | 55 | 11 | 31 | 13 |
| 0.4.1.0 | 53 | 11 | 30 | 12 |
| 0.4.0.0 | 53 | 11 | 30 | 12 |

## Releases requiring a ledger fixup

Most Kioku migrations are additive, and additive migrations need no special
action. These are the exceptions — releases that changed the payload of an
**already-released** migration, and therefore its recorded checksum.

- **0.5.0.0 corrects `0011-kioku-memory-space-partition.sql`.** Its SHA-256
  changes from `eee9cd25…` to `6c83d3f0…`. A database that already applied
  `0011` under 0.4.0.0 or 0.4.1.0 must run
  `ledger-fixups/2026-08-19-rebaseline-0011-checksum.sql` once, before its next
  `up` or `verify`. A database where `0011` is pending needs no action; fresh
  and ephemeral databases need no action. The script ships in the
  `kioku-migrations` source distribution, so it is available from Hackage and
  not only from a git checkout.

A checksum mismatch on any migration **other** than the one a release names is
not covered by that release's fixup. It is a separate problem and must be
reported, not bypassed.

## Deprecated upstream releases

- **`kiroku-store-migrations` 0.3.2.0 and 0.3.2.1.** Their payload of migration
  `0010` cannot be applied on PostgreSQL 17 outside a bootstrap session.
  Superseded by 0.4.0.0. Kioku has required `^>=0.4.0.0` since 0.4.0.0, so a
  project on a current Kioku release cannot resolve them.

## PostgreSQL versions

Kioku's own test suites run against the PostgreSQL major its development shell
provides. Kiroku runs acceptance shells on **17 and 18**. A project deploying on
PostgreSQL 17 should treat Kiroku's 17 coverage as the authority for anything in
the `kiroku` schema, and should not assume Kioku's suites would have caught a
17-specific defect in a lower layer.
