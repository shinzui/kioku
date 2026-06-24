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
| 2 | kioku Hybrid Retrieval (pgvector + FTS + RRF) | docs/plans/2-kioku-hybrid-retrieval-pgvector-fts-rrf.md | EP-1 | None | Complete |
| 3 | kioku Distillation Pyramid (L0 to L3) | docs/plans/3-kioku-distillation-pyramid-l0-to-l3.md | EP-1 | EP-2 | In Progress |
| 4 | Rei Migration to kioku | docs/plans/4-rei-migration-to-kioku.md | EP-1 | EP-2, EP-3 | In Progress |
| 5 | mori agent exec with kioku Memory | docs/plans/5-mori-agent-exec-with-kioku-memory.md | EP-1 | EP-2 | In Progress |
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
- [x] EP-2: optional `pgvector` migration + capability probe exist; Baikai embedding config/retry,
      `kioku worker --backfill`, and the continuous Shibuya/Kiroku embedding worker exist; vector
      backfill acceptance passed against a disposable `pgvector/pgvector:pg17` DB and deterministic
      OpenAI-compatible embedding stub; worker idempotency is covered by `Kioku.EmbeddingWorkerSpec`
- [x] EP-2: hybrid RRF recall API and `kioku recall` CLI exist; local no-pgvector fail-open path
      returns FTS-ranked results; pgvector/vector-path acceptance returned a keyword-disjoint memory
      via `vec=1` while keyword recall returned no matches; pure RRF/signal/budget and fail-open
      execution planning unit coverage passes
- [ ] EP-3: shikumi/baikai Claude runtime wiring compiles; distillation tables and
      `MemoryMerged`/`Kioku.Memory.merge` exist; L1 atom extraction + LLM consolidation shikumi
      programs compile; L1 orchestration composes extraction, consolidation, memory writes, and audit
      rows; manual `kioku distill session` CLI exists; timer arming and one-pass dispatch exist;
      continuous timer host exists; local sample acceptance is blocked on `ANTHROPIC_API_KEY`
- [ ] EP-3: L2 scene program plus regeneration/timer-arming core exist, L2 timers are routed by
      the worker, and scenes CLI/filesystem mirror exist; live L2 acceptance and L3 persona
      acceptance remain; L3 persona program, reactor, timer route, CLI, and filesystem mirror exist;
      deterministic replay coverage now proves L1 merge, L2 scene, and L3 persona rows without network
      access
