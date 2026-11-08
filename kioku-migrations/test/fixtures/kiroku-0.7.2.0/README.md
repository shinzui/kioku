# Released Kiroku 0.7.2.0 migration payload

Frozen from the Hackage `kiroku-store-migrations-0.7.2.0.tar.gz` archive,
owned by mori://shinzui/kiroku/packages/kiroku-store-migrations, at release
commit `22d103e4f424caab06c6a2b76ad92b408c262bc0`.

Archive SHA-256: `b346415978147bcd24636be33313011cc5f1eb763272fa14c2f65dce042f4f71`.
`0016.sql` SHA-256: `53b22f14e20af7af0f444877544217a2433939be6a9a245295485e2f87228ee4`.

The preceding fifteen payloads match the adjacent `kiroku-0.7.1.0` fixtures
byte-for-byte; tests compose those bytes with this payload and verify every
checksum. This reconstructs the released 63-entry Kioku 0.12 plan without
slicing current migration SQL. Never regenerate these fixtures from current SQL.
