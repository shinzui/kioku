---
id: 1
slug: kioku-reusable-agent-memory-session-library
title: "kioku (記憶): Reusable Agent Memory & Session Library"
kind: master-plan
created_at: 2026-06-24T16:31:00Z
intention: "intention_01kvx5py1yeanvyn7xh58epfnt"
---

# kioku (記憶): Reusable Agent Memory & Session Library

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

**kioku** (記憶, "memory") is a new standalone Haskell library in the kikan ecosystem that
provides reusable, event-sourced **agent memory** and **agent session** primitives, plus an
elevated **hybrid retrieval** layer and an **L0→L3 distillation pyramid**. It is extracted
from Rei's existing (functional but "naive") AgentMemory/AgentSession modules and generalized
so that three different agent platforms can share one memory engine: **Rei** (personal
coaching), **mori** (multi-repo agent execution), and **shikigami** (autonomous system-agent
platform).

After this initiative is complete:

- A new repository `kioku` exists at `/Users/shinzui/Keikaku/bokuno/kioku`, structured as the
  conventional kikan 4-package project (`kioku-api`, `kioku-core`, `kioku-cli`,
  `kioku-migrations`), pinning the same keiro/keiki/kiroku/shibuya stack as `kizashi`.
- kioku models an agent **memory** as an event-sourced aggregate (kiroku stream =
  source-of-truth) whose queryable forms are projections: a structured row (inline), a
  full-text `tsvector` (inline), and a `pgvector` embedding (async). Memory is scoped by a
  generic, host-agnostic `MemoryScope` (namespace + entity reference) rather than Rei's
  hard-coded `IntentionId`/`HabitId` anchors.
- kioku models an agent **session** as an event-sourced aggregate, optionally capturing
  raw conversation **turns** (the L0 "evidence floor") when a host opts in.
- **Recall** is hybrid: Postgres full-text search fused with `pgvector` cosine similarity via
  Reciprocal Rank Fusion (RRF), with recency/priority/confidence signals — a large step up
  from Rei's `WHERE status='active'` filters.
- A **distillation pyramid** turns raw memory/turns (L0) into atoms (L1), scenes (L2), and a
  per-scope persona (L3), driven by `shikumi`/`baikai` LLM programs, with LLM-driven
  consolidation (`store | update | merge | skip`) recorded as events.
- Rei is migrated onto kioku (its `IntentionId`/`HabitId` anchors mapped into `MemoryScope`),
  mori gains a new `mori agent exec --group` command that runs a prompt/skill across a group
  of repos while accumulating cross-run learnings in kioku, and shikigami adopts kioku as its
  memory subsystem.