- [ ] EP-4: Rei AgentMemory/AgentSession re-homed onto kioku with `IntentionId`/`HabitId` scope mapping
      has started: Rei now consumes local kioku packages, composes kioku's own migrations into the
      migration runner, has a tested `Rei.Modules.Agent.Memory.KiokuAdapter` for scope/focus/row
      mapping, delegates AgentMemory/AgentSession writes to `Kioku.Memory`/`Kioku.Session`, and
      rewires `ContextBuilder` and `rei agent memory list/show/archive` memory reads onto scoped
      `Kioku.Recall` adapter functions. The `{{agent_memories}}` byte-stability proof is covered;
      the additive `rei-kioku-migrate` executable for historical stream copy now builds; its
      verifier checks Rei-scoped read-model counts plus missing/extra/mismatched memory/session
      rows plus active recall-equivalent memory sets by scope; a disposable fixture rehearsal now
      proves copy, verify, and idempotent re-copy over legacy Rei streams; live `ContextBuilder`
      integration coverage now proves coaching context recall reads Kioku-backed intention and
      workspace memories; the Rei workspace filesystem mirror now decodes native Kioku memory events
      from `kioku_memory`, the old AgentMemory filesystem reactor is removed, and the workspace
      memory renderer no longer imports legacy AgentMemory event/domain modules; Rei's stable
      `AgentMemoryRow` shape now lives in `Rei.Modules.Agent.Memory.Types` so live prompt/agent CLI
      paths no longer import the old SQL table module directly; `rei today` now derives its memory
      summary through the Kioku adapter via `StoreRunner` instead of the old Hasql AgentMemory read
      model; `AgentSessionRow` now lives in `Rei.Modules.Agent.Session.Types` so live session CLI
      and Today session activity formatting no longer import the old AgentSession table module for
      the row shape; Kioku's public session read API now covers recent/scope/focus/range/chain
      reads and live `rei agent sessions`, `rei agent session show`, and Today session activity use
      those reads through `StoreRunner`; Rei no longer exposes or builds the unused legacy Hasql
      helper modules `Rei.Modules.AgentMemory.Infrastructure.ReadModel` and
      `Rei.Modules.AgentSession.Infrastructure.ReadModel`; the migration rehearsal now seeds
      explicit legacy Kiroku payloads plus old read-model rows directly, so the legacy
      table/projection/transducer/event modules and their specs/diagram entries are removed from
      `rei-core.cabal` and the tree. Runtime-facing IDs, enums, command data, and Kioku-backed
      store handlers now live under `Rei.Modules.Agent.Memory.*` and
      `Rei.Modules.Agent.Session.*`; the old command/type and application compatibility re-exports
      are deleted; the unused top-level AgentMemory/AgentSession facades are deleted; and the memory
      handler error type moved to `Rei.Modules.Agent.Memory.Errors`. The M3 fixture still proves
      copy, verify, and idempotent re-copy without any remaining `Rei.Modules.AgentMemory` /
      `Rei.Modules.AgentSession` modules. Disposable production data-copy execution remains.
- [ ] EP-4: Rei historical memory/session streams migrated; coaching context recall unchanged or improved
- [x] EP-5: M0 pin/schema slice completed. mori links local kioku packages, resolves current
      `kioku-core`'s `shikumi`/Baikai transitive package needs under mori's pin-set, and applies
      kioku read-model migrations in its ephemeral test DB. Verification: mori
      `cabal build mori-core`; `cabal test mori-core-test --test-options='-p TestSupport.Database'`.
- [x] EP-5: `mori agent exec --group` runs a prompt/skill across a repo group sequentially.
      Verification: mori `cabal build mori-cli`; focused `mori-cli-test` patterns
      `validateAgentExecIntent` and `buildAgentExecPrompt`; full `cabal test mori-cli-test`; real
      registry dry-run/debug smokes against `frontend`/`intentui/intentui`; and a non-debug
      fake-`claude` smoke proving repo `cwd`.
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

- **EP-5 M0 needs the current distillation transitive stack.** The current `kioku-core` package
  imports EP-3-era dependencies (`shikumi`, `shikumi-trace`, `shikumi-cache`, `baikai-claude`,
  `baikai-effectful`, `baikai-openai`) even for mori's base M0 link/schema slice. mori's existing
  Baikai pin `d0ac866907239189d8f30efc42ddb6cd14ba0e4d` is a descendant of kioku's standalone
  Baikai pin `a219b92278d8e475b0e45c602e65dbf108cf8dc1`, so EP-5 kept mori's consumer pin and
  expanded its Baikai `subdir` list. Discovered during EP-5 M0 implementation.

- **EP-4 migration composition uses kioku-owned migrations only.** Rei already applies Kiroku and
  Keiro framework migrations via `Keiro.Migrations.allKeiroMigrations`; kioku's exported
  `kiokuMigrations` includes those framework migrations again. Rei therefore composes
  `Kioku.Migrations.kiokuOwnMigrations` into its codd pass, between framework migrations and
  Rei-owned app migrations. Discovered during EP-4 implementation.

- **Rei focus storage text has no `focus_` prefix.** The live mapping is the private
  `focusTypeToText` table in `Rei.Modules.AgentSession.Projection.InlineReadModel`, where
  `FocusGeneralCoaching` stores as `general_coaching`, not `focus_general_coaching`. EP-4's adapter
  follows that live contract and tests all 15 constructors. Discovered during EP-4 implementation.

