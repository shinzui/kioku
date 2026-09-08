---
title: "Read-model registry reconciliation"
type: Capability
description: "Bring Keiro's read-model registry rows into agreement with the schema identities compiled into the running binary, idempotently and derived from the same values the queries use, so a version bump fails closed instead of leaving every query down forever."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-14
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-core
  - kioku-migrate
interface:
  - Kioku.ReadModel
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/ReadModelReconcileSpec.hs
    proves: "A pre-relocation registry fails every query closed and then reconciles, reconciliation is idempotent, and a binary declaring a pre-relocation identity fails closed rather than reading relations that moved."
  - kind: test
    resource: kioku-core/test/Kioku/SpaceIsolationSpec.hs
    proves: "Reconciliation leaves both memory spaces readable, so repairing the registry does not disturb the partition."
  - kind: guide
    resource: docs/user/library-api.md
    proves: "Why registerReadModel alone never repairs an existing row, and the exact call a host running a composed plan directly must make after pg-migrate succeeds."
---

# Read-model registry reconciliation

Keiro records each read model's schema identity — its version and shape hash — in a
`keiro_read_models` registry row, and refuses to serve any query whose registry row
disagrees with the code's declared identity, failing with `ReadModelStaleSchema`. That
guard is deliberate: a binary on the wrong side of a projection change should fail closed
rather than query relations that have moved.

Nothing repairs those rows on its own. `registerReadModel` only ever *inserts*, so an
existing row stays pinned at its old version forever, and a Kioku upgrade that bumps a
read model's version would take every query for that model down until somebody noticed.

`reconcileReadModelRegistry` is the repair. It derives every name, version, and shape hash
from the same `ReadModel` values the queries themselves use, so it cannot drift from the
code, and it is idempotent — a second run writes nothing.
[`kioku-migrate up` (CAP-13)](embedded-migration-component.md) calls it after pg-migrate
succeeds, and read-only commands never write the registry. **A host that runs a composed
plan directly must call it itself.**

This is not hypothetical. Migration `0012-relocate-projections-to-kioku-schema` advances
memory to v3, session to v5, and turn to v3 precisely so a binary on the wrong side of the
move fails closed — which means every Kioku read stays down until reconciliation runs.

## Shape

```haskell
import Kioku.ReadModel (reconcileReadModelRegistry)

withNoopAppEnv (defaultConnectionSettings connStr) \env -> do
  result <- runAppIO env reconcileReadModelRegistry
  either throwIO (const (pure ())) result
```

## Limits

- Run it at **migration time, not application startup**: every host process would
  otherwise race to write the registry on boot.
- It reconciles the registry, not the data. It is the second half of a schema upgrade,
  after the SQL has applied, and it does not substitute for the migration.
- A host embedding Kioku must also call `registerKiokuReadModels` once at startup before
  serving queries, which is a different call with a different job.
