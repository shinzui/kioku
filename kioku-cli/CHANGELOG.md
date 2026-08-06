# Changelog

## Unreleased

### Added

- `KIOKU_MEMORY_SPACE` (default `kioku_legacy`) and `KIOKU_ACTOR` (default `kioku_cli`) decide the
  memory space CLI commands write into and the principal writes are attributed to. A malformed
  value is a startup error rather than a silent fallback. The worker is not pinned to one space:
  it acts in whichever space a claimed timer names.

## 0.3.0.0 — 2026-08-05

### Changed

- No API change. Released in lockstep with the rest of the Kioku packages for the Keiki 0.9 and
  Keiro 0.11 cohort upgrade. The commands and their option parsers are unchanged; what changes is
  the framework they link against through `kioku-core`.

## 0.2.0.0 — 2026-07-30

### Changed

- No API change. Released in lockstep with the rest of the Kioku packages for the Keiki 0.4,
  Keiro 0.4, Baikai 0.4 and Shikumi cohort upgrade. The commands themselves are unchanged; what
  changes is the framework they link against through `kioku-core`.

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
