# Changelog

## 0.1.0.0 — 2026-07-14

### Added

- Added host-agnostic global and entity memory scopes with validating constructors and column/text
  conversion helpers.
- Added TypeID-backed `MemoryId` and `SessionId` generation, rendering, strict parsing, and an
  explicitly named lenient parser for legacy identifiers.
- Added shared memory type, confidence, status, and record wire types plus the Kioku prelude.

### Fixed

- Rejected reserved characters in namespace and scope-kind labels so distinct scopes cannot
  collapse to the same distillation identity.

### Changed

- Renamed the any-prefix identifier parser to `parseIdLenient` and documented the narrow cases
  where rebranding an identifier is safe.
