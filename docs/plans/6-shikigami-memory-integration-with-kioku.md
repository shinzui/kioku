---
id: 6
slug: shikigami-memory-integration-with-kioku
title: "shikigami Memory Integration with kioku"
kind: exec-plan
created_at: 2026-06-24T16:31:00Z
intention: "intention_01kvx5py1yeanvyn7xh58epfnt"
master_plan: "docs/masterplans/1-kioku-reusable-agent-memory-session-library.md"
---

# shikigami Memory Integration with kioku

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

**shikigami** (式神, "summoned spirit-servant") is a brand-new, not-yet-built runtime for
*declared* autonomous agents: instead of writing and deploying a bespoke service, you write a
short typed Dhall file that says "run **this behavior**, when **this trigger** fires, send the
result to **these sinks**," and a thin worker runs it forever. The shikigami design already
plans to record every agent *run* in a bespoke `agent_runs` SQL table (the design spec calls it
"the intention-free mirror of Rei's `AgentSessionExistsData`"), but it has **no memory layer at
all** — today an agent's only shared substrate is the ephemeral `activity.v1` event stream, so an
agent that runs every hour learns nothing from its previous runs.

This plan makes **kioku** (記憶, "memory") shikigami's session-and-memory subsystem. kioku is a
separate, reusable, event-sourced Haskell library (built by ExecPlan EP-1,
`docs/plans/1-kioku-scaffold-and-core-extraction.md`) that gives any agent platform two
primitives: a **Session** (a record of one agent run, with start/complete/fail and optional raw
"turns") and a **Memory** (a durable, queryable learning), both scoped by a generic
`MemoryScope` (a namespace plus an optional entity reference) so the same engine serves Rei, mori,
and shikigami. After this plan, a shikigami agent **opens a kioku session when it runs, recalls
the memories it recorded on prior runs, and records new learnings** — so the agent accumulates
persistent knowledge across runs instead of starting blank every time.

What someone can do after this change that they could not before, stated as observable behavior:
from the new shikigami repo, run a demo agent twice and watch the second run *remember* what the
first run learned.

```bash
cabal run shikigami -- agent-demo --agent stalled-intention   # run 1
cabal run shikigami -- agent-demo --agent stalled-intention   # run 2
```

Run 1 prints "recalled 0 prior memories" and records a learning; run 2 prints "recalled 1 prior
memory: <the learning from run 1>". Two `kioku_sessions` rows exist (one per run), both scoped to
the agent `shikigami/agent/stalled-intention`, and one `kioku_memories` row holds the learning.
That write-then-recall-across-runs loop is the headline acceptance.

**Scope boundary (read this carefully).** shikigami is greenfield: as of this plan it is only a
design spec (`/Users/shinzui/Keikaku/bokuno/shikigami/docs/initial-spec.md`, 1369 lines) plus a
handful of seed Dhall declarations under
`/Users/shinzui/Keikaku/bokuno/shikigami/agents/detectors/`. There is **zero Haskell source**.
Building the *full* shikigami runtime (the Dhall loader, the three trigger evaluators, the
behavior runner over handan/baikai, the five sink dispatchers, the shomei permission gate, the
Kafka `activity.v1` consumer) is a large, separate initiative and is **out of scope here**. This
plan delivers the *minimal* shikigami scaffold needed to **demonstrate the kioku integration end
to end**: the four-package project skeleton that builds and applies kioku's migrations
(Milestone 1), a `shikigami-core` memory/session seam plus a `shikigami-cli` `agent-demo`
command that **simulates one agent run** by opening a kioku session, recalling memory, recording
a learning, and completing the session (Milestone 2), and the proof that a second run recalls the
first run's learning together with the documented `activity.v1`→kioku mapping (Milestone 3).
Everything else shikigami eventually needs — triggers, sinks, shomei, the behavior runner, the
real `agent_runs` table — is explicitly **not built here**; this plan replaces the *planned*
bespoke `agent_runs` table with kioku's Session aggregate and proves per-agent memory works, and
leaves the rest of shikigami to its own MasterPlan.

