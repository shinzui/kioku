# Keiro 0.22 upgrade acceptance

This record qualifies Kioku 0.12.0.0 against fixed baseline
`9cd613d5087a08d6625cb266ff09845197b1d3d4`. It does not authorize deployment.
M1–M3 pass. The clean-candidate gate ran against commit
`a9ad985d752e60a3e883622b96f61a83ad1fe15d` with no generated tracked changes after the second build.
M4's actual restored-history acceptance is pending an operator archive, provenance,
deployment PostgreSQL major, scratch identities and installation inventory.

## Sources and artifacts

Research and implementation used Mori before reading dependency sources. Hackage
package metadata and published Cabal files were refreshed on 2026-10-28 UTC;
Keiro 0.22.0.0 remains the latest published Keiro. Annotated release tags peel to
`b28201f2063fa4f6dcb724cbf474959107e36b74` at mori://shinzui/keiro,
`22d103e4f424caab06c6a2b76ad92b408c262bc0` at mori://shinzui/kiroku,
and `14f35d8995cc3dc3e2671e4d2505abf9bf4f5a9e` at mori://shinzui/shibuya.
The release JSONs and Cabal files are retained under `.dev/keiro-0.22/releases/`.

The fresh empty-store solve uses GHC 9.12.4 on aarch64 Darwin, Hackage index
`2026-10-28T02:00:03Z`, tests enabled, `-O1`, `-Werror`, and cleared package
databases plus the compiler's global database. `fresh-plan.json` and
`evidence.freeze` are retained under `.dev/keiro-0.22/`. The non-boot units have
source and revised-Cabal SHA256s. Compiler-supplied boot units are explicitly
identified by their unit IDs; `ghc-pkg list --global --simple-output` supplies
the boot inventory. Cabal does not emit a separate compiler-ABI key here; the
compiler ID and exact boot unit IDs qualify the ABI comparison.

| Package | Version | Source archive SHA256 | Revised Cabal SHA256 |
| --- | --- | --- | --- |
| keiro | 0.22.0.0 | `fac8d9cdcb881756261058b9ecbfb290de72d137a31302c95a8550c3f050653b` | `9ce08be6c4a841bc6e8bfc5389d4fc92a995314cac856d6cfc2cbb9d598b043a` |
| keiro-core | 0.22.0.0 | `773e54c42b3cf5d71f5e6ae780779f9dd9d241e7473577b756bdef1434700df0` | `70812faa0adce48556c601521f0b21637287021936b601ee2c481274b4a8bbf3` |
| keiro-migrations | 0.22.0.0 | `f0221db7fdc6206597776f062b5d7b89d0b1f6734d8858de06b0695dd6ce9fb9` | `8ef650f955416891d59d29fb671bd1f23414d1d4b162386bc23f3c6dbb1b2eda` |
| keiro-test-support | 0.22.0.0 | `b3dc02fa2ee957b0b14f3fdce973acca59c3593fc7b51640893e24c5c6569aa1` | `76a9292970b14c651342a2692557028811139a57e595362236eee45e62d75985` |
| kiroku-store | 0.12.0.0 | `cb0ce88c44c766d6460d28224a48f3c02fd1829c733e9493af89e58b324319d0` | `f742ee73f0354c54f6c0f9ff60492a7983fcf2ce74d51a77d6617a7d8fa94a36` |
| kiroku-store-migrations | 0.7.2.0 | `b346415978147bcd24636be33313011cc5f1eb763272fa14c2f65dce042f4f71` | `7a2e175fd9999d9b38a9027ffe124ecf5c6a8c7c6fafd1200ef32051c5258d20` |
| shibuya-core | 0.12.0.0 | `d5dac4e9bfbfddfd97a0ab14fed317621252dd875d0fe1136be51041820178c3` | `75e59517323d0b44af8a30bdbe89a0edca2d9892f54f676aa941d8a69e33630f` |
| shibuya-kiroku-adapter | 0.7.0.0 | `08cf781fa7e2fc15333df51835b75a152e5a2ab444393f995a06f003850d30cf` | `c8d18e2fee40520993e0eb957caa2ed67ec7a99507d6f80730daf8ddba684b49` |

