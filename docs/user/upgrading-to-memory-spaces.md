# Upgrading to memory spaces

This release gives Kioku an explicit isolation boundary. Every command and event now names a
**memory space** — the outer partition that keeps one caller's memories away from another's — and
the principal responsible for the write.

If you run a single-tenant deployment and do nothing but recompile, your data keeps working: it
all belongs to one explicit space named `kioku_legacy`, and so does everything replayed from your
existing event streams. What changes is *why* it works. Nothing in Kioku treats a missing
partition as "visible everywhere"; there is no such state.

This page covers what breaks at compile time, what to do about it, how to deploy and verify the
backfill migration, and what deliberately did not change yet.

## What happens to data already in the database

Every existing row is backfilled into one explicit space named `kioku_legacy`, by the migration
`0011-kioku-memory-space-partition.sql`. Nothing moves between spaces and nothing is deleted; a
column is added, filled, and made mandatory.

Every event written before this release decodes into `legacyMemorySpaceId` — the same identifier
— the moment it is read. That applies to Kioku's own older payloads and to the even older
Rei-format ones. Aggregates rebuilt from history land in the same space the backfill put their
rows in, so the two paths cannot disagree.

Attribution follows two rules, and neither invents anything:

- An event that carried the old free-text `agentId` is attributed to that label, **marked as
  legacy**. It renders as `kioku:legacy:demo-agent`. It is never rewritten into a directory
  principal id: nobody issued `demo-agent`, two hosts could both have picked it, and promoting it
  would put an identity no directory ever vouched for into an audit trail.
- An event that recorded no agent at all — archiving a memory, completing a session, recording a
  turn — is `kioku:unattributed`. That is the honest answer, and it is a named state rather than
  an absence, so nothing downstream has to guess.

Timers already scheduled behave the same way: an L1 distillation timer whose payload predates the
memory-space field fires in the legacy space.

Encoders only ever write the new form. A stream that is rebuilt and re-encoded keeps its legacy
marking; it is not laundered into a real principal.

## What breaks at compile time

Command payloads gained required fields, and write functions gained a required first argument.
Both are deliberate: this is the one change where a silent default would preserve exactly the
footgun the work exists to remove.

You will see two kinds of error.

**Missing record fields.** Every command payload now carries `memorySpaceId` and
`actorPrincipal`; the three creation payloads (`RecordMemoryData`, `StartSessionData`,
`RecordInteractiveSessionData`) also carry `ownerPrincipal`:

```text
Constructor ‘RecordMemoryData’ does not have the required strict field(s):
    memorySpaceId :: MemorySpaceId
    actorPrincipal :: RecordedPrincipal
    ownerPrincipal :: Maybe PrincipalRef
```

**A missing context argument.** `record`, `start`, and the rest are now
`recordWithContext`, `startWithContext`, … , each taking a `MemoryAccessContext` first.

## The migration, in two steps

### 1. Build a context

An embedded host that has already authorized its user by other means builds one directly:

```haskell
import Kioku.Api.Access

hostContext :: MemoryAccessContext
hostContext =
  assumeAuthorizedMemoryContext
    (either error id (mkMemorySpaceId "kioku_legacy"))   -- or your own space
    (MemoryActor (either error id (mkPrincipalRef "agent_01h9xk3v7hf8b9c0d1e2f3g4h5")))
```

Use `legacyMemorySpaceId` if you have one collection of memories and no reason to split it. Use
your own identifier if you are separating tenants; it is opaque validated text, so it can be
whatever your own system already calls that boundary.

A host serving untrusted callers should not use `assumeAuthorizedMemoryContext` at all. Use
`authorizeMemoryAccess`, which runs a coarse credential check, a directory lookup, and a per-space
permission check in that order, and keeps their four failures distinct. See
[Scopes & Integrations](integrations.md).

### 2. Fill the payload from the context, and pass it

```haskell
result <-
  Memory.recordWithContext hostContext
    RecordMemoryData
      { memoryId = mid
      , memorySpaceId = memoryContextSpace hostContext
      , actorPrincipal = memoryContextRecordedActor hostContext
      , ownerPrincipal = Nothing
      , agentId = "demo-agent"
      , …
      }
```

