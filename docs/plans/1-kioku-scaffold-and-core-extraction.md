---
id: 1
slug: kioku-scaffold-and-core-extraction
title: "kioku Scaffold and Core Extraction"
kind: exec-plan
created_at: 2026-06-24T16:31:00Z
intention: "intention_01kvx5py1yeanvyn7xh58epfnt"
master_plan: "docs/masterplans/1-kioku-reusable-agent-memory-session-library.md"
---

# kioku Scaffold and Core Extraction

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

**kioku** (記憶, "memory") is a brand-new standalone Haskell library that gives an AI agent a
durable, queryable memory and a record of its work sessions. Today Rei (a personal-coaching
agent system) has this capability, but it is hard-wired to Rei's own concepts: a memory can
only be "about" a Rei intention or a Rei habit, and a session can only have one of fifteen
fixed Rei "coaching focus" modes. This plan lifts that machinery out of Rei into a reusable
library so that three different agent platforms — Rei, mori (a multi-repo agent runner), and
shikigami (an autonomous agent platform) — can share one memory engine.

After this plan is complete, a person who has never seen this codebase can clone the new
`kioku` repository, run two commands, and watch an agent **record a memory in a named scope and
then recall it back by that scope** — proving the full write-then-read loop works end to end on
a real PostgreSQL database. Concretely, after `just create-database` and a build, this command:

```bash
cabal run kioku -- demo
```

prints a transcript that records a memory ("prefers concise answers") under the scope
`rei/intention/intention_abc`, then queries that scope and prints the same memory back. That
observable behavior — write, then scoped recall returns it — is the acceptance criterion for the
whole plan.

What makes kioku different from Rei's current code, and why it matters:

- A memory is an **event-sourced aggregate**. "Event-sourced" means the source of truth is an
  append-only log of facts (events) on a stream, never a mutable row. The queryable table is a
  *projection* — a derived view rebuilt from events. We use the `kiroku` event store (the stream
  log) and `keiki`/`keiro` (the aggregate state machine and command runner). Each new fact about
  a memory (recorded, superseded, archived, re-tagged, confidence-changed) is an immutable event.
- A memory is scoped by a **generic `MemoryScope`** (a namespace plus an optional typed entity
  reference) instead of Rei's hard-coded `IntentionId`/`HabitId`. This is the single decoupling
  that lets mori and shikigami reuse the engine. Rei maps its `IntentionId` into
  `ScopeEntity "rei" "intention" "<id-text>"` at the edge; mori maps a repo id into
  `ScopeEntity "mori" "repo" "<id>"`; and so on.
- The memory's content is **full-text searchable** out of the box: the read-model table carries a
  PostgreSQL `tsvector` generated column with a GIN index, so recall can do real text search, not
  just `WHERE status='active'`.

This plan (EP-1) is only the **foundation**. It does not build the elevated hybrid (vector +
text) retrieval (that is EP-2) or the LLM distillation pyramid (EP-3). It delivers the project
skeleton, the two aggregates (Memory and Session), the inline projections (structured row + FTS),
the public write API, a placeholder scoped-recall read API, the migrations package, and a CLI
demo that proves the loop. Everything else in the kioku initiative hard-depends on this plan, so
it must exist and build before any sibling plan can compile.

This plan also carries one forward-looking responsibility: kioku's event JSON codec must be able
to **read Rei's existing event JSON** so that EP-4 (the Rei migration) can replay Rei's historical
memory/session streams into kioku without a lossy transform. The exact field-by-field mapping is
documented here (see Interfaces and Dependencies, IP-6) and is the binding contract between EP-1
and EP-4.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `kioku` repo created at `/Users/shinzui/Keikaku/bokuno/kioku` with the 4-package layout,
      `cabal.project` pin-set copied from kizashi, flake/nix/Justfile/process-compose/mori files in
      place; `cabal build all` succeeds; `just create-database` applies kiroku + keiro + kioku
      migrations to a fresh DB with no errors. Completed 2026-06-24: `cabal build all` exited 0;
      `just create-database` applied 21 migrations; `psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt
      kiroku.kioku_*'` listed `kioku_memories`, `kioku_sessions`, and `kioku_turns`.
- [x] M1: `kioku-api` defines `Kioku.Api.Scope` (`Namespace`, `MemoryScope`, `ScopeKind`),
      `Kioku.Api.Types` (`MemoryType`, `Confidence`, `MemoryRecord`), `Kioku.Id`, `Kioku.Prelude`.
      Completed 2026-06-24: the package exposes all four modules and they compile in
      `cabal build all`.
- [ ] M2: Memory aggregate (`Kioku.Memory.Domain`, `.EventStream`, `.ReadModel`) builds; the
      `kioku_memories` inline row + `content_tsv` FTS projection upserts on every event constructor.
- [ ] M2: `Kioku.Memory` write API (`record`/`supersede`/`archive`/`updateTags`/`updateConfidence`)
      and placeholder `Kioku.Recall` scoped queries build and run.
- [ ] M2: `cabal run kioku -- demo` records a memory in a scope and recalls it back (observable).
- [ ] M3: Session aggregate (`Kioku.Session.Domain`, `.EventStream`, `.ReadModel`) builds; events
      `SessionStarted`/`SessionCompleted`/`SessionFailed`/`InteractiveSessionRecorded`/`TurnRecorded`;
      `Kioku.Session` write API builds and a session start→turn→complete demo runs.
- [ ] M4: A golden test in `kioku-core/test` decodes a sample Rei `agent_memory` JSON payload
      (`{"type":"agent_memory_recorded","data":{…}}`) and a sample Rei `agent_session` payload
      through kioku's codec into the kioku event types, proving IP-6 backward compatibility.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Local Postgres TCP port collision.** The repo-local Postgres data directory was initialized, but
  `pg_ctl -D "$PGDATA" -l "$PGLOG" -o "-k $PGHOST" start` failed because another server was already
  bound to TCP port 5432. Starting with TCP disabled,
  `pg_ctl -D "$PGDATA" -l "$PGLOG" -o "-k $PGHOST -c listen_addresses=''" start`, succeeded and
  allowed `just create-database` to apply the full migration suite over the Unix socket.
  Evidence: the log showed `FATAL: could not create any TCP/IP sockets`, then `just
  create-database` applied 21 migrations and `\dt kiroku.kioku_*` listed the three kioku tables.


## Decision Log

Record every decision made while working on the plan.

- Decision: kioku's hand-written codec performs **lenient decode**: it accepts BOTH kioku's native
  flat `{"kind": "...", ...}` shape AND Rei's legacy `{"type": "agent_memory_recorded", "data":
  {...}}` shape. Encode always writes the native flat shape.
  Rationale: IP-6 makes EP-1 responsible for letting EP-4 replay Rei's historical streams. A
  lenient decoder lets EP-4 copy event payloads verbatim into kioku streams (no transform), and a
  rebuild of the projection re-reads them. The two shapes are unambiguous: the legacy shape has a
  top-level `"type"` + `"data"` envelope; the native shape has a top-level `"kind"` and flat fields.
  Date: 2026-06-24

- Decision: kioku stores the scope as three flat columns/fields — `namespace TEXT`,
  `scope_kind TEXT NULL`, `scope_ref TEXT NULL` — not as a nested JSON object, and `ScopeGlobal ns`
  is `(ns, NULL, NULL)` while `ScopeEntity ns kind ref` is `(ns, kind, ref)`.
  Rationale: it maps cleanly to Rei's existing `(anchor_type, anchor_id)` columns (so the EP-4
  field map is mechanical), it indexes well, and it keeps the codec byte-stable (no polymorphic
  payload). The MasterPlan IP-2 / Decision Log already chose a concrete `MemoryScope` value over a
  type parameter for exactly this reason.
  Date: 2026-06-24

- Decision: `priority :: Int` with sentinel `priority = 0` meaning "always inject" (highest);
  larger numbers mean lower priority (1 = high, 2 = medium, …). Rei's current model has no numeric
  priority, so kioku introduces one with a documented default of `100` ("normal").
  Rationale: the MasterPlan asks for a numeric priority with a documented "always inject" sentinel;
  `0` as the strongest signal is conventional and sorts first ascending.
  Date: 2026-06-24

- Decision: Reserve the `MemoryMerged` event constructor on the Memory event type now (EP-1) even
  though no command emits it until EP-3, and add `Merged` as a terminal vertex.
  Rationale: declaring the event and vertex now keeps the codec's `eventTypes` list and the
  transducer's terminal set stable across EP-3, so EP-3 adds only an edge and a command, never a
  breaking codec change. The inline projection handles `MemoryMerged` as a status update to
  `'merged'`.
  Date: 2026-06-24

- Decision: `TurnRecorded` is an **opt-in** event on the Session stream; the Session vertex
  `Running` is non-terminal so turns can append while a session is open. A host that does not want
  turns simply never issues `recordTurn`.
  Rationale: MasterPlan Decision Log ("Raw conversation turns are an optional, per-session
  capability"). Rei's current sessions record no turns; shikigami/mori may.
  Date: 2026-06-24

- Decision: EP-1 pins `kiroku` to `4312aa8cc3e4f6ab0d19fc8bb12d0dd9f8cc164a`, matching Rei and mori,
  instead of the older kizashi scaffold tag `322096c88ce3db125e9cd0cea3fcf5f96c158db2`.
  Rationale: the MasterPlan Surprises & Discoveries section recorded the ecosystem pin skew and
  explicitly directed EP-1 to use the newer consumer-compatible pin. Keeping kioku on the same
  `kiroku` revision as Rei and mori avoids introducing a second event-store pin when those consumers
  import kioku locally.
  Date: 2026-06-24

- Decision: `mori repo id --new` is unavailable in the installed mori CLI, so M1 created
  `mori/repo-id` with the fallback TypeID-shaped value `repo_01kvx8x8mte41a2mbr8y9g9q2h`.
  Rationale: the plan requires a fresh repo id and explicitly allows a fallback when mori cannot mint
  one. A later registry normalization can replace it with a canonical TypeID if mori adds a minting
  command.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this codebase. Read it fully before running anything.

### Where things live

You will create a **new repository** at the absolute path `/Users/shinzui/Keikaku/bokuno/kioku`.
It is a peer directory of the source repositories you will copy from:

- `/Users/shinzui/Keikaku/bokuno/kizashi` — an existing Haskell project that uses the exact same
  event-sourcing stack you will use. It is your **template for the scaffold** (project layout,
  `cabal.project` pin-set, flake/nix files, Justfile, migrations composition, the per-aggregate
  code shape). You copy its structure, not its domain.
- `/Users/shinzui/Keikaku/bokuno/rei-project/rei` — the Rei monorepo. Its
  `rei-core/src/Rei/Modules/AgentMemory/` and `.../AgentSession/` directories are the **source of
  the domain logic** you generalize. You will not modify Rei in this plan; you only read it.

This ExecPlan file itself lives in the kioku repo at
`docs/plans/1-kioku-scaffold-and-core-extraction.md` (it is the EP-1 of MasterPlan #1,
`docs/masterplans/1-kioku-reusable-agent-memory-session-library.md`). The MasterPlan's
Integration Points IP-1 through IP-6 are binding contracts; they are restated and made concrete
in the Interfaces and Dependencies section below.

### Terms of art (defined in plain language)

- **Event sourcing.** The source of truth for an entity is an append-only sequence of immutable
  facts called *events*, kept on a named *stream* in the `kiroku` event store (a PostgreSQL-backed
  log). To know the current value you fold the events. To make events queryable you build a
  *projection*.
- **Aggregate.** A single entity whose write rules are enforced by a small state machine. Here a
  Memory and a Session are each an aggregate. Each has its own stream, e.g.
  `kioku_memory-<id>` and `kioku_session-<id>`.
- **keiki `SymTransducer`.** keiki is the library that expresses an aggregate's write logic as a
  pure state machine: a set of *vertices* (states), *edges* (which command is valid in which state
  and what event it emits), and an optional *register file* (extra carried state). A `SymTransducer`
  is that machine. We use empty registers (`'[]`) for both aggregates — the lifecycle lives entirely
  in the vertex.
