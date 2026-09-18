# Keiro 0.17 pattern conformance

This matrix records which runtime, Haskell, CLI, and PostgreSQL patterns govern Kioku 0.7.0.0
and the executable evidence for each classification. It is a release artifact, not an aspiration:
“Conformant” means the cited code or test exists on this release line.

The request name `postgresql-jitsurei-patterns` resolves in the registry to the canonical project
`mori://shinzui/postgresql-jitsurei`.

## Classifications

- **Conformant** — Kioku implements the applicable pattern and has executable or directly
  inspectable evidence.
- **Conformant with documented boundary** — the governing invariant is met, but Kioku's library
  architecture or an upstream representational limit requires a precise exception.
- **Not applicable** — Kioku does not expose the capability the pattern governs; the row names
  the absent surface.
- **Deferred with an owner** — applicable work remains and names the project responsible. There
  are no deferred Keiro 0.17 compatibility APIs in this release.

## Keiro runtime patterns

| Pattern | Classification | Why and evidence |
|---|---|---|
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-read-models-and-projections` | **Conformant** | All nineteen models in `Kioku.Memory.ReadModel` and `Kioku.Session.ReadModel` expose `ReadModelBlueprint` values with `NoQueryCursor`, are built by `immediateReadModel`, and execute through `runQueryWithFreshness Immediate`. `Kioku.ProjectionCatalogSpec` proves every catalog query is immediate and cursorless and that a cursorless blueprint cannot be made waiting. The release-readiness legacy-symbol scan is empty. |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-projection-catalogs` | **Conformant with documented boundary** | `Kioku.ProjectionCatalog` declares two sources, three application targets, two rebuild groups, two projection owners, and nineteen query bindings. Startup validates and registers the catalog; invalid ownership/reference fixtures fail. Keiro 0.17 requires exclusive target ownership, so the shared framework-owned `keiro.keiro_timers` table cannot be a Kioku catalog target. Timer scheduling stays an explicit handler in the same append transaction; [ADR-13](../adr/catalog-application-projections-not-framework-timers.md) and the rollback test prove that boundary. |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-runtime-assembly` | **Conformant with documented boundary** | `Kioku.App.withNoopAppEnv` validates both hand-written event streams, validates the catalog, acquires the store, and registers the catalog before running user effects. `Kioku.Memory.EventStream` and `Kioku.Session.EventStream` expose explicit validation functions. Migration application remains a deployment job because `kioku-core` cannot depend on `kioku-migrations` without closing the package cycle; `kioku-migrate` composes and applies the plan separately. |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-two-schema-arrangement` | **Conformant** | Kiroku owns the shared event store in `kiroku`, Keiro owns framework state in `keiro`, and Kioku owns its projections in `kioku`. `Kioku.Database.Schema`, migration 0012, migration tests, and [ADR-10](../adr/projections-live-in-the-kioku-schema.md) make every ownership boundary explicit. |
| `mori://shinzui/keiro-runtime-patterns/docs/migrations-authoring` | **Conformant** | `Kioku.Migrations.Internal.Definition` embeds the ordered manifest. The migration suite freezes every released native payload, separately validates the ten-entry Codd evidence, and rejects unqualified future objects or future `search_path` changes. No released SQL changed in this adoption. |
| `mori://shinzui/keiro-runtime-patterns/docs/migrations-testing` | **Conformant** | `Kioku.Migrations.TestSupport` delegates framework setup to `Keiro.Test.Postgres.withMigratedSuiteWith [kioku]`. The 30-test migration suite covers fresh apply, supported Codd upgrade, hostile session composition, rerun idempotence, checksum verification, and normalized fresh/upgrade schema convergence. |
| `mori://shinzui/keiro-runtime-patterns/docs/migrations-operations` | **Conformant** | `kioku-migrate` embeds the Kiroku → Keiro → Kioku plan, exposes pg-migrate plan/status/check/verify/up operations, retains a guarded one-time Codd import, and reconciles read-model identities after a successful `up`. The composed plan remains 56 entries: Kiroku 11, Keiro 32, Kioku 13. |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-brownfield-adoption` | **Conformant with documented boundary** | Native Kioku codecs remain the single current-history authority. The finite Codd-to-pg-migrate bridge imports only the pinned thirty-row Kiroku/Keiro/Kioku cohort and validates equivalent state; it is not a second runtime codec or a general unknown-history importer. Fresh and imported databases converge on the same normalized Kioku schema. |
| `mori://shinzui/keiro-runtime-patterns/docs/keiro-evolution-and-rollout` | **Conformant** | Event golden tests retain pre-upgrade native payloads, both event streams validate before traffic, catalog fingerprint drift fails startup, projection schema moves bump read-model identities, and deployment remains migration-first. The 0.6.0.0 → 0.7.0.0 blueprint entails Keiro's exact 0.16.0.0 → 0.17.0.0 edge and requires a deprecation-as-error consumer build. |
| `mori://shinzui/keiro-runtime-patterns/docs/architecture-service-packages` | **Not applicable** | Kioku is a reusable library cohort plus local CLI and migration executables. It has no independently deployed HTTP server, public generated client, or service worker fleet whose ownership would justify the six-package service topology. |