**In scope:** the kioku library; hybrid retrieval; the distillation pyramid; and the three
consumer integrations. **Out of scope:** Rei's `AgentSchedule` module (too Rei-coupled —
DelegationScope/AutonomyLevel/Rei event triggers — stays in Rei); a Voyage AI embedding client
(deferred; v1 uses baikai's OpenAI-compatible client); the TencentDB short-term "symbolic
offload" working-memory subsystem (a separate concern, not memory persistence).


## Decomposition Strategy

The initiative decomposes into six child ExecPlans grouped into three phases by functional
concern, following the MasterPlan decomposition principles (functional concerns, dependency
minimization, independent verifiability).

**Phase 1 — Foundation.** EP-1 stands up the kioku project and extracts the *core* event-sourced
memory + session aggregates with the generic scoping model and the inline projections (row +
FTS). This is the hard dependency of everything else; it must exist and build before any other
plan can compile.

**Phase 2 — Elevation.** EP-2 (hybrid retrieval: pgvector + FTS + RRF) and EP-3 (the L0→L3
distillation pyramid) each elevate the foundation along an independent axis — retrieval vs.
consolidation. They can largely proceed in parallel; EP-3 *benefits from* EP-2's recall for its
dedup/merge step but does not require it to compile.

**Phase 3 — Consumers.** EP-4 (Rei migration), EP-5 (mori `agent exec`), and EP-6 (shikigami
integration) are three independent consumer integrations, each a hard dependent of EP-1 and a
soft dependent of EP-2/EP-3 (they get richer the more of the elevation is done, but core
integration only needs EP-1). They can proceed in parallel once EP-1 lands.

**Alternatives considered.** (a) *Faithful lift first, elevate later* — rejected per the user's
explicit choice to build full hybrid retrieval and the layered pyramid up front. (b) *Type-
parameterize the aggregate over the anchor type* (`AgentMemory anchor`) — rejected because
event-sourced codecs and keiki transducers become significantly harder to keep byte-stable when
the event payload is polymorphic; instead the scope is a concrete `MemoryScope` value
(namespace + tag + id as text) that each consumer maps its typed IDs into (see Integration
Points IP-2). (c) *One mega-plan* — rejected; the scope spans four repositories and far exceeds
five milestones / ten files.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | kioku Scaffold and Core Extraction | docs/plans/1-kioku-scaffold-and-core-extraction.md | None | None | Complete |
| 2 | kioku Hybrid Retrieval (pgvector + FTS + RRF) | docs/plans/2-kioku-hybrid-retrieval-pgvector-fts-rrf.md | EP-1 | None | In Progress |
| 3 | kioku Distillation Pyramid (L0 to L3) | docs/plans/3-kioku-distillation-pyramid-l0-to-l3.md | EP-1 | EP-2 | Not Started |
| 4 | Rei Migration to kioku | docs/plans/4-rei-migration-to-kioku.md | EP-1 | EP-2, EP-3 | Not Started |
| 5 | mori agent exec with kioku Memory | docs/plans/5-mori-agent-exec-with-kioku-memory.md | EP-1 | EP-2 | Not Started |
| 6 | shikigami Memory Integration with kioku | docs/plans/6-shikigami-memory-integration-with-kioku.md | EP-1 | EP-2, EP-3 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.


## Dependency Graph

EP-1 is the root. It produces the kioku project, the `MemoryScope`/`Namespace`/`MemoryType`/
`Confidence`/`MemoryRecord` types in `kioku-api`, the memory + session keiki aggregates and
codecs, the inline projections (structured row + `tsvector` FTS), the write API
(`Kioku.Memory`, `Kioku.Session`), the migrations package, and the coherent `cabal.project`
pin-set. Nothing else can compile without these artifacts, so every other plan hard-depends on
EP-1.

EP-2 hard-depends on EP-1 because it adds the `pgvector` column and the embedding async
projection onto EP-1's memory read-model table and extends EP-1's recall surface
(`Kioku.Recall`). EP-3 hard-depends on EP-1 (it consumes the L0 streams and appends
consolidation/scene/persona events) and soft-depends on EP-2 (its LLM dedup step calls recall
to find merge candidates; if EP-2 is not yet done it can fall back to a recency/scope SQL scan).
EP-2 and EP-3 can run concurrently.

EP-4, EP-5, EP-6 each hard-depend on EP-1 (they import kioku's write/read API and compose
kioku's migrations) and soft-depend on EP-2/EP-3 (richer recall and distillation make the
consumer better but are not required for the core integration to compile and demonstrate
value). The three consumer plans are mutually independent and can run in parallel once EP-1 is
Complete.


## Integration Points

**IP-1 — kioku public API surface.** The modules `Kioku.Memory` (write: record/supersede/
merge/archive/retag/reconfidence), `Kioku.Session` (write: start/complete/failSession/recordTurn/
recordInteractive), and `Kioku.Recall` (read: hybrid recall + simple scoped queries), plus the
re-exported core types. EP-1 defines `Kioku.Memory`/`Kioku.Session` and a *placeholder*
`Kioku.Recall` (scoped SQL queries only). EP-2 fills in hybrid `Kioku.Recall`. EP-4/5/6 consume
all three. **Rule:** consumers depend only on these top-level modules plus `kioku-api` types —
never on `Kioku.*.Domain.*` internals.

**IP-2 — `MemoryScope` mapping.** The core scoping type, defined in `kioku-api`
(`Kioku.Api.Scope`), is:

```haskell
newtype Namespace = Namespace Text          -- e.g. "rei", "mori", "shikigami"

data MemoryScope
  = ScopeGlobal Namespace                    -- workspace-wide within a namespace
  | ScopeEntity Namespace ScopeKind Text     -- kind tag + entity id as text
  deriving stock (Eq, Show, Generic)

newtype ScopeKind = ScopeKind Text           -- "intention" | "habit" | "repo" | "group" | "agent" | ...
```

EP-1 owns this type. Each consumer maps its typed identifiers into it: Rei (EP-4) maps
`AnchorToIntention iid → ScopeEntity "rei" "intention" (KindID.toText iid)`,
`AnchorToHabit hid → ScopeEntity "rei" "habit" …`, `WorkspaceGlobal → ScopeGlobal "rei"`; mori
(EP-5) uses `ScopeEntity "mori" "repo" <projectId>` and `ScopeEntity "mori" "group" <groupId>`;
shikigami (EP-6) uses `ScopeEntity "shikigami" "agent" <agentName>`. Consumers must round-trip
their IDs through `MemoryScope` consistently; the mapping helper lives in each consumer, not in
kioku.

**IP-3 — database schema & migrations.** `kioku-migrations` (codd + `embedDir`, the kizashi
pattern) owns: the `pgvector` extension (`CREATE EXTENSION IF NOT EXISTS vector`), the
`kioku_memories` table (with a `tsvector` generated column and a `vector` embedding column), the
`kioku_sessions` (+ optional `kioku_turns`) table, and the `kioku_scenes`/`kioku_personas`
tables. EP-1 creates the base `kioku_memories`/`kioku_sessions` tables and the FTS column; EP-2
adds the `vector` column + ANN index; EP-3 adds the scene/persona tables. Read-model tables live
in the **`kiroku` schema** (kizashi convention; `extraSearchPath=[]`). Consumers (EP-4/5/6)
compose `kiokuMigrations` into their own migration set exactly as kizashi composes
`kirokuMigrations <> keiroFrameworkMigrations <> ownMigrations`. **Note:** `CREATE EXTENSION
vector` requires the extension to be available in the Postgres install and superuser-or-owner
privileges at migration time — call this out in EP-1/EP-2 and the consumer plans.

**IP-4 — embedding & LLM provider config.** EP-2 depends on `baikai`'s `Baikai.Embedding`
(`embed`/`embedOne`, OpenAI-compatible `/v1/embeddings`, `OPENAI_API_KEY`) for vectors; EP-3
depends on `shikumi` programs over `baikai-claude` (+ `baikai-effectful`, `runLLMResilient` for
retry/budget) for distillation. The embedding model id + dimensions are config carried on each
vector row (`embedding_model`, `dimensions`, `content_hash`) so re-embedding is a projection
rebuild. Consumers configure the relevant env vars; the provider wiring is internal to kioku. The
embedding **provider is pluggable via configuration**: kioku resolves an `EmbeddingConfig` from
`KIOKU_EMBEDDING_BASE_URL`/`_MODEL`/`_DIMENSIONS`/`_API_KEY` (defaulting to OpenAI), so a local
OpenAI-compatible embedder (Ollama, text-embeddings-inference, vLLM, llama.cpp server) is a
config-only swap with no code or baikai change — except that a model with a different vector
dimension than the column's `vector(1536)` also needs a one-line dimension migration plus a
re-embed (the rebuildable-projection design makes this a clean incremental backfill). EP-3's LLM
distillation provider is likewise reached through baikai/shikumi, not hand-rolled.

**IP-5 — `cabal.project` pin-set.** EP-1 establishes the coherent kikan source-repository-package
set by copying kizashi's verbatim (keiki `bc987f46`, keiro `f1d67a01`, kiroku `322096c8`,
shibuya `3f276ee1`, pgmq-hs, forks) and adds `baikai`/`shikumi` pins for EP-2/EP-3. Consumers
(EP-4/5/6) add a `kioku` source-repository-package pin to their own `cabal.project`. When any
consumer is mid-keiro-migration (mori is), the kioku pin must be compatible with that repo's
existing keiro/kiroku tags — flag and reconcile in EP-5.