- **EP-4 preserves Rei IDs at the API edge and re-prefixes inside the adapter.**
  `Kioku.Id.parseIdAnyPrefix` lets Rei keep accepting `agent_memory_*` / `agent_session_*` typed
  IDs while Kioku writes `kioku_memory_*` / `kioku_session_*` streams with the same TypeID UUID
  body. This is now covered by Rei's Kioku adapter tests and matches the planned historical stream
  copy rule. Discovered during EP-4 implementation.

- **EP-4 historical migration is logical-event copy, not raw event-row copy.**
  `Keiro.Codec.decodeRecorded` checks the stored event-type tag before payload decoding, so legacy
  Rei tags such as `AgentMemoryRecorded` cannot reach Kioku's compatibility parser through the
  normal recorded-event decoder. Kiroku event IDs are also globally unique, so a copied native Kioku
  event cannot reuse the old event UUID while changing payload/type. The `rei-kioku-migrate` tool
  therefore decodes legacy `events.data` with Kioku's compatibility parsers, re-encodes native Kioku
  events, preserves the TypeID UUID body plus metadata/causation/correlation, and lets Kiroku assign
  fresh event IDs. Discovered during EP-4 M3 implementation.

- **EP-4 migration verification must check row equivalence, not only counts.** The stronger
  `rei-kioku-migrate verify` now compares old Rei read-model rows to `namespace = 'rei'` Kioku rows
  after applying the documented scope/focus/subject mapping, and reports missing, extra, and
  mismatched memory/session rows. This catches semantic projection drift before the old modules are
  decommissioned. Discovered during EP-4 M3 implementation.

- **EP-4 fixture rehearsal found compatibility gaps that static checks missed.** Row-equivalence
  verification must re-prefix expected Rei row IDs to Kioku IDs before joining, and Kioku's legacy
  session parser must normalize old `CoachingFocusType` constructor names (`FocusToday`,
  `FocusIntentionAssist`, etc.) to Rei's stored focus strings (`today`, `intention_assist`, etc.).
  Both fixes are now covered by Kioku's `ReiCompatSpec` and Rei's `KiokuMigrateSpec`. Discovered
  during EP-4 M3 implementation.

- **EP-4 row extraction found and cleared a dashboard read-model consumer.** Moving
  `AgentMemoryRow` behind `Rei.Modules.Agent.Memory.Types` removed direct legacy table imports from
  prompt rendering and the agent memory CLI/FZF path, but initially exposed that `rei today` still
  got memory counts and the last recorded memory through the old Hasql `AgentMemoryReadModelEff`.
  The Today command now opens both the Hasql pool and `StoreRunner`, leaving unrelated dashboard
  queries on Hasql while deriving memory summary data from Kioku active rows. Discovered and fixed
  during EP-4 M3 decommission work.

- **EP-4 legacy read helper cleanup stops at the helper modules.** After live memory and session
  reads moved to the Kioku adapter, the old Hasql helper modules were only referenced from the
  aggregate facades and cabal exposure, so they could be deleted. The older table/projection and
  transducer modules remain because migration fixtures still seed and verify legacy Rei streams
  through them. Discovered during EP-4 M3 decommission work.

- **EP-4 runtime namespace extraction precedes deleting legacy replay modules.** Live memory/session
  command data and store handlers now live under `Rei.Modules.Agent.*`, while the old
  AgentMemory/AgentSession modules were temporarily reduced to compatibility re-exports. This kept
  old replay fixtures working while moving runtime code away from the legacy aggregate namespace;
  those command/type/application aliases were removed in a later M3 cleanup. Discovered during EP-4
  M3 decommission work.

