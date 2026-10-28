# Kioku release cohort map

Which upstream releases each Kioku version pairs with. Kioku's five published
packages share one version and are released together, so a row describes the
whole set.

Use this to answer "what else moves when I move Kioku?" — not to decide what to
edit. What to edit is in the edge prompt.

## Runtime cohort

| Kioku | `keiro` / `keiro-core` | `kiroku-store` | `keiki` | `shibuya-core` | `shibuya-kiroku-adapter` | `baikai` |
|---|---|---|---|---|---|---|
| 0.12.0.1 | `^>=0.22.0.0` | `^>=0.12.0.0` | `^>=0.9.1.0` | `^>=0.12.0.0` | `^>=0.7.0.0` | `^>=0.10.0.0` |
| 0.12.0.0 | `^>=0.22.0.0` | `^>=0.12.0.0` | `^>=0.9.1.0` | `^>=0.12.0.0` | `^>=0.7.0.0` | `>=0.7.0.0 && <0.9` |
| 0.11.0.0 | `^>=0.21.0.0` | `^>=0.11.0.0` | `^>=0.9.1.0` | `^>=0.10.0.1` | `^>=0.6.0.1` | `>=0.7.0.0 && <0.9` |
| 0.10.0.0 | `^>=0.21.0.0` | `^>=0.11.0.0` | `^>=0.9.1.0` | `^>=0.10.0.1` | `^>=0.6.0.1` | `>=0.7.0.0 && <0.9` |
| 0.9.1.0 | `^>=0.21.0.0` | `^>=0.11.0.0` | `^>=0.9.1.0` | `^>=0.10.0.1` | `^>=0.6.0.1` | `>=0.7.0.0 && <0.9` |
| 0.9.0.2 | `^>=0.21.0.0` | `^>=0.11.0.0` | `^>=0.9.1.0` | `^>=0.10.0.1` | `^>=0.6.0.1` | `>=0.7.0.0 && <0.9` |
| 0.9.0.1 | `^>=0.21.0.0` | `^>=0.11.0.0` | `^>=0.9.1.0` | `^>=0.10.0.1` | `^>=0.6.0.1` | `^>=0.7.0.0` |
| 0.9.0.0 | `^>=0.20.0.0` | `^>=0.11.0.0` | `^>=0.9.1.0` | `^>=0.10.0.1` | `^>=0.6.0.1` | `^>=0.7.0.0` |
| 0.8.0.2 | `^>=0.19.0.0` | `^>=0.9.0.1` | `^>=0.9.1.0` | `^>=0.10.0.0` | `^>=0.5.1.5` | `^>=0.7.0.0` |
| 0.8.0.1 | `^>=0.19.0.0` | `^>=0.9.0.1` | `^>=0.9.1.0` | `^>=0.10.0.0` | `^>=0.5.1.5` | `^>=0.7.0.0` |
| 0.8.0.0 | `^>=0.19.0.0` | `^>=0.9.0.1` | `^>=0.9.1.0` | `^>=0.10.0.0` | `^>=0.5.1.5` | `^>=0.7.0.0` |
| 0.7.0.0 | `^>=0.17.0.0` | `^>=0.8.0.0` | `^>=0.9.0.0` | `^>=0.9.0.0` | `^>=0.5.1.1` | `^>=0.7.0.0` |
| 0.6.0.0 | `^>=0.16.0.0` | `^>=0.8.0.0` | `^>=0.9.0.0` | `^>=0.9.0.0` | `^>=0.5.1.1` | `^>=0.7.0.0` |
| 0.5.2.0 | `^>=0.15.0.0` | `^>=0.8.0.0` | `^>=0.9.0.0` | `^>=0.9.0.0` | `^>=0.5.1.1` | `^>=0.6.0.0` |
| 0.5.1.0 | `^>=0.14.0.0` | `^>=0.8.0.0` | `^>=0.9.0.0` | `^>=0.9.0.0` | `^>=0.5.1.1` | `^>=0.6.0.0` |
| 0.5.0.0 | `^>=0.14.0.0` | `^>=0.8.0.0` | `^>=0.9.0.0` | `^>=0.9.0.0` | `^>=0.5.1.1` | `^>=0.5.0.0` |
| 0.4.1.0 | `^>=0.13.0.0` | `^>=0.8.0.0` | `^>=0.9.0.0` | `^>=0.9.0.0` | `^>=0.5.1.1` | `^>=0.5.0.0` |
| 0.4.0.0 | `^>=0.13.0.0` | `^>=0.8.0.0` | `^>=0.9.0.0` | `^>=0.9.0.0` | `^>=0.5.1.1` | `^>=0.4.1.0` |
| 0.3.0.0 | `^>=0.11.0.0` | `^>=0.3.0.1` | `^>=0.9.0.0` | `>=0.8.0.1 && <0.9` | `^>=0.4.0.0` | `^>=0.4.1.0` |