**IP-6 — Rei codec backward-compatibility.** Rei's existing `agent_memory`/`agent_session`
events are serialized with `eventAesonOptions` (`{"type": …, "data": …}`). kioku's event codec
must be designed so EP-4 can migrate Rei's historical streams. Per IP-7 below, kioku adopts the
**`eventAesonOptions` codec shape** (not a hand-written one), which is byte-identical to what Rei
already wrote — so reading Rei's existing JSON is essentially free; EP-1 keeps a lenient
`parseJSON` for any snake_case/anchor-field differences. The exact JSON field map is an
EP-1 ↔ EP-4 integration concern documented in both plans.

**IP-7 — Coding conventions (haskell-jitsurei).** All Haskell across kioku and the consumer
integrations follows the binding conventions in `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/`
(the `shinzui/haskell-jitsurei` cookbook; `mori registry docs haskell-jitsurei`). Owned by no
single plan — every plan that writes Haskell honors it. The load-bearing rules: GHC2024 + the
`common` stanza (`DeriveAnyClass`/`DuplicateRecordFields`/`OverloadedLabels`/`OverloadedStrings`,
plus `MultilineStrings` for embedded SQL) and postpositive `qualified` imports
(`core/standards.md`); a `Kioku.Prelude` that **does NOT re-export `Data.Generics.Labels`**
because that orphan `IsLabel` instance collides with the **keiki DSL**'s `#label` overloading that
kioku's transducers use — modules needing generic-lens `#label` import it per-module
(`core/custom-prelude.md`, `core/record-patterns.md`); no field prefixes, strict `!` fields,
entity-ID-first events/commands, explicit deriving strategies, and lens operators over
record-update syntax (`core/record-patterns.md`); `eventAesonOptions` as the event JSON shape
(which satisfies IP-6 for free). For CLI work, `cli/*` applies — option groups, hierarchical
config, and especially `cli/agents/claude-cli-pitfalls.md` (terminate `claude -p` argv with
`["--", prompt]` or use stdin; `--add-dir` is variadic and otherwise eats the prompt), which
binds EP-5's `mori agent exec` and any agent-spawning code.