- **EP-4 top-level AgentMemory/AgentSession facades became dead code.** Once live imports moved to
  `Rei.Modules.Agent.*`, the broad old facades had no callers and could be deleted, leaving only
  targeted compatibility modules for replay and migration fixtures. Discovered during EP-4 M3
  decommission work.

- **EP-4 command/type compatibility re-exports are no longer needed.** Legacy replay modules now
  import `Rei.Modules.Agent.Memory.{Command,Types}` and
  `Rei.Modules.Agent.Session.{Command,Types}` directly, so the old AgentMemory/AgentSession
  command/type and application alias modules could be deleted while keeping event/transducer/
  projection/table modules for historical stream replay. Discovered during EP-4 M3 decommission
  work.

- **EP-4 legacy replay modules were fixture scaffolding, not production migration dependencies.**
  The `rei-kioku-migrate` executable already copies stored legacy payloads and verifies old
  read-model rows directly. Rewriting the rehearsal to seed explicit legacy Kiroku payloads plus old
  `agent_memories` / `agent_sessions` rows preserved the copy/verify/idempotency proof and allowed
  the old AgentMemory/AgentSession event/transducer/projection/table modules, specs, and diagram
  sections to be deleted. Discovered during EP-4 M3 decommission work.


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

- Decision: In EP-4, delete unused legacy Hasql read-model helper modules once live reads are on
  Kioku, but keep legacy table/projection/transducer modules until migration fixtures no longer need
  them.
  Rationale: the helper modules were only public query wrappers after the adapter migration, while
  the remaining legacy modules still provide the old replay and SQL statement behavior needed to
  prove historical stream migration.
  Date: 2026-06-24

- Decision: In EP-4, move runtime-facing memory/session types, command data, and store handlers
  under `Rei.Modules.Agent.Memory.*` and `Rei.Modules.Agent.Session.*` before deleting legacy replay
  modules.
  Rationale: this decouples live CLI/adapter/AgentSchedule code from legacy aggregate namespaces
  while preserving the historical replay path until it can be retired.
  Date: 2026-06-24

- Decision: In EP-4, delete unused top-level AgentMemory/AgentSession facades and move the memory
  handler error type into the runtime namespace.
  Rationale: the top-level facades had no remaining callers and only widened the legacy public
  surface. Narrow legacy replay/projection modules remain only where migration fixtures still need
  historical stream behavior.
  Date: 2026-06-24

- Decision: In EP-4, remove old AgentMemory/AgentSession command/type and application
  compatibility re-exports after updating legacy replay modules to import runtime command/type
  modules directly.
  Rationale: historical replay still needs old event/transducer/projection/table behavior, but alias
  modules for command data, IDs/enums, errors, and store handlers only preserve dead public surface.
  Date: 2026-06-24

- Decision: In EP-4, replace legacy replay-module test dependencies with explicit legacy payload
  and read-model fixtures, then delete the old AgentMemory/AgentSession event/transducer/projection/
  table modules.
  Rationale: the production migration path depends on stored Kiroku payloads and old read-model
  rows, not the old aggregate implementation. Direct fixtures keep the rehearsal focused on the
  historical on-disk shapes while removing the last dead legacy module surface from Rei.
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

- Decision: In EP-5 M0, consume kioku through local `optional-packages` in mori, keep mori's
  existing Baikai revision while exposing the extra Baikai subpackages current `kioku-core` needs,
  include local `shikumi` packages, and add a narrow `allow-newer: claude:http-client-tls`.
  Rationale: mori is the consumer pin authority for this integration; one coherent build plan is
  preferable to introducing a second ecosystem pin-set.
  Date: 2026-06-24

- Decision: In EP-5 M1, keep `mori agent exec --group` sequential by default and warn rather than
  run parallel when `--jobs > 1` is supplied until memory/session semantics land.
  Rationale: the master-plan value proposition is accumulation across repos; M1 proves selection,
  prompt assembly, and `cwd` propagation without introducing a parallel behavior that M2/M3 must
  immediately reinterpret.
  Date: 2026-06-24


