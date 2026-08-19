---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Bug Report

- [Migration 0011's session search_path leaks into every migration applied after it](migration-0011-session-search-path-leaks-into-later-migrations.md) - Migration 0011 opens with a bare SET search_path TO kiroku, pg_catalog and never restores it, so every migration a consumer applies after it on the same connection resolves unqualified names against the kiroku schema instead of its own.