## Progress

Track milestone-level progress across all child plans.

- [x] EP-1: kioku 4-package project scaffolds and builds (`cabal build all`) with the kikan pin-set
- [x] EP-1: memory + session keiki aggregates, native codecs, and generic `MemoryScope` model exist
- [x] EP-1: inline projections (structured row + `tsvector` FTS) and `kioku-migrations` apply to a fresh DB
- [x] EP-1: `Kioku.Memory`/`Kioku.Session` write API + placeholder scoped `Kioku.Recall` demonstrated via `kioku-cli`
- [x] EP-1: Rei legacy memory/session JSON decode is covered by a golden compatibility test
- [ ] EP-2: optional `pgvector` migration + capability probe exist; Baikai embedding config/retry
      and `kioku worker --backfill` one-shot backfill exist; continuous embedding projection still
      needs the long-running worker host
- [ ] EP-2: hybrid RRF recall (FTS + cosine + recency/priority) returns ranked results via CLI
- [ ] EP-3: L1 atom extraction + LLM consolidation (`store|update|merge|skip`) recorded as events
- [ ] EP-3: L2 scene + L3 persona projections generated by shikumi/baikai programs
- [ ] EP-4: Rei AgentMemory/AgentSession re-homed onto kioku with `IntentionId`/`HabitId` scope mapping
- [ ] EP-4: Rei historical memory/session streams migrated; coaching context recall unchanged or improved
- [ ] EP-5: `mori agent exec --group` runs a prompt/skill across a repo group sequentially
- [ ] EP-5: cross-run learnings recorded/recalled in kioku improve subsequent runs
- [ ] EP-6: shikigami adopts kioku for agent_runs (sessions) + per-agent memory