Keiki/codecs remain 0.9.1.0; pg-migrate family remains 1.2.0.0;
Effectful/Core remain 2.7.1.0/2.7.1.2; Shikumi/trace remain 0.4.1.1/0.3.0.2;
Baikai remains 0.8.0.0 with Claude/OpenAI 0.7.1.1 and Effectful adapter 0.4.0.3.
The fresh solve selects Hasql 1.10.3.7 and ephemeral-pg 0.3.1.0.
A source/hash/flags comparison against the rebuilt fixed baseline changes only
the eight intended upstream package families. The original cached plan predates
the baseline (its local Kioku packages were 0.9.0.1); unrelated patch movement
from that cache also occurs in the rebuilt baseline at the refreshed index and
is not caused by this upgrade. No PGMQ package
is in the closure. The existing TLS override, Blake3 flags, pkg-config libpq and
profiling coercion workaround are preserved; no solver exception was added.

Seihou's module preview reports 0.37.0 already current. The Nix flake supplies
the bare compiler and native development tools. Cabal supplies runtime sources;
there is no shipping Nix runtime package set, retained manifest, DSL workspace,
HTTP operations mount or PGMQ delivery lane to compare or adopt.

The archive-only external consumer builds all exported libraries, public migration
test support and both executables. Cabal requires explicit component targets for
archive packages; `all` selects no local targets. Source-origin/hash/Cabal-hash,
flags, compiler/platform and boot-unit comparison passes for 227 nonlocal runtime
components. Their normalized identity report SHA256 is
`cd25a9d78d29d159216c258bdd90e9f3595d3c57cd842577cf39647b665172a5`.
The ordinary cached build has the same source-bearing runtime identities. Local
test roots have separate test-only dependencies and are covered by full suites.

## Verified behavior

The warnings-as-errors build passes. Bounded-concurrency full validation passes
125 API, 275 core, 64 CLI and 34 migration tests. The initial unconstrained
parallel run exhausted ephemeral PostgreSQL startup; use `TASTY_NUM_THREADS=4`
and Cabal `-j1` for the full gate. The three real-adapter tests pass without
skipping pgvector: actual vector writes, durable exact-category checkpointing,
legacy adoption, conflicting-target refusal and graceful shutdown are exercised.

Native historical payload fixtures, foreign-language rejection, partition and
attribution invariants, catalog inventory/registration/reconciliation/rollback,
recall, transactional timers, deferred claims and CLI help/completion remain
covered by those unchanged application suites. Production source APIs, event
stream definitions, handwritten codecs, catalog ownership and timer callbacks
are unchanged. The source adaptation is the complete test `Ingested` envelope's
new `deliveryStatus = pure DeliveryCurrent` field.

Migration acceptance covers fresh installation, a complete 62-entry previous
cohort, the frozen earlier 59-entry cohort, Codd import, exact schema convergence,
checksum refusal and idempotent repeat. All fifteen 0.7.1.0 Kiroku fixture SQL
hashes are frozen from its Hackage archive and match the release prefix.
Only `kiroku/0016` applies from the complete previous cohort. Historical Kioku SQL,
manifest, lock, old 0.6 fixture and frozen Kioku schema checksum are unchanged.

All five `cabal check` invocations, Haskell conventions, Seihou blueprint
validation, formatting and native Darwin flake checks pass. Linux execution has
not been tested by the Darwin flake check.

## Rehearsal tooling and limits

`scripts/kioku-upgrade-probe.hs` compiles against old and candidate public
libraries with exact unit identities through `scripts/build-kioku-upgrade-probe.py`.
It separates read, paired write, full native replay, catalog rebuild and delivery.
Mutations require the recorded scratch identity plus an explicit disposable flag.
All provider callbacks are deterministic and the production embedding checkpoint
is never opened. `scripts/compare-kioku-upgrade.py` checks the exact reviewed
migration allowance, paired commands and repeated rebuilds.

Synthetic twins restored from the same synthetic archive demonstrate public
command/CLI parity, exact migration preservation, a native replay denominator of
two, and two distinct catalog rebuild runs with preserved rows. This is a tooling
smoke check, not evidence about actual operator history. Reports are retained
under `.dev/keiro-0.22/twin-1/`. A separate synthetic delivery rehearsal
under `.dev/keiro-0.22/delivery-1/` observes exactly two provider effects,
two stored vectors across adapter restart, a category checkpoint at position 2,
and a due timer with final status `fired`. A second delivery/rebuild rehearsal
under `.dev/keiro-0.22/delivery-2/` proves both non-null 1536-dimensional vectors
and all four enrichment fields survive two catalog rebuilds. The migration
comparator also rejects an injected unexpected protected-row mutation.