- **keiro.** The runtime that runs a command against an aggregate: it loads the stream, folds it
  through the transducer to the current vertex, validates the command, appends the emitted event(s),
  and runs any *inline projections* in the same database transaction. The key function is
  `runCommandWithProjections opts eventStream streamFn cmd projections`.
- **Inline projection.** A function `event -> RecordedEvent -> Tx.Transaction ()` that upserts a
  read-model row in the **same transaction** as the event append. Because it commits atomically with
  the event, a read immediately after the write sees the row ("read-your-own-writes"). Inline
  projections must be simple and never fail (no network calls); they MUST handle every event
  constructor or the append transaction aborts.
- **Codec.** A hand-written `Keiro.Codec.Codec event` value that says how to serialize/deserialize
  an event to/from JSON. kizashi's style is a flat JSON object with a `"kind"` discriminator string
  plus flat fields. We mirror that and additionally make `decode` accept Rei's legacy shape.
- **`tsvector` / FTS.** PostgreSQL's full-text search type. A `GENERATED ALWAYS AS
  (to_tsvector('english', content)) STORED` column computes a searchable index of the memory's text;
  a GIN index over it makes `content_tsv @@ to_tsquery(...)` fast.
- **codd.** The migration tool. Migrations are timestamped `.sql` files embedded into a binary via
  Template Haskell `embedDir` and applied in order, idempotently. kioku composes its own migrations
  *after* the kiroku event-store migrations and the keiro framework migrations.
- **TypeID / KindID.** An id scheme rendering as `<prefix>_<base32-uuidv7>`, e.g.
  `kioku_memory_01j…`. `KindID "kioku_memory"` is the compile-time-checked flavor (from
  `mmzk-typeid`). UUIDv7 makes ids sort by creation time.
- **Namespace / MemoryScope / ScopeKind.** kioku's generic scoping. `Namespace` is a host label
  like `"rei"`/`"mori"`/`"shikigami"`. `MemoryScope` is either `ScopeGlobal ns` (whole-namespace) or
  `ScopeEntity ns kind ref` (a typed entity reference, e.g. kind `"intention"`, ref a typeid text).
  `ScopeKind` is the kind tag.

### The kikan event-sourcing stack (read-only background)

You do not build keiki/keiro/kiroku/shibuya; you depend on them as git-pinned packages, exactly as
kizashi does. The relevant modules you will import:

- `Keiki.Builder` (as `B`), `Keiki.Core` (`HsPred`, `SymTransducer`, `RegFile`), `Keiki.Generics`
  (`emptyRegFile`), `Keiki.Generics.TH` (`deriveAggregate`).
- `Keiro.Codec` (`Codec(..)`, `EventType(..)`), `Keiro.EventStream` (`EventStream(..)`,
  `SnapshotPolicy(..)`), `Keiro.Stream` (`Stream`, `entityStream`, `categoryUnsafe`, `streamName`),
  `Keiro.Command` (`RunCommandOptions(..)`, `defaultRunCommandOptions`), `Keiro.Projection`
  (`InlineProjection(..)`, `runCommandWithProjections`), `Keiro.ReadModel` (`ReadModel(..)`,
  `ConsistencyMode(..)`, `runQueryWith`).
- `Kiroku.Store.Connection` (`KirokuStore`, `defaultConnectionSettings`, `withStore`),
  `Kiroku.Store.Effect` (`Store`, `runStorePool`), `Kiroku.Store.Error` (`StoreError`),
  `Kiroku.Store.Types` (`RecordedEvent`, `GlobalPosition`), `Kiroku.Store.Migrations`
  (`kirokuMigrations`).
- `Keiro.Migrations` (`keiroFrameworkMigrations`), `Shibuya.Telemetry.Effect` (`Tracer`, `Tracing`,
  `runTracing`).

### The reference shape you are copying

The canonical kizashi aggregate is `Kizashi.Actor.*` with four files: `Domain.hs` (the transducer),
`EventStream.hs` (the codec + stream + `EventStream` record), `Http.hs` (the write handler), and
`ReadModel.hs` (the inline projection + read models). kioku has no HTTP server, so instead of
`Http.hs` you write a thin **write-API module** (`Kioku.Memory` / `Kioku.Session`) that calls
`runCommandWithProjections` directly. The full verbatim `Kizashi.Actor.*` code, the kizashi
`App.hs` effect stack, the migrations composition, and the kizashi-api prelude/ids are reproduced
in the milestone steps below so you never have to leave this document.

### What already exists vs. what you create

Nothing exists in `/Users/shinzui/Keikaku/bokuno/kioku` yet — you create the whole repo. Rei's
modules and kizashi's files already exist and are read-only inputs.


## Plan of Work

The work is four milestones. M1 stands up the buildable, migratable skeleton. M2 delivers the
Memory aggregate end to end with the observable CLI demo. M3 adds the Session aggregate including
optional turns. M4 proves Rei-JSON backward-compat with a golden test. Each milestone leaves the
tree building (`cabal build all`) and is independently verifiable.

### Milestone M1 — Project scaffold that builds and migrates

**Scope and result.** At the end of M1, `/Users/shinzui/Keikaku/bokuno/kioku` is a git repo with
four packages (`kioku-api`, `kioku-core`, `kioku-cli`, `kioku-migrations`), the kikan `cabal.project`
pin-set copied verbatim from kizashi, the nix/flake/Justfile/process-compose/mori files, and the
`kioku-api` wire types. `cabal build all` succeeds and `just create-database` applies the kiroku +
keiro + kioku migrations to a fresh PostgreSQL database. There are no aggregates yet; the goal is a
green build and a migrated empty schema.

**Files created in M1** (all under `/Users/shinzui/Keikaku/bokuno/kioku`):

`cabal.project` — copy kizashi's verbatim, changing only the four `packages:` lines to the kioku
package dirs. The full pin-set to reproduce exactly:

```text
packages:
  kioku-api
  kioku-core
  kioku-cli
  kioku-migrations

with-compiler: ghc-9.12.4

source-repository-package
  type: git
  location: https://github.com/shinzui/keiki.git
  tag: bc987f46393b604c335f034385b4c3c1ad118074

source-repository-package
  type: git
  location: https://github.com/shinzui/keiki.git
  tag: bc987f46393b604c335f034385b4c3c1ad118074
  subdir: keiki-codec-json

source-repository-package
  type: git
  location: https://github.com/shinzui/keiro.git
  tag: f1d67a01b7457387a4861e7268d1c521ef82287d
  subdir: keiro

source-repository-package
  type: git
  location: https://github.com/shinzui/keiro.git
  tag: f1d67a01b7457387a4861e7268d1c521ef82287d
  subdir: keiro-core

source-repository-package
  type: git
  location: https://github.com/shinzui/keiro.git
  tag: f1d67a01b7457387a4861e7268d1c521ef82287d
  subdir: keiro-migrations

source-repository-package
  type: git
  location: https://github.com/shinzui/keiro.git
  tag: f1d67a01b7457387a4861e7268d1c521ef82287d
  subdir: keiro-pgmq

source-repository-package
  type: git
  location: https://github.com/shinzui/kiroku.git
  tag: 322096c88ce3db125e9cd0cea3fcf5f96c158db2
  subdir: kiroku-store

source-repository-package
  type: git
  location: https://github.com/shinzui/kiroku.git
  tag: 322096c88ce3db125e9cd0cea3fcf5f96c158db2
  subdir: kiroku-store-migrations

source-repository-package
  type: git
  location: https://github.com/shinzui/kiroku.git
  tag: 322096c88ce3db125e9cd0cea3fcf5f96c158db2
  subdir: kiroku-test-support

source-repository-package
  type: git
  location: https://github.com/shinzui/kiroku.git
  tag: 322096c88ce3db125e9cd0cea3fcf5f96c158db2
  subdir: shibuya-kiroku-adapter

