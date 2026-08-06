# Changelog

## Unreleased

### Added

- `RecordedPrincipal` and `LegacyPrincipalRef` in `Kioku.Api.Access`: who a stored fact says
  acted. Three cases — a principal a directory issued, a pre-memory-space free-text agent label
  kept verbatim and marked, and an event that recorded no actor at all. The wire markers
  `kioku:legacy:` and `kioku:unattributed` are unambiguous because `mkPrincipalRef` rejects `:`.
- `memoryContextRecordedActor`, the supported way to attribute a write. Attribution comes from the
  context that authorized it, never from a separate caller-supplied name.
- `MemoryContextProvider` and `assumeAuthorizedContextProvider`, for background work that
  discovers which memory space it belongs to only after claiming it.

## 0.3.0.0 — 2026-08-05

### Changed

- No API change. Released in lockstep with the rest of the Kioku packages for the Keiki 0.9 and
  Keiro 0.11 cohort upgrade. `kioku-api` depends on neither, so a consumer that uses only this
  package can move from 0.2.0.0 to 0.3.0.0 with no other change.

## 0.2.0.0 — 2026-07-30

### Changed

- No API change. Released in lockstep with the rest of the Kioku packages for the Keiki 0.4,
  Keiro 0.4, Baikai 0.4 and Shikumi cohort upgrade.

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