## Outcomes & Retrospective

- 2026-06-24: EP-5 M0 completed in mori. mori now builds against local kioku packages, resolves the
  current `kioku-core` transitive package set under mori's pin-set, and applies kioku read-model
  migrations in its ephemeral test DB after kiroku and keiro. Verification: mori
  `cabal build mori-core`; `cabal test mori-core-test --test-options='-p TestSupport.Database'`.

- 2026-06-24: EP-5 M1 completed in mori. `mori agent exec --group` now has prompt/skill parsing,
  dry-run, debug prompt rendering, path skips, fail-fast, and sequential non-debug `claude` launch
  with the child process rooted in each repo path. Verification: mori `cabal build mori-cli`;
  focused `mori-cli-test` patterns `validateAgentExecIntent` and `buildAgentExecPrompt`; full
  `cabal test mori-cli-test` (317 tests); real registry dry-run/debug smokes against
  `frontend`/`intentui/intentui`; and a non-debug fake-`claude` smoke that printed
  `/Users/shinzui/Keikaku/hub/ui-libraries/intentui-project` from the child.

- 2026-06-24: EP-4 M2 now has a focused byte-stability regression for the `{{agent_memories}}`
  prompt variable. Rei compares legacy `AgentMemoryRow` fixtures against equivalent
  `Kioku.MemoryRecord` fixtures converted through the adapter, covering fact/pattern/preference/
  constraint grouping, the empty placeholder, and unknown-type dropping. Verification:
  `cabal test rei-core-test --test-options='-p Kioku'` in Rei.

- 2026-06-24: EP-4 M3 additive migration-tool slice builds in Rei. `rei-kioku-migrate` exposes
  `copy-memories`, `copy-sessions`, `copy-all`, and `verify`; copy commands decode legacy Rei
  payloads through Kioku parsers, re-encode native Kioku events, append missing destination-stream
  tails, and rebuild Kioku inline read models. Verification:
  `cabal build rei-core:rei-kioku-migrate` and
  `cabal run rei-core:rei-kioku-migrate -- --help` in Rei.

- 2026-06-24: EP-4 M3 verifier strengthened in Rei. `rei-kioku-migrate verify` now scopes Kioku
  counts to `namespace = 'rei'` and checks read-model row equivalence for memories and sessions,
  reporting missing, extra, and mismatched rows separately. Verification: Rei `nix fmt`;
  `cabal build rei-core:rei-kioku-migrate`;
  `cabal run rei-core:rei-kioku-migrate -- --help`; `git diff --check`.

- 2026-06-24: EP-4 M3 disposable fixture rehearsal landed. Rei's `KiokuMigrateSpec` seeds legacy
  memory/session streams through the old Rei transducers and projections, runs the migration copy,
  verifies read-model equivalence, checks migrated Kioku rows, and proves a second copy appends zero
  events. Kioku's legacy session parser now normalizes Rei focus constructors to storage strings.
  Verification: Kioku `cabal test kioku-core`; `cabal build all`; Rei
  `cabal test rei-core-test --test-options='-p rei-kioku-migrate'`;
  `cabal build rei-core:rei-kioku-migrate`;
  `cabal run rei-core:rei-kioku-migrate -- --help`.

- 2026-06-24: EP-4 M3 migration verifier now includes recall-equivalence checks. `verify` compares
  active Rei memories against active Kioku memories by namespace, scope, memory ID, and content, and
  checks the set of active recall scopes separately; the disposable rehearsal fixture now includes
  both intention-scoped and workspace-global active memories. Verification: Rei
  `cabal test rei-core-test --test-options='-p /rei-kioku-migrate/'`; Kioku `cabal test kioku-test`.