source-repository-package
  type: git
  location: https://github.com/shinzui/shibuya.git
  tag: 3f276ee190e563fddb0bc81e01d62a96a1b31715
  subdir: shibuya-core

source-repository-package
  type: git
  location: https://github.com/shinzui/pgmq-hs.git
  tag: 973c1076f469448818de5d2044a483296be2c02e
  subdir: pgmq-core pgmq-hasql pgmq-effectful pgmq-migration

source-repository-package
  type: git
  location: https://github.com/shinzui/shibuya-pgmq-adapter.git
  tag: 71a7b82223449d84c395b64e480c9cfe4ff274f1
  subdir: shibuya-pgmq-adapter

source-repository-package
  type: git
  location: https://github.com/shinzui/hasql-migration
  tag: 4aaff6c0919d1fe8e1c248c3ce4ce05775c59c8c

source-repository-package
  type: git
  location: https://github.com/shinzui/ephemeral-pg.git
  tag: 304c160f25570ea5e225baf5024778c93f434b56

source-repository-package
  type: git
  location: https://github.com/shinzui/codd-project.git
  tag: d176b3088f23ef2218c7a1f31835e8ee0c0601aa
  subdir: codd

source-repository-package
  type: git
  location: https://github.com/shinzui/hasql-project.git
  tag: 2bc7ace5db942d87962990bba0b2323ec4c67770
  subdir: hasql-notifications

package codd
  tests: False
  benchmarks: False

allow-newer:
  haxl:time
```

`flake.nix`, `nix/haskell.nix`, `nix/treefmt.nix`, `nix/pre-commit.nix`, `.envrc` — copy kizashi's
verbatim, replacing the string `kizashi` with `kioku` wherever it appears (description text, and the
`PGDATABASE=kizashi` line which must become `PGDATABASE=kioku`). The `.envrc` is exactly:

```text
use flake
eval "$shellHook"
```

`Justfile` — copy kizashi's verbatim, replacing every `kizashi` token with `kioku` (so `migrate`
touches `kioku-migrations/kioku-migrations.cabal` and runs `cabal run kioku-migrate`, and
`new-migration` writes to `kioku-migrations/sql-migrations/`). The `CODD_SCHEMAS=kiroku` line stays
(kioku read models live in the `kiroku` schema, the kizashi convention).

`process-compose.yaml` — copy kizashi's verbatim (it references `just create-database` and the PG
env vars, no `kizashi`-specific names except the `$PGLOG` echo).

`mori.dhall` — copy kizashi's, changing `name = "kioku"`, the `description`, the `repos` entry to
`shinzui/kioku`, and set `dependencies` to exactly the five the prompt requires:

```dhall
    , dependencies =
      [ "shinzui/kiroku"
      , "shinzui/keiro"
      , "shinzui/keiki"
      , "shinzui/shibuya"
      , "shinzui/pgmq-hs"
      ]
```

`mori/repo-id` — generate a fresh repo id (a TypeID `repo_…`). Do **not** copy kizashi's id. The
Concrete Steps below show the command (`mori repo init`-style or a generated typeid). If mori cannot
mint one, write a placeholder `repo_<uuidv7>` and note it in the Decision Log.

`kioku-api/kioku-api.cabal` — model on kizashi's `kizashi-api.cabal`. The minimal dependency set the
prompt requires (no keiro/kiroku/effectful): `aeson, base, generic-lens, lens, mmzk-typeid, text,
time, uuid`, plus `containers` (for `Set`/`Map` in the read-row and scope helpers). Exposed modules:
`Kioku.Prelude`, `Kioku.Id`, `Kioku.Api.Scope`, `Kioku.Api.Types`. Use the same `common warnings`
and `common shared` stanzas (GHC2024, the same default-extensions list).

`kioku-core/kioku-core.cabal` — model on `kizashi-core.cabal` but trimmed: depends on `kioku-api`
plus `keiki, keiro, keiro-core, kiroku-store, shibuya-core, shibuya-kiroku-adapter, effectful,
effectful-core, hasql, hasql-pool, hasql-transaction, contravariant-extras, containers, aeson,
bytestring, generic-lens, lens, mmzk-typeid, text, time, uuid`. (Drop servant/warp/http/pgmq/otel
unless a build error demands one; add back the minimum that errors require — e.g.
`hs-opentelemetry-api` if `Shibuya.Telemetry.Effect` pulls it.) Exposed modules grow per milestone;
M1 needs only `Kioku.App`. Add a `test-suite kioku-test` (`tasty` + `tasty-hunit`) depending on
`kioku-migrations:test-support` (used in M4).

`kioku-cli/kioku-cli.cabal` — model on `kizashi-cli.cabal`: a library `Kioku.Cli` (+ a
`Kioku.Cli.Commands.Demo`) and an `executable kioku` whose `Main.hs` calls `Kioku.Cli.main`. Depends
on `kioku-core`, `kioku-api`, `kiroku-store`, `optparse-applicative`, `text`, `base`.

`kioku-migrations/kioku-migrations.cabal` — copy `kizashi-migrations.cabal` structure exactly:
library `Kioku.Migrations`, executable `kioku-migrate`, public sublibrary `test-support` exposing
`Kioku.Migrations.TestSupport`. Same dependency set (`codd`, `file-embed`, `keiro-migrations`,
`kiroku-store-migrations`, `streaming`, plus the test-support deps `ephemeral-pg`, `attoparsec`,
`aeson`, `containers`).

`kioku-migrations/src/Kioku/Migrations.hs` — copy kizashi's `Kizashi/Migrations.hs` verbatim,
renaming `Kizashi`→`Kioku` and `kizashi`→`kioku` throughout. The composition stays
`kirokuMigrations <> keiroFrameworkMigrations <> kiokuOwnMigrations` with
`$(embedDir "sql-migrations")`.

`kioku-migrations/app/Main.hs` — copy kizashi's verbatim, renaming to `runKiokuMigrationsNoCheck`.

`kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs` — copy kizashi's
`Kizashi/Migrations/TestSupport.hs` verbatim, renaming, exposing `withKiokuMigratedDatabase`.

`kioku-migrations/sql-migrations/2026-06-24-00-00-00-kioku-base.sql` — the base schema (the
`kioku_memories` and `kioku_sessions` tables, plus `kioku_turns`). Full SQL is in the Concrete Steps;
it begins `-- codd: in-txn` and `SET search_path TO kiroku, pg_catalog;`.

`kioku-core/src/Kioku/App.hs` — copy kizashi's `App.hs` effect stack verbatim, renaming the module
to `Kioku.App` and the `AppEnv`/`runAppIO` accordingly. The stack is
`type AppEffects = '[Store, Error StoreError, Tracing, IOE]` and
`runAppIO env = runEff . runTracing (tracer env) . runErrorNoCallStack . runStorePool (store env)`.

`kioku-api/src/Kioku/Prelude.hs`, `Kioku/Id.hs`, `Kioku/Api/Scope.hs`, `Kioku/Api/Types.hs` — full
contents in the Concrete Steps and Interfaces sections.

**Acceptance for M1.** From inside `/Users/shinzui/Keikaku/bokuno/kioku` (in the nix dev shell):
`cabal build all` exits 0; `just create-database` exits 0 and a follow-up
`psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt kiroku.*'` lists `kioku_memories`, `kioku_sessions`,
`kioku_turns` alongside the kiroku/keiro framework tables.

### Milestone M2 — Memory aggregate, FTS projection, write API, scoped recall, CLI demo

**Scope and result.** At the end of M2, kioku can record a memory in a scope and recall it back by
scope, both through the public API and via `cabal run kioku -- demo`. This is the plan's headline
acceptance. You add the Memory aggregate (transducer, codec, stream), the inline projection that
upserts the structured row and lets PostgreSQL compute the `content_tsv`, the `Kioku.Memory` write
API, and the placeholder `Kioku.Recall` scoped read queries.

**Files added in M2:**

- `kioku-core/src/Kioku/Memory/Domain.hs` — the keiki transducer. Vertices
  `NotCreated | Active | Superseded | Merged | Archived` (terminal: `Superseded`, `Merged`,
  `Archived`). Commands and events for record/supersede/archive/updateTags/updateConfidence, plus the
  reserved `MemoryMerged` event (no command emits it in EP-1; the transducer has no `Merged` edge
  yet, only the terminal vertex and the codec entry). Empty registers. Full code in Concrete Steps.