## Surprises & Discoveries

- **kiroku pin skew across the ecosystem (affects IP-5).** kizashi (the scaffold template EP-1
  copies) pins kiroku `322096c8`, but both Rei and mori pin kiroku `4312aa8c` (+2 commits: a
  `kiroku-metrics` release + docs, not touching `kiroku-store`). keiki `bc987f46`, keiro
  `f1d67a01`, shibuya `3f276ee1` match everywhere. Resolution adopted by EP-4 and EP-5: do NOT
  introduce a second kiroku pin in the consumer; instead consume kioku as a local
  `optional-packages`/source path so it resolves against the consumer's single coherent pin-set
  (or bump kioku's kiroku to `4312aa8c`). EP-1 should pin the newer kiroku `4312aa8c` to match
  the actual consumers rather than kizashi's older tag. Discovered while drafting EP-4/EP-5.

- **Rei's keiro cutover tooling was deleted (affects EP-4).** Rei's `rei-history-transform` /
  `CutoverConfig` / `REI_KIROKU_CONTEXTS` machinery was removed in commit `51a08f27` after the
  original keiro migration completed; Rei's store now opens unconditionally. So EP-4's historical
  data migration is a NEW one-shot `rei-kioku-migrate` executable modeled on the *historical*
  `transform-context` shape, not an extension of still-live code. (This corrects a stale
  assumption from project memory that the cutover infra is still present.) The chosen migration
  is a pure stream-rename: `agent_memory-<id>`/`agent_session-<id>` → `kioku_memory-<id>`/
  `kioku_session-<id>`, relying on EP-1's lenient codec to read Rei's legacy JSON, then a
  projection rebuild. Discovered while drafting EP-4.

- **EP-2 ↔ EP-3 worker-host ownership.** The async embedding worker (EP-2) and the distillation
  timers/reactors (EP-3) both need a kioku worker host (`kioku worker`). EP-2 introduces it; if
  EP-3 is implemented before EP-2, it must port the `runKirokuWorkerHost` slice from Rei's
  `WorkerHost.hs`. Whichever lands first owns the host; the other extends it. Recorded so the two
  Phase-2 plans don't each invent a separate host.

- **Schema coexistence in consumers is clean.** kioku read-model tables live in the `kiroku`
  schema; mori opens its store with `extraSearchPath=["public"]` (Rei similarly uses `public`),
  so kioku (`kiroku` schema) and the consumer's own read models (`public`) share one pool without
  name collisions. Consumers apply `kiokuMigrations` the same way they already apply
  kiroku/keiro framework migrations. No conflict — confirmed while drafting EP-4/EP-5/EP-6.


## Decision Log

- Decision: Name the library **kioku** (記憶) and stand it up as a new standalone kikan repo at
  `/Users/shinzui/Keikaku/bokuno/kioku`, 4-package layout mirroring `kizashi`.
  Rationale: peer-of-keiro/kiroku placement keeps it independently versioned and consumable by
  rei, mori, and shikigami without coupling releases to any one consumer.
  Date: 2026-06-24

- Decision: Build full hybrid retrieval (pgvector + FTS + RRF) and the L0→L3 distillation
  pyramid up front, not a faithful lift-and-elevate-later.
  Rationale: explicit user choice; the three consumers (esp. shikigami, greenfield) want the
  elevated feature set from day one.
  Date: 2026-06-24

- Decision: Scope memory with a concrete `MemoryScope` value (namespace + kind tag + id text),
  not a type parameter over the anchor.
  Rationale: keeps event payloads and hand-written codecs byte-stable and the keiki transducer
  monomorphic; consumers map typed IDs in/out at the edge (IP-2).
  Date: 2026-06-24

- Decision: Embeddings are an **async** projection; the structured memory row and the `tsvector`
  FTS column are **inline** projections.
  Rationale: generating an embedding is an external `baikai` HTTP call, which the ecosystem rule
  forbids inline (inline projections must be simple/never-fail); FTS is deterministic pure SQL.
  Keeping vectors as a derived projection makes re-embedding (new model/dimensions) a rebuild,
  with `embedding_model`/`dimensions`/`content_hash` carried per row for staleness detection.
  Date: 2026-06-24

- Decision: Raw conversation **turns** (the L0 evidence floor for true drill-down) are an
  **optional, per-session capability**. kioku supports a `TurnRecorded` event on the session
  stream when a host opts in; otherwise L0 = session envelope + explicitly-recorded memories.
  Rationale: full TencentDB-style provenance drill-down wants turns, but recording every turn
  bloats streams; making it opt-in lets shikigami/mori capture turns while Rei keeps its current
  lighter granularity. EP-3's pyramid consumes whatever L0 exists.
  Date: 2026-06-24

- Decision: v1 embeddings via baikai's OpenAI-compatible `Baikai.Embedding` (e.g.
  `text-embedding-3-small`, 1536 dims); a Voyage AI client is deferred. v1 distillation via
  `shikumi` programs over `baikai-claude` with the resilient interpreter.
  Rationale: these already exist in the ecosystem; pgvector and Postgres FTS do not and are
  greenfield here. Avoid hand-rolling LLM/HTTP; build only the pgvector/FTS/RRF plumbing.
  Date: 2026-06-24

