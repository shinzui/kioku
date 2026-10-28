---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [Cabal project file did not isolate baseline source paths](1-cabal-project-file-did-not-isolate-baseline-source-paths.md) - Invoking the baseline project file from the active checkout resolved local packages into the active tree and required restarting the baseline build.
- [Planned pg-migrate component accessor is hidden in the release](2-planned-pg-migrate-component-accessor-is-hidden-in-the-release.md) - The source-only Types accessor prescribed by Plan 51 cannot be imported from released pg-migrate 1.2, requiring frozen archive fixtures.
- [Default Tasty concurrency exhausts ephemeral PostgreSQL startup](3-default-tasty-concurrency-exhausts-ephemeral-postgresql-startup.md) - Running the complete suite at default concurrency timed out creating many ephemeral PostgreSQL clusters and required a bounded rerun.
- [Cabal all target excludes source archives](4-cabal-all-target-excludes-source-archives.md) - The archive-only consumer solve contained components but Cabal all selected no targets because archive packages are not local checkout packages.