`memoryContextSpace` and `memoryContextRecordedActor` are the supported way to fill those fields.
The payload is checked against the context rather than overwritten by it, so a disagreement is a
loud `MemorySpaceMismatch` or `MemoryActorMismatch` instead of a quiet rewrite — the stored event
and the decision that allowed it stay the same fact.

Set `ownerPrincipal` when the memory belongs to somebody other than the actor: an agent recording
on a person's behalf is the motivating case, and later retention or deletion questions are asked
about the owner.

## If you cannot migrate in one go

The old names survive for one release as **deprecated** wrappers:

```haskell
{-# DEPRECATED record "Use recordWithContext. This wrapper accepts only legacyMemorySpaceId and will be removed." #-}
```

They take no context and refuse any payload naming a space other than `legacyMemorySpaceId`, so
they cannot reach anybody else's data — including through a memory id belonging to another space,
which they cannot even see. You still have to add the payload fields; what you can defer is
threading a context through your call sites.

## New failure modes

| Error | Means |
| --- | --- |
| `MemoryNotPermitted` / `SessionNotPermitted` | the context authorized other actions, but not this one |
| `MemorySpaceMismatch` / `SessionSpaceMismatch` | the payload named a space the context was not minted for |
| `MemoryActorMismatch` / `SessionActorMismatch` | the payload attributed the write to somebody else |
| `MemoryCommandRejected` | the aggregate refused it |
| `MemoryNotFound` / `SessionNotFound` | no such row **in this space** — which now includes an id that exists in another one |
| `L1NotPermitted` | the context does not authorize distillation in this space |

`MemorySpaceMismatch` is a caller bug caught before anything was read: the payload and the context
disagree.

`MemoryNotFound` is where a cross-space id now lands, and that is deliberate. Every write looks
its row up inside the command's own space, so an id belonging to somewhere else is simply absent
and cannot be distinguished from one that was never written. Earlier releases reached the
aggregate and returned `MemoryCommandRejected`, which told the caller the id existed.

## Which permission each write asks for

- `MemoryRecord` — recording a memory, retagging, re-scoring confidence, and every session write
  (a session, its turns, and its lifecycle are memory being recorded).
- `MemoryForget` — superseding, archiving, and merging.
- `MemoryDistill` — running an L1 distillation pass, checked before any LLM call.

`assumeAuthorizedMemoryContext` grants all of them. A context obtained through
`authorizeMemoryAccess` grants exactly what was checked, so ask for what you intend to do.

## Background workers

A worker claims a timer and only then learns which space the work belongs to, so it takes a
`MemoryContextProvider` rather than a context:

```haskell
contexts = assumeAuthorizedContextProvider (MemoryActor …)
drainKiokuTimers Nothing contexts runtime finder
```

A refusal dead-letters the timer instead of retrying it silently: a worker that is not authorized
for a space is a configuration problem, and an operator needs to see it rather than watch it
retry every thirty seconds for an hour.

The embedding worker takes a provider for the same reason — it learns the space from the
`MemoryRecorded` event it was handed, not from its caller:

```haskell
runEmbeddingWorkerHost store contexts capability model dimensions
```

Two of its outcomes are worth knowing about. A space the provider refuses dead-letters, as above.
And an event whose `memorySpaceId` disagrees with the memory row it names dead-letters too,
without writing anything: the row's own space is read back and compared, so a stale or forged
envelope is visible rather than quietly acked as "no such memory".

`backfillMissingEmbeddings` takes an `EmbeddingBackfillScope`. `BackfillEverySpace` is what the
continuous worker runs at startup; `BackfillOneSpace` is for repairing one tenant:

```bash
kioku worker --backfill                       # every space in the database
kioku worker --backfill --space space_prod    # one space
```

Every space is the default deliberately. A worker subscribes to every space's events, so
defaulting to `KIOKU_MEMORY_SPACE` would let you run a backfill, read a count, and never learn
that the other spaces are still unsearchable.

