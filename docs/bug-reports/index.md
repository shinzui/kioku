---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Bug Report

- [Migration 0011's session search_path leaks into every migration applied after it](migration-0011-session-search-path-leaks-into-later-migrations.md) - Migration 0011 is the final of ten released Kioku migrations that set the session search_path and never restore it, so later components on the same connection resolve unqualified names against the kiroku schema instead of their own.
