# Changelog

## 0.1.0.0 — 2026-07-14

### Added

- Added commands for memory and session demonstrations, hybrid recall, manual L1 distillation, L2
  scenes, L3 personas, and background workers.
- Added one-shot embedding backfill, timer processing, continuous worker supervision, startup
  backfill, and graceful worker draining.
- Added parser validation for session identifiers, scope references, mutually exclusive worker
  modes, and bounded result limits.

### Fixed

- Wired recall-based merge candidates into timer-driven distillation.
- Allowed colons in scope references while preserving namespace and kind boundaries.

### Changed

- `demo` and `demo-session` now require `--yes-write-events`, redact database credentials in their
  warning, and write only to the isolated `kioku_demo/demo/demo` scope.
- Session arguments now require the `kioku_session` prefix instead of silently rebranding other
  TypeID prefixes.