Diagnostics name the space. Each fire runs inside a `kioku.timer.fire` span carrying
`kioku.memory_space_id`, the timer id, the attempt count, and a bounded
`kioku.timer.outcome`; and the `last_error` written to a dead-lettered timer is prefixed with the
space its payload named. Metrics carry neither the space nor the principal, and must not start
to: a space is caller-supplied text, so a counter labelled by it is an unbounded time series per
tenant.

## Workspace artifacts

Scene and persona mirrors used to be written to `.kioku/scenes/<scope-slug>.md` and
`.kioku/persona/<scope-slug>.md`. The slug is derived from the namespace, kind, and ref — all
three of which two spaces are allowed to share — so both spaces wrote to one file. They are now
rooted per space:

```text
.kioku/spaces/<space-dir>/scenes/<scope-slug>.md
.kioku/spaces/<space-dir>/persona/<scope-slug>.md
```

`<space-dir>` is not the space id. A `MemorySpaceId` is validated for a database column, not for
a path: `..` is a legal space id and would walk out of `.kioku/spaces` entirely, and on a
case-folding filesystem `space_A` and `space_a` are two spaces and one directory. It is a
sanitised readable prefix plus a digest of the exact id — the same shape, for the same reasons,
as the scope slug in the filename.

Nothing writes to the old tree any more. To relocate what is already there:

```bash
kioku migrate-artifacts                # dry run: report every move and every collision
kioku migrate-artifacts --apply        # copy the files
```

The destination space is `KIOKU_MEMORY_SPACE`, which defaults to `kioku_legacy` — the same rule
the database backfill follows, because every file in the historical tree was written before the
partition existed. `--workspace DIR` points it somewhere other than the current directory.

It copies rather than moves, so a failed verification still has the originals; removing the old
tree is your call and is deliberately not something the command will do. A destination that
already holds byte-identical content is reported as `migrated` and skipped, which is what makes a
second run a no-op. A destination holding *different* content is a `COLLISION`: it is refused,
never overwritten — the partitioned file is what the running worker writes, and a pre-partition
snapshot is older. The command exits non-zero if any collision was reported, in dry-run mode too.

One thing still touches the old tree: when every memory in a scope is forgotten, the legacy
space's historical mirror is unlinked along with the partitioned one. A merely out-of-date file
shows up in the migration plan; forgotten content surviving on disk is not out of date, it is a
retention failure.

### Ordering

Roll the pieces out in this order, which is the order in which each one stops being able to
mislead the next:

1. **Migrate the database** (`kioku-migrate up`), which backfills every row into `kioku_legacy`.
2. **Deploy the new writers and workers.** Every write now carries a space; every timer payload
   and embedding envelope names one.
3. **Drain or convert old work.** Timers scheduled by the previous release keep their old ids and
   fire in the legacy space, which is correct for a single-space installation and is the only
   thing they can safely do. Let the queue empty before step 5.
4. **Migrate the workspace artifacts** (`kioku migrate-artifacts --apply`), then point host agents
   at the new paths and remove the old tree once you have verified them.
5. **Only then create a second memory space.** Every step above is safe while `kioku_legacy` is
   the only space with rows; none of them is once a second one exists.

## The CLI

`kioku` resolves its space and actor from the environment:

- `KIOKU_MEMORY_SPACE` — default `kioku_legacy`, so an unchanged CLI operates on exactly the data
  it did before.
- `KIOKU_ACTOR` — default `kioku_cli`. The CLI is genuinely the thing acting, and naming it
  plainly beats borrowing an identity from a directory the CLI does not talk to.

A malformed value is a startup error rather than a silent fallback: a typo in a space name must
not quietly send writes somewhere else.

## Reads take a memory space

Every read function takes a `MemorySpaceId` as its first argument and returns nothing outside it:

```haskell
rows <- Memory.getActiveRowsByScope (memoryContextSpace hostContext) scope
hits <-
  Recall.recall model capability
    Recall.RecallRequest
      { memorySpaceId = memoryContextSpace hostContext
      , scope = ScopeGlobal namespace
      , …
      }
```

`memoryContextSpace` of the context that authorized the read is the value to pass. A read takes
the space rather than the whole context because reads return `Either ReadModelError` and the
permission decision has already been made: `authorizeMemoryAccess` mints a context only for
permissions it actually checked, so ask it for `MemoryRead` when you mint one.