## Haskell and CLI patterns

| Pattern | Classification | Why and evidence |
|---|---|---|
| `mori://shinzui/haskell-jitsurei/docs/core-standards` | **Conformant** | All five packages declare GHC `>=9.12 && <9.13`, GHC 2024, the shared warning baseline, and explicit extensions. `cabal build all --ghc-options=-Werror` passes. |
| `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude` | **Conformant** | `Kioku.Prelude` is the sole `PackageImports` boundary. The convention check rejects package imports elsewhere; label optics are imported only by modules that use them. |
| `mori://shinzui/haskell-jitsurei/docs/core-record-patterns` | **Conformant** | Product records use strict fields, entity identifiers lead command/event records, and every deriving clause names `stock`, `newtype`, or `anyclass`. Newtype fields remain unannotated because GHC forbids bang annotations on them. |
| `mori://shinzui/haskell-jitsurei/docs/cli-overview` | **Conformant** | `Kioku.Cli` has one optparse-applicative command tree with stable command names and nested worker/distill commands; parser and subprocess suites exercise the user boundary. |
| `mori://shinzui/haskell-jitsurei/docs/cli-option-groups` | **Conformant** | The CLI requires optparse-applicative `>=0.19 && <0.20` and groups recall targets, query/output options, AI configuration, and worker execution modes under semantic headings. Structural help tests pin those headings. |
| `mori://shinzui/haskell-jitsurei/docs/cli-help-width` | **Conformant** | `cliParserPrefs` fixes rendering at 100 columns. Top-level, worker, and recall help tests reject any wider line. |
| `mori://shinzui/haskell-jitsurei/docs/cli-shell-completions` | **Conformant** | The top-level parser uses optparse-applicative's built-in completion requests. Tests execute and verify non-empty bash, zsh, and fish scripts; direct executable probes exit zero. |

These conventions are themselves ratcheted by `scripts/check-haskell-conventions.sh`, the
pre-commit hook, the Nix `haskell-conventions` check, and [ADR-14](../adr/haskell-and-cli-conventions-are-executable-contracts.md).

## PostgreSQL object ownership

| Pattern | Classification | Why and evidence |
|---|---|---|
| `mori://shinzui/postgresql-jitsurei/docs/migrations-schema-qualify-migration-objects` | **Conformant** | Runtime SQL uses qualified `kioku` relation constants. Released migrations 0001–0013 are frozen history; the future-migration lint rejects unqualified owned objects and any `search_path` mutation after that baseline. Hostile-composition tests prove later host DDL lands in the host schema. |

## Intentionally unused Keiro surfaces

Absence in this inventory is deliberate and bounded:

- **`keiro-dsl` — Not applicable.** Kioku's two aggregates and streams are hand-written and
  validated explicitly; no `.keiro` source or generated Haskell exists in this repository.
- **`keiro-pgmq` and PGMQ jobs — Not applicable.** Kioku has no PGMQ queue, job codec, or worker.
  `cabal.project` carries only an optional compatibility solve so consumers that do use the 0.17
  PGMQ cohort resolve PGMQ 0.6 and `shibuya-pgmq-adapter` 0.16 coherently.
- **Inbox/outbox and integration events — Not applicable.** Kioku writes native aggregate events,
  inline application projections, and Keiro timers; it publishes no integration-event contract
  and consumes no inbox.
- **External SQL read contracts — Not applicable.** Kioku exports typed Haskell queries and grants
  no out-of-process reader direct or guarded SQL access to its projection tables. If that changes,
  the versioned Keiro external-read contract becomes mandatory.
- **Operations server — Not applicable.** Kioku provides `kioku` and `kioku-migrate` local
  executables, not a mounted HTTP operations service.

## Release evidence

The release-readiness run requires all of the following to stay green:

```sh
cabal build all --dry-run
cabal build all --ghc-options=-Werror
cabal test all
scripts/check-haskell-conventions.sh
seihou validate-blueprint blueprints/kioku-upgrade
nix fmt -- --ci
nix flake check
```

The migration suite must still report 56 composed migrations, the legacy Keiro freshness-symbol
scan must remain empty in `kioku-core/src` and `kioku-core/test`, and `git diff` for migrations
0001–0013 must remain empty.