- `kioku-core/src/Kioku/Memory/EventStream.hs` — the hand-written `Codec MemoryEvent` (native flat
  `"kind"` shape on encode, lenient decode that also reads Rei's `{"type","data"}` shape), the stream
  `kioku_memory-<id>` via `Stream.entityStream (Stream.categoryUnsafe "kioku_memory")`, and the
  `EventStream` record.
- `kioku-core/src/Kioku/Memory/ReadModel.hs` — the `memoryInlineProjection :: InlineProjection
  MemoryEvent` upserting `kioku_memories` (handling all six event constructors: Recorded, Superseded,
  Archived, TagsUpdated, ConfidenceUpdated, Merged), and the `ReadModel`s + hasql statements for the
  scoped queries used by `Kioku.Recall`.
- `kioku-core/src/Kioku/Memory.hs` — the public write API: `record`, `supersede`, `archive`,
  `updateTags`, `updateConfidence`, each calling `runCommandWithProjections` with
  `[memoryInlineProjection]`, mirroring Rei's StoreHandler idempotency (pre-check the inline row).
- `kioku-core/src/Kioku/Recall.hs` — placeholder scoped reads: `getActiveByScope`, `getGlobal`,
  `getBySession`, `getByType`. SQL-only (no vector/RRF — that's EP-2).
- `kioku-cli/src/Kioku/Cli/Commands/Demo.hs` and `Kioku/Cli.hs` and `app/Main.hs` — the `demo`
  subcommand.

The `kioku-core.cabal` `exposed-modules` grows to add `Kioku.Memory.Domain`,
`Kioku.Memory.EventStream`, `Kioku.Memory.ReadModel`, `Kioku.Memory`, `Kioku.Recall`.

**Acceptance for M2.** `cabal build all` exits 0. `cabal run kioku -- demo` prints a transcript
(shown in Validation) that records a memory under scope `rei/intention/intention_demo` and then,
querying `getActiveByScope (ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_demo")`,
prints back the same memory id and content. A direct
`psql -h "$PGHOST" -d "$PGDATABASE" -c "SELECT memory_id, namespace, scope_kind, scope_ref, content,
content_tsv IS NOT NULL AS has_tsv FROM kiroku.kioku_memories;"` shows one row with a non-null
`content_tsv`, proving the FTS generated column is populated.

### Milestone M3 — Session aggregate with optional turns

**Scope and result.** At the end of M3, kioku models an agent session as an aggregate with events
`SessionStarted`, `SessionCompleted`, `SessionFailed`, `InteractiveSessionRecorded`, and the opt-in
`TurnRecorded`. The session vertex `Running` is non-terminal so `TurnRecorded` can append while the
session is open; `Completed`, `Failed`, `Interactive` are terminal. The `focus` field is free-form
`Text` (replacing Rei's 15-constructor `CoachingFocusType`), and the subject reference is the generic
`subjectRef :: Maybe Text` plus a `scope :: MemoryScope`.

**Files added in M3:**

- `kioku-core/src/Kioku/Session/Domain.hs` — the transducer (mirrors Rei's AgentSession transducer
  but with `focus :: Text`, `scope :: MemoryScope`, and an extra `RecordTurn` edge out of `Running`
  back to `Running`).
- `kioku-core/src/Kioku/Session/EventStream.hs` — codec (native + lenient Rei decode) and stream
  `kioku_session-<id>`.
- `kioku-core/src/Kioku/Session/ReadModel.hs` — inline projection upserting `kioku_sessions` (all
  five event constructors) and inserting a `kioku_turns` row on `TurnRecorded`.
- `kioku-core/src/Kioku/Session.hs` — write API `start`, `complete`, `fail`, `recordInteractive`,
  `recordTurn`.
- Extend the `demo` command (or add `demo-session`) to start a session, record a turn, and complete
  it, then read the session and its turn back.

**Acceptance for M3.** `cabal build all` exits 0. A session demo records a turn and completes; a
`psql` query of `kioku.kioku_sessions` and `kioku.kioku_turns` shows the session `status='completed'`
and one turn row.

### Milestone M4 — Rei-JSON backward-compatible decode (golden test)

**Scope and result.** At the end of M4, a golden test in `kioku-core/test` proves that kioku's codec
`decode` reads a real Rei `agent_memory_recorded` JSON payload and a Rei `agent_session_started`
payload (the `{"type":…,"data":…}` envelope with snake_case fields and `anchor_type`/`anchor_id`)
into the corresponding kioku event values. This is the EP-1↔EP-4 seam (IP-6) made executable.

**Files added in M4:**

- `kioku-core/test/Main.hs` (tasty entry) and `kioku-core/test/Kioku/ReiCompatSpec.hs` — the golden
  test. It embeds two sample JSON strings (taken from the field map in IP-6 below), calls the Memory
  and Session codec `decode`, and asserts the decoded kioku event equals the expected value.

**Acceptance for M4.** `cabal test kioku-core` runs and the `ReiCompat` test group passes, with the
test failing if you break the lenient decode (verify by temporarily removing the legacy branch and
observing a red test, then restoring it).


## Concrete Steps

Run all commands from inside the new repo directory `/Users/shinzui/Keikaku/bokuno/kioku` unless
stated otherwise, and inside the nix dev shell (which exports the PG env vars). Enter the shell with
`direnv allow` (after writing `.envrc`) or `nix develop`.

### Step 0 — Create the repo and copy the scaffold

```bash
mkdir -p /Users/shinzui/Keikaku/bokuno/kioku
cd /Users/shinzui/Keikaku/bokuno/kioku
git init
# Copy scaffold files from kizashi, then rename tokens. Do these one file at a time and
# rename 'kizashi'->'kioku' / 'Kizashi'->'Kioku' / 'PGDATABASE=kizashi'->'PGDATABASE=kioku'.
cp /Users/shinzui/Keikaku/bokuno/kizashi/flake.nix ./flake.nix
mkdir -p nix
cp /Users/shinzui/Keikaku/bokuno/kizashi/nix/haskell.nix nix/haskell.nix
cp /Users/shinzui/Keikaku/bokuno/kizashi/nix/treefmt.nix nix/treefmt.nix
cp /Users/shinzui/Keikaku/bokuno/kizashi/nix/pre-commit.nix nix/pre-commit.nix
cp /Users/shinzui/Keikaku/bokuno/kizashi/process-compose.yaml ./process-compose.yaml
cp /Users/shinzui/Keikaku/bokuno/kizashi/Justfile ./Justfile
cp /Users/shinzui/Keikaku/bokuno/kizashi/.envrc ./.envrc
cp /Users/shinzui/Keikaku/bokuno/kizashi/mori.dhall ./mori.dhall
printf 'use flake\neval "$shellHook"\n' > .envrc
```

After copying, edit each file to replace `kizashi`/`Kizashi` with `kioku`/`Kioku`. In `nix/haskell.nix`
the only functional change is `export PGDATABASE=kizashi` → `export PGDATABASE=kioku`. In `mori.dhall`
set `name`, `description`, `repos`, and the five-element `dependencies` list shown in the Plan of Work.

Generate a fresh `mori/repo-id`:

```bash
mkdir -p mori
# Prefer mori's own minting if available; otherwise mint a typeid-shaped id.
mori repo id --new 2>/dev/null > mori/repo-id || \
  printf 'repo_%s\n' "$(uuidgen | tr 'A-Z' 'a-z' | tr -d '-')" > mori/repo-id
cat mori/repo-id
```

Expected: a single line like `repo_01k…`. If you fell back to the `uuidgen` branch, note it in the
Decision Log so a later step can re-register through mori.

Write `cabal.project` with the exact content from the Plan of Work (the kioku `packages:` block plus
the verbatim pin-set).

### Step 1 — Write the four `.cabal` files

Create `kioku-api/kioku-api.cabal`, `kioku-core/kioku-core.cabal`, `kioku-cli/kioku-cli.cabal`,
`kioku-migrations/kioku-migrations.cabal` per the Plan of Work. The `kioku-api` library stanza
(minimal-deps wire contract):

```text
library
  import:          warnings, shared
  hs-source-dirs:  src
  exposed-modules:
    Kioku.Api.Scope
    Kioku.Api.Types
    Kioku.Id
    Kioku.Prelude
  build-depends:
    , aeson         >=2.2
    , base          >=4.21 && <5
    , containers    >=0.6
    , generic-lens  >=2.2
    , lens          >=5.2
    , mmzk-typeid   >=0.7
    , text          >=2.1
    , time          >=1.12
    , uuid          >=1.3
```

Use kizashi's `common warnings` and `common shared` blocks verbatim (GHC2024 + the
`BlockArguments DeriveAnyClass DuplicateRecordFields MultilineStrings OverloadedLabels
OverloadedRecordDot OverloadedStrings QualifiedDo TemplateHaskell` extension list).

### Step 2 — Write `kioku-api` modules

`kioku-api/src/Kioku/Prelude.hs` — copy kizashi's prelude verbatim, renaming the module to
`Kioku.Prelude`. It re-exports `Generic`, the common base functions, `Text`, the aeson event-options,
`Control.Lens`, etc., and **must not** re-export `Data.Generics.Labels ()` (that orphan collides with
the keiki `B.do` builder; modules that need `^. #field` import it themselves). Keep its
`eventAesonOptions` (`TaggedObject "type" "data"`, `camelTo2 '_'`, `tagSingleConstructors = True`) —
this is exactly the encoding Rei used, which is why M4's golden test can rely on the snake_case tag
strings.

`kioku-api/src/Kioku/Id.hs` — copy kizashi's `Kizashi/Id.hs` shape but with kioku's ids. Define:

```haskell
type MemoryId  = KindID "kioku_memory"
type SessionId = KindID "kioku_session"

genMemoryId  :: (MonadIO m) => m MemoryId
genMemoryId  = KindID.genKindID @"kioku_memory"
genSessionId :: (MonadIO m) => m SessionId
genSessionId = KindID.genKindID @"kioku_session"
```

Keep kizashi's `idText`/`parseId` helpers verbatim (prefix-polymorphic). Drop the servant
`FromHttpApiData`/`ToHttpApiData` orphans (kioku-api has no servant dependency).

`kioku-api/src/Kioku/Api/Scope.hs` — the generic scoping types, EXACTLY as quoted in MasterPlan IP-2,
plus flat-column helpers used by the read models and codec:

```haskell
module Kioku.Api.Scope
  ( Namespace (..)
  , ScopeKind (..)
  , MemoryScope (..)
  , scopeNamespaceText
  , scopeKindText
  , scopeRefText
  , scopeFromColumns
  ) where

import Kioku.Prelude

-- | A host label: "rei", "mori", "shikigami", ...
newtype Namespace = Namespace Text
  deriving stock (Eq, Ord, Show, Generic)

-- | The entity-kind tag: "intention" | "habit" | "repo" | "group" | "agent" | ...
newtype ScopeKind = ScopeKind Text
  deriving stock (Eq, Ord, Show, Generic)

data MemoryScope
  = ScopeGlobal Namespace                 -- whole-namespace
  | ScopeEntity Namespace ScopeKind Text  -- kind tag + entity id as text
  deriving stock (Eq, Show, Generic)

scopeNamespaceText :: MemoryScope -> Text
scopeNamespaceText = \case
  ScopeGlobal (Namespace ns)     -> ns
  ScopeEntity (Namespace ns) _ _ -> ns

-- | The (scope_kind, scope_ref) pair stored in the read-model columns.
scopeKindText :: MemoryScope -> Maybe Text
scopeKindText = \case
  ScopeGlobal _                    -> Nothing
  ScopeEntity _ (ScopeKind k) _    -> Just k

scopeRefText :: MemoryScope -> Maybe Text
scopeRefText = \case
  ScopeGlobal _          -> Nothing
  ScopeEntity _ _ ref    -> Just ref

-- | Rebuild a MemoryScope from the three stored columns. The inverse of the helpers above.
scopeFromColumns :: Text -> Maybe Text -> Maybe Text -> MemoryScope
scopeFromColumns ns (Just k) (Just ref) = ScopeEntity (Namespace ns) (ScopeKind k) ref
scopeFromColumns ns _ _                  = ScopeGlobal (Namespace ns)
```

`kioku-api/src/Kioku/Api/Types.hs` — the shared enums and the read-row type:

```haskell
module Kioku.Api.Types
  ( MemoryType (..)
  , memoryTypeToText, memoryTypeFromText
  , Confidence (..)
  , confidenceToText, confidenceFromText
  , MemoryStatus (..)
  , memoryStatusToText, memoryStatusFromText
  , MemoryRecord (..)
  ) where

import Data.Set (Set)
import Data.Time (UTCTime)
import Kioku.Api.Scope (MemoryScope)
import Kioku.Prelude

-- Rei wire strings preserved exactly so the M4 golden test and EP-4 replay match.
data MemoryType = MemoryFact | MemoryPattern | MemoryPreference | MemoryConstraint | MemoryInstruction
  deriving stock (Generic, Eq, Show, Enum, Bounded)

memoryTypeToText :: MemoryType -> Text
memoryTypeToText = \case
  MemoryFact -> "fact"; MemoryPattern -> "pattern"; MemoryPreference -> "preference"
  MemoryConstraint -> "constraint"; MemoryInstruction -> "instruction"

memoryTypeFromText :: Text -> Maybe MemoryType
memoryTypeFromText = \case
  "fact" -> Just MemoryFact; "pattern" -> Just MemoryPattern; "preference" -> Just MemoryPreference
  "constraint" -> Just MemoryConstraint; "instruction" -> Just MemoryInstruction; _ -> Nothing

data Confidence = HighConfidence | MediumConfidence | LowConfidence
  deriving stock (Generic, Eq, Show, Enum, Bounded)

confidenceToText :: Confidence -> Text
confidenceToText = \case HighConfidence -> "high"; MediumConfidence -> "medium"; LowConfidence -> "low"

confidenceFromText :: Text -> Maybe Confidence
confidenceFromText = \case
  "high" -> Just HighConfidence; "medium" -> Just MediumConfidence; "low" -> Just LowConfidence; _ -> Nothing

data MemoryStatus = MemoryActive | MemorySuperseded | MemoryMergedStatus | MemoryArchived
  deriving stock (Generic, Eq, Show, Enum, Bounded)

memoryStatusToText :: MemoryStatus -> Text
memoryStatusToText = \case
  MemoryActive -> "active"; MemorySuperseded -> "superseded"
  MemoryMergedStatus -> "merged"; MemoryArchived -> "archived"

memoryStatusFromText :: Text -> Maybe MemoryStatus
memoryStatusFromText = \case
  "active" -> Just MemoryActive; "superseded" -> Just MemorySuperseded
  "merged" -> Just MemoryMergedStatus; "archived" -> Just MemoryArchived; _ -> Nothing

-- | The JSON-facing read row returned by Kioku.Recall.
data MemoryRecord = MemoryRecord
  { memoryId   :: !Text
  , agentId    :: !Text
  , sessionId  :: !(Maybe Text)
  , scope      :: !MemoryScope
  , memoryType :: !Text
  , content    :: !Text
  , priority   :: !Int
  , confidence :: !Text
  , tags       :: !(Set Text)
  , status     :: !Text
  , createdAt  :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
```

Note `MemoryStatus`'s `MemoryMergedStatus` is named to avoid clashing with the `MemoryMerged` event
constructor in core. Add `ToJSON`/`FromJSON` instances for `MemoryType`/`Confidence`/`MemoryRecord`
and a `ToJSON`/`FromJSON` for `MemoryScope` (a small tagged object) if the CLI demo prints JSON; the
golden test does not need them.

### Step 3 — Write `Kioku.App` and the base migration, then build and migrate

Copy kizashi's `App.hs` into `kioku-core/src/Kioku/App.hs` (rename module + `AppEnv`/`runAppIO`).
Write the base migration `kioku-migrations/sql-migrations/2026-06-24-00-00-00-kioku-base.sql`:

```sql
-- codd: in-txn

-- Migration: kioku-base
-- Created: 2026-06-24-00-00-00 UTC
-- kioku read-model tables live in the kiroku schema: the app queries them on the
-- event-store pool, whose search_path is kiroku. Pin it so unqualified CREATEs land there.
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS kioku_memories (
  memory_id    text PRIMARY KEY,
  agent_id     text NOT NULL,
  session_id   text,
  namespace    text NOT NULL,
  scope_kind   text,
  scope_ref    text,
  memory_type  text NOT NULL,
  content      text NOT NULL,
  priority     integer NOT NULL DEFAULT 100,
  confidence   text NOT NULL DEFAULT 'medium',
  tags         jsonb NOT NULL DEFAULT '[]',
  status       text NOT NULL DEFAULT 'active',
  superseded_by text,
  supersedes   text,
  content_tsv  tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED,
  created_at   timestamptz NOT NULL,
  updated_at   timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS kioku_memories_status_idx ON kioku_memories (status);
CREATE INDEX IF NOT EXISTS kioku_memories_scope_idx
  ON kioku_memories (namespace, scope_kind, scope_ref) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS kioku_memories_type_idx ON kioku_memories (memory_type) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS kioku_memories_session_idx ON kioku_memories (session_id);
CREATE INDEX IF NOT EXISTS kioku_memories_tsv_idx ON kioku_memories USING gin (content_tsv);

CREATE TABLE IF NOT EXISTS kioku_sessions (
  session_id          text PRIMARY KEY,
  agent_id            text NOT NULL,
  focus               text NOT NULL,
  namespace           text NOT NULL,
  scope_kind          text,
  scope_ref           text,
  subject_ref         text,
  previous_session_id text,
  status              text NOT NULL DEFAULT 'running',
  started_at          timestamptz NOT NULL,
  completed_at        timestamptz,
  model_used          text,
  summary             text,
  error_message       text,
  created_at          timestamptz NOT NULL DEFAULT NOW(),
  updated_at          timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS kioku_sessions_status_idx ON kioku_sessions (status);
CREATE INDEX IF NOT EXISTS kioku_sessions_agent_idx ON kioku_sessions (agent_id);
CREATE INDEX IF NOT EXISTS kioku_sessions_scope_idx ON kioku_sessions (namespace, scope_kind, scope_ref);

CREATE TABLE IF NOT EXISTS kioku_turns (
  turn_id       text PRIMARY KEY,
  session_id    text NOT NULL,
  turn_index    integer NOT NULL,
  role          text NOT NULL,
  content       text NOT NULL,
  tool_summary  text,
  prompt_tokens integer,
  output_tokens integer,
  recorded_at   timestamptz NOT NULL,
  UNIQUE (session_id, turn_index)
);

CREATE INDEX IF NOT EXISTS kioku_turns_session_idx ON kioku_turns (session_id, turn_index);
```

Reserve (do NOT create now) the `vector` embedding column on `kioku_memories` and the
`kioku_scenes`/`kioku_personas` tables — those are EP-2/EP-3 additions. This base migration's seam is
that EP-2 adds an `ALTER TABLE kioku_memories ADD COLUMN embedding vector(1536)` migration and the
`CREATE EXTENSION IF NOT EXISTS vector` (which needs the extension available + owner privileges).

Now build and migrate:

```bash
cd /Users/shinzui/Keikaku/bokuno/kioku
direnv allow      # or: nix develop
cabal build all
just create-database
psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt kiroku.kioku_*'
```

Expected final transcript (table list):

```text
            List of relations
 Schema |      Name       | Type  | ...
--------+-----------------+-------+----
 kiroku | kioku_memories  | table | ...
 kiroku | kioku_sessions  | table | ...
 kiroku | kioku_turns     | table | ...
```

This closes M1.

### Step 4 — Memory aggregate (M2)

Write `kioku-core/src/Kioku/Memory/Domain.hs`. Model it on Rei's `AgentMemory/Domain/Transducer.hs`
and the kizashi `Actor/Domain.hs` shape. The command/event payloads carry the generalized fields
(`scope :: MemoryScope`, `priority :: Int`, free `agentId :: Text`, `sessionId :: Maybe SessionId`).
The transducer:

```haskell
{-# LANGUAGE TemplateHaskell #-}
module Kioku.Memory.Domain ( {- export Command/Event ADTs + *Data, vertices, transducer -} ) where

import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer)
import Keiki.Generics (emptyRegFile)
import Keiki.Generics.TH (deriveAggregate)
import Kioku.Prelude
-- ... Command/Event types omitted here for brevity; see full sketch below ...

data MemoryVertex = NotCreated | Active | Superseded | Merged | Archived
  deriving stock (Eq, Show, Enum, Bounded)

type MemoryRegs = '[]

$(deriveAggregate ''MemoryCommand ''MemoryRegs ''MemoryEvent)

memoryTransducer ::
  SymTransducer (HsPred MemoryRegs MemoryCommand) MemoryRegs MemoryVertex MemoryCommand MemoryEvent
memoryTransducer =
  B.buildTransducer NotCreated emptyRegFile isTerminal do
    B.from NotCreated do
      B.onCmd inCtorRecordMemory $ \d -> B.do
        B.emit wireMemoryRecorded MemoryRecordedTermFields { {- copy fields from d -} }
        B.goto Active
    B.from Active do
      B.onCmd inCtorSupersedeMemory $ \d -> B.do
        B.emit wireMemorySuperseded MemorySupersededTermFields { {- ... -} }
        B.goto Superseded
      B.onCmd inCtorArchiveMemory $ \d -> B.do
        B.emit wireMemoryArchived MemoryArchivedTermFields { {- ... -} }
        B.goto Archived
      B.onCmd inCtorUpdateMemoryTags $ \d -> B.do
        B.emit wireMemoryTagsUpdated MemoryTagsUpdatedTermFields { {- ... -} }
        B.goto Active
      B.onCmd inCtorUpdateMemoryConfidence $ \d -> B.do
        B.emit wireMemoryConfidenceUpdated MemoryConfidenceUpdatedTermFields { {- ... -} }
        B.goto Active
  where
    isTerminal = \case Superseded -> True; Merged -> True; Archived -> True; _ -> False
```

The `MemoryMerged` event constructor exists in `MemoryEvent` and `Merged` is a declared terminal
vertex, but EP-1 adds **no** edge that emits it (no `inCtorMergeMemory`). That is intentional: EP-3
adds the merge command and the edge later without changing the codec's event-type list. The event
data records:

- `MemoryRecorded` carries: `memoryId, agentId, sessionId :: Maybe SessionId, scope :: MemoryScope,
  memoryType :: MemoryType, content :: Text, priority :: Int, confidence :: Confidence,
  tags :: Set Text, supersedes :: Maybe MemoryId, recordedAt :: UTCTime`.
- `MemorySuperseded`: `memoryId, supersededBy :: MemoryId, supersededAt`.
- `MemoryArchived`: `memoryId, archivedAt`.
- `MemoryTagsUpdated`: `memoryId, tags :: Set Text, updatedAt`.
- `MemoryConfidenceUpdated`: `memoryId, confidence :: Confidence, updatedAt`.
- `MemoryMerged` (reserved): `memoryId, mergedInto :: MemoryId, mergedAt`.

Write `kioku-core/src/Kioku/Memory/EventStream.hs`. The codec mirrors kizashi's `actorCodec`: a flat
`"kind"` object on encode, and a `decode` that accepts the native shape OR Rei's legacy shape. The
discriminator logic:

```haskell
-- decode :: const $ \value -> parseMemoryEvent value
-- parseMemoryEvent first checks for a top-level "type" + "data" (Rei legacy) and dispatches to a
-- legacy parser; otherwise it reads the native top-level "kind".
parseMemoryEvent :: Value -> Either Text MemoryEvent
parseMemoryEvent value =
  case value of
    Object o
      | Just (String legacyType) <- KM.lookup "type" o
      , Just (Object dat) <- KM.lookup "data" o ->
          parseLegacyRei legacyType dat        -- Rei's {"type":"agent_memory_recorded","data":{...}}
    _ -> parseNative value                     -- kioku's {"kind":"MemoryRecorded", ...}
```

`parseLegacyRei` maps the Rei snake_case payloads into kioku events using the field map in IP-6 (e.g.
Rei's `anchor_type`/`anchor_id` → `scopeFromColumns "rei" anchorType anchorId`; Rei has no `priority`,
so default to `100`). The stream:

```haskell
memoryStream :: MemoryId -> Stream MemoryEventStream
memoryStream mid = Stream.entityStream (Stream.categoryUnsafe "kioku_memory") (idText mid)
```

(`idText` from `Kioku.Id`. The category token must contain no `-`; `kioku_memory` is fine.)

The `EventStream` record copies kizashi's: `initialState = NotCreated`, `initialRegisters =
emptyRegFile`, `eventCodec = memoryCodec`, `resolveStreamName = Stream.streamName`,
`snapshotPolicy = Never`, `stateCodec = Nothing`.

Write `kioku-core/src/Kioku/Memory/ReadModel.hs`. The inline projection upserts `kioku_memories`
from `MemoryRecorded` (writing `namespace`/`scope_kind`/`scope_ref` from the scope helpers, never the
`content_tsv` column — PostgreSQL computes it) and applies status/value updates for the other five
constructors (`MemoryMerged` → status `'merged'`). It MUST handle all six constructors. Model the
hasql statements on Rei's `AgentMemory/Infrastructure/Table.hs` and kizashi's `Actor/ReadModel.hs`
(`preparable`, multiline SQL, `contrazipN`). `import Data.Generics.Labels ()` here (this module has no
`B.do`). Then define the scoped `ReadModel`s used by `Kioku.Recall`.

Write `kioku-core/src/Kioku/Memory.hs` — the write API. Mirror Rei's StoreHandler idempotency
(pre-check the inline row, skip when the decider would have no-op'd). The core writer:

```haskell
runMemoryCommand :: (AppEffects-style es) => MemoryId -> MemoryCommand -> Eff es (Either CommandError ())
runMemoryCommand mid cmd =
  runCommandWithProjections defaultRunCommandOptions memoryEventStream (memoryStream mid) cmd
    [memoryInlineProjection]
```

`record`/`supersede`/`archive`/`updateTags`/`updateConfidence` wrap it, generating the id with
`genMemoryId` where appropriate.

Write `kioku-core/src/Kioku/Recall.hs` — placeholder scoped queries:

```haskell
getActiveByScope :: (es ...) => MemoryScope -> Eff es [MemoryRecord]
getGlobal        :: (es ...) => Namespace   -> Eff es [MemoryRecord]
getBySession     :: (es ...) => SessionId   -> Eff es [MemoryRecord]
getByType        :: (es ...) => Namespace -> MemoryType -> Eff es [MemoryRecord]
```

Each runs a hasql statement (`WHERE status='active' AND namespace=$1 AND scope_kind …`) and decodes
into `MemoryRecord` via `scopeFromColumns`. No vector/RRF here.

### Step 5 — CLI demo (M2 acceptance)

Write `kioku-cli/src/Kioku/Cli/Commands/Demo.hs`, `kioku-cli/src/Kioku/Cli.hs`, and
`kioku-cli/app/Main.hs`. `Kioku.Cli.main` is an optparse-applicative subparser with a `demo`
subcommand. `runDemo` opens the store like kizashi's worker:

```haskell
runDemo :: IO ()
runDemo = do
  connStr <- requireEnv "PG_CONNECTION_STRING"
  withStore (defaultConnectionSettings connStr) $ \st -> do
    tr <- noopTracer
    let env = AppEnv { store = st, tracer = tr, metrics = Nothing }
    mid <- genMemoryId
    now <- getCurrentTime
    let scope = ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_demo"
    _ <- runAppIO env $ Kioku.Memory.record RecordMemoryData
            { memoryId = mid, agentId = "demo-agent", sessionId = Nothing, scope = scope
            , memoryType = MemoryPreference, content = "prefers concise answers"
            , priority = 100, confidence = HighConfidence, tags = Set.fromList ["style"]
            , supersedes = Nothing, recordedAt = now }
    putStrLn ("Recorded memory " <> show mid <> " in scope rei/intention/intention_demo")
    recs <- runAppIO env $ Kioku.Recall.getActiveByScope scope
    mapM_ (putStrLn . renderRecord) (either (const []) id recs)
```

Build and run:

```bash
cabal build all
just create-database     # ensure schema present
cabal run kioku -- demo
```

Expected transcript:

```text
Recorded memory kioku_memory_01j... in scope rei/intention/intention_demo
- kioku_memory_01j... [preference/high] prefers concise answers
```

Verify the FTS column:

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "SELECT memory_id, namespace, scope_kind, scope_ref, content, content_tsv IS NOT NULL AS has_tsv FROM kiroku.kioku_memories;"
```

Expected: one row, `has_tsv = t`. This closes M2.

### Step 6 — Session aggregate (M3)

Write `Kioku/Session/Domain.hs`, `Session/EventStream.hs`, `Session/ReadModel.hs`, and `Kioku/Session.hs`.
Mirror Rei's AgentSession transducer (`Domain/Transducer.hs`) but:

- vertices `NotCreated | Running | Completed | Failed | Interactive` with terminal set
  `{Completed, Failed, Interactive}` — `Running` stays open;
- add an edge `Running --RecordTurn--> Running` emitting `TurnRecorded`;
- `SessionStarted` carries `focus :: Text` (not `CoachingFocusType`), `scope :: MemoryScope`,
  `subjectRef :: Maybe Text`, `previousSessionId :: Maybe SessionId`, `startedAt`;
- `TurnRecorded` carries `sessionId, turnIndex :: Int, role :: Text, content :: Text,
  toolSummary :: Maybe Text, promptTokens :: Maybe Int, outputTokens :: Maybe Int, recordedAt`.

The inline projection upserts `kioku_sessions` (start/interactive insert, complete/fail update) and
inserts a `kioku_turns` row on `TurnRecorded` (idempotent on `(session_id, turn_index)`). The codec
again accepts native + Rei legacy (`agent_session_started` → kioku `SessionStarted` with
`focus = focus_type` text, `scope = ScopeEntity "rei" "intention" intention_id` or
`ScopeGlobal "rei"` when `intention_id` is null). `Kioku.Session` exposes `start`/`complete`/`fail`/
`recordInteractive`/`recordTurn`.

Extend the CLI: add a `demo-session` (or fold into `demo`) that starts a session, records one turn,
completes it. Build, run, and verify:

```bash
cabal build all
cabal run kioku -- demo-session
psql -h "$PGHOST" -d "$PGDATABASE" -c "SELECT status FROM kiroku.kioku_sessions;"
psql -h "$PGHOST" -d "$PGDATABASE" -c "SELECT session_id, turn_index, role FROM kiroku.kioku_turns;"
```

Expected: session `status='completed'`; one turn row. This closes M3.

### Step 7 — Rei-JSON golden test (M4)

Write `kioku-core/test/Main.hs` (tasty `defaultMain` over the spec tree) and
`kioku-core/test/Kioku/ReiCompatSpec.hs`. Embed two real Rei payloads as `ByteString`/`Value` literals
(use the field maps in IP-6). The memory sample:

```json
{
  "type": "agent_memory_recorded",
  "data": {
    "memoryId": "agent_memory_01jrei",
    "agentId": "rei-coach",
    "sessionId": "agent_session_01jrei",
    "memoryType": "preference",
    "content": "prefers morning reviews",
    "anchor": { "type": "intention", "id": "intention_01jrei" },
    "confidence": "high",
    "tags": ["cadence"],
    "supersedes": null,
    "recordedAt": "2026-03-16T14:12:46Z"
  }
}
```

The test decodes it through `memoryCodec`'s `decode` and asserts the result is
`MemoryRecorded MemoryRecordedData { memoryId = parse "agent_memory_01jrei", agentId = "rei-coach",
sessionId = Just …, scope = ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_01jrei",
memoryType = MemoryPreference, content = "prefers morning reviews", priority = 100,
confidence = HighConfidence, tags = {"cadence"}, supersedes = Nothing, recordedAt = … }`.

Note the two Rei field shapes for `anchor`/`sessionId`: Rei's top-level `AgentMemoryEvent` uses
`eventAesonOptions` (so the envelope is `{"type":"agent_memory_recorded","data":…}`, snake_case tag),
but the inner `*Data` uses `defaultOptions` (so inner keys are **camelCase**: `memoryId`,
`recordedAt`, etc.). The legacy parser must read camelCase inner keys and the nested `anchor` object,
exactly as Rei's `MemoryAnchor` FromJSON does (`{"type":"intention","id":…}` /
`{"type":"workspace"}`). A second sample for `agent_session_started` proves the Session codec the same
way (mapping `focus_type`→`focus`, `intention_id`→scope).

Run:

```bash
cabal test kioku-core
```

Expected: the `ReiCompat` group passes. Prove the test bites by temporarily deleting the legacy branch
in `parseMemoryEvent`, re-running (expect a failure decoding the `{"type",…}` payload), then restoring.
This closes M4.


## Validation and Acceptance

The plan is accepted when all four milestone acceptances hold simultaneously on a fresh checkout:

1. **Build.** From `/Users/shinzui/Keikaku/bokuno/kioku` in the dev shell, `cabal build all` exits 0.
2. **Migrate.** `just create-database` exits 0; `psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt
   kiroku.kioku_*'` lists `kioku_memories`, `kioku_sessions`, `kioku_turns`.
3. **Memory write→scoped recall (headline).** `cabal run kioku -- demo` prints the "Recorded memory
   …" line followed by the recalled record with the same id and content, and
   `SELECT … content_tsv IS NOT NULL …` returns `t` for the row. This is observable behavior — the
   memory was written as events, projected to a row with a populated FTS column, and read back by its
   generic scope, not by any Rei-specific id.
4. **Session + turn.** `cabal run kioku -- demo-session` leaves a `completed` session and one turn row.
5. **Rei backward-compat decode.** `cabal test kioku-core` passes the `ReiCompat` golden tests; the
   tests fail if the lenient decode branch is removed (demonstrated once during M4).

Each acceptance is phrased as something a human runs and sees, not "code added". The headline
acceptance (#3) is the user-visible behavior promised in the Purpose: an agent records a memory in a
scope and recalls it by that scope.


## Idempotence and Recovery

- **Scaffold copy (Step 0–2).** Re-running the copies overwrites files with identical content; safe to
  repeat. Generating `mori/repo-id` is the one non-idempotent step — guard it: only generate if the
  file is absent (`[ -s mori/repo-id ] || mori repo id --new > mori/repo-id`).
- **Migrations.** All DDL is `CREATE TABLE/INDEX IF NOT EXISTS`; codd records applied migrations by
  timestamped filename and skips already-applied ones, so `just create-database` and `just migrate`
  are safe to run repeatedly. If you add a migration file after a prior `migrate`, the Justfile
  `migrate` recipe `touch`es `kioku-migrations/kioku-migrations.cabal` to force the `embedDir` splice
  to re-bake the new file — without that touch a newly added `.sql` is silently not embedded.
- **Inline projections.** Upserts use `ON CONFLICT … DO UPDATE` and are idempotent under keiro's
  at-least-once redelivery, so re-running a command or replaying a stream converges. The `kioku_turns`
  insert is idempotent via `UNIQUE (session_id, turn_index)` + `ON CONFLICT DO NOTHING`.
- **CLI demo.** Re-running `demo` records a new memory each time (fresh id), which is harmless; the
  scoped recall returns all active memories in that scope. To reset, `TRUNCATE kiroku.kioku_memories,
  kiroku.kioku_sessions, kiroku.kioku_turns;` and drop the corresponding `kiroku_memory-*`/
  `kiroku_session-*` streams (or recreate the database with `backup-restore`-style drop+create).
- **Build recovery.** If a dependency resolution conflict appears, the cause is almost always a
  diverging pin; the `cabal.project` pin-set must be byte-identical to kizashi's. Do NOT delete
  inplace `.conf` registrations to "fix" a hidden-module error — that re-solves the plan into two
  incompatible hasql builds and forces a ~20-minute clean rebuild. A "hidden module in package
  kioku-core" error means a module is in `other-modules` instead of `exposed-modules`; fix the
  `.cabal` file. (This is a known kikan-stack gotcha carried over from the Rei keiro migration.)
- **`CREATE EXTENSION vector` is NOT in this plan.** EP-1's base migration deliberately omits the
  pgvector extension and the `embedding` column; if a later plan's migration fails on
  `CREATE EXTENSION vector`, that is an EP-2 concern (the extension must be installed and the migrating
  role must be superuser-or-owner) and not a regression here.


## Interfaces and Dependencies

This section names the exact types/functions that must exist at the end of each milestone and the
binding integration contracts (IP-1…IP-6 from MasterPlan #1).

### Libraries depended on (and why)

- `keiki` (transducer DSL), `keiro`/`keiro-core` (command runner, codec, projections, read models),
  `kiroku-store` (event store + `KirokuStore`/`withStore`), `shibuya-core` (telemetry effect),
  `shibuya-kiroku-adapter` — the kikan event-sourcing stack; kioku does not reimplement any of it.
- `kiroku-store-migrations`, `keiro-migrations`, `codd`, `file-embed`, `ephemeral-pg` — the migration
  composition and the test-support ephemeral DB, exactly as kizashi uses them.
- `effectful`/`effectful-core`, `hasql`/`hasql-pool`/`hasql-transaction`, `contravariant-extras` — the
  effect stack and SQL plumbing.
- `mmzk-typeid` — the `KindID` id scheme. `aeson`, `text`, `time`, `uuid`, `containers`,
  `generic-lens`, `lens` — wire types and helpers (the whole `kioku-api` dep set).
- `optparse-applicative` — the CLI subparser (cli only).

### Module/function signatures by milestone

**End of M1** (`kioku-api` + scaffold):

- `Kioku.Api.Scope`: `Namespace(..)`, `ScopeKind(..)`, `MemoryScope(ScopeGlobal | ScopeEntity)`,
  `scopeNamespaceText :: MemoryScope -> Text`, `scopeKindText :: MemoryScope -> Maybe Text`,
  `scopeRefText :: MemoryScope -> Maybe Text`,
  `scopeFromColumns :: Text -> Maybe Text -> Maybe Text -> MemoryScope`.
- `Kioku.Api.Types`: `MemoryType(..)` (`MemoryFact|MemoryPattern|MemoryPreference|MemoryConstraint|
  MemoryInstruction`), `Confidence(..)`, `MemoryStatus(..)`, `MemoryRecord(..)`, and the
  `*ToText`/`*FromText` helpers.
- `Kioku.Id`: `type MemoryId = KindID "kioku_memory"`, `type SessionId = KindID "kioku_session"`,
  `genMemoryId`, `genSessionId`, `idText`, `parseId`.
- `Kioku.App`: `type AppEffects = '[Store, Error StoreError, Tracing, IOE]`,
  `data AppEnv = AppEnv { store :: KirokuStore, tracer :: Tracer, metrics :: Maybe KeiroMetrics }`,
  `runAppIO :: AppEnv -> Eff AppEffects a -> IO (Either StoreError a)`, `noopTracer :: IO Tracer`.
- `Kioku.Migrations`: `kiokuMigrations`, `runKiokuMigrationsNoCheck`; `Kioku.Migrations.TestSupport`:
  `withKiokuMigratedDatabase :: (Text -> IO a) -> IO a`.

**End of M2** (Memory):

- `Kioku.Memory.Domain`: `MemoryCommand(..)`, `MemoryEvent(..)` (with reserved `MemoryMerged`),
  `MemoryVertex(NotCreated|Active|Superseded|Merged|Archived)`, `type MemoryRegs = '[]`,
  `memoryTransducer`.
- `Kioku.Memory.EventStream`: `type MemoryEventStream = EventStream …`, `memoryEventStream`,
  `memoryCodec :: Codec MemoryEvent` (encode native; decode native **and** Rei legacy),
  `memoryStream :: MemoryId -> Stream MemoryEventStream`, `parseMemoryEvent :: Value -> Either Text
  MemoryEvent`.
- `Kioku.Memory.ReadModel`: `memoryInlineProjection :: InlineProjection MemoryEvent` (handles all six
  constructors), the scoped `ReadModel`s, and hasql statements.
- `Kioku.Memory` (IP-1 public write surface): `record`, `supersede`, `archive`, `updateTags`,
  `updateConfidence` over the store.
- `Kioku.Recall` (IP-1 placeholder read surface): `getActiveByScope :: MemoryScope -> Eff es
  [MemoryRecord]`, `getGlobal :: Namespace -> Eff es [MemoryRecord]`, `getBySession :: SessionId ->
  Eff es [MemoryRecord]`, `getByType :: Namespace -> MemoryType -> Eff es [MemoryRecord]`.

**End of M3** (Session):

- `Kioku.Session.Domain`: `SessionCommand(..)`, `SessionEvent(SessionStarted|SessionCompleted|
  SessionFailed|InteractiveSessionRecorded|TurnRecorded)`, `SessionVertex(NotCreated|Running|
  Completed|Failed|Interactive)` (terminal `{Completed,Failed,Interactive}`), `sessionTransducer`.
- `Kioku.Session.EventStream`: `sessionEventStream`, `sessionCodec` (native + Rei legacy),
  `sessionStream :: SessionId -> Stream SessionEventStream`.
- `Kioku.Session.ReadModel`: `sessionInlineProjection :: InlineProjection SessionEvent`.
- `Kioku.Session` (IP-1): `start`, `complete`, `fail`, `recordInteractive`, `recordTurn`.

**End of M4**: a passing `ReiCompat` tasty group in `kioku-core:kioku-test`.

### IP-1 — kioku public API surface

Consumers (EP-4/5/6) depend only on `Kioku.Memory`, `Kioku.Session`, `Kioku.Recall`, and the
`kioku-api` types — never on `Kioku.*.Domain` internals. EP-1 ships `Kioku.Memory`/`Kioku.Session` and
a placeholder `Kioku.Recall` (scoped SQL only); EP-2 fills in hybrid recall behind the same module.

### IP-2 — `MemoryScope` mapping

`Kioku.Api.Scope` owns `Namespace`/`MemoryScope`/`ScopeKind` exactly as quoted in the MasterPlan. Each
consumer maps its typed ids at the edge: Rei `AnchorToIntention iid → ScopeEntity "rei" "intention"
(idText iid)`, `AnchorToHabit hid → ScopeEntity "rei" "habit" …`, `WorkspaceGlobal → ScopeGlobal
"rei"`; mori `ScopeEntity "mori" "repo" <projectId>` / `"group" <groupId>`; shikigami
`ScopeEntity "shikigami" "agent" <agentName>`. The mapping helper lives in each consumer, not in kioku.

### IP-3 — database schema & migrations

`kioku-migrations` owns the schema. EP-1 creates `kioku_memories` (with the `content_tsv` generated
column + GIN index), `kioku_sessions`, `kioku_turns`, all in the **`kiroku` schema**
(`extraSearchPath=[]`, kizashi convention). EP-2 adds the `vector` embedding column + the
`CREATE EXTENSION vector`; EP-3 adds `kioku_scenes`/`kioku_personas`. Consumers compose
`kiokuMigrations` into their migration set exactly as kizashi composes
`kirokuMigrations <> keiroFrameworkMigrations <> ownMigrations`. The pgvector extension requires it to
be installed and the migrating role to be owner/superuser — called out as an EP-2 concern.

### IP-4 — embedding & LLM provider config

Out of EP-1 scope (no `baikai`/`shikumi` dependency in kioku yet). The base `kioku_memories` table
reserves room for EP-2's `embedding`/`embedding_model`/`dimensions`/`content_hash` columns; EP-1 adds
none of them.

### IP-5 — `cabal.project` pin-set

EP-1 establishes the coherent kikan set by copying kizashi's verbatim (the full block is in the Plan
of Work). EP-2/EP-3 add `baikai`/`shikumi` pins; consumers add a `kioku` source-repository-package
pin. When a consumer is mid-keiro-migration (mori), reconcile tags in that consumer's plan (EP-5).

### IP-6 — Rei codec backward-compatibility (the EP-1↔EP-4 seam)

kioku's codec `encode` always writes the native flat shape; `decode` accepts native AND Rei's legacy
`eventAesonOptions` shape. The exact field map kioku's legacy decoder must implement:

**Rei `agent_memory` events.** Envelope: `{"type": "<snake_case_tag>", "data": <inner>}` where the tag
is `agent_memory_recorded | agent_memory_superseded | agent_memory_archived |
agent_memory_tags_updated | agent_memory_confidence_updated`. Inner keys are **camelCase**
(`defaultOptions` on the `*Data` records). Field map for `agent_memory_recorded` →
kioku `MemoryRecorded`:

- `memoryId` (text typeid `agent_memory_…`) → `memoryId` (parse as `KindID "kioku_memory"` is NOT
  prefix-compatible; for the golden test, parse the text and re-tag via `decorateKindID`, OR store the
  raw text — EP-4 decides the final id remap. For EP-1's golden test, assert on the text via `idText`
  round-trip, decoding the Rei prefix leniently).
- `agentId` → `agentId`.
- `sessionId` (`agent_session_…`) → `sessionId :: Maybe SessionId` (Just).
- `memoryType` (`"fact"|"pattern"|"preference"|"constraint"`) → `memoryType` via `memoryTypeFromText`.
- `content` → `content`.
- `anchor` (nested `{"type":"intention","id":…}` / `{"type":"habit","id":…}` / `{"type":"workspace"}`)
  → `scope`: `intention`→`ScopeEntity (Namespace "rei") (ScopeKind "intention") id`;
  `habit`→`ScopeEntity … "habit" id`; `workspace`→`ScopeGlobal (Namespace "rei")`.
- `confidence` (`"high"|"medium"|"low"`) → `confidence` via `confidenceFromText`.
- `tags` (JSON array) → `tags :: Set Text`.
- Rei has NO `priority` → default `priority = 100`.
- `supersedes` (nullable text) → `supersedes :: Maybe MemoryId`.
- `recordedAt` → `recordedAt`.

The Rei read-model table the streams were projected from is
`migrations/scripts/20260316141246_create_agent_memories.sql` with columns
`memory_id, agent_id, session_id, memory_type, content, anchor_type, anchor_id, confidence, tags
JSONB, status, superseded_by, supersedes, created_at, updated_at` — note the table flattens the
anchor into `(anchor_type, anchor_id)`, which is the same flattening kioku stores as
`(namespace, scope_kind, scope_ref)` with `namespace="rei"`. The other four memory events map
field-for-field (`memoryId`/`supersededBy`/`supersededAt`, `memoryId`/`archivedAt`,
`memoryId`/`tags`/`updatedAt`, `memoryId`/`confidence`/`updatedAt`).

**Rei `agent_session` events.** Tags `agent_session_started | agent_session_completed |
agent_session_failed | interactive_session_recorded`. For `agent_session_started` → kioku
`SessionStarted`: `sessionId`→`sessionId`; `agentId`→`agentId`; `focusType` (a Rei `CoachingFocusType`
serialized via `defaultOptions`, e.g. `"FocusToday"`) → `focus :: Text` (carry the raw constructor
text — kioku's `focus` is free-form, so no enum decode needed); `intentionId` (nullable
`intention_…`) + `focusTarget` → `scope` (`Just iid → ScopeEntity "rei" "intention" iid`;
`Nothing → ScopeGlobal "rei"`) and `subjectRef = focusTarget`; `previousSessionId`→`previousSessionId`;
`startedAt`→`startedAt`. The legacy session table is
`migrations/scripts/20260314224946_create_agent_sessions.sql` with columns `session_id, agent_id,
focus_type, intention_id, previous_session_id, focus_target, status, started_at, completed_at,
model_used, summary, error_message, created_at, updated_at`. Rei records NO turns, so there is no
legacy `TurnRecorded` to decode.

This field map is the binding contract: EP-4 either replays Rei streams verbatim (relying on kioku's
lenient decode) or transforms them; in both cases the mapping above is the reference. M4's golden test
makes the memory and session halves of this map executable.


## Coding Conventions (haskell-jitsurei)

All Haskell in this plan follows the binding conventions in
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/` (the `shinzui/haskell-jitsurei` cookbook —
browse with `mori registry docs haskell-jitsurei`), as mandated by MasterPlan #1 Integration
Point IP-7. The rules that bear on this plan:

- **Core standards** (`core/standards.md`): GHC 9.12+ with the `GHC2024` language edition; a
  `common common` cabal stanza enabling `DeriveAnyClass`, `DuplicateRecordFields`,
  `OverloadedLabels`, `OverloadedStrings`, plus `MultilineStrings` for embedded SQL, with every
  library/exe/test stanza doing `import: common`; postpositive `qualified` imports
  (`import Data.Text qualified as Text`, never `import qualified`).
- **Custom prelude** (`core/custom-prelude.md`): a project prelude (`Kioku.Prelude` for kioku)
  re-exports the common surface + `Control.Lens` behind a per-file `{-# LANGUAGE PackageImports #-}`
  pragma. It **must NOT re-export `Data.Generics.Labels`** — that orphan `IsLabel` instance
  collides with the **keiki DSL**'s own `#label` overloading that kioku's transducers rely on.
  Modules that need generic-lens `#label` import `"generic-lens" Data.Generics.Labels ()`
  per-module; keiki-DSL modules use the keiki instance instead. The shared `eventAesonOptions`
  lives in the prelude.
- **Record patterns** (`core/record-patterns.md`): no field prefixes, strict `!` fields,
  entity-ID-first on event/command records, explicit `deriving stock`/`anyclass`/`newtype`
  strategies, and lens operators (`^.`, `.~`, `?~`, `%~`, `at`, `ix`) over record-update syntax.
- **Multiline strings** (`core/multiline-strings.md`): embedded SQL uses `MultilineStrings`
  (`"""…"""`), not `unlines` or string concatenation.
- **Codec reconciliation (design-affecting, per IP-6/IP-7):** prefer the `eventAesonOptions`
  generic codec (`{"type": "snake_case_tag", "data": {…}}`, `tagSingleConstructors = True`, via
  `deriving anyclass (FromJSON, ToJSON)`) over a kizashi-style hand-written codec. The keiro
  `Codec.encode`/`decode` delegate to `genericToJSON`/`genericParseJSON eventAesonOptions`. This is
  the convention AND makes IP-6 free: kioku then emits and accepts the exact JSON shape Rei already
  wrote. Keep a lenient `parseJSON` to absorb any Rei-specific snake_case/anchor-field differences.
  The kizashi project remains the structural scaffold (packages, store wiring, migrations); only
  the codec strategy is overridden.


## Revision Notes

- 2026-06-24: Implemented and verified M1 scaffold work in the working tree. Updated Progress with
  `cabal build all`, `just create-database`, and `\dt kiroku.kioku_*` evidence; recorded the newer
  consumer-compatible `kiroku` pin, the valid fallback `mori/repo-id`, and the local Postgres TCP
  port workaround.