Two behaviours are worth knowing about:

- **Recall's namespace-wide target does not widen tenancy.** A `ScopeGlobal` recall still means
  "every scope in this namespace", and it still stops at the space boundary.
- **A memory id from another space now behaves exactly like an id that does not exist.** Before
  this release the write path's idempotency precheck could tell a caller that such an id existed
  and whether it was active. It cannot any more: the precheck looks the row up inside the
  command's own space and gets nothing, so the write is refused with `MemoryNotFound` /
  `SessionNotFound` rather than `MemoryCommandRejected`. If you match on that error, this is the
  change to look for.

## Deploying the migration

**Preflight.** Take a backup or a snapshot you can restore from; this migration is forward-only.
On a large installation, measure the lock: adding a `NOT NULL` column and rebuilding the scene and
persona primary keys takes `ACCESS EXCLUSIVE` on those tables for the duration, and the backfill
rewrites every row of the seven partitioned tables.

**Apply.** `kioku-migrate` applies the migration and then reconciles keiro's read-model registry
in the same run, which the read-model version bumps need — memory models advance to v2, sessions
to v4, and turns to v2:

```bash
kioku-migrate up
kioku-migrate verify
```

A host that applies migrations as a library (through `Kioku.Migrations.kiokuMigrationPlan`) must
call `Kioku.ReadModel.reconcileReadModelRegistry` itself afterwards. Skipping it leaves every
session and memory query failing closed with `ReadModelStaleSchema`.

**Verify.** Every partitioned row should name a space, and on a single-tenant installation they
should all name the same one:

```sql
SELECT 'memories' AS table_name, memory_space_id, count(*) FROM kiroku.kioku_memories GROUP BY 1, 2
UNION ALL SELECT 'sessions', memory_space_id, count(*) FROM kiroku.kioku_sessions GROUP BY 1, 2
UNION ALL SELECT 'turns', memory_space_id, count(*) FROM kiroku.kioku_turns GROUP BY 1, 2
UNION ALL SELECT 'watermarks', memory_space_id, count(*) FROM kiroku.kioku_l1_watermarks GROUP BY 1, 2
UNION ALL SELECT 'decisions', memory_space_id, count(*) FROM kiroku.kioku_consolidation_decisions GROUP BY 1, 2
UNION ALL SELECT 'scenes', memory_space_id, count(*) FROM kiroku.kioku_scenes GROUP BY 1, 2
UNION ALL SELECT 'personas', memory_space_id, count(*) FROM kiroku.kioku_personas GROUP BY 1, 2
ORDER BY 1, 2;
```

The migration refuses to finish if a turn or watermark ends up in a different space from the
session it belongs to, so a successful run has already proved that much.

**Rolling back.** Rolling the *application* back is safe only while two things hold: the old code
ignores the additive column, and nothing has yet been written into a space other than
`kioku_legacy`. Once a second space has rows, the old code cannot see the partition and would read
and write across it. After that point, roll forward and fix, or restore the snapshot; do not
downgrade the binary.

The migration itself has no down step. Re-running it is a no-op — every statement is idempotent —
so a deployment that failed part-way can simply be re-run.

## What has not changed yet

**Recall targets are still a `MemoryScope`,** so "the exact global bucket" and "every scope in
this namespace" remain the same value with two meanings depending on which function reads it.
That asymmetry is unchanged by the partition and is documented in [Recall](recall.md).

## Related

- [Library API](library-api.md) — the full write and read surface.
- [Scopes & Integrations](integrations.md) — namespaces, scopes, and wiring an identity stack.
- [ADR-2](../adr/namespace-is-not-a-security-boundary.md) — why a namespace is not tenancy.
- [ADR-3](../adr/legacy-data-lands-in-one-explicit-space.md) — why legacy data gets a named space.
- [ADR-6](../adr/the-partition-is-a-column-not-a-schema.md) — how the boundary is enforced in
  PostgreSQL.
- [ADR-7](../adr/the-partition-reaches-the-filesystem-as-a-digest.md) — how it is enforced on
  disk, and why a space never becomes a metric label.