### AI cohort

`kioku-core` reaches its providers through Baikai and its programs through
Shikumi. `baikai-openai` became a direct requirement at 0.6.0.0.

| Kioku | `baikai` / `baikai-claude` | `baikai-openai` | `baikai-effectful` | `shikumi` | `shikumi-trace` |
|---|---|---|---|---|---|
| 0.12.0.1 | `baikai ^>=0.10.0.0`; `baikai-claude ^>=0.7.3.0` | `^>=0.7.3.0` | `^>=0.4.0.5` | `^>=0.4.1.1` | `^>=0.3.0.2` |
| 0.12.0.0 | `baikai >=0.7.0.0 && <0.9`; `baikai-claude ^>=0.7.0.0` | `^>=0.7.0.0` | `^>=0.4.0.1` | `^>=0.4.0.0` | `^>=0.3.0.0` |
| 0.11.0.0 | `baikai >=0.7.0.0 && <0.9`; `baikai-claude ^>=0.7.0.0` | `^>=0.7.0.0` | `^>=0.4.0.1` | `^>=0.4.0.0` | `^>=0.3.0.0` |
| 0.10.0.0 | `baikai >=0.7.0.0 && <0.9`; `baikai-claude ^>=0.7.0.0` | `^>=0.7.0.0` | `^>=0.4.0.1` | `^>=0.4.0.0` | `^>=0.3.0.0` |
| 0.9.1.0 | `baikai >=0.7.0.0 && <0.9`; `baikai-claude ^>=0.7.0.0` | `^>=0.7.0.0` | `^>=0.4.0.1` | `^>=0.4.0.0` | `^>=0.3.0.0` |
| 0.9.0.2 | `baikai >=0.7.0.0 && <0.9`; `baikai-claude ^>=0.7.0.0` | `^>=0.7.0.0` | `^>=0.4.0.1` | `^>=0.4.0.0` | `^>=0.3.0.0` |
| 0.9.0.1 | `^>=0.7.0.0` | `^>=0.7.0.0` | `^>=0.4.0.1` | `^>=0.4.0.0` | `^>=0.3.0.0` |
| 0.9.0.0 | `^>=0.7.0.0` | `^>=0.7.0.0` | `^>=0.4.0.1` | `^>=0.4.0.0` | `^>=0.3.0.0` |
| 0.8.0.2 | `^>=0.7.0.0` | `^>=0.7.0.0` | `^>=0.4.0.1` | `^>=0.4.0.0` | `^>=0.3.0.0` |
| 0.8.0.1 | `^>=0.7.0.0` | `^>=0.7.0.0` | `^>=0.4.0.1` | `^>=0.4.0.0` | `^>=0.3.0.0` |
| 0.8.0.0 | `^>=0.7.0.0` | `^>=0.7.0.0` | `^>=0.4.0.1` | `^>=0.4.0.0` | `^>=0.3.0.0` |
| 0.7.0.0 | `^>=0.7.0.0` | `^>=0.7.0.0` | `^>=0.4.0.1` | `^>=0.4.0.0` | `^>=0.3.0.0` |
| 0.6.0.0 | `^>=0.7.0.0` | `^>=0.7.0.0` | `^>=0.4.0.1` | `^>=0.4.0.0` | `^>=0.3.0.0` |
| 0.5.2.0 | `^>=0.6.0.0` | — | `^>=0.4.0.0` | `^>=0.3.0.3` | `^>=0.2.0.3` |
| 0.5.1.0 | `^>=0.6.0.0` | — | `^>=0.4.0.0` | `^>=0.3.0.3` | `^>=0.2.0.3` |
| 0.5.0.0 | `^>=0.5.0.0` | — | `^>=0.3.0.0` | `^>=0.3.0.0` | `^>=0.2.0.0` |