- Decision: The embedding provider is **pluggable by configuration** (env-resolved
  `EmbeddingConfig`: base URL / model / dimensions / api key), defaulting to OpenAI but supporting
  a local OpenAI-compatible embedder with no API and no baikai change. No changes to baikai are
  required by this initiative; kioku owns all provider/resilience policy as a thin layer over
  `Baikai.Embedding`. A different-dimension model additionally needs a column migration + re-embed.
  Rationale: keeps the door open to fully local/offline embeddings without rework, and keeps baikai
  policy-free. (Detail in EP-2, `docs/plans/2-kioku-hybrid-retrieval-pgvector-fts-rrf.md`.)
  Date: 2026-06-24

- Decision: Defer Rei's `AgentSchedule` module from extraction (stays in Rei).
  Rationale: deeply Rei-coupled (DelegationScope, AutonomyLevel, Rei-specific event triggers);
  not part of the reusable memory/session core.
  Date: 2026-06-24

- Decision: Adopt the `haskell-jitsurei` conventions as binding for all kioku code (IP-7), and
  consequently use the **`eventAesonOptions` generic codec shape** for kioku's events rather than a
  kizashi-style hand-written codec.
  Rationale: jitsurei is the canonical kikan Haskell standard (prelude/record/multiline/CLI
  patterns), and its documented event-JSON shape equals Rei's existing on-disk shape — so adopting
  it both follows convention and makes IP-6 (Rei backward-compat) free. It also pins the
  keiki-vs-generic-lens `#label` hazard (don't re-export `Data.Generics.Labels` from the prelude)
  that kioku would otherwise hit because its transducers use the keiki DSL. The kizashi scaffold is
  still the structural template; only the codec strategy is overridden. (Reconciliation recorded in
  EP-1 and EP-4.)
  Date: 2026-06-24

- Decision: Decompose into 6 child ExecPlans across 3 phases (Foundation / Elevation /
  Consumers).
  Rationale: functional-concern boundaries with EP-1 as the single hard root; Phase-2 and
  Phase-3 plans parallelize.
  Date: 2026-06-24


## Outcomes & Retrospective

(To be filled during and after implementation.)