- 2026-06-24: EP-4 M3 live coaching-context recall proof added. Rei's `ContextBuilderSpec` now writes
  memories through the Kioku-backed `AgentMemoryStore.recordMemory`, runs `buildIntentionContext`
  through `runReiEffWithStore`, and proves the resulting `AgentContext.agentMemories` includes the
  target intention memory plus workspace-global memory while excluding an unrelated intention memory.
  Verification: Rei `cabal test rei-core-test --test-options='-p Kioku'`.

- 2026-06-24: EP-4 M3 filesystem-mirror decommission slice completed. Rei's worker now registers
  `Rei.Modules.Agent.Memory.FilesystemProjection` on the Kioku-owned `kioku_memory` category, and
  the old `Rei.Modules.AgentMemory.Reactor.FilesystemProjection` module/test are removed. The new
  coverage proves native Kioku memory events maintain Rei workspace markdown artifacts while
  preserving historical Rei-shaped IDs. Verification: Rei
  `cabal test rei-core-test --test-options='-p Kioku'`; `cabal build rei-cli`; `git diff --check`.

- 2026-06-24: EP-4 M3 workspace-memory compatibility wrappers removed. `Rei.Workspace.Config` and
  `Rei.Workspace.Memory` no longer expose unused AgentMemory-event path/rendering wrappers; the
  workspace memory renderer now consumes generic text/scope data from the Kioku adapter path.
  Verification: Rei `cabal build rei-cli`; `cabal test rei-core-test --test-options='-p Kioku'`;
  `git diff --check`.

- 2026-06-24: EP-4 M3 memory row extraction completed. Rei's stable `AgentMemoryRow` type now lives
  in `Rei.Modules.Agent.Memory.Types`; prompt context rendering, Kioku adapter code, the agent memory
  CLI, FZF selection, and the adapter tests import it from that Kioku-adapter-side module. The legacy
  SQL table module only re-exports the row while old projections and migration fixtures remain.
  Verification: Rei `cabal test rei-core-test --test-options='-p Kioku'`; `cabal build rei-cli`;
  `git diff --check`.

- 2026-06-24: EP-4 M3 Today dashboard memory summary moved to Kioku. `rei today` is now a
  pool-and-store command; its dashboard builder receives `MemorySummaryInfo` from the Kioku adapter
  via `StoreRunner`, while the rest of the dashboard stays on Hasql read models. Verification:
  Rei `cabal test rei-core-test --test-options='-p Kioku'`; `cabal build rei-cli`;
  `git diff --check`.

- 2026-06-24: EP-4 M3 session row extraction completed. Rei's stable `AgentSessionRow` type now
  lives in `Rei.Modules.Agent.Session.Types`; the AgentSession facade re-exports it from there, and
  live agent-session CLI output plus Today session activity formatting import it directly from the
  adapter-side module. The legacy SQL table module only re-exports the row while old projections and
  migration fixtures remain. Verification: Rei
  `cabal test rei-core-test --test-options='-p Kioku'`; `cabal build rei-cli`; `git diff --check`.

- 2026-06-24: EP-4 M3 live agent-session reads moved to Kioku. `Kioku.Session` now exposes public
  read helpers for recent sessions by namespace, sessions by scope, sessions by focus, started-at
  range, and previous-session chain. Rei's adapter converts those rows back to Rei-shaped
  `AgentSessionRow` values, and `rei agent sessions`, `rei agent session show`, and Today session
  activity now run through `StoreRunner` instead of the old Hasql AgentSession read model.
  Verification: Kioku `cabal test kioku-core`; Rei
  `cabal test rei-core-test --test-options='-p Kioku'`; `cabal build rei-cli`; `git diff --check`.

- 2026-06-24: EP-4 M3 legacy read helper cleanup completed in Rei. The old
  `Rei.Modules.AgentMemory.Infrastructure.ReadModel` and
  `Rei.Modules.AgentSession.Infrastructure.ReadModel` modules are deleted from the tree and cabal
  exposure, and the aggregate facades no longer re-export their queries. Verification: Rei
  `cabal build rei-cli`; `cabal test rei-core-test --test-options='-p Kioku'`.

