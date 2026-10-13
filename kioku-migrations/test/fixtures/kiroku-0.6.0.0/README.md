# Released previous-cohort migration fixture

These are verbatim migration bytes from
mori://shinzui/kiroku/packages/kiroku-store-migrations version 0.6.0.0,
project-relative `kiroku-store-migrations/migrations/` (artifact-level SQL URIs pending).
The authoritative Hackage archive is
https://hackage.haskell.org/package/kiroku-store-migrations-0.6.0.0/kiroku-store-migrations-0.6.0.0.tar.gz
with SHA-256 `8c0d8e9b98e39c332457a0d34d37c8e909e3c2618dc6d334b6a16cc98fc353de`.
Every payload was compared byte-for-byte with upstream tag
`kiroku-store-migrations-v0.6.0.0`, peeled commit
`691c6efed78ca6bb344c9cac5d122eb5ca4980b2`, on 2026-10-13.
`SHA256SUMS` freezes each payload; the test checks these before composing the old plan.

This fixture is solely for disposable database evolution. Its comments and SQL
are preserved verbatim. Do not edit it to repair a new migration failure.
Keiro's 32 and Kioku's 13 payloads are unchanged across this upgrade; the fixture
composes those current components after this genuine 12-entry Kiroku component.
It is separate from the older 30-entry Codd cutover fixture.