## Migration cohort

| Kioku | `keiro-migrations` | `kiroku-store-migrations` | `pg-migrate` |
|---|---|---|---|
| 0.12.0.1 | `^>=0.22.0.0` | `^>=0.7.2.0` (project constraint `==0.7.2.0`) | `^>=1.2.0.0` |
| 0.12.0.0 | `^>=0.22.0.0` | `^>=0.7.2.0` | `^>=1.2.0.0` |
| 0.11.0.0 | `^>=0.21.0.0` | `^>=0.7.1.0` | `^>=1.2.0.0` |
| 0.10.0.0 | `^>=0.21.0.0` | `^>=0.7.1.0` | `^>=1.2.0.0` |
| 0.9.1.0 | `^>=0.21.0.0` | `^>=0.7.1.0` | `^>=1.2.0.0` |
| 0.9.0.2 | `^>=0.21.0.0` | `^>=0.7.1.0` | `^>=1.2.0.0` |
| 0.9.0.1 | `^>=0.21.0.0` | `^>=0.7.1.0` | `^>=1.2.0.0` |
| 0.9.0.0 | `^>=0.20.0.0` | `^>=0.7.1.0` | `^>=1.2.0.0` |
| 0.8.0.2 | `^>=0.19.0.0` | `^>=0.6.0.0` | `^>=1.2.0.0` |
| 0.8.0.1 | `^>=0.19.0.0` | `^>=0.6.0.0` | `^>=1.2.0.0` |
| 0.8.0.0 | `^>=0.19.0.0` | `^>=0.6.0.0` | `^>=1.2.0.0` |
| 0.7.0.0 | `^>=0.17.0.0` | `^>=0.4.0.0` | `^>=1.1.0.0` |
| 0.6.0.0 | `^>=0.16.0.0` | `^>=0.4.0.0` | `^>=1.1.0.0` |
| 0.5.2.0 | `^>=0.15.0.0` | `^>=0.4.0.0` | `^>=1.1.0.0` |
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

For 0.12.0.1, consuming projects also need scoped `allow-newer` entries for
`shikumi:baikai`, `shikumi-cache:baikai` and `shikumi-trace:baikai`. The latest
released packages at mori://shinzui/shikumi still cap Baikai below 0.9.
Keep mori://shinzui/kiroku/packages/kiroku-store-migrations constrained to
`==0.7.2.0` to retain the qualified 63-entry plan. Repository project settings
are not inherited through Hackage packages. Follow the 0.12.0.0-to-0.12.0.1 edge
for direct Baikai API adaptations and consumer validation.

## Composed migration plan

Kioku's migration component composes after Kiroku's and Keiro's. A project that
asserts on migration counts or ids needs the right row for its release.

| Kioku | Total | Kiroku | Keiro | Kioku |
|---|---|---|---|---|
| 0.12.0.0 | 63 | 16 | 32 | 15 |
| 0.11.0.0 | 62 | 15 | 32 | 15 |
| 0.9.1.0–0.10.0.0 | 61 | 15 | 32 | 14 |
| 0.9.0.0 | 60 | 15 | 32 | 13 |
| 0.8.0.0–0.8.0.2 | 57 | 12 | 32 | 13 |
| 0.7.0.0 | 56 | 11 | 32 | 13 |
| 0.6.0.0 | 56 | 11 | 32 | 13 |
| 0.5.2.0 | 55 | 11 | 31 | 13 |
| 0.5.1.0 | 55 | 11 | 31 | 13 |
| 0.5.0.0 | 55 | 11 | 31 | 13 |
| 0.4.1.0 | 53 | 11 | 30 | 12 |
| 0.4.0.0 | 53 | 11 | 30 | 12 |