This plan (EP-6) **hard-depends on EP-1** (it imports kioku's `Kioku.Memory`, `Kioku.Session`,
`Kioku.Recall`, and the `kioku-api` types, and composes kioku's migrations) and **soft-depends on
EP-2** (`docs/plans/2-kioku-hybrid-retrieval-pgvector-fts-rrf.md`, richer hybrid recall) and
**EP-3** (`docs/plans/3-kioku-distillation-pyramid-l0-to-l3.md`, persona/scene distillation).
The soft dependencies make the integration *richer* (better recall ranking; a distilled per-agent
persona) but are not required for the core integration to compile and demonstrate value — EP-6
only needs EP-1's placeholder scoped recall.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `shikigami` repo scaffolded at `/Users/shinzui/Keikaku/bokuno/shikigami` with the
      four-package layout (`shikigami-api`, `shikigami-core`, `shikigami-cli`,
      `shikigami-migrations`), `cabal.project` pinning the kikan stack **plus a `kioku`
      source-repository-package** (IP-5); `cabal build all` succeeds.
- [ ] M1: `shikigami-migrations` composes `kirokuMigrations <> keiroFrameworkMigrations <>
      kiokuMigrations <> shikigamiOwnMigrations`; `just create-database` applies all of them to a
      fresh DB and `\dt kiroku.kioku_*` lists `kioku_memories`, `kioku_sessions`, `kioku_turns`.
- [ ] M2: `shikigami-core` defines `Shikigami.Memory.Scope` (the `agentScope`/`globalScope`
      mapping helpers, IP-2) and `Shikigami.Agent.Run` (the `runAgentDemo` seam that opens a
      kioku session, recalls, records a learning, completes the session).
- [ ] M2: `shikigami-cli` exposes `cabal run shikigami -- agent-demo --agent <name>`; a single
      run opens a session scoped to `shikigami/agent/<name>`, recalls (empty first run), records a
      learning, completes the session — observable via SQL and the kioku CLI.
- [ ] M3: a second run of the same agent recalls run 1's learning (printed and asserted), proving
      persistent per-agent memory; the `activity.v1`→kioku-memory/turn mapping is demonstrated by
      `agent-demo --from-activity <envelope.json>`.
- [ ] M3 (soft, optional): if EP-2 is Complete, `agent-demo` uses hybrid recall; if EP-3 is
      Complete, an `agent-persona --agent <name>` subcommand prints the distilled per-agent
      persona. Skipped (with a note) if the soft deps are not yet done.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Scope EP-6 to **the pragmatic v1 (option b)** — scaffold the shikigami four-package
  project only as far as needed to build + apply kioku's migrations, then prove the integration
  with a `shikigami-cli` `agent-demo` command that *simulates* an agent run (open kioku session →
  recall memory → record a learning → complete session). Do **not** build the full shikigami
  runtime (Dhall loader, triggers, behavior runner, sinks, shomei, Kafka consumer).
  Rationale: the prompt offered (a) full runtime scaffold vs. (b) memory/session seam + demo, and
  chose (b) explicitly as "the pragmatic v1 (full shikigami runtime is its own initiative)". The
  full runtime spans Dhall/Kafka/handan/baikai/shomei and far exceeds this plan's milestone
  budget; the integration this plan owns is *memory + session*, which the demo proves cleanly.
  Date: 2026-06-24

- Decision: **Replace shikigami's planned bespoke `agent_runs` table with kioku's Session
  aggregate.** An agent run becomes a `Kioku.Session`: started at run begin, completed/failed at
  run end, focus = the agent's behavior kind, scope = `ScopeEntity "shikigami" "agent" <agentName>`,
  `subjectRef` = the trigger/run id. The shikigami spec's `agent_runs` columns
  (`run_id, agent_name, status, started_at, completed_at, model_used, summary`) map onto kioku's
  `kioku_sessions` columns (`session_id, agent_id, focus, namespace/scope_kind/scope_ref,
  subject_ref, status, started_at, completed_at, model_used, summary`).
  Rationale: the spec itself calls `agent_runs` "the intention-free mirror of Rei's
  `AgentSessionExistsData`", and kioku's Session aggregate **is** exactly that mirror, generalized.
  Reusing kioku removes a bespoke table, gives sessions an event-sourced audit trail, and unlocks
  optional turn capture (`TurnRecorded`) for free.
  Date: 2026-06-24

- Decision: Use **two scope kinds** for shikigami memory: `ScopeEntity (Namespace "shikigami")
  (ScopeKind "agent") <agentName>` for *per-agent* memory (what this agent has learned across its
  own runs) and `ScopeGlobal (Namespace "shikigami")` for *cross-agent shared learnings* (facts
  any shikigami agent may consult).
  Rationale: IP-2 reserves `ScopeEntity "shikigami" "agent" <agentName>` for shikigami; a per-agent
  scope keyed by the *agent name* (not a run id) is the natural "memory of this agent" key because
  it is stable across runs, while a namespace-global scope models portfolio-wide knowledge.
  Date: 2026-06-24

- Decision: Map an `activity.v1` Activity Envelope onto kioku L0 as **either a memory or a turn**:
  the agent's *digests/learnings* (verb `digest.produced`, `actor.kind:"agent"`) become
  `Kioku.Memory` records under the agent scope (content = the digest payload text, tags from the
  envelope `verb`/`subject.type`); the agent's *raw observation/reasoning steps* during a run
  become `TurnRecorded` events on the run's session. This is the seam EP-3's distillation pyramid
  consumes per agent.
  Rationale: kioku's MasterPlan defines L0 as "session envelope + explicitly-recorded memories +
  optional turns"; the nine-field Activity Envelope (`actor.kind:"agent"`) is the natural L0 event
  shape, so the mapping is a field projection, not a new aggregate.
  Date: 2026-06-24

- Decision: The demo simulates the agent run with a **fixed, deterministic "learning"** (no LLM
  call). The `agent-demo` command records a memory whose content is a constant string keyed on
  the run, so a second run can recall it without a model provider configured.
  Rationale: mirrors EP-1's choice to use a `noop-summary`/fixed-body program so the loop is
  provable without a model key. The behavior runner (handan/baikai) is shikigami's own initiative,
  not this plan; here we only prove the *memory* seam.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Read this section fully before running anything. It assumes you have never seen any of these
repositories.

### Where things live

You will create new Haskell source inside an **existing but code-empty** repository at the
absolute path `/Users/shinzui/Keikaku/bokuno/shikigami`. As of this plan that directory contains
only documentation and Dhall seeds:

- `/Users/shinzui/Keikaku/bokuno/shikigami/docs/initial-spec.md` — the 1369-line architecture
  spec for the shikigami runtime (design only, "not yet an implementation … there is no `.cabal`
  file or Haskell source in this repository yet"). It defines the declared-agent model
  (`{ name, behavior, trigger, sinks }`), the nine-field Activity Envelope (contract C1), and the
  planned `agent_runs` session table this plan replaces with kioku.
- `/Users/shinzui/Keikaku/bokuno/shikigami/agents/detectors/*.dhall` — seed agent declarations
  (`stalled-intention.dhall`, `at-risk-customer.dhall`) plus a local `schema.dhall`. These are
  illustrative declarations authored *before* the runtime; they describe what an agent looks like
  but nothing executes them yet. You read them to understand the agent shape; you do not run them.

You will copy the project skeleton from a sibling template repository and depend on a sibling
library:

- `/Users/shinzui/Keikaku/bokuno/kizashi` — an existing Haskell project on the exact same
  event-sourcing stack. It is the **scaffold template**: four packages (`kizashi-api`,
  `kizashi-core`, `kizashi-cli`, `kizashi-migrations`), a `flake.nix` wrapping
  `github:shinzui/haskell-nix-dev` at GHC 9.12.4, a `cabal.project` with `source-repository-package`
  pins, a `Justfile` (`create-database`/`migrate`/`new-migration`), a `process-compose.yaml`
  (ephemeral Postgres), and a `withKizashiMigratedDatabase` test-support sublibrary. You copy its
  *structure*, renaming `kizashi`→`shikigami`.
- `/Users/shinzui/Keikaku/bokuno/kioku` — the kioku library (created by EP-1). You depend on its
  four packages (`kioku-api`, `kioku-core`, `kioku-cli`, `kioku-migrations`) via a
  `source-repository-package` pin (or a local-path pin during co-development). You import
  `Kioku.Memory`, `Kioku.Session`, `Kioku.Recall`, `Kioku.Api.Scope`, `Kioku.Api.Types`, `Kioku.Id`,
  `Kioku.App`, and `Kioku.Migrations`. **You never import `Kioku.*.Domain.*` internals** (IP-1).

This ExecPlan file itself lives in the kioku repo at
`docs/plans/6-shikigami-memory-integration-with-kioku.md`. It is EP-6 of MasterPlan #1,
`docs/masterplans/1-kioku-reusable-agent-memory-session-library.md`, whose Integration Points
IP-1 through IP-6 are binding contracts restated concretely in **Interfaces and Dependencies**
below.

### What you must NOT do (the boundary again)

This plan does **not** create the shikigami Dhall loader, the trigger evaluators
(`Shikigami.Trigger.*`), the behavior runner (`Shikigami.Behavior.*`), the sink dispatchers
(`Shikigami.Sink.*`), the shomei permission gate, or the Kafka `activity.v1` consumer. Those are
the full-runtime initiative. The only shikigami modules you create are the memory/session seam
(`Shikigami.Memory.Scope`, `Shikigami.Agent.Run`) and the CLI demo. If a step tempts you to wire a
real trigger or sink, stop — that is out of scope.

### Terms of art (defined in plain language)

- **Declared agent.** In shikigami, an agent is a *declaration*, a typed Dhall record
  `{ name, behavior, trigger, sinks }` — not a deployed service. `name` is a stable text id;
  `behavior` is what it does; `trigger` is when; `sinks` are what it produces. This plan uses only
  the `name` (as a memory scope key) and treats the behavior as a fixed stub.
- **Activity Envelope (contract C1).** The canonical nine-field event shape every activity on the
  shared `activity.v1` stream takes: `activity_id` (a UUIDv7 string the publisher mints itself),
  `occurred_at` (RFC3339 timestamp), `source` (e.g. `"shinzui/shikigami"`), `actor`
  (`{ kind: "human"|"agent"|"service", id, session? }`), `subject` (`{ type, id }` — what it's
  about), `verb` (a past-tense dotted string, e.g. `"digest.produced"`), `payload` (free-form JSON),
  `context_refs` (back-references), and `idempotency_key`. An *agent's own* output carries
  `actor.kind: "agent"`. This plan reads an envelope from a JSON file and maps it into a kioku
  memory or turn; it does **not** consume a live Kafka stream.
- **kioku Session.** An event-sourced record of one agent run. Created by `Kioku.Session.start`,
  closed by `Kioku.Session.complete` or `Kioku.Session.fail`. It carries a free-form `focus :: Text`,
  a `scope :: MemoryScope`, an optional `subjectRef :: Maybe Text`, and may capture raw `TurnRecorded`
  events while open. Projected to the `kioku_sessions` (and `kioku_turns`) read-model table.
- **kioku Memory.** An event-sourced durable learning, recorded by `Kioku.Memory.record`. It carries
  a `scope :: MemoryScope`, a `memoryType` (fact/pattern/preference/constraint/instruction), free
  text `content`, a numeric `priority`, a `confidence` (high/medium/low), and `tags`. Projected to
  the `kioku_memories` table with a full-text `content_tsv` column.
- **MemoryScope (IP-2).** kioku's generic scoping value: `ScopeGlobal (Namespace ns)` for
  namespace-wide memory, or `ScopeEntity (Namespace ns) (ScopeKind k) ref` for a typed-entity-scoped
  memory. shikigami uses `Namespace "shikigami"`, kind `"agent"`, ref = the agent name.
- **Recall.** Reading memories back by scope. EP-1 ships a *placeholder* `Kioku.Recall` with simple
  scoped SQL (`getActiveByScope`, `getGlobal`, `getBySession`, `getByType`). EP-2 replaces it with
  hybrid (vector + FTS + RRF) recall behind the same module. This plan uses `getActiveByScope`.
- **codd / migrations composition.** kioku and the kikan framework ship their schema as timestamped
  `.sql` files embedded into a binary by Template Haskell `embedDir` and applied by the `codd`
  tool. shikigami's migration binary composes them in order:
  `kirokuMigrations <> keiroFrameworkMigrations <> kiokuMigrations <> shikigamiOwnMigrations`. The
  kioku read-model tables live in the **`kiroku` schema** (the kizashi convention).

### What already exists vs. what you create

`/Users/shinzui/Keikaku/bokuno/kioku` exists and builds once EP-1 is Complete (it is this plan's
hard dependency). `/Users/shinzui/Keikaku/bokuno/kizashi` exists and is the read-only scaffold
template. `/Users/shinzui/Keikaku/bokuno/shikigami` exists but has **no Haskell** — you create all
four packages, the migration composition, the memory/session seam, and the CLI demo. The shikigami
spec and Dhall seeds are read-only inputs.


## Plan of Work

The work is three milestones. M1 stands up the buildable, migratable shikigami skeleton that
pins and applies kioku. M2 delivers the memory/session seam and the `agent-demo` command that
simulates one agent run (the integration made executable). M3 proves persistence across two runs
and demonstrates the `activity.v1`→kioku mapping. Each milestone leaves the tree building
(`cabal build all`) and is independently verifiable. The full shikigami runtime is **not** part
of any milestone (see the boundary in Context and Orientation).

### Milestone M1 — shikigami scaffold that builds and applies kioku's migrations

**Scope and result.** At the end of M1, `/Users/shinzui/Keikaku/bokuno/shikigami` is a git repo
with the four packages (`shikigami-api`, `shikigami-core`, `shikigami-cli`,
`shikigami-migrations`), a `cabal.project` that pins the kikan stack **and** kioku, and the
nix/flake/Justfile/process-compose files. `cabal build all` succeeds and `just create-database`
applies the kiroku + keiro + **kioku** + shikigami migrations to a fresh database. There is no
agent logic yet; the goal is a green build, a kioku dependency that resolves, and a migrated
schema that includes kioku's `kioku_memories`/`kioku_sessions`/`kioku_turns` tables.

**Files created in M1** (all under `/Users/shinzui/Keikaku/bokuno/shikigami`):

`cabal.project` — copy kizashi's `cabal.project` verbatim (the same keiki/keiro/kiroku/shibuya/
pgmq pin-set EP-1 reproduces), change the four `packages:` lines to the shikigami package dirs,
and **add the kioku dependency**. During co-development with a local kioku checkout the simplest,
most reliable pin is a local-path package:

```text
packages:
  shikigami-api
  shikigami-core
  shikigami-cli
  shikigami-migrations
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-api
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-core
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-cli
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-migrations
```

For a released/pinned build (IP-5), replace those four local paths with a
`source-repository-package` stanza once kioku has a published git tag:

```text
source-repository-package
  type: git
  location: https://github.com/shinzui/kioku.git
  tag: <kioku-commit-after-EP-1>
  subdir: kioku-api kioku-core kioku-cli kioku-migrations
```

Either way, the rest of the pin-set (keiki `bc987f46…`, keiro `f1d67a01…`, kiroku `322096c8…`,
shibuya `3f276ee1…`, pgmq-hs, the forks) must be **byte-identical to kioku's own `cabal.project`**
so the solver picks one coherent set; copy kioku's `cabal.project` pin block rather than
re-typing it. Keep kioku's `package codd { tests: False }` and `allow-newer: haxl:time` lines.

`flake.nix`, `nix/haskell.nix`, `nix/treefmt.nix`, `nix/pre-commit.nix`, `.envrc`,
`process-compose.yaml`, `Justfile` — copy kizashi's verbatim, replacing every `kizashi` token
with `shikigami` (description text, `PGDATABASE=kizashi`→`PGDATABASE=shikigami`, the `migrate`
recipe's `kizashi-migrations` path → `shikigami-migrations`, and `cabal run kizashi-migrate` →
`cabal run shikigami-migrate`). The `CODD_SCHEMAS=kiroku` line stays (kioku's read models live in
the `kiroku` schema). The `.envrc` is exactly `use flake` then `eval "$shellHook"`.

`shikigami-api/shikigami-api.cabal` and `shikigami-api/src/Shikigami/Prelude.hs` — a minimal wire
package modeled on `kizashi-api`. In M1 the only module strictly required is `Shikigami.Prelude`
(copy kizashi's, rename). The `AgentDecl`/`Behavior`/`Trigger`/`Sink` wire types from the spec are
**not** needed by this plan (no Dhall loader); add them only if a later, out-of-scope runtime plan
wants them. Dependency set mirrors `kizashi-api`'s minimal set (`aeson, base, generic-lens, lens,
mmzk-typeid, text, time, uuid, containers`).

`shikigami-core/shikigami-core.cabal` — modeled on `kizashi-core.cabal` but trimmed and pointed at
kioku. Depends on `shikigami-api` plus `kioku-api`, `kioku-core`, and the effect/SQL stack kioku
itself uses (`effectful, effectful-core, kiroku-store, shibuya-core, hasql, hasql-pool, text, time,
containers, aeson`). M1 needs no exposed modules beyond a trivial placeholder; M2 adds
`Shikigami.Memory.Scope` and `Shikigami.Agent.Run`.

`shikigami-cli/shikigami-cli.cabal` — modeled on `kizashi-cli.cabal`: a library `Shikigami.Cli`
(+ `Shikigami.Cli.Commands.AgentDemo` in M2) and an `executable shikigami` whose `app/Main.hs`
calls `Shikigami.Cli.main`. Depends on `shikigami-core`, `shikigami-api`, `kioku-core`,
`kioku-api`, `kiroku-store`, `optparse-applicative`, `text`, `base`.

`shikigami-migrations/shikigami-migrations.cabal`, `src/Shikigami/Migrations.hs`,
`app/Main.hs`, `test-support/Shikigami/Migrations/TestSupport.hs`,
`sql-migrations/<timestamp>-shikigami-base.sql` — copy `kizashi-migrations` structure exactly
(library `Shikigami.Migrations`, executable `shikigami-migrate`, public sublibrary `test-support`
exposing `withShikigamiMigratedDatabase`). The one functional change is the migration
**composition**: it must include kioku's migrations. In `src/Shikigami/Migrations.hs` import
`Kioku.Migrations (kiokuMigrations)` and compose:

```haskell
shikigamiMigrations :: [AddedSqlMigration m]
shikigamiMigrations =
  kirokuMigrations
    <> keiroFrameworkMigrations
    <> kiokuMigrations
    <> shikigamiOwnMigrations
  where
    shikigamiOwnMigrations = $(embedDir "sql-migrations")
```

The `sql-migrations/<timestamp>-shikigami-base.sql` file in M1 can be **empty of shikigami-owned
tables** (the planned bespoke `agent_runs` table is intentionally *not* created — kioku's
`kioku_sessions` replaces it). Make it a no-op marker migration so the `embedDir` splice has at
least one file:

```sql
-- codd: in-txn
-- Migration: shikigami-base
-- shikigami stores agent runs as kioku Sessions (kioku_sessions), so there is no
-- bespoke agent_runs table. This marker reserves the shikigami migration slot.
SET search_path TO kiroku, pg_catalog;
SELECT 1;
```

`shikigami-core/src/Shikigami/App.hs` (optional, M1 or M2) — copy kioku's `Kioku.App` effect-stack
shape, or simply reuse `Kioku.App.runAppIO`/`AppEnv` directly from `kioku-core` (preferred — fewer
modules). The demo opens the store and runs kioku effects through `Kioku.App.runAppIO`.

**Acceptance for M1.** From inside `/Users/shinzui/Keikaku/bokuno/shikigami` in the nix dev shell:
`cabal build all` exits 0; `just create-database` exits 0; and
`psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt kiroku.kioku_*'` lists `kioku_memories`,
`kioku_sessions`, `kioku_turns`. This proves the kioku dependency resolves and its schema is
present in shikigami's database.

### Milestone M2 — the memory/session seam and the `agent-demo` command (one simulated run)

**Scope and result.** At the end of M2, shikigami has a `Shikigami.Memory.Scope` module (the
IP-2 mapping helpers) and a `Shikigami.Agent.Run` module (the run seam), and
`cabal run shikigami -- agent-demo --agent <name>` runs **one simulated agent run** end to end:
it opens a kioku session scoped to the agent, recalls the agent's prior memory (empty on the very
first run), records a learning as a kioku memory, and completes the session. This is the
integration made executable. No trigger, no behavior runner, no sink — just the memory/session
seam.

**Files added in M2:**

`shikigami-core/src/Shikigami/Memory/Scope.hs` — the consumer-side scope mapping (IP-2; the helper
lives in shikigami, not kioku). It maps an agent name to its per-agent scope and exposes the
namespace-global scope:

```haskell
module Shikigami.Memory.Scope
  ( shikigamiNamespace
  , agentScope
  , sharedScope
  ) where

import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Data.Text (Text)

-- | The shikigami namespace label used for every shikigami-owned memory/session.
shikigamiNamespace :: Namespace
shikigamiNamespace = Namespace "shikigami"

-- | Per-agent memory scope: everything THIS agent has learned across its own runs.
--   Keyed by the agent's stable declared name (not a run id), so it is stable across runs.
agentScope :: Text -> MemoryScope
agentScope agentName = ScopeEntity shikigamiNamespace (ScopeKind "agent") agentName

-- | Cross-agent shared learnings any shikigami agent may consult.
sharedScope :: MemoryScope
sharedScope = ScopeGlobal shikigamiNamespace
```

`shikigami-core/src/Shikigami/Agent/Run.hs` — the run seam. It bundles the session lifecycle and
the recall/record steps so the CLI is thin. The shape (signatures are exact; bodies call kioku's
public API):

```haskell
module Shikigami.Agent.Run
  ( AgentRunInput (..)
  , AgentRunResult (..)
  , runAgentDemo
  ) where

import Kioku.App           (AppEnv, runAppIO)
import Kioku.Api.Scope     (MemoryScope)
import Kioku.Api.Types     (MemoryType (..), Confidence (..), MemoryRecord)
import Kioku.Id            (SessionId, MemoryId, genSessionId, genMemoryId, idText)
import qualified Kioku.Session as Session
import qualified Kioku.Memory  as Memory
import qualified Kioku.Recall  as Recall
import Shikigami.Memory.Scope (agentScope)
import Data.Time (UTCTime, getCurrentTime)
import Data.Text (Text)
import qualified Data.Set as Set

data AgentRunInput = AgentRunInput
  { agentName    :: !Text          -- the declared agent's name (scope key)
  , behaviorKind :: !Text          -- "ShikumiProgram" | "Skill" — recorded as the session focus
  , learning     :: !Text          -- the (fixed, for the demo) thing this run learned
  }

data AgentRunResult = AgentRunResult
  { runSessionId  :: !SessionId
  , recalledPrior :: ![MemoryRecord]   -- what the agent remembered from earlier runs
  , recordedMemId :: !MemoryId         -- the learning recorded this run
  }

-- | Simulate one agent run against kioku: open a session, recall this agent's prior
--   memory, record a new learning, complete the session. Returns what was recalled and
--   recorded so the CLI can print the across-run proof.
runAgentDemo :: AppEnv -> AgentRunInput -> IO (Either Text AgentRunResult)
runAgentDemo env input = do
  let scope = agentScope (agentName input)
  now <- getCurrentTime
  sid <- genSessionId
  -- 1. open the session (replaces shikigami's bespoke agent_runs insert)
  _ <- runAppIO env $ Session.start Session.StartSessionData
         { sessionId = sid, agentId = agentName input, focus = behaviorKind input
         , scope = scope, subjectRef = Just (idText sid), previousSessionId = Nothing
         , startedAt = now }
  -- 2. recall what this agent already knows (empty on the first ever run)
  prior <- runAppIO env $ Recall.getActiveByScope scope
  -- 3. record this run's learning as a durable memory under the agent scope
  mid <- genMemoryId
  _ <- runAppIO env $ Memory.record Memory.RecordMemoryData
         { memoryId = mid, agentId = agentName input, sessionId = Just sid, scope = scope
         , memoryType = MemoryPattern, content = learning input, priority = 100
         , confidence = MediumConfidence, tags = Set.fromList ["agent-demo"]
         , supersedes = Nothing, recordedAt = now }
  -- 4. complete the session
  done <- getCurrentTime
  _ <- runAppIO env $ Session.complete sid done (Just "agent-demo run completed")
  pure (Right (AgentRunResult sid (either (const []) id prior) mid))
```

(The exact field names of `StartSessionData`/`RecordMemoryData` come from EP-1's `Kioku.Session`/
`Kioku.Memory` write API; match them when EP-1 lands — EP-1's demo in
`docs/plans/1-...md` Step 5 shows `RecordMemoryData` field-for-field. If a field name differs,
adjust here; the *shape* is the contract.)

`shikigami-cli/src/Shikigami/Cli/Commands/AgentDemo.hs`, `shikigami-cli/src/Shikigami/Cli.hs`,
`shikigami-cli/app/Main.hs` — the `agent-demo` subcommand. `Shikigami.Cli.main` is an
optparse-applicative subparser; `agent-demo` takes `--agent <name>` (and optional
`--behavior <kind>` defaulting to `"ShikumiProgram"`, `--learning <text>` defaulting to a fixed
string). `runAgentDemoCmd` opens the kioku store exactly as EP-1's demo does, builds the
`AppEnv`, calls `runAgentDemo`, and prints the across-run report:

```haskell
runAgentDemoCmd :: AgentDemoOpts -> IO ()
runAgentDemoCmd opts = do
  connStr <- requireEnv "PG_CONNECTION_STRING"
  withStore (defaultConnectionSettings connStr) $ \st -> do
    tr <- noopTracer
    let env = AppEnv { store = st, tracer = tr, metrics = Nothing }
    res <- runAgentDemo env AgentRunInput
             { agentName = optAgent opts, behaviorKind = optBehavior opts
             , learning = optLearning opts }
    case res of
      Left err -> putStrLn ("agent-demo failed: " <> show err)
      Right r  -> do
        putStrLn ("agent " <> show (optAgent opts) <> " run "
                    <> idText (runSessionId r))
        putStrLn ("recalled " <> show (length (recalledPrior r)) <> " prior memories:")
        mapM_ (putStrLn . ("  - " <>) . renderRecord) (recalledPrior r)
        putStrLn ("recorded learning " <> idText (recordedMemId r))
```

**Acceptance for M2.** `cabal build all` exits 0. `cabal run shikigami -- agent-demo --agent
stalled-intention` prints `recalled 0 prior memories` (first run), then `recorded learning
kioku_memory_…`. A `psql` query of `kiroku.kioku_sessions` shows one row with
`namespace='shikigami', scope_kind='agent', scope_ref='stalled-intention', status='completed'`,
and `kiroku.kioku_memories` shows one row in that same scope. This proves shikigami records an
agent run as a kioku session and a learning as a kioku memory — the planned bespoke `agent_runs`
table is replaced.

### Milestone M3 — persistence across runs + the activity→memory mapping

**Scope and result.** At the end of M3, running `agent-demo --agent <name>` a *second* time
recalls the learning recorded in the first run (proving per-agent memory persists across runs,
the headline acceptance), and the `activity.v1`→kioku-L0 mapping is demonstrated by a
`--from-activity <file>` mode that reads an Activity Envelope JSON file and records its digest
payload as a kioku memory (and, optionally, its observation steps as session turns).

**Files added/changed in M3:**

`shikigami-core/src/Shikigami/Activity.hs` — the envelope→kioku mapping. It defines a minimal
`ActivityEnvelope` decode (the nine C1 fields; only `actor`, `subject`, `verb`, `payload`,
`occurred_at` are load-bearing here) and two mappers:

```haskell
module Shikigami.Activity
  ( ActivityEnvelope (..)
  , activityToMemory   -- digest/learning envelope -> a kioku memory under the agent scope
  , activityToTurn     -- a raw observation step    -> a kioku TurnRecorded on the run's session
  ) where

-- activityToMemory env agentName ->
--   scope    = agentScope agentName              (or sharedScope if actor.id is namespace-wide)
--   content  = render (payload env)              (the digest body text)
--   type     = MemoryPattern                     (a digest is a learned pattern)
--   tags     = Set.fromList [ "verb:" <> verb env, "subject:" <> subjectType env ]
--   recordedAt = occurredAt env
-- activityToTurn env sid turnIx ->
--   sessionId = sid; turnIndex = turnIx; role = "agent";
--   content   = render (payload env); recordedAt = occurredAt env
```

The mapping rationale, stated for the reader: an `activity.v1` envelope an agent *produces*
(`actor.kind:"agent"`, e.g. `verb:"digest.produced"`) is exactly a learning that L0 should
capture — so it becomes a `Kioku.Memory` under the producing agent's scope, with the envelope's
`verb`/`subject.type` becoming searchable tags and the `payload` becoming the memory `content`.
An envelope that represents a *raw step within a run* (an observation the agent made before
emitting its digest) becomes a `TurnRecorded` event on that run's session — the opt-in L0
"turns" capability. Either way the kioku stream now holds the agent's L0 evidence, which is
precisely what EP-3's distillation pyramid (`docs/plans/3-...md`) consumes per agent to build a
per-agent persona (L3) — the soft dependency made concrete.

`shikigami-cli/src/Shikigami/Cli/Commands/AgentDemo.hs` — extend with `--from-activity <file>`:
when present, decode the envelope, derive the agent name from `actor.id` (or `--agent`), and
record the envelope as a memory via `activityToMemory` (and, if `--with-turns`, also open a
session and record the envelope's payload as one turn). Print the recorded memory id and the
scope.

**Acceptance for M3.** Running `agent-demo --agent stalled-intention` twice in a row: the first
run prints `recalled 0 prior memories`, the second prints `recalled 1 prior memories:` followed by
the learning text from run 1. `kiroku.kioku_sessions` has two rows scoped to the agent,
`kiroku.kioku_memories` has the learning(s) under `scope_ref='stalled-intention'`. Then
`agent-demo --agent stalled-intention --from-activity ./fixtures/digest.json` records the
envelope's payload as a memory and prints its id; a `psql` query shows the new memory with tags
`verb:digest.produced` / `subject:intention`. This proves persistent per-agent memory and the
activity→memory mapping. The kioku CLI cross-check (`cabal run kioku -- ...` against the same DB,
if EP-1's recall demo is wired) shows the same rows.

**Soft-dependency note (optional, M3).** If EP-2 is Complete, `Recall.getActiveByScope` is already
hybrid behind the same module, so no shikigami change is needed to benefit. If EP-3 is Complete,
add an `agent-persona --agent <name>` subcommand that reads the per-scope L3 persona kioku
produced for `agentScope name` and prints it. If neither soft dep is done, skip these and note it
in Progress — the core acceptance does not depend on them.


## Concrete Steps

Run all commands from inside `/Users/shinzui/Keikaku/bokuno/shikigami` unless stated otherwise,
and inside the nix dev shell (which exports the PG env vars `PGHOST`/`PGDATABASE` and
`PG_CONNECTION_STRING`). Enter the shell with `direnv allow` (after writing `.envrc`) or
`nix develop`. EP-1 (kioku) must be Complete and `/Users/shinzui/Keikaku/bokuno/kioku` must build
before you start.

### Step 0 — Create the repo skeleton from the kizashi template

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
git init 2>/dev/null || true
# Copy scaffold files from kizashi; rename tokens kizashi->shikigami / Kizashi->Shikigami.
cp /Users/shinzui/Keikaku/bokuno/kizashi/flake.nix ./flake.nix
mkdir -p nix
cp /Users/shinzui/Keikaku/bokuno/kizashi/nix/haskell.nix    nix/haskell.nix
cp /Users/shinzui/Keikaku/bokuno/kizashi/nix/treefmt.nix    nix/treefmt.nix
cp /Users/shinzui/Keikaku/bokuno/kizashi/nix/pre-commit.nix nix/pre-commit.nix
cp /Users/shinzui/Keikaku/bokuno/kizashi/process-compose.yaml ./process-compose.yaml
cp /Users/shinzui/Keikaku/bokuno/kizashi/Justfile ./Justfile
printf 'use flake\neval "$shellHook"\n' > .envrc
```

Then edit each copied file to replace `kizashi`/`Kizashi` with `shikigami`/`Shikigami`, and in
`nix/haskell.nix` change `export PGDATABASE=kizashi` → `export PGDATABASE=shikigami`. Write
`cabal.project` from the Plan-of-Work block (the four shikigami packages + the four kioku local
paths + kioku's verbatim kikan pin block). The fastest way to get the pin block exactly right:

```bash
# Show kioku's pin block so you can copy it verbatim into shikigami/cabal.project.
sed -n '/^source-repository-package/,$p' /Users/shinzui/Keikaku/bokuno/kioku/cabal.project
```

### Step 1 — Write the four `.cabal` files and the migration package

Create `shikigami-api/shikigami-api.cabal` (+ `src/Shikigami/Prelude.hs`),
`shikigami-core/shikigami-core.cabal`, `shikigami-cli/shikigami-cli.cabal`, and the
`shikigami-migrations` package (cabal + `src/Shikigami/Migrations.hs` + `app/Main.hs` +
`test-support/Shikigami/Migrations/TestSupport.hs` + `sql-migrations/<timestamp>-shikigami-base.sql`),
all per the Plan of Work. The migration composition in `src/Shikigami/Migrations.hs` MUST include
`kiokuMigrations` (import from `Kioku.Migrations`). Build and migrate:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikigami
direnv allow      # or: nix develop
cabal build all
just create-database
psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt kiroku.kioku_*'
```

Expected table list (closes M1):

```text
            List of relations
 Schema |      Name       | Type  | ...
--------+-----------------+-------+----
 kiroku | kioku_memories  | table | ...
 kiroku | kioku_sessions  | table | ...
 kiroku | kioku_turns     | table | ...
```

### Step 2 — Memory/session seam + `agent-demo` (M2)

Write `shikigami-core/src/Shikigami/Memory/Scope.hs` and `shikigami-core/src/Shikigami/Agent/Run.hs`
(full shapes in Plan of Work), add both to `shikigami-core.cabal` `exposed-modules`. Write
`shikigami-cli/src/Shikigami/Cli/Commands/AgentDemo.hs`, `Shikigami/Cli.hs`, and `app/Main.hs`.
Build and run one agent:

```bash
cabal build all
just create-database              # ensure schema present
cabal run shikigami -- agent-demo --agent stalled-intention
```

Expected transcript on the **first** run:

```text
agent "stalled-intention" run kioku_session_01j...
recalled 0 prior memories:
recorded learning kioku_memory_01j...
```

Verify the session and memory rows:

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "SELECT session_id, agent_id, focus, namespace, scope_kind, scope_ref, status FROM kiroku.kioku_sessions;"
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "SELECT memory_id, namespace, scope_kind, scope_ref, content FROM kiroku.kioku_memories;"
```

Expected: one session row (`scope_kind='agent'`, `scope_ref='stalled-intention'`,
`status='completed'`) and one memory row in the same scope. This closes M2.

### Step 3 — Persistence across runs + activity mapping (M3)

Run the **same** agent a second time:

```bash
cabal run shikigami -- agent-demo --agent stalled-intention
```

Expected transcript on the **second** run (the headline proof — run 2 remembers run 1):

```text
agent "stalled-intention" run kioku_session_01j...
recalled 1 prior memories:
  - kioku_memory_01j... [pattern/medium] <the learning text from run 1>
recorded learning kioku_memory_01j...
```

Then demonstrate the activity→memory mapping. Write a fixture envelope and feed it in:

```bash
mkdir -p fixtures
cat > fixtures/digest.json <<'JSON'
{
  "activity_id": "0192f000-0000-7000-8000-000000000001",
  "occurred_at": "2026-06-24T07:00:00Z",
  "source": "shinzui/shikigami",
  "actor": { "kind": "agent", "id": "stalled-intention" },
  "subject": { "type": "intention", "id": "intention_01jrei" },
  "verb": "digest.produced",
  "payload": { "summary": "intention has had no action for 7 days" },
  "context_refs": [],
  "idempotency_key": "stalled-intention:0192f000"
}
JSON
cabal run shikigami -- agent-demo --agent stalled-intention --from-activity fixtures/digest.json
psql -h "$PGHOST" -d "$PGDATABASE" -c \
  "SELECT memory_id, content, tags FROM kiroku.kioku_memories WHERE scope_ref='stalled-intention' ORDER BY created_at DESC LIMIT 1;"
```

Expected: a new memory row whose `content` is the rendered payload and whose `tags` include
`verb:digest.produced` and `subject:intention`. This closes M3.

### Step 4 — Test-support sanity (optional but recommended)

`shikigami-migrations`'s test-support sublibrary spins up an ephemeral Postgres and applies the
composed migrations. A tiny `tasty` test in `shikigami-core/test` can call
`withShikigamiMigratedDatabase` and assert the `kioku_memories` table exists, giving CI a fast,
DB-backed check that the kioku-migration composition stays wired:

```bash
cabal test shikigami-core
```


## Validation and Acceptance

The plan is accepted when all three milestone acceptances hold on a fresh checkout, each phrased
as something a human runs and sees:

1. **Build + migrate (M1).** From `/Users/shinzui/Keikaku/bokuno/shikigami` in the dev shell,
   `cabal build all` exits 0 (proving the kioku dependency resolves into shikigami's package set),
   `just create-database` exits 0, and `\dt kiroku.kioku_*` lists `kioku_memories`,
   `kioku_sessions`, `kioku_turns`.
2. **One simulated run records a session + memory (M2).** `cabal run shikigami -- agent-demo
   --agent stalled-intention` prints the run id, `recalled 0 prior memories`, and `recorded
   learning …`. A `psql` query shows one `kioku_sessions` row scoped to
   `shikigami/agent/stalled-intention` with `status='completed'` and one `kioku_memories` row in
   the same scope. This is the observable replacement of the spec's bespoke `agent_runs` table by
   kioku's Session.
3. **Memory persists across runs (M3, headline).** Running `agent-demo --agent stalled-intention`
   a second time prints `recalled 1 prior memories:` followed by run 1's learning text. Two
   `kioku_sessions` rows and at least one `kioku_memories` row exist under the agent scope. This is
   the user-visible behavior promised in the Purpose: an agent remembers across runs.
4. **Activity→memory mapping (M3).** `agent-demo --agent stalled-intention --from-activity
   fixtures/digest.json` records the envelope's payload as a memory whose tags carry the envelope's
   `verb`/`subject.type`. This shows the documented `activity.v1`→kioku-L0 mapping is real, which
   is the L0 EP-3's per-agent distillation consumes.

Acceptance is *behavioral*, not "code added": each check is a command whose output a novice can
compare against the transcripts above. The change is effective beyond compilation because the
second run's recall demonstrably depends on the first run's write landing in the event store and
its inline projection.


## Idempotence and Recovery

- **Scaffold copy (Step 0–1).** Re-running the copies overwrites files with identical content; safe
  to repeat. Editing the token renames is idempotent (the second pass finds nothing to change).
- **Migrations.** All kioku/kikan DDL is `CREATE … IF NOT EXISTS`; codd records applied migrations
  by timestamped filename and skips already-applied ones, so `just create-database` and
  `just migrate` are safe to re-run. If you add a `.sql` file after a prior `migrate`, the Justfile
  `migrate` recipe `touch`es `shikigami-migrations/shikigami-migrations.cabal` to force the
  `embedDir` splice to re-bake it — without that touch a newly added migration is silently not
  embedded. **Every database that opens the kioku store must apply kioku's migrations first** — the
  composed `shikigamiMigrations` already does this, but if you point at a DB migrated without
  `kiokuMigrations` the demo fails with `relation "kioku_sessions" does not exist`; re-run
  `just create-database`.
- **kioku store search_path.** kioku's read-model tables live in the `kiroku` schema. If a query
  errors with `relation "kioku_…" does not exist` despite the table existing, the store pool's
  `search_path` is the cause; kioku's `withStore`/`AppEnv` already set it (the kizashi convention).
  Do not add a bespoke search_path here.
- **The `agent-demo` command.** Re-running `agent-demo` records a *new* memory each time (fresh id),
  which is harmless and is exactly what the across-run proof relies on. To reset the demo to a clean
  "first run", `TRUNCATE kiroku.kioku_memories, kiroku.kioku_sessions, kiroku.kioku_turns;` and drop
  the corresponding `kioku_memory-*`/`kioku_session-*` streams (or recreate the database). After a
  truncate, run 1 again prints `recalled 0 prior memories`.
- **`--from-activity`.** The envelope's `idempotency_key` is carried into the memory's tags/metadata
  but EP-1's placeholder recall does not dedup on it; re-feeding the same envelope records a
  duplicate memory. That is acceptable for the demo. (Real dedup on `idempotency_key` is a
  full-runtime concern, out of scope.)
- **Build recovery.** A dependency-resolution conflict almost always means the kikan pin block in
  `shikigami/cabal.project` diverged from kioku's — make them byte-identical. A "hidden module in
  package shikigami-core" error means a module is in `other-modules` instead of `exposed-modules`;
  fix the `.cabal` file. Do **not** delete inplace `.conf` registrations to "fix" it — that
  re-solves the plan into two incompatible hasql builds and forces a long clean rebuild (a known
  kikan-stack gotcha).


## Interfaces and Dependencies

This section names the exact types/functions that must exist at the end of each milestone and the
binding integration contracts (IP-1…IP-6 from MasterPlan #1,
`docs/masterplans/1-kioku-reusable-agent-memory-session-library.md`).

### Libraries depended on (and why)

- `kioku-api` — `Kioku.Api.Scope` (`Namespace`, `ScopeKind`, `MemoryScope`), `Kioku.Api.Types`
  (`MemoryType`, `Confidence`, `MemoryRecord`), `Kioku.Id` (`MemoryId`, `SessionId`, `genMemoryId`,
  `genSessionId`, `idText`). The wire types shikigami maps its agent names into.
- `kioku-core` — `Kioku.Memory` (write: `record`/…), `Kioku.Session` (write: `start`/`complete`/
  `fail`/`recordTurn`), `Kioku.Recall` (read: `getActiveByScope` and the other scoped queries),
  `Kioku.App` (`AppEnv`, `runAppIO`, `noopTracer`). **shikigami imports only these top-level
  modules + `kioku-api` types — never `Kioku.*.Domain.*` internals (IP-1).**
- `kioku-migrations` — `Kioku.Migrations.kiokuMigrations` (composed into shikigami's migration set,
  IP-3) and `Kioku.Migrations.TestSupport` (for the optional ephemeral-DB test).
- `kiroku-store` — `KirokuStore`, `defaultConnectionSettings`, `withStore` (open the store in the
  CLI demo, exactly as kioku's own demo does).
- The kikan stack (`keiki`/`keiro`/`kiroku`/`shibuya`/`pgmq-hs` + forks) — pinned transitively for a
  coherent solve, identical to kioku's `cabal.project`.
- `optparse-applicative`, `text`, `time`, `containers`, `aeson` — the CLI and the activity-envelope
  decode.

### Module/function signatures by milestone

**End of M1.** A buildable four-package shikigami repo; `Shikigami.Migrations.shikigamiMigrations`
(composing `kirokuMigrations <> keiroFrameworkMigrations <> kiokuMigrations <>
shikigamiOwnMigrations`); `Shikigami.Migrations.TestSupport.withShikigamiMigratedDatabase ::
(Text -> IO a) -> IO a`. `just create-database` lands kioku's tables in the `kiroku` schema.

**End of M2.**

- `Shikigami.Memory.Scope`: `shikigamiNamespace :: Namespace`, `agentScope :: Text -> MemoryScope`
  (= `ScopeEntity (Namespace "shikigami") (ScopeKind "agent") <agentName>`),
  `sharedScope :: MemoryScope` (= `ScopeGlobal (Namespace "shikigami")`). This is shikigami's
  side of **IP-2**.
- `Shikigami.Agent.Run`: `data AgentRunInput`, `data AgentRunResult`,
  `runAgentDemo :: AppEnv -> AgentRunInput -> IO (Either Text AgentRunResult)` — opens a kioku
  session (`Kioku.Session.start`), recalls (`Kioku.Recall.getActiveByScope`), records a learning
  (`Kioku.Memory.record`), and completes (`Kioku.Session.complete`).
- `Shikigami.Cli`: `main :: IO ()` with an `agent-demo` subcommand;
  `Shikigami.Cli.Commands.AgentDemo.runAgentDemoCmd :: AgentDemoOpts -> IO ()`.

**End of M3.**

- `Shikigami.Activity`: `data ActivityEnvelope` (the nine C1 fields, with `aeson` `FromJSON`),
  `activityToMemory :: ActivityEnvelope -> Text -> Kioku.Memory.RecordMemoryData` (envelope +
  agent name → a memory under `agentScope`), `activityToTurn :: ActivityEnvelope -> SessionId ->
  Int -> Kioku.Session.RecordTurnData`.
- `Shikigami.Cli.Commands.AgentDemo` extended with `--from-activity <file>` (and optional
  `--with-turns`).

### IP-1 — kioku public API surface (consumed)

shikigami depends only on `Kioku.Memory`, `Kioku.Session`, `Kioku.Recall`, and the `kioku-api`
types. EP-1 ships the write APIs and a placeholder scoped `Kioku.Recall`; EP-2 fills in hybrid
recall behind the same module (so shikigami benefits with no code change). Never depend on
`Kioku.*.Domain.*`.

### IP-2 — `MemoryScope` mapping (shikigami's edge)

shikigami maps its declared agent name into kioku's scope at the edge, in `Shikigami.Memory.Scope`
(the mapping helper lives in the consumer, not in kioku): per-agent memory is
`ScopeEntity (Namespace "shikigami") (ScopeKind "agent") <agentName>`; cross-agent shared memory is
`ScopeGlobal (Namespace "shikigami")`. A kioku **Session** for a run carries the same per-agent
scope plus `subjectRef = <run/trigger id>`.

### IP-3 — database schema & migrations (composed)

`shikigami-migrations` composes `kiokuMigrations` into its set exactly as kizashi composes
`kirokuMigrations <> keiroFrameworkMigrations <> ownMigrations`. kioku's read-model tables
(`kioku_memories`, `kioku_sessions`, `kioku_turns`) live in the `kiroku` schema. shikigami adds
**no** bespoke `agent_runs` table — kioku's `kioku_sessions` replaces it (the marker migration is a
no-op). EP-2 later adds a pgvector column to `kioku_memories` and EP-3 adds scene/persona tables;
those flow in through `kiokuMigrations` automatically when EP-2/EP-3 land and the kioku pin is
advanced.

### IP-4 — embedding & LLM provider config (not used here)

EP-6 records a *fixed* learning (no LLM call) and uses EP-1's scoped recall (no embeddings), so it
needs no `OPENAI_API_KEY`/`baikai` config. If EP-2 is Complete and you want hybrid recall to score
semantically in the demo, configure EP-2's embedding env vars and run EP-2's embedding worker;
otherwise recall degrades to FTS/scoped, which is sufficient for the across-run proof.

### IP-5 — `cabal.project` pin-set

shikigami adds a `kioku` dependency to its own `cabal.project` (local-path pins during
co-development, or a single `source-repository-package` git stanza with subdirs `kioku-api
kioku-core kioku-cli kioku-migrations` once kioku is tagged). The rest of the pin block is copied
byte-identically from kioku's `cabal.project` so the solver picks one coherent kikan set.
shikigami is greenfield (not mid-keiro-migration), so there is no tag reconciliation to do.

### IP-6 — Rei codec backward-compatibility (not applicable to shikigami)

IP-6 is the EP-1↔EP-4 seam for replaying Rei's historical streams. shikigami is greenfield with no
historical event streams, so it neither relies on nor exercises the lenient Rei decode. (Noted for
completeness so a reader does not look for a backward-compat step that does not belong here.)


## Revision Note

2026-06-24 — Initial authoring. Filled all prose sections of the EP-6 skeleton against the binding
contracts: MasterPlan #1 (IP-1…IP-6), the ExecPlan spec (`PLANS.md`), EP-1
(`docs/plans/1-...md`, the hard dependency — API shapes, scope model, migration composition,
demo command shape), and the shikigami design spec
(`/Users/shinzui/Keikaku/bokuno/shikigami/docs/initial-spec.md`) plus its Dhall seeds. Chose the
pragmatic v1 (option b): scaffold the four-package shikigami project far enough to build + apply
kioku's migrations, then prove the memory/session integration with a `shikigami-cli agent-demo`
command that simulates one agent run (open kioku session → recall → record learning → complete),
and demonstrate persistence across two runs plus the `activity.v1`→kioku-L0 mapping. Recorded the
scope mapping (`ScopeEntity "shikigami" "agent" <name>` per-agent; `ScopeGlobal "shikigami"`
shared), the replacement of the spec's bespoke `agent_runs` table by kioku's Session aggregate, and
the explicit out-of-scope boundary (triggers, sinks, shomei, behavior runner, Kafka consumer). Why:
the prompt directed (b) as the pragmatic v1 and shikigami is greenfield with zero Haskell, so the
deliverable is the memory/session seam + an observable demo, not the full runtime.


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
- **Plan-specific:** the greenfield shikigami scaffold adopts these standards from the first
  commit (it mirrors the kizashi/kioku structure). `cli/agents/claude-cli-pitfalls.md` applies
  if/when shikigami's behavior runner spawns `claude`.