Released catalog registration runs `upsertGroupCursorAuthorityStmt` in
mori://shinzui/keiro plus project-relative
`keiro/src/Keiro/ReadModel/Rebuild/Group.hs` (artifact-level URI pending).
It unconditionally advances the two Kioku cursor `updated_at` clocks even when
append authority and empty subscription lists are unchanged. This exact
source-verified startup effect is recorded separately from migration 0016 and
allowed only for those two rows; no registry repair or semantic identity change
is allowed. Full schema comparisons allow only the named constraints/comment.

Rebuild uses the actual catalog runner and preserves enrichment by matching
memory ID, space and content. Session projection database clocks are excluded
from semantic equality; event-derived timestamps are exact. The runner's own
lifecycle reports/registry clocks are captured separately. Every other table,
including events, timers, subscriptions, inbox/outbox and non-target Kioku rows,
is checked for preservation. No production rebuild is prescribed.

The [operator runbook](../user/upgrading-to-keiro-0-22.md) specifies archive
verification, deployment-major/grants checks, stopped writers/workers, migration,
post-restart observation and recovery boundaries. Actual archive hash/time,
restored identities, actual native-stream denominator, installation supervisors,
production delivery and cutover approval are unsupplied. M4 remains unaccepted.

## Final clean-candidate artifact record

The clean-candidate build and all 498 tests pass in the isolated fresh store.
The second build produces no tracked changes; the final five source archives
build all seven exported library/executable components through an external
archive-only project, with the same 227-component runtime source identity digest.
Native Nix checks pass from the clean candidate. Synthetic PostgreSQL coverage
uses the development shell's PostgreSQL 18; the deployment major is still unknown.

Immutable qualified artifacts, exact build/test logs, source identities, Cabal
plan/freeze, archive consumer and `qualification.json` are retained under
`.dev/keiro-0.22/qualified-a9ad985/`. Binary and source-archive SHA256s are:

| Artifact | SHA256 |
| --- | --- |
| `shipping/kioku` | `b3aad749046d10a24e8ea642944d279fa911c540e97312004093ad87896498a0` |
| `migration-runner/kioku-migrate` | `9ab874858288351e7d67e5c1045e571b34dc743f5e60aa3641c03c829893d51e` |
| `sdist/kioku-api-0.12.0.0.tar.gz` | `7a94bcb409d7b4e3b7a7e04c0ab4823f6cc66beddee700c13ca99c90caa28f7b` |
| `sdist/kioku-cli-0.12.0.0.tar.gz` | `cc2d5032b212908383795bf6b724e92cf2e1d21d484a7c2147cc2b87c2e2bbf9` |
| `sdist/kioku-core-0.12.0.0.tar.gz` | `fb2991b19634b2a86f56a5337a8a3f2809bf9dde9cf94a6985561bb2fd539d66` |
| `sdist/kioku-migrate-0.12.0.0.tar.gz` | `bbf70b10bbec56cd309dc9e52509892888fb99b60445e70814087bfb860f265e` |
| `sdist/kioku-migrations-0.12.0.0.tar.gz` | `0037cff5a84c4ebf68439e87cbeba9b96e8e1c77ab43f45eeaa3b154ed0ec45e` |

Old shipping artifacts are retained separately under `.dev/keiro-0.22/baseline/`,
with the detached source worktree and original build plan. Their SHA256s are:

- `kioku`: `acc7b17f67e984f45e809c61d566f4bbfd83bd896c4271e523aeefcdd11fbc43`
- `kioku-migrate`: `3e157da660c28b1668a1a82071ebc878a1e4b17db9b11ec79c7c0e8c189ed7e2`

Old and candidate final probes use identical source SHA256
`e933d9e235d7650b448093b2f094ab5360734494a2a1e0daaf13709bf48e2855`,
with separate linked-unit, plan and binary provenance. These artifacts are reviewable
candidates; package publication and persistent installation activation remain operator work.