- 2026-06-24: EP-4 M3 runtime namespace extraction completed in Rei. Runtime-facing memory/session
  IDs, enums, command data, and Kioku-backed store handlers now live under
  `Rei.Modules.Agent.Memory.*` and `Rei.Modules.Agent.Session.*`; the old AgentMemory/AgentSession
  command/type/application modules were temporarily compatibility re-exports for migration replay
  and were removed in a later M3 cleanup. Verification: Rei `cabal build rei-cli`;
  `cabal build rei-core:rei-kioku-migrate`; `cabal test rei-core-test --test-options='-p Kioku'`.

- 2026-06-24: EP-4 M3 top-level legacy facade cleanup completed in Rei. `Rei.Modules.AgentMemory`
  and `Rei.Modules.AgentSession` are deleted from the tree and cabal exposure, and the memory
  handler error type now lives in `Rei.Modules.Agent.Memory.Errors`. Verification: Rei
  `cabal build rei-cli`; `cabal build rei-core:rei-kioku-migrate`;
  `cabal test rei-core-test --test-options='-p Kioku'`.

- 2026-06-24: EP-4 M3 compatibility re-export pruning completed in Rei. The old
  `Rei.Modules.AgentMemory.Domain.{Command,Types}`,
  `Rei.Modules.AgentSession.Domain.{Command,Types}`,
  `Rei.Modules.AgentMemory.Application.{Errors,StoreHandler}`, and
  `Rei.Modules.AgentSession.Application.StoreHandler` modules are deleted from the tree and cabal
  exposure. Legacy event/transducer/projection/table modules remain for historical replay and now
  import runtime command/type modules directly. Verification: Rei `nix fmt`;
  `cabal build rei-cli`; `cabal build rei-core:rei-kioku-migrate`;
  `cabal test rei-core-test --test-options='-p Kioku'`;
  `cabal test rei-core-test --test-options='-p rei-kioku-migrate'`; `git diff --check`.

- 2026-06-24: EP-4 M3 legacy replay modules deleted in Rei. The old AgentMemory/AgentSession
  event/transducer/table/projection modules, their specs, and their transducer diagram sections are
  no longer in the build or tree. The migration rehearsal now seeds explicit legacy Kiroku payloads
  plus old read-model rows directly and still proves copy, verify, and idempotent re-copy.
  Verification: Rei `nix fmt`; `cabal build rei-cli rei-core:rei-kioku-migrate`;
  `cabal test rei-core-test --test-options='-p rei-kioku-migrate'`;
  `cabal test rei-core-test --test-options='-p Kioku'`;
  `cabal test rei-core-test --test-option=-p --test-option='Transducer diagrams'`;
  stale-reference `rg` sweep; `git diff --check`.

- 2026-06-24: EP-2 fail-open recall coverage tightened. `Kioku.Recall` now exposes a pure
  `RecallExecutionPlan`/`planRecallExecution` seam, and `Kioku.RecallSpec` proves that unavailable
  pgvector extension/columns downgrade recall to keyword-only without needing a query embedding.
  Verification: `cabal test kioku-core` and `cabal build all`.

- 2026-06-24: EP-2 completed. A disposable `pgvector/pgvector:pg17` database plus deterministic
  OpenAI-compatible embedding stub proved vector-column migration, `kioku worker --backfill`,
  idempotent re-backfill, hybrid recall of a keyword-disjoint memory (`fts=- vec=1`), keyword
  non-match for the same query, and embedding-outage fail-open (`fts=1 vec=-`). Verification:
  `cabal test kioku-core`, `cabal build all`, `cabal run kioku-migrate`,
  `cabal run kioku -- demo`, `cabal run kioku -- worker --backfill`, and
  `cabal run kioku -- recall ... --show-scores`.
