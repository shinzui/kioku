---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Bug Report

- [Migration 0011's session search_path leaks into every migration applied after it](migration-0011-session-search-path-leaks-into-later-migrations.md) - The 0.4.x payload of migration 0011 was the final of ten Kioku migrations that left the session search_path pinned to the kiroku schema; the corrected payload resets the host default before later components run.