## Releases requiring a ledger fixup

Most Kioku migrations are additive, and additive migrations need no special
action. These are the exceptions — releases that changed the payload of an
**already-released** migration, and therefore its recorded checksum.

0.10.0.0 requires no ledger fixup and changes no SQL. It gates the 0.9.1.0
bounded reads on `MemoryRead` and changes their result types; see the
0.9.1.0-to-0.10.0.0 edge. 0.9.1.0 was tagged but never published to Hackage.

0.9.0.2 admits `mori://shinzui/baikai/packages/baikai` 0.8 while retaining 0.7
support. No upgrade edge or ledger fixup is needed: the optional wider bound
requires no consumer source change, and the composed 60-entry plan, SQL, and
checksums are unchanged. Provider bounds retain their existing ranges.

0.9.0.1 changes only dependency bounds to the `mori://shinzui/keiro` 0.21
cohort. The composed plan remains at 60 entries (15 Kiroku, 32 Keiro, 13 Kioku),
with no SQL or checksum changes and no new ledger fixup. No upgrade edge is
needed: the upstream DSL API and generated-service changes do not reach
consumers through Kioku. Projects using that DSL directly should follow the
`keiro-upgrade` 0.20.0.0-to-0.21.0.0 edge owned by `mori://shinzui/keiro`
(project-relative `blueprints/keiro-upgrade/blueprint.dhall`; artifact URI pending).

0.9.0.0 requires no new Kioku ledger fixup and changes no Kioku SQL. Its three
new entries come from mori://shinzui/kiroku: 0013 infers group size, 0014 binds
checkpoint targets, and 0015 adds the browsing index. Stop subscription workers
for 0013/0014, confirm legacy targets before adoption, and schedule the 0015
write pause using the recursively entailed upstream runbooks. These obligations
also apply through Kioku's runner. A source-migration receipt is not operational
completion. AI bounds are unchanged; 0.8.0.1/0.8.0.2 patch gaps intentionally
select the same 0.8.0.2-to-0.9.0.0 edge.

0.8.0.0 requires no Kioku ledger fixup: it adds no Kioku migration and corrects
no released payload. Its plan grows to 57 through Kiroku's appended
`kiroku/0012`, which is additive but must be applied with every Kiroku 0.8
writer stopped; see the entailed `kiroku-upgrade` `0.8.0.2 -> 0.9.0.0` edge.

0.7.0.0 requires none: it adds no migration and corrects no released payload.
The composed plan remains at 56 migrations.

0.6.0.0 requires none: it adds no Kioku migration and corrects no released
payload. Its plan grows only through Keiro's appended `keiro/0032`.

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

0.11.0.0 adds migration 0015 (active Memory recency index) with a transactional
write pause and no ledger fixup. Four Memory query registrations require public
catalog preview/adoption before startup. Consumers initialize the new
`MemoryFilter.scopeKind` field explicitly; the 0.10.0.0-to-0.11.0.0 edge explains
source migration, complete-host catalog selection and tag cursor mutation limits.
The upstream runtime, AI and migration cohorts are unchanged.

0.12.0.0 selects Keiro 0.22, Store 0.12, Store migrations 0.7.2 and Shibuya
0.12/adapter 0.7. The composed plan has 63 entries (16 Kiroku, 32 Keiro,
15 Kioku). Only `kiroku/0016` is new from a complete 0.11 installation; it
changes subscription constraints and the Kiroku schema comment. Stop affected
workers for the operator-owned migration, preserve exact-category targets, and
restart new Store-linked hosts before enabling any namespace bindings. No Kioku
SQL, codec, catalog identity or AI policy changes. No ledger fixup is required.
