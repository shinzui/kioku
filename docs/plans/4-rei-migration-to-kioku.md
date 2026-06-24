---
id: 4
slug: rei-migration-to-kioku
title: "Rei Migration to kioku"
kind: exec-plan
created_at: 2026-06-24T16:31:00Z
intention: "intention_01kvx5py1yeanvyn7xh58epfnt"
master_plan: "docs/masterplans/1-kioku-reusable-agent-memory-session-library.md"
---

# Rei Migration to kioku

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Rei is a personal time-management and coaching system. When you run a coaching command such as
`rei agent coach` or `rei agent today`, Rei builds a large text prompt for a language model. Part
of that prompt is a section labelled `### Agent Memories`, listing things the agent has previously
learned about you ("prefers concise answers", "tends to over-commit on Mondays"). Those memories,
and the records of each coaching session, are stored today inside Rei's own code, in two modules:
`Rei.Modules.AgentMemory` and `Rei.Modules.AgentSession`. Those modules are hard-wired to Rei's
own concepts — a memory can only be "about" a Rei intention, a Rei habit, or the whole workspace,
and a session can only have one of fifteen fixed Rei "coaching focus" modes.

A new standalone library called **kioku** (記憶, Japanese for "memory") has been extracted from
exactly this Rei machinery and generalized so three different agent platforms (Rei, mori,
shikigami) can share one memory engine. kioku replaces Rei's hard-coded anchors with a generic
**`MemoryScope`** (a namespace label plus an optional typed entity reference) and replaces the
fifteen-constructor focus enum with a free-form `focus :: Text`. kioku is built and proven by a
prior plan, **EP-1** (`docs/plans/1-kioku-scaffold-and-core-extraction.md`), which is a hard
dependency of this plan; richer recall (EP-2, `docs/plans/2-...`) and an LLM distillation
pyramid (EP-3, `docs/plans/3-...`) are soft dependencies that make recall better when present
but are not required to compile or demonstrate this plan.

**This plan (EP-4) migrates Rei onto kioku.** After it is complete:

- Rei depends on kioku as a git-pinned library, and Rei's AgentMemory/AgentSession domain modules
  are gone; in their place are thin Rei-side adapters that map Rei's `IntentionId`/`HabitId`/
  workspace anchors into `MemoryScope` and translate kioku read rows back into Rei's existing
  `MemorySummary` shape.
- Running a coaching command (`rei agent coach`) injects memories that were **recalled from
  kioku** into the rendered prompt's `### Agent Memories` section, and that rendered section is
  byte-for-byte identical to what Rei produced before the migration for the same set of memories.
- `rei agent memory list` / `show` / `archive` and the implicit memory-recording that happens
  after each coaching response all flow through kioku's `Kioku.Memory` write API and
  `Kioku.Recall` read API instead of Rei's own store handlers.
- Every historical memory and session that Rei recorded before the migration still appears: the
  old `agent_memory-<id>` and `agent_session-<id>` event streams have been decoded through kioku's
  legacy payload parsers, re-encoded as native kioku events, and appended into kioku's
  `kioku_memory-<id>` / `kioku_session-<id>` streams. The TypeID UUID body, metadata, causation, and
  correlation are preserved where the store API permits it, and kioku's projection rebuild has
  populated kioku's read-model tables from the copied streams.
- Rei's full test suite (`cabal test rei-core`, roughly 1060+ tests) stays green throughout.

The single user-visible proof is this: after the migration, `rei agent coach` (or any coaching
command) still prints the same `### Agent Memories` block it printed before, but every memory in
it now came out of kioku's `kioku_memories` table, and `rei agent memory list` returns the same
historical memories it always did. You can confirm the data path by querying the new table
directly (`SELECT count(*) FROM kiroku.kioku_memories;`) and seeing it match the old
`agent_memories` count.

**Out of scope (do not touch):** Rei's `AgentSchedule` module (`Rei.Modules.AgentSchedule`,
streams `agent_schedule-<id>`). It is deliberately Rei-coupled (delegation scopes, autonomy
levels, Rei-specific event triggers) and the MasterPlan explicitly keeps it in Rei. This plan
does not migrate, rename, or remove any AgentSchedule code.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0 (prerequisite gate): confirmed on 2026-06-24 that EP-1 is Complete enough for EP-4.
      kioku exists at `/Users/shinzui/Keikaku/bokuno/kioku`; `git rev-parse HEAD` returned
      `d969b2b438f801aabb26c2cb6cb39eea18347b95`; `cabal build all` reported `Up to date`;
      `cabal test kioku-core` passed all 7 tests, including the Rei compatibility group.
- [x] M1: Rei now consumes kioku from local source paths in `cabal.project`, reconciled with
      Rei's keiro/kiroku/keiki pins; `kioku-api`/`kioku-core` are in the `rei-core.cabal`
      library build-deps; `kioku-migrations` is in the `rei-migrations` executable build-deps.
      `cabal build rei-core` succeeds.
- [x] M1: kioku migrations are composed into Rei's migration runner by appending
      `Kioku.Migrations.kiokuOwnMigrations` after Rei's existing Kiroku/Keiro framework
      migrations and before Rei's application migrations.
- [ ] M1 remaining: run `just run-migrations` against a disposable Rei DB and verify it creates
      `kiroku.kioku_memories` / `kiroku.kioku_sessions` / `kiroku.kioku_turns`. A direct
      `rei-migrations` run against `rei_kioku_mig_check_20260624` did not reach the codd/kioku
      migration pass because frozen legacy hasql migrations fail first on missing historical
      `message_store`/`messages` schema objects.
- [x] M1: new adapter module `Rei.Modules.Agent.Memory.KiokuAdapter` maps `MemoryAnchor ↔ MemoryScope`,
      `CoachingFocusType → focus :: Text`, session intention scope, and `Kioku` read rows →
      Rei `AgentMemoryRow`; it also owns Rei→Kioku ID re-prefixing and command-data conversion.
- [x] M1: AgentMemory/AgentSession write paths are re-homed onto `Kioku.Memory`/`Kioku.Session`
      while preserving the existing Rei handler signatures. `cabal test rei-core-test
      --test-options '-p Kioku'` passes 10 focused tests, including integration checks that call
      Rei's public write handlers and read the resulting rows from `kioku_memories` /
      `kioku_sessions`. The old read-model path still serves reads until M2.
- [x] M2: `ContextBuilder.hs` recall (the three memory call sites) is rewired onto
      Kioku-backed adapter functions. Kioku now exposes `Kioku.Recall.getActiveInNamespace`, and
      Rei's adapter exposes the old `getActiveMemories`, `getActiveMemoriesForIntention`, and
      `getWorkspaceMemories` names while converting `Kioku.MemoryRecord` back to
      `AgentMemoryRow`.
- [x] M2: `rei agent memory list/show/archive`, FZF memory selection, and the
      `rei agent session show` memory list now read memories through the Kioku adapter and
      `StoreRunner`. `Kioku.Recall.getById` was added for by-id show/resolve; read rows are
      re-prefixed back to Rei `agent_memory_*` / `agent_session_*` IDs at the adapter boundary so
      existing CLI parsing and archive command data remain compatible.
- [x] M2: `{{agent_memories}}` rendered section is proven byte-identical on a fixture spanning
      fact/pattern/preference/constraint memories. The regression compares legacy
      `AgentMemoryRow` fixtures against equivalent `Kioku.MemoryRecord` fixtures converted through
      the adapter, and also covers the empty placeholder plus unknown-type dropping.
- [ ] M3: historical `agent_memory`/`agent_session` kiroku streams copied into kioku streams by a
      one-shot transform; additive `rei-kioku-migrate` executable now builds and exposes
      `copy-memories`, `copy-sessions`, `copy-all`, and `verify`. It decodes legacy Rei payloads
      through Kioku's compatibility parsers, re-encodes native Kioku events, appends only missing
      destination-stream tails, and reapplies Kioku inline projections. `verify` now checks
      migrated Rei-scoped read-model counts plus missing/extra/mismatched business rows for
      memories and sessions, plus active recall-equivalent memory sets by scope. A focused
      disposable-Postgres rehearsal now seeds legacy Rei memory/session streams through the old
      transducers, runs the copy, proves `verify` passes for intention and workspace-global active
      recall scopes, and proves a second copy appends zero events. Remaining: run against a
      disposable production data copy and add any production-derived stream-replay probes needed.
- [x] M3: live coaching-context recall path is covered by an integration test. Rei's
      `ContextBuilderSpec` now writes intention-scoped, workspace-global, and unrelated memories
      through the production Kioku-backed `AgentMemoryStore.recordMemory`, runs
      `buildIntentionContext` through `runReiEffWithStore`, and asserts the resulting
      `AgentContext.agentMemories` contains the target intention memory plus workspace memory and
      excludes the unrelated intention memory. Verification: Rei
      `cabal test rei-core-test --test-options='-p Kioku'`.
- [x] M3: Rei's workspace filesystem mirror no longer depends on the old
      `Rei.Modules.AgentMemory.Reactor.FilesystemProjection` module or the old `agent_memory`
      stream category. A new `Rei.Modules.Agent.Memory.FilesystemProjection` decodes native Kioku
      memory events from the `kioku_memory` category, filters to the `rei` namespace, preserves
      historical `agent_memory_*` / `agent_session_*` artifact IDs, and keeps the markdown mirror
      replay-safe for record/update/supersede/archive/merge. Follow-up cleanup removed the unused
      legacy `resolveMemoryPath` export and old AgentMemory-event wrappers from
      `Rei.Workspace.{Config,Memory}`, so the workspace memory renderer no longer imports legacy
      AgentMemory domain/event modules. Verification: Rei `cabal build rei-cli`;
      `cabal test rei-core-test --test-options='-p Kioku'`.
- [ ] M3: old Rei AgentMemory/AgentSession domain/projection/infrastructure/store-handler modules
      decommissioned (deleted from `rei-core.cabal` and the tree), keeping only the thin adapters.
      The old AgentMemory filesystem reactor is already removed; remaining work covers the old
      command/domain types, inline projections/read-model helpers, store-handler facades, migration
      fixture dependence on old transducers/projections, and the old AgentSession modules. `cabal
      test rei-core` green; AgentSchedule untouched.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The `rei-history-transform` executable and the `Rei.Infrastructure.History.{Routing,Transform,
  Verifier,Repair}` modules referenced in the project `CLAUDE.md`/`MEMORY.md` **no longer exist in
  the working tree.** They were authored during the original keiro migration (first commit
  `65dc9138`) and deleted in commit `51a08f27` ("remove legacy message-db cutover scaffolding")
  once that migration finished. The `CutoverConfig` / `REI_KIROKU_CONTEXTS` gating is likewise
  gone; `rei-cli/src/Rei/Cli/Cutover.hs` now exports only `StoreRunner` and `runStoreOnly`, and
  `rei-cli/src/Rei/Cli.hs` opens the kiroku store unconditionally. Consequence for this plan: there
  is no live cutover flag to migrate behind. The M3 data transform is modeled on the *historical*
  `transform-context` pattern (retrievable from git at `51a08f27^`) re-expressed as a new one-shot
  executable, not an extension of live tooling. Evidence: `grep -rn "REI_KIROKU\|CutoverConfig\|
  routeContext" rei-cli rei-core` returns nothing; `git show 51a08f27 --stat` shows the History
  modules deleted.

- The child plan's original cabal step says to add a git `source-repository-package` pin for kioku,
  but the MasterPlan's later cross-plan discovery says consumers should use local source paths to
  avoid kiroku pin skew. The implementation followed the MasterPlan: Rei's `packages:` now includes
  `../../kioku/kioku-api`, `../../kioku/kioku-core`, and `../../kioku/kioku-migrations`, plus the
  local shikumi packages kioku-core imports. This also avoids depending on whether the current
  kioku commit has been pushed to GitHub.

- `Kioku.Migrations.kiokuMigrations` includes Kiroku and Keiro framework migrations, while Rei
  already applies `Keiro.Migrations.allKeiroMigrations`. Composing `kiokuMigrations` in Rei would
  risk duplicating framework DDL in the same codd ledger. The migration runner now appends
  `kiokuOwnMigrations` instead.

- Rei's stored `CoachingFocusType` text does **not** include a `focus_` prefix. The authoritative
  mapping is the private `focusTypeToText` table in
  `Rei.Modules.AgentSession.Projection.InlineReadModel`, e.g. `FocusGeneralCoaching` maps to
  `general_coaching`, not `focus_general_coaching`. The adapter uses that table's exact strings and
  `KiokuAdapterSpec` guards all 15 round-trips.

- On Apple Silicon, Cabal's existing `package blake3` flag stanza did not prevent `blake3-0.3.1`
  from compiling x86 SIMD C files. Adding the flag assignment to the solver `constraints:` block
  (`blake3 -avx512 -avx2 -sse41 -sse2`) let Rei compile kioku-core and the test suite.

- Rei's existing shared ephemeral-Postgres test harness only applies Keiro/Kiroku migrations.
  Testing the Kioku-backed write handlers against real read models needed a narrower opt-in helper,
  `withKiokuTestStore`, that applies Kioku's full migration bundle on a fresh test database without
  changing the existing Keiro-only tests.

- A disposable Rei DB migration run exposed a pre-existing fresh-database break in frozen legacy
  hasql migrations before Rei reaches the codd migration list that now contains Kioku. With
  `HASKELL_ENV=development`, `rei-core:rei-migrations` first failed in
  `20260119180244_search_path.sql` because schema `message_store` did not exist; after creating
  that schema in the disposable DB, it failed later because relation `messages` did not exist. This
  means the current M1 verification cannot prove or disprove Kioku's composed migrations until the
  legacy bootstrap assumptions are satisfied or bypassed.

- Moving `ContextBuilder` recall to Kioku changed its effect requirement from Hasql-only reads to
  the kiroku `Store` effect. The Rei CLI had several prompt-building paths (`rei agent --debug`,
  interactive assist/intention-assist, non-interactive coaching, and note get-help) that still
  interpreted those builders with only `runHasqlWithPool`. Those runners now execute through the
  existing `StoreRunner`, while unrelated read-model-only CLI queries remain on Hasql.

- The M3 migration cannot be a byte-for-byte event row copy. `Keiro.Codec.decodeRecorded` rejects
  legacy `AgentMemoryRecorded` / `AgentSessionStarted` event-type tags before Kioku's compatibility
  payload parser can run, and Kiroku event IDs are globally unique so the same event UUID cannot be
  inserted again with a different native payload. The migration therefore decodes the old
  `events.data` payload with `Kioku.Memory.EventStream.parseMemoryEvent` /
  `Kioku.Session.EventStream.parseSessionEvent`, re-encodes it with Kioku's native codec, preserves
  the TypeID UUID body plus metadata/causation/correlation, and lets Kiroku assign fresh event IDs.
  Evidence: `cabal build rei-core:rei-kioku-migrate` succeeds with this design.

- Count-only migration verification is too weak for M3 because it can miss scope, focus, status,
  tag, or timestamp drift after projection rebuild. The `verify` subcommand now compares the
  migrated Rei namespace (`namespace = 'rei'`) at the read-model row level: old
  `agent_memories.anchor_type/anchor_id` maps to Kioku `scope_kind/scope_ref` (`workspace` becomes
  NULL scope columns), old sessions map `focus_type` to Kioku `focus`, `intention_id` to Kioku
  intention scope, and `focus_target` to Kioku `subject_ref`. It reports missing, extra, and
  mismatched memory/session rows separately. Evidence:
  `cabal build rei-core:rei-kioku-migrate`;
  `cabal run rei-core:rei-kioku-migrate -- --help`; `git diff --check`.

- The first executable rehearsal of `verify` exposed two semantic gaps that compile-only checks did
  not catch. First, row equivalence must compare old Rei rows after re-prefixing IDs
  (`agent_memory_*`/`agent_session_*` to `kioku_memory_*`/`kioku_session_*`) because Kioku owns the
  destination stream/read-model IDs. Second, Rei's legacy session JSON stores `CoachingFocusType`
  constructor names such as `FocusIntentionAssist`, while Rei's old `agent_sessions.focus_type`
  read model stores normalized strings such as `intention_assist`; Kioku's compatibility parser now
  normalizes every legacy focus constructor to the read-model string. Evidence:
  `cabal test kioku-core`; Rei `cabal test rei-core-test --test-options='-p rei-kioku-migrate'`.

- The M3 verifier needs an explicit recall-level assertion in addition to full-row equivalence.
  Full rows catch drift in all projected fields, but the user-visible coaching path depends on the
  active memory set returned for each scope. `rei-kioku-migrate verify` now compares active
  `agent_memories` against active `kioku_memories` as recall items keyed by namespace, scope, memory
  ID, and content, and separately checks that the set of recall scopes matches. The fixture now
  covers both an intention-scoped active memory and a workspace-global active memory while keeping a
  superseded workspace memory excluded. Evidence: Rei
  `cabal test rei-core-test --test-options='-p /rei-kioku-migrate/'`; Kioku `cabal test kioku-test`.

(Add further discoveries as work proceeds.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Migrate Rei's historical data by **copying logical events from the kiroku streams**
  (`agent_memory-<id>` → `kioku_memory-<id>`, `agent_session-<id>` → `kioku_session-<id>`) through
  Kioku's legacy payload parsers and native encoders, then rebuilding kioku's read-model projection
  — NOT by transforming the read-model rows of `agent_memories`/`agent_sessions`.
  Rationale: kioku is event-sourced; the streams are the source of truth and the read-model tables
  are derived. EP-1's compatibility parsers read Rei's legacy
  `{"type":"agent_memory_recorded","data":{…}}` envelope and re-prefix legacy TypeIDs into Kioku
  typed IDs with the same UUID body. Re-encoding as native Kioku events is necessary because Keiro
  rejects legacy event-type tags before payload decoding, and Kiroku event IDs are globally unique.
  Copying logical stream contents + rebuilding the projection is faithful, idempotent, and avoids
  reconstructing tag/confidence/supersession history from a flattened row. The read-model rows are
  then recomputed by the same inline projection EP-1 ships, guaranteeing they match a fresh kioku
  write.
  Date: 2026-06-24

- Decision: Reconcile the kioku pin against Rei's pins by **bumping kioku's kiroku pin to match
  Rei's** (`4312aa8c…`), keeping keiro (`f1d67a01…`) and keiki (`bc987f4…`) which already match.
  Rationale: IP-5 says EP-1 copies kizashi's pin-set verbatim (kiroku `322096c8`); Rei pins kiroku
  at `4312aa8c` (the revision keiro `f1d67a01` internally pins). A single Haskell program (Rei +
  kioku linked together) must resolve ONE kiroku version. `4312aa8c` and `322096c8` differ only by a
  kiroku-metrics release chore + docs (per Rei's `cabal.project` comment), so Rei's `4312aa8c` is a
  safe common pin and is the one keiro `f1d67a01` already wants. We do not downgrade Rei.
  Date: 2026-06-24

- Decision: Keep a thin Rei-side **adapter layer** (`Rei.Modules.Agent.Memory.KiokuAdapter` and a
  session adapter) rather than calling `Kioku.*` directly from `ContextBuilder`/the CLI. The adapter
  owns the `MemoryAnchor ↔ MemoryScope` and `CoachingFocusType ↔ Text` maps and the
  `MemoryRecord → AgentMemoryRow → MemorySummary` conversions.
  Rationale: it localizes the kioku coupling to one module, keeps `ContextBuilder`/`PromptRenderer`
  diff minimal, lets `formatMemories` and `MemorySummary` stay byte-stable in Rei, and gives a
  single place to re-target when EP-2's hybrid recall lands.
  Date: 2026-06-24

- Decision: For recall, call kioku's **scoped** queries (EP-1's placeholder `Kioku.Recall`:
  `getActiveByScope`, `getGlobal`) for M2, and switch to EP-2's hybrid `Kioku.Recall` only if/when
  EP-2 is Complete. The adapter exposes the same three Rei-facing functions
  (`getWorkspaceMemories`, `getActiveMemoriesForIntention`, `getActiveMemories`) so the switch is
  internal.
  Rationale: EP-2 is a soft dependency. Scoped recall reproduces Rei's current
  `WHERE status='active'` behaviour exactly (which is what the byte-stability test needs); hybrid
  recall is a strict improvement layered later without touching ContextBuilder.
  Date: 2026-06-24

- Decision: Add `Kioku.Recall.getActiveInNamespace` and its `kioku-memories-by-namespace` read model
  for Rei's all-active memory recall path instead of emulating it with multiple scope queries.
  Rationale: Rei's `getActiveMemories` historically returned every active memory in creation order
  without scope filtering. A namespace-level active query preserves that behavior for
  `ContextBuilder` and keeps the API host-agnostic for other consumers.
  Date: 2026-06-24

- Decision: Add `Kioku.Recall.getById` returning a `MemoryRecord` for CLI by-id display, and keep
  the Rei adapter responsible for re-prefixing Kioku read IDs back to Rei-shaped row IDs.
  Rationale: `rei agent memory show` and `archive` are public CLI surfaces that historically accept
  `agent_memory_*` IDs. Kioku owns streams internally as `kioku_memory_*`, but the CLI should not
  start rejecting IDs it just displayed. Re-prefixing at the adapter boundary preserves the existing
  Rei row/command contract while retaining Kioku's internal stream ownership.
  Date: 2026-06-24

- Decision: Until Kioku exposes a supersession-chain read model, `rei agent memory show --chain`
  renders the selected Kioku memory as a one-row chain rather than querying the old
  `agent_memories` table.
  Rationale: M2's goal is to remove CLI memory reads from Rei's old table. A partial chain from
  Kioku is more truthful than falling back to stale old read-model data; full historical chain
  reconstruction belongs with M3's history copy and/or a Kioku chain query.
  Date: 2026-06-24

- Decision: The AgentMemory **filesystem mirror** reactor **stays in Rei** as a Rei-specific
  side-effect leg, but its implementation moved from the legacy
  `Rei.Modules.AgentMemory.Reactor.FilesystemProjection` module to
  `Rei.Modules.Agent.Memory.FilesystemProjection` and now reads the `kioku_memory` category instead
  of `agent_memory`.
  Rationale: writing markdown memory files into the Rei workspace is a Rei concern (it uses
  `Rei.Workspace.*`), not part of the reusable engine. It only needs to decode kioku events, filter
  to the `rei` namespace, and preserve Rei-shaped artifact IDs at the adapter boundary.
  Date: 2026-06-24

- Decision: Consume kioku in Rei via local `packages:` entries during EP-4 implementation rather
  than a git `source-repository-package` pin.
  Rationale: the MasterPlan's IP-5 discovery supersedes the child plan's original git-pin wording:
  local source paths let Rei resolve kioku against Rei's single coherent keiro/kiroku/keiki pin-set
  and also work while the current kioku HEAD (`d969b2b438f801aabb26c2cb6cb39eea18347b95`) is only
  present locally. The M0 hash remains recorded as the baseline being consumed.
  Date: 2026-06-24

- Decision: Compose `kiokuOwnMigrations` into Rei's codd pass, not `kiokuMigrations`.
  Rationale: Rei already composes Kiroku and Keiro through `allKeiroMigrations`; `kiokuMigrations`
  includes those framework migrations again. `kiokuOwnMigrations` is the additive kioku read-model
  DDL that belongs between framework migrations and Rei's app migrations.
  Date: 2026-06-24

- Decision: Use Rei's existing focus storage strings without a `focus_` prefix.
  Rationale: `Rei.Modules.AgentSession.Projection.InlineReadModel.focusTypeToText` is the live
  storage contract for `agent_sessions.focus_type`; keeping those strings (`general_coaching`,
  `today`, etc.) preserves historical session rendering and avoids a needless data transform.
  Date: 2026-06-24

- Decision: Preserve Rei's public `AgentMemoryId` / `AgentSessionId` inputs but re-prefix them to
  Kioku IDs with `Kioku.Id.parseIdAnyPrefix`, keeping the same TypeID UUID body
  (`agent_memory_...` → `kioku_memory_...`, `agent_session_...` → `kioku_session_...`).
  Rationale: callers and CLI data construction remain unchanged while Kioku owns the event streams
  and read models. The same rule also matches the planned M3 historical stream-copy transform.
  Date: 2026-06-24

- Decision: Map `StartAgentSessionData.focusTarget` to Kioku session `subjectRef` when present,
  falling back to the intention ID text; interactive sessions, which have no `focusTarget`, use the
  intention ID text when available.
  Rationale: `subjectRef` is Kioku's generic slot for the concrete thing a session was about.
  Preserving Rei's explicit `focusTarget` avoids dropping useful note/topic/task text while still
  retaining intention scoping in `MemoryScope`.
  Date: 2026-06-24

- Decision: Make `rei-kioku-migrate verify` a read-model equivalence check, not just a count check.
  It compares old `agent_memories`/`agent_sessions` rows against Rei-scoped
  `kioku_memories`/`kioku_sessions` rows after applying the documented column mapping, including
  Rei-to-Kioku ID prefix conversion for memory IDs, session IDs, and supersession references, and
  fails on missing, extra, or mismatched rows.
  Rationale: the migration copies streams and rebuilds Kioku projections, so the practical cutover
  gate is whether Rei's old prompt/CLI data can be reproduced from Kioku rows. Row equivalence
  catches semantic drift that counts cannot, while keeping the check deterministic and executable
  against a disposable data copy before decommission.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.

- 2026-06-24: M2 ContextBuilder recall slice compiles and passes focused tests. Verification:
  `cabal build kioku-core`; `cabal test kioku-test`; Rei `cabal build rei-core`;
  `cabal test rei-core-test --test-options '-p Kioku'`. A `ContextBuilder` test filter compiled but
  matched zero named tests, so the current executable proof is the Kioku-backed adapter integration
  test plus build coverage of `ContextBuilder`.

- 2026-06-24: M2 CLI memory read slice compiles and passes focused tests. Verification:
  `cabal test kioku-test`; Rei `cabal build rei-core rei-cli`;
  `cabal test rei-core-test --test-options '-p Kioku'`; `cabal test rei-cli-test`. At this point,
  the remaining M2 work was the captured `{{agent_memories}}` byte-stability comparison.

- 2026-06-24: M2 `{{agent_memories}}` byte-stability proof added to
  `Rei.Modules.Agent.Memory.KiokuAdapterSpec`. The test renders the public `agent_memories` prompt
  variable from legacy rows and Kioku-converted rows and asserts identical bytes for the four known
  memory type groups, the empty placeholder, and unknown-type dropping. Verification:
  Rei `cabal test rei-core-test --test-options='-p Kioku'`.

- 2026-06-24: M3 additive migration-tool slice landed in Rei. `rei-kioku-migrate` builds and exposes
  `copy-memories`, `copy-sessions`, `copy-all`, and `verify`; copy commands decode legacy Rei
  payloads through Kioku compatibility parsers, re-encode native Kioku events, append missing
  destination-stream tails, and rebuild Kioku inline read models. Verification:
  Rei `cabal build rei-core:rei-kioku-migrate`;
  `cabal run rei-core:rei-kioku-migrate -- --help`.

- 2026-06-24: M3 verifier slice strengthened `rei-kioku-migrate verify` from counts-only to
  read-model row equivalence. It now scopes Kioku-side counts to `namespace = 'rei'` and reports
  missing, extra, and mismatched business rows for memories and sessions. Verification:
  Rei `nix fmt`; `cabal build rei-core:rei-kioku-migrate`;
  `cabal run rei-core:rei-kioku-migrate -- --help`; `git diff --check`.

- 2026-06-24: M3 disposable fixture rehearsal added. The migration logic is now importable as
  `Rei.KiokuMigrate`, and `Rei.Modules.Agent.Memory.KiokuMigrateSpec` seeds old
  `agent_memory`/`agent_session` streams and old read-model tables through Rei's legacy
  transducers/projections, runs `copyMemories`/`copySessions`, verifies row equivalence, and reruns
  copy to prove idempotency (`appendedEvents = 0`). The rehearsal found and fixed the verifier's
  missing ID re-prefix mapping and Kioku's legacy session focus normalization. Verification:
  Kioku `cabal test kioku-core`; `cabal build all`; Rei
  `cabal test rei-core-test --test-options='-p rei-kioku-migrate'`;
  `cabal build rei-core:rei-kioku-migrate`;
  `cabal run rei-core:rei-kioku-migrate -- --help`.

- 2026-06-24: M3 live coaching-context recall proof added. `ContextBuilderSpec` now records memories
  through Rei's Kioku-backed memory store handler, then runs `buildIntentionContext` through the same
  Rei effect stack used by coaching context construction. The assertion proves the context includes
  both the target intention-scoped memory and the workspace-global memory from Kioku recall, while an
  unrelated intention memory is excluded. Verification: Rei
  `cabal test rei-core-test --test-options='-p Kioku'`.

- 2026-06-24: M3 filesystem-mirror decommission slice landed. The worker no longer subscribes a
  legacy AgentMemory reactor to `agent_memory`; `KirokuRunner` now registers
  `Rei.Modules.Agent.Memory.FilesystemProjection` on the Kioku-owned `kioku_memory` category. The
  new spec proves native Kioku record/update/supersede/archive events maintain Rei workspace
  markdown files replay-safely, ignore non-Rei namespaces, and preserve the historical
  `agent_memory_*` / `agent_session_*` IDs in artifacts. Verification: Rei
  `cabal test rei-core-test --test-options='-p Kioku'`; `cabal build rei-cli`; `git diff --check`.

- 2026-06-24: M3 workspace-memory compatibility wrappers removed. After the Kioku-backed filesystem
  mirror landed, `Rei.Workspace.Config.resolveMemoryPath` and the old `Rei.Workspace.Memory`
  functions that accepted `AgentMemoryRecordedData`/`AgentMemoryTagsUpdatedData`/
  `AgentMemoryConfidenceUpdatedData` had no remaining callers. Removing them leaves the workspace
  memory renderer on generic text/scope data owned by the Kioku adapter path. Verification: Rei
  `cabal build rei-cli`; `cabal test rei-core-test --test-options='-p Kioku'`; `git diff --check`.


## Context and Orientation

Read this section fully before running anything. It assumes no prior knowledge of this repository.

### What Rei is and where the relevant code lives

Rei is a Haskell monorepo at `/Users/shinzui/Keikaku/bokuno/rei-project/rei` with two packages:
`rei-core` (the library: domain logic, event store, read models) and `rei-cli` (the `rei`
command-line tool). It is **event-sourced**: the source of truth for an entity is an append-only
log of immutable facts ("events") on a named "stream" in a PostgreSQL-backed event store called
**kiroku**; the queryable tables ("read models") are derived projections rebuilt from those events.
Aggregate write rules are pure state machines built with a library called **keiki**, run by a
runtime called **keiro**. You do not build keiki/keiro/kiroku; Rei depends on them as git-pinned
packages declared in `/Users/shinzui/Keikaku/bokuno/rei-project/rei/cabal.project`.

The two modules this plan replaces:

- `rei-core/src/Rei/Modules/AgentMemory/` — the agent-memory aggregate. Its pieces:
  `Domain/Types.hs` (the `MemoryType`, `MemoryConfidence`, `MemoryAnchor`, `MemoryStatus` enums and
  the `AgentMemoryId` typeid), `Domain/Event.hs` (`AgentMemoryEvent` with five constructors),
  `Domain/Command.hs`, `Domain/Transducer.hs` (the keiki state machine, stream
  `agent_memory-<id>`), `Application/StoreHandler.hs` (the five write functions `recordMemory`,
  `supersedeMemory`, `archiveMemory`, `updateMemoryTags`, `updateMemoryConfidence`),
  `Infrastructure/Table.hs` + `Infrastructure/ReadModel.hs` (the `agent_memories` SQL read-model
  queries), `Projection/InlineReadModel.hs` (the projection that upserts `agent_memories` in the
  append transaction), and `Reactor/FilesystemProjection.hs` (a best-effort side-effect leg that
  mirrors active memories as markdown files in the workspace).
- `rei-core/src/Rei/Modules/AgentSession/` — the same shape for agent sessions
  (`Application/StoreHandler.hs` exports `startSession`, `completeSession`, `failSession`,
  `recordInteractiveSession`; stream `agent_session-<id>`; read-model table `agent_sessions`).

The two consumers of the above:

- `rei-core/src/Rei/Modules/Agent/Application/ContextBuilder.hs` builds the prompt context. It calls
  exactly three memory recall functions from
  `Rei.Modules.AgentMemory.Infrastructure.ReadModel`: `getWorkspaceMemories`,
  `getActiveMemoriesForIntention`, and `getActiveMemories`. Each returns `[AgentMemoryRow]`; the
  builder folds rows through `memoryRowToSummary :: AgentMemoryRow -> MemorySummary` and stores the
  list in the `agentMemories` field of the `AgentContext` record. (`ContextBuilder` does no session
  reads.)
- `rei-core/src/Rei/Modules/Agent/Application/PromptRenderer.hs` turns the recalled memories into the
  `{{agent_memories}}` template substitution via `formatMemories :: [MemorySummary] -> Text`. This
  function's exact output is the **byte-stable contract** of this plan (its body is reproduced in
  full in "Interfaces and Dependencies" below).
- `rei-cli/src/Rei/Cli/Commands/Agent/Handler.hs` is the CLI. It (a) drives the three memory
  subcommands `rei agent memory list|show|archive`, (b) records memories implicitly after a coaching
  response (`recordMemoriesFromResponse` → `MemoryK.recordMemory`/`supersedeMemory`), and (c) starts
  and completes a session around every LLM call (`withSessionRecording` →
  `SessionK.startSession`/`completeSession`/`failSession`, and `recordInteractiveAgentSession` →
  `SessionK.recordInteractiveSession`). All writes already go through a single `StoreRunner` value
  (`rei-cli/src/Rei/Cli/Cutover.hs`); reads run on a Hasql pool. There is **no** message-db dual
  path or `routeContext` here anymore.

### What kioku is (the new dependency)

kioku is a standalone Haskell library at `/Users/shinzui/Keikaku/bokuno/kioku`, four packages
(`kioku-api`, `kioku-core`, `kioku-cli`, `kioku-migrations`), built by EP-1
(`docs/plans/1-kioku-scaffold-and-core-extraction.md`). The modules this plan imports (kioku's
public API surface, MasterPlan IP-1 — consumers depend only on these, never on `Kioku.*.Domain.*`
internals):

- `Kioku.Api.Scope` — the generic scoping types `Namespace`, `ScopeKind`, `MemoryScope`
  (`ScopeGlobal Namespace | ScopeEntity Namespace ScopeKind Text`), plus helpers
  `scopeNamespaceText`, `scopeKindText`, `scopeRefText`, `scopeFromColumns`.
- `Kioku.Api.Types` — `MemoryType` (Fact/Pattern/Preference/Constraint/Instruction), `Confidence`
  (High/Medium/Low), `MemoryStatus`, and the JSON read row `MemoryRecord` (fields `memoryId`,
  `agentId`, `sessionId :: Maybe Text`, `scope :: MemoryScope`, `memoryType :: Text`,
  `content :: Text`, `priority :: Int`, `confidence :: Text`, `tags :: Set Text`, `status :: Text`,
  `createdAt :: UTCTime`), plus the text round-trips (`memoryTypeToText`, `confidenceToText`, …).
- `Kioku.Memory` — the memory **write** API: `record`, `supersede`, `archive`, `updateTags`,
  `updateConfidence`, each running `runCommandWithProjections` with kioku's inline projection.
- `Kioku.Session` — the session **write** API: `start`, `complete`, `failSession`, `recordInteractive`,
  `recordTurn` (turns are opt-in; Rei never records turns).
- `Kioku.Recall` — the **read** API: EP-1 ships scoped SQL queries (`getActiveByScope`, `getGlobal`,
  `getBySession`, `getByType`); EP-2 fills in a hybrid (vector + full-text + RRF) recall behind the
  same module.
- `Kioku.Id` — `MemoryId = KindID "kioku_memory"`, `SessionId = KindID "kioku_session"`, generators
  `genMemoryId`/`genSessionId`.

The exact signatures of these functions are restated in "Interfaces and Dependencies" below; if
EP-1's final signatures differ slightly from what is restated here, treat EP-1's source as
authoritative and adjust the adapter, recording the difference in this plan's Decision Log.

### Terms of art (plain language)

- **Aggregate / stream / event / projection.** See "What Rei is" above. A *memory* and a *session*
  are aggregates. Each has a stream (`kioku_memory-<id>`); a *projection* is a function that upserts
  a read-model row in the same DB transaction as the event append, so a read right after a write
  sees the row ("read-your-own-writes").
- **MemoryScope.** kioku's generic "what this memory is about". Either `ScopeGlobal ns` (the whole
  namespace, e.g. all of Rei) or `ScopeEntity ns kind ref` (a typed entity, e.g.
  `ScopeEntity "rei" "intention" "intention_01k…"`). It is stored as three flat columns
  `namespace`, `scope_kind`, `scope_ref` (the latter two NULL for a global scope).
- **MemoryAnchor.** Rei's *old* "what this memory is about": `AnchorToIntention IntentionId`,
  `AnchorToHabit HabitId`, or `WorkspaceGlobal`. The adapter maps these to/from `MemoryScope`.
- **CoachingFocusType.** Rei's fifteen-constructor session-mode enum
  (`FocusGeneralCoaching`, `FocusToday`, …). It serializes to snake_case strings via Rei's
  `eventAesonOptions` (constructor tag modifier `camelTo2 '_'`), so `FocusGeneralCoaching` ⇒
  `focus_general_coaching`, `FocusToday` ⇒ `focus_today`, etc. kioku's session `focus` is a free
  `Text`; the adapter preserves these exact strings.
- **codd.** Rei's migration tool. Application migrations are timestamped `.sql` files under
  `rei-core/migrations/codd/`, embedded into the migrations binary via Template Haskell `embedDir`.
  kioku ships its own migration set (`kioku-migrations`, IP-3); Rei composes it into its runner.
- **StoreRunner.** A Rei-CLI value (`rei-cli/src/Rei/Cli/Cutover.hs`) that runs a store action
  (`forall es. ReiStoreEff es => Eff es a`) against the opened kiroku store and returns
  `IO (Either Text (Either Text a))`. All agent writes already go through it.

### The pin reconciliation problem (read carefully)

Rei's `cabal.project` pins the event-sourcing stack at: keiki `bc987f46…`, keiro `f1d67a01…`,
**kiroku `4312aa8c…`**. EP-1's kioku copies kizashi's pin-set, which pins **kiroku `322096c8…`**
(keiki and keiro match Rei). A single executable that links Rei and kioku together must resolve a
single kiroku version. Per this plan's Decision Log, we keep Rei's `4312aa8c…` and bump kioku's
kiroku pin to it (the two revisions differ only by a kiroku-metrics release chore + docs, per Rei's
own `cabal.project` comment). Concretely: Rei adds a `kioku` source-repository-package pin to
`/Users/shinzui/Keikaku/bokuno/rei-project/rei/cabal.project`, and does **not** add a second kiroku
pin — Rei's existing kiroku pin governs. If kioku's `cabal.project` (which is irrelevant once kioku
is consumed as a source-repository-package — its own `cabal.project` is not used by Rei's build)
ever leaks a conflicting constraint via its `.cabal` `build-depends` bounds, relax it in Rei's
`allow-newer`/`constraints` block and record it in Surprises.

### What already exists vs. what you create

EP-1's kioku already exists, builds, and has a golden test proving its codec reads Rei's legacy
JSON. Rei's AgentMemory/AgentSession modules and their two consumers exist and are what you change.
You create: the kioku pin in Rei's `cabal.project`, the kioku migrations composition, two thin
adapter modules, and a one-shot stream-copy migration executable. You delete the old AgentMemory/
AgentSession domain/projection/infrastructure/store-handler modules at the end.


## Plan of Work

The work is four milestones (M0 a gate, then M1–M3). Each leaves the tree building and the test
suite green, and is independently verifiable. The guiding principle is *additive first, subtractive
last*: M1 wires kioku in and re-homes the **writes** while the old read path still serves reads, so
the suite stays green; M2 moves the **reads** and proves byte-stable prompt output; M3 migrates the
**historical data** and only then deletes the old modules.

### Milestone M0 — Prerequisite gate (EP-1 is Complete)

**Scope and result.** This milestone runs no Rei edits. It confirms the hard dependency is met. At
its end you have verified that `/Users/shinzui/Keikaku/bokuno/kioku` exists, `cabal build all`
succeeds there, and EP-1's M4 golden test (`cabal test kioku-core`, the `ReiCompat` group) passes —
proving kioku's codec decodes Rei's legacy `agent_memory`/`agent_session` JSON. Note the exact kioku
commit hash you build against; record it in the Decision Log so the Rei pin is reproducible.

**Commands.** In `/Users/shinzui/Keikaku/bokuno/kioku` (in its nix dev shell): `git rev-parse HEAD`
(record the hash), `cabal build all`, `cabal test kioku-core`. Acceptance: all three succeed and the
`ReiCompat` test group passes. If EP-1 is not Complete, **stop** — this plan cannot proceed.

### Milestone M1 — Wire kioku into Rei, re-home the write paths (suite stays green)

**Scope and result.** At the end of M1: Rei's `cabal.project` pins kioku at the M0 hash;
`rei-core.cabal` build-depends on `kioku-api` and `kioku-core`; kioku's migrations are composed into
Rei's migration runner so `just run-migrations` creates `kiroku.kioku_memories`,
`kiroku.kioku_sessions`, `kiroku.kioku_turns`; a new adapter module
`Rei.Modules.Agent.Memory.KiokuAdapter` (and a small session adapter) provides the
`MemoryAnchor ↔ MemoryScope` and `CoachingFocusType ↔ Text` maps and the kioku-row → Rei-row
conversions; and the five memory writers and four session writers in Rei now delegate to
`Kioku.Memory`/`Kioku.Session` through the adapter. The old read path
(`AgentMemory.Infrastructure.ReadModel` over the `agent_memories` table) is **left in place** and
still serves all reads, so the entire suite stays green. Nothing is deleted yet.

This milestone is deliberately ordered writes-first so that, with reads still on the old table, the
suite's existing AgentMemory/AgentSession projection and transducer specs continue to pass against
the unchanged read model while the write side is being re-pointed. The two write paths
(Rei→kioku stream and the old Rei→`agent_memory` stream) are mutually exclusive per writer; you flip
each writer to kioku and rely on M3 to backfill history.

**Files and edits in M1:**

1. **`/Users/shinzui/Keikaku/bokuno/rei-project/rei/cabal.project`** — add a kioku source-repository-package
   pin. Place it near the other shinzui pins (after the keiki stanza). Use the M0 hash. Add the four
   kioku subdir packages Rei needs at build (api + core; cli and migrations are needed only by the
   migration runner and the one-shot tool — include all four for simplicity):

   ```text
   source-repository-package
     type: git
     location: https://github.com/shinzui/kioku
     tag: <M0-HASH>
     subdir:
       kioku-api
       kioku-core
       kioku-cli
       kioku-migrations
   ```

   Do **not** add a kioku-internal kiroku/keiro/keiki pin: Rei's existing pins govern. If the solver
   complains about kioku's `.cabal` bounds against Rei's kiroku `4312aa8c`, add the offending package
   to `allow-newer` (mirroring the existing keiro entries) and note it in Surprises.

2. **`/Users/shinzui/Keikaku/bokuno/rei-project/rei/rei-core/rei-core.cabal`** — add `kioku-api` and
   `kioku-core` to the `library` stanza `build-depends`. Add `kioku-migrations` to the
   `rei-migrations` executable stanza's `build-depends` (for the migrations composition in edit 3),
   and to the new one-shot tool stanza in M3.

3. **Compose kioku migrations into Rei's runner.** Find Rei's migration entry point
   (`rei-core/migrations/` executable; per the project `CLAUDE.md` it runs
   `runKirokuMigrationsNoCheck` then codd application). kioku exposes its migration set as
   `Kioku.Migrations.kiokuMigrations` (IP-3, the kizashi pattern: `codd` + `embedDir`). Compose it
   into Rei's codd migration application **after** the kiroku + keiro framework migrations and Rei's
   own application migrations, exactly as kizashi composes
   `kirokuMigrations <> keiroFrameworkMigrations <> ownMigrations`. The kioku read-model tables live
   in the `kiroku` schema (IP-3), which Rei already uses, so no new schema is introduced. Read the
   exact name kioku exports for its migration value from EP-1's
   `kioku-migrations/src/Kioku/Migrations.hs` and use it verbatim. Acceptance for this edit:
   `just run-migrations` then `psql … -c '\dt kiroku.kioku_*'` lists the three kioku tables.

   *Note on `CREATE EXTENSION vector` (IP-3):* EP-1's base migration does **not** create the vector
   extension (that is EP-2). So composing EP-1's migrations needs no superuser privilege. If EP-2 is
   present and you choose to pull its vector migration, the migrating role must be able to
   `CREATE EXTENSION vector`; otherwise stay on EP-1's base set. Default for this plan: EP-1 base set
   only.

4. **New module `rei-core/src/Rei/Modules/Agent/Memory/KiokuAdapter.hs`** (add to `rei-core.cabal`
   `exposed-modules`). It defines:

   - `reiNamespace :: Namespace` = `Namespace "rei"`.
   - `anchorToScope :: MemoryAnchor -> MemoryScope`:
     `AnchorToIntention iid → ScopeEntity reiNamespace (ScopeKind "intention") (KindID.toText iid)`;
     `AnchorToHabit hid → ScopeEntity reiNamespace (ScopeKind "habit") (KindID.toText hid)`;
     `WorkspaceGlobal → ScopeGlobal reiNamespace`.
   - `scopeToAnchor :: MemoryScope -> Either Text MemoryAnchor` (inverse, parsing the typeid text
     back into `IntentionId`/`HabitId`; a `ScopeGlobal` or unknown kind → `WorkspaceGlobal` /
     `Left` as appropriate). Used by reads that must reconstruct Rei anchors.
   - `focusToText :: CoachingFocusType -> Text` and `focusFromText :: Text -> Maybe CoachingFocusType`
     producing/consuming the exact snake_case strings Rei's `eventAesonOptions` already emits
     (`focus_general_coaching`, `focus_today`, `focus_intention_review`, `focus_nudge`,
     `focus_daily_reflection`, `focus_weekly_reflection`, `focus_note_help`, `focus_assist`,
     `focus_intention_assist`, `focus_collection_explore`, `focus_create_note`, `focus_create_skill`,
     `focus_scheduled_work`, `focus_update_note`, `focus_ask_note`). Implement
     `focusToText` by reusing `toJSON` of the existing instance (or hand-write the table — pick one
     and assert with a round-trip test that all 15 constructors round-trip).
   - `memoryRecordToRow :: Kioku.Api.Types.MemoryRecord -> AgentMemoryRow` converting a kioku read
     row into Rei's existing `AgentMemoryRow` shape (so `ContextBuilder.memoryRowToSummary` and the
     CLI keep working unchanged in M2): map `scope` back to `(anchorType, anchorId)` via
     `scopeKindText`/`scopeRefText` (a global scope ⇒ `anchorType = "workspace"`, `anchorId =
     Nothing`); copy `memoryType`/`content`/`confidence`/`status`/`createdAt`; encode the `Set Text`
     `tags` to the JSON-array text Rei's row carries; default `updatedAt` to `createdAt` and
     `sessionId` to the kioku `sessionId` (or `""` if `Nothing`, matching Rei's `NOT NULL`
     `session_id`). Supersession columns (`supersededBy`/`supersedes`) map from kioku's record if it
     carries them; otherwise leave `Nothing` (only the supersession-chain CLI view uses them, and M2
     re-points that view onto kioku directly).
   - A session adapter (same module or a sibling `Rei.Modules.Agent.Session.KiokuAdapter.hs`):
     `sessionScope :: Maybe IntentionId -> MemoryScope` = `maybe (ScopeGlobal reiNamespace)
     (\iid -> ScopeEntity reiNamespace (ScopeKind "intention") (KindID.toText iid))`, and the
     `subjectRef :: Maybe Text` is `fmap KindID.toText intentionId`.

   Add a unit-test spec `rei-core/test/Rei/Modules/Agent/Memory/KiokuAdapterSpec.hs` (register in
   `rei-core.cabal` `test-suite` `other-modules`) asserting: every `MemoryAnchor` round-trips through
   `anchorToScope`/`scopeToAnchor`; every `CoachingFocusType` round-trips through
   `focusToText`/`focusFromText`; and a representative `MemoryRecord` converts to the expected
   `AgentMemoryRow`. These tests are the M1 acceptance.

5. **Re-home the memory writers.** Rewrite `Rei.Modules.AgentMemory.Application.StoreHandler` (or
   replace its callers) so the five write functions delegate to `Kioku.Memory`. The cleanest seam is
   to keep the *same Rei-facing signatures* the CLI already calls (`recordMemory ::
   RecordAgentMemoryData -> Eff es (Either AgentMemoryHandlerError ())`, etc.) but implement each by
   (a) mapping the Rei command data into kioku's call (`anchorToScope` the anchor, pass through
   content/type/confidence/tags/sessionId, generate or reuse the `kioku_memory` id from the existing
   `agent_memory` id text), and (b) calling `Kioku.Memory.record`/`supersede`/`archive`/`updateTags`/
   `updateConfidence` via the `StoreRunner`'s effect stack. The idempotency pre-checks that the old
   handler did against the `agent_memories` row should now read kioku's row (via `Kioku.Recall` /
   kioku's by-id query) — or, simplest, rely on kioku's own write-API idempotency (EP-1's
   `Kioku.Memory` mirrors exactly this pre-check). Pick the approach that keeps the existing
   `AgentMemoryHandlerError` cases (`MemoryNotFound`, `MemoryNotActive`) observable to the CLI.

   *Id mapping:* a Rei memory has an `agent_memory_…` typeid; a kioku memory has a `kioku_memory_…`
   typeid. New writes mint a fresh `kioku_memory` id (`Kioku.Id.genMemoryId`) and the CLI/recall use
   it thereafter. The stream-copy in M3 likewise re-prefixes ids (`agent_memory_X` → `kioku_memory_X`
   keeping the UUID part) so historical and new ids share the same UUID body — see M3.

6. **Re-home the session writers.** Same pattern for
   `Rei.Modules.AgentSession.Application.StoreHandler`'s `startSession`, `completeSession`,
   `failSession`, `recordInteractiveSession` → `Kioku.Session.start`/`complete`/`failSession`/
   `recordInteractive`, mapping `CoachingFocusType` to `focusToText`, the intention to
   `sessionScope`/`subjectRef`, and re-prefixing the id (`agent_session` → `kioku_session`).

**Commands to run for M1.** From the Rei repo root in the dev shell:
`cabal build rei-core`, then `just run-migrations`, then
`psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt kiroku.kioku_*'`, then `cabal test rei-core`.

**Acceptance for M1.** `cabal build rei-core` exits 0. The `\dt` lists `kioku_memories`,
`kioku_sessions`, `kioku_turns`. `cabal test rei-core` is green (count ≥ the pre-migration count;
record the exact count). The new `KiokuAdapterSpec` passes. A manual smoke test: run a coaching
command that records a memory (or call the writer in a ghci/test harness), then
`psql … -c "SELECT count(*) FROM kiroku.kioku_memories;"` shows the new row, proving the write landed
in kioku (the old `agent_memories` table does **not** get the new row).

### Milestone M2 — Move recall onto kioku; prove `{{agent_memories}}` byte-identical

**Scope and result.** At the end of M2, the prompt's `### Agent Memories` section is built from
memories recalled from **kioku**, and that rendered section is byte-for-byte identical to what Rei
produced before for the same memories. You rewire the three `ContextBuilder` recall call sites and
the three `rei agent memory` subcommands onto kioku reads (through the adapter), while keeping
`MemorySummary`, `memoryRowToSummary`, `deduplicateMemories`, and `PromptRenderer.formatMemories`
unchanged in Rei.

**Files and edits in M2:**

1. **`rei-core/src/Rei/Modules/Agent/Application/ContextBuilder.hs`** — replace the import of the
   three recall functions from `Rei.Modules.AgentMemory.Infrastructure.ReadModel`
   (`getWorkspaceMemories`, `getActiveMemoriesForIntention`, `getActiveMemories`) with adapter
   functions of the **same names and same `[AgentMemoryRow]` result type** that call `Kioku.Recall`
   under the hood:

   - `getWorkspaceMemories` → `Kioku.Recall.getGlobal reiNamespace` then `map memoryRecordToRow`.
   - `getActiveMemoriesForIntention iid` → `Kioku.Recall.getActiveByScope
     (ScopeEntity reiNamespace (ScopeKind "intention") (KindID.toText iid))` then
     `map memoryRecordToRow`.
   - `getActiveMemories` → kioku's "all active in namespace" query. If EP-1's `Kioku.Recall` has no
     namespace-wide "all active" query, add the adapter to combine `getGlobal` with the per-scope
     queries, or (preferred) ask kioku for it; for M2 it is acceptable to define the adapter's
     `getActiveMemories` as `getGlobal reiNamespace` *unioned with* any entity-scoped actives via a
     single kioku query if EP-1 exposes one. Record the exact kioku function used in the Decision
     Log. The ordering and `take 20`/`take 3` caps live in `ContextBuilder` and are unchanged.

   Put these three adapter functions in `Rei.Modules.Agent.Memory.KiokuAdapter` with the same
   effect constraint shape `ContextBuilder` expects (a Hasql/store read constraint). The diff to
   `ContextBuilder` is then only the import line; the nine call sites are untouched because the
   function names and types match.

   *Ordering/byte-stability caution:* `formatMemories` groups by type and renders date-only, so the
   **set** of memories per scope and their `(confidence, content, recordedAt)` must match the old
   path for byte-identical output. EP-1's scoped recall is `WHERE status='active'` over the same
   underlying events Rei recorded, so the set matches once M3 backfills history. For M2's
   byte-stability test you compare against the **same data** present in both tables on a small fixture
   (see Validation), not against a pre-M3 production DB.

2. **`rei-cli/src/Rei/Cli/Commands/Agent/Handler.hs`** — rewire the three memory subcommands and the
   session-show memory list:
   - `handleAgentMemoryList` (the four-way filter on session/intention/type/all) → adapter calls into
     `Kioku.Recall` (`getBySession`, `getActiveByScope` for intention, `getByType`, all-active),
     `map memoryRecordToRow` so the existing row-rendering code is unchanged.
   - `handleAgentMemoryShow` (`--chain` and by-id) → kioku's by-id read; for `--chain` use kioku's
     supersession query if EP-1/EP-3 exposes one, else render the single memory (note the limitation
     in Decision Log; supersession chains are an EP-3 concern).
   - `handleAgentMemoryArchive` → already re-homed in M1 (it calls the memory writer); confirm it
     reads the kioku row to resolve the id.
   - `handleAgentSessionShow`'s `getMemoriesBySession` → `Kioku.Recall.getBySession`.
   - The session-list views (`getRecentSessions`, `getSessionsForIntention`, etc.) → kioku session
     reads (add the adapter functions; sessions are simpler — they have no formatting contract beyond
     the CLI table).

3. Leave `MemorySummary`, `memoryRowToSummary`, `deduplicateMemories` (all in `ContextBuilder`) and
   `formatMemories`/`contextToVariables` (in `PromptRenderer`) **unchanged**.

**Commands for M2.** `cabal build rei-core rei-cli`, `cabal test rei-core`, then the byte-stability
check in Validation, then a live `rei agent coach` run with `--debug`/prompt-dump to eyeball the
`### Agent Memories` block.

**Acceptance for M2.** `cabal build` and `cabal test rei-core` green. On the fixture, the rendered
`{{agent_memories}}` text from kioku recall equals the captured pre-migration text (diff is empty).
`rei agent memory list` returns the fixture memories. A `rei agent coach` run injects the memories
(visible in the prompt dump).

### Milestone M3 — Migrate historical data; decommission old modules

**Scope and result.** At the end of M3, every historical Rei memory and session appears through
kioku, and the old AgentMemory/AgentSession domain/projection/infrastructure/store-handler modules
are deleted (only the thin adapters remain). You write a one-shot executable that copies the
historical `agent_memory-<id>` and `agent_session-<id>` kiroku streams into kioku's
`kioku_memory-<id>` / `kioku_session-<id>` streams by decoding Rei's legacy JSON payloads through
Kioku's compatibility parsers and re-encoding native Kioku events, then rebuild kioku's read-model
projection from those streams. Counts match and coaching recall returns the same memories.

**Why copy streams, not rows (restated from the Decision Log).** kioku is event-sourced. The
streams are the source of truth; the `kioku_memories`/`kioku_sessions` rows are derived. EP-1's
compatibility parsers already decode Rei's `{"type":"agent_memory_recorded","data":{…}}` envelope
and re-prefix legacy TypeIDs into Kioku TypeIDs with the same UUID body. The migration re-encodes
those decoded values with Kioku's native codec because Keiro's recorded-event decoder checks the
stored event-type tag before it reaches the payload parser. The read-model rows are then recomputed
by kioku's own inline projection, guaranteeing they are identical to a fresh kioku write.

**The transform, concretely.** The historical keiro-migration `transform-context` tool no longer
exists (see Surprises) but its shape is the template. AgentMemory and AgentSession are
**boundary-stable leaf aggregates** (empty registers, no cross-stream events, 1:1 stream routing),
so the transform is still a one-to-one stream copy: decode one legacy event, encode one native
Kioku event, and append it to the corresponding Kioku stream.

Write a new executable `rei-kioku-migrate` (a stanza in `rei-core.cabal`, `hs-source-dirs:
kioku-migrate`, `main-is: Main.hs`, deps: `rei-core`, `kioku-core`, `kiroku-store`,
`hasql`, `optparse-applicative`, `text`, `containers`). It connects to the same DB (DSN from
`REI_PG_CONNECTION_STRING`, fallback `PG_CONNECTION_STRING`) with
`SET search_path TO "kiroku", public, pg_catalog`. It offers subcommands `copy-memories`,
`copy-sessions`, `copy-all`, `verify`. The copy, per aggregate:

1. Read every recorded event whose source stream category is `agent_memory` (resp.
   `agent_session`) in `$all` order via Kiroku's category read API.
2. Decode each legacy payload with `Kioku.Memory.EventStream.parseMemoryEvent` or
   `Kioku.Session.EventStream.parseSessionEvent`. These parsers read Rei's legacy tagged-union JSON
   and re-prefix `agent_memory_*` / `agent_session_*` TypeIDs to `kioku_memory_*` /
   `kioku_session_*`, preserving the TypeID UUID body.
3. Compute the destination stream from the decoded Kioku event's ID:
   `kioku_memory-kioku_memory_<UUID>` or `kioku_session-kioku_session_<UUID>`. Re-encode the event
   with Kioku's native codec, preserving source metadata plus causation/correlation IDs. Let Kiroku
   assign fresh event IDs; the old event UUID cannot be reused because Kiroku's `events.event_id` is
   globally unique.
4. Append only the missing tail of each destination stream. If a destination stream already has the
   same number of events, the copy is skipped for that stream. If it has fewer events, append the
   remaining source events at `ExactVersion`; if it has more, fail loudly because manual inspection is
   required.
5. After each destination stream copy, rebuild kioku's read-model projection by reading the
   destination stream, decoding native events with Kioku's codec, and applying
   `Kioku.Memory.ReadModel.memoryInlineProjection` or `Kioku.Session.ReadModel.sessionInlineProjection`.
   This makes `kioku_memories`/`kioku_sessions` reflect the copied streams without needing a separate
   projection-rebuild command.

**Verify.** The `verify` subcommand asserts:
- Row counts: `SELECT count(*) FROM agent_memories WHERE status='active'` equals
  `SELECT count(*) FROM kiroku.kioku_memories WHERE status='active'` (and likewise total counts, and
  for sessions). Counts must match.
- Replay equivalence: for a sample of memory ids, fold the old `agent_memory-<id>` stream through
  Rei's old evolve and the new `kioku_memory-<id>` stream through kioku's evolve and assert the
  logical state (content, type, confidence, tags, status) matches.
- Recall equivalence: for a sample intention and the workspace global scope, the set of active
  memory contents returned by the *old* `getActiveMemoriesForIntention`/`getWorkspaceMemories`
  equals the set returned by kioku's scoped recall through the adapter.

**Decommission.** Once verify passes, delete the now-unused old modules and their cabal entries:
`Rei.Modules.AgentMemory.Domain.{Types,Event,Command,Transducer}`,
`Rei.Modules.AgentMemory.Application.{StoreHandler,Errors}` (fold any still-needed error type into the
adapter), `Rei.Modules.AgentMemory.Infrastructure.{Table,ReadModel}`,
`Rei.Modules.AgentMemory.Projection.InlineReadModel`, and the same set for `AgentSession`. **Keep**
the adapters and **keep** `Rei.Modules.AgentMemory.Reactor.FilesystemProjection` (retargeted to read
the `kioku_memory` category and decode with kioku's codec — see Decision Log). **Do not touch
`Rei.Modules.AgentSchedule`.** Remove the deleted modules from `rei-core.cabal` `exposed-modules` and
the deleted specs from the `test-suite` `other-modules`. Drop the now-orphaned
`agent_memories`/`agent_sessions` read-model migrations? No — never edit applied migrations
(`CLAUDE.md`); leave the old tables in place (harmless; they simply stop being written). Optionally
add a new codd migration that drops them only after a soak period; default: leave them.

Retarget the filesystem reactor's category in `rei-cli/src/Rei/Cli/Commands/Worker/KirokuRunner.hs`
(the `agentMemoryStreamCategory cats` argument) to the `kioku_memory` category, and point its
`decodeAgentMemoryEvent` at kioku's codec / event type. Add a `kioku_memory` (and, if any reactor
needs them, `kioku_session`) category to `Rei.Config.StreamCategories` so the worker can subscribe.

**Commands for M3.** Build the tool (`cabal build rei-core:rei-kioku-migrate`), back up the DB
(`pg_dump`), run `cabal run rei-core:rei-kioku-migrate -- copy-all`, then
`cabal run rei-core:rei-kioku-migrate -- verify`, then `cabal build all && cabal test rei-core` after
the decommission edits, then a `rei agent coach` smoke test.

**Acceptance for M3.** `verify` prints all checks PASS and exits 0. After the decommission,
`cabal build all` exits 0, `cabal test rei-core` is green, and `rei agent memory list` returns the
historical memories (now served by kioku). `psql … -c "SELECT count(*) FROM kiroku.kioku_memories;"`
matches the pre-migration `agent_memories` count. `grep -rn "Rei.Modules.AgentMemory.Domain" rei-core
rei-cli` returns nothing (the domain modules are gone), while `grep -rn "AgentSchedule"` is unchanged.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/rei-project/rei` (the Rei repo root) in the nix
dev shell unless stated otherwise. The DB env vars (`PGHOST`, `PGDATABASE`, the connection string)
are exported by the shell; the project `CLAUDE.md` documents `just run-migrations` and the two-PG
topology (real prod vs. a disposable local copy). **Rehearse against a disposable local copy of prod
data first** (the `MEMORY.md` rehearsal recipe), never against real prod.

### Step 0 — M0 gate (in the kioku repo)

```bash
cd /Users/shinzui/Keikaku/bokuno/kioku
git rev-parse HEAD            # record this hash → it becomes the Rei pin tag
cabal build all
cabal test kioku-core         # ReiCompat group must pass
```

Expected: a 40-char commit hash, a clean build, and a passing `ReiCompat` test group. Record the
hash in the Decision Log.

### Step 1 — Pin kioku in Rei and add build-deps (M1)

Edit `/Users/shinzui/Keikaku/bokuno/rei-project/rei/cabal.project`: add the kioku
source-repository-package block (Plan of Work edit 1) with `tag: <M0-HASH>`. Edit
`/Users/shinzui/Keikaku/bokuno/rei-project/rei/rei-core/rei-core.cabal`: add `kioku-api`,
`kioku-core` to the library `build-depends`; add `kioku-migrations` to the `rei-migrations`
executable's `build-depends`.

```bash
cd /Users/shinzui/Keikaku/bokuno/rei-project/rei
cabal build rei-core 2>&1 | tail -20
```

Expected: a successful build. If the solver reports a kiroku/keiro version conflict from kioku's
`.cabal` bounds, add the package to `allow-newer` and note it in Surprises, then rebuild.

### Step 2 — Compose kioku migrations; create the tables (M1)

Read EP-1's `kioku-migrations/src/Kioku/Migrations.hs` for the exported migration value name (e.g.
`kiokuMigrations`). Edit Rei's migration runner (`rei-core/migrations/.../Main.hs` or wherever codd
application happens) to append `kiokuMigrations` to the composed set after the framework + Rei app
migrations. Then:

```bash
cd /Users/shinzui/Keikaku/bokuno/rei-project/rei
just run-migrations
psql -h "$PGHOST" -d "$PGDATABASE" -c '\dt kiroku.kioku_*'
```

Expected table list:

```text
            List of relations
 Schema |      Name       | Type
--------+-----------------+-------
 kiroku | kioku_memories  | table
 kiroku | kioku_sessions  | table
 kiroku | kioku_turns     | table
```

### Step 3 — Write the adapters + their spec; re-home writers (M1)

Create `rei-core/src/Rei/Modules/Agent/Memory/KiokuAdapter.hs` (and the session adapter) per Plan of
Work edit 4, the writer re-homing per edits 5–6, and the spec
`rei-core/test/Rei/Modules/Agent/Memory/KiokuAdapterSpec.hs`. Register the new modules in
`rei-core.cabal`. Then:

```bash
cd /Users/shinzui/Keikaku/bokuno/rei-project/rei
cabal build rei-core
cabal test rei-core 2>&1 | tail -15
```

Expected: build succeeds; the test summary shows all tests passing (record the count, e.g.
`1064 examples, 0 failures`) and includes the new `KiokuAdapter` group.

Smoke-test a write lands in kioku (run a coaching command that records a memory, or exercise the
writer in a test):

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -c "SELECT count(*) FROM kiroku.kioku_memories;"
```

Expected: count increases by the number of memories the run recorded.

### Step 4 — Move recall + CLI reads onto kioku; byte-stability check (M2)

Apply Plan of Work M2 edits 1–2. Build and test, then run the byte-stability comparison. The
comparison harness (a small test or a `ghci` snippet) builds the same fixture memory set in both the
old `agent_memories` table and kioku, renders `formatMemories` from each path, and diffs:

```bash
cd /Users/shinzui/Keikaku/bokuno/rei-project/rei
cabal build rei-core rei-cli
cabal test rei-core 2>&1 | tail -15
# byte-stability: capture old vs new rendered {{agent_memories}} on the fixture and diff
diff <(cat /tmp/agent_memories_old.txt) <(cat /tmp/agent_memories_kioku.txt) && echo "IDENTICAL"
```

Expected: tests green; the `diff` prints nothing and `IDENTICAL`. Then a live look:

```bash
rei agent coach --dump-prompt 2>&1 | sed -n '/### Agent Memories/,/^###/p'
```

(Use whatever prompt-dump/debug flag the CLI exposes; if none, render the section in a test.)
Expected: the `### Agent Memories` block lists the memories recalled from kioku.

### Step 5 — Build and run the one-shot stream-copy migration (M3)

Add the `rei-kioku-migrate` executable stanza to `rei-core.cabal` and write
`rei-core/kioku-migrate/Main.hs` per Plan of Work M3. Back up first (read-only against prod), then
run against the disposable local copy:

```bash
cd /Users/shinzui/Keikaku/bokuno/rei-project/rei
# Back up (read-only on prod), per the MEMORY.md rehearsal recipe:
pg_dump -Fc -Z9 -h /Users/shinzui/.local/state/postgresql -d rei -f .backups/prod_kioku_premig.dump
# Restore into the disposable local copy + run migrations (see MEMORY.md recipe), then:
cabal build rei-core:rei-kioku-migrate
cabal run rei-core:rei-kioku-migrate -- copy-all
cabal run rei-core:rei-kioku-migrate -- verify
```

Expected `copy-all` transcript (illustrative):

```text
copy-memories: read 482 events across 137 streams → wrote 482 events to kioku_memory streams (new $all 13853..14334)
copy-sessions: read 1190 events across 642 streams → wrote 1190 events to kioku_session streams (new $all 14335..15524)
rebuild: kioku_memories rows=137 kioku_sessions rows=642
```

Expected `verify` transcript:

```text
CHECK memories.count            PASS (active old=137 new=137; total old=137 new=137)
CHECK sessions.count            PASS (old=642 new=642)
CHECK memories.replay-sample    PASS (40/40 logical states equal)
CHECK recall.intention-sample   PASS (12/12 scopes: content sets equal)
CHECK all.gap-free              PASS ($all contiguous 1..15524)
OVERALL PASS
```

`verify` exits 0 on PASS, non-zero on any FAIL. It is idempotent: re-running `copy-all` inserts
nothing new (`ON CONFLICT DO NOTHING`) and `verify` still passes.

### Step 6 — Decommission old modules; final build/test (M3)

Delete the old AgentMemory/AgentSession domain/projection/infrastructure/store-handler modules and
their `rei-core.cabal` entries and specs (Plan of Work M3 "Decommission"), keeping the adapters and
the retargeted filesystem reactor. Retarget the reactor category and add `kioku_memory` to
`StreamCategories`.

```bash
cd /Users/shinzui/Keikaku/bokuno/rei-project/rei
cabal build all
cabal test rei-core 2>&1 | tail -15
grep -rn "Rei.Modules.AgentMemory.Domain\|Rei.Modules.AgentSession.Domain" rei-core rei-cli || echo "DOMAIN MODULES GONE"
grep -rn "AgentSchedule" rei-core rei-cli | head -3   # must still be present, unchanged
psql -h "$PGHOST" -d "$PGDATABASE" -c "SELECT count(*) FROM kiroku.kioku_memories;"
rei agent memory list | head
```

Expected: `cabal build all` and `cabal test rei-core` succeed (count unchanged from M1); the first
grep prints `DOMAIN MODULES GONE`; the AgentSchedule grep still shows AgentSchedule modules; the
kioku_memories count matches the pre-migration `agent_memories` count; `rei agent memory list` lists
the historical memories.


## Validation and Acceptance

Validation is layered to match the milestones, and every check is a behavior a human can observe.

**M1 — kioku wired, writes re-homed (suite green).** `cabal build rei-core` exits 0;
`psql … '\dt kiroku.kioku_*'` lists the three kioku tables; `cabal test rei-core` passes with a count
≥ the pre-migration count (record both). The `KiokuAdapterSpec` round-trip tests pass (every
`MemoryAnchor` and every `CoachingFocusType` round-trips; a `MemoryRecord` converts to the expected
`AgentMemoryRow`). A recorded memory appears in `kioku_memories`, not `agent_memories`.

**M2 — recall on kioku, byte-identical prompt.** With a fixture set of memories present in both the
old table and kioku, the rendered `{{agent_memories}}` text from the kioku path equals the
pre-migration text (empty `diff`). This is the headline behavioral proof: the `### Agent Memories`
prompt section is unchanged for the same memories. A live `rei agent coach` shows the section
populated from kioku. `rei agent memory list` returns the fixture memories.

The byte-stable contract is `PromptRenderer.formatMemories` (reproduced under Interfaces). The test
must exercise all four type groups (fact/pattern/preference/constraint), the empty case
(`_No agent memories recorded_`), and a memory whose `memoryType` is none of the four (silently
dropped). Because `formatMemories` renders `recordedAt` as UTC `%Y-%m-%d`, the fixture's `createdAt`
values must be identical across both paths.

**M3 — history migrated, modules gone.** `rei-kioku-migrate verify` prints `OVERALL PASS` and exits
0; counts match between `agent_memories` and `kioku_memories` (and sessions); a sample of memory ids
replays to equal logical state in both schemes; sample-scope recall returns equal content sets.
After decommission, `cabal build all` and `cabal test rei-core` are green, the AgentMemory/
AgentSession domain modules are absent (grep), AgentSchedule is untouched (grep), and
`rei agent memory list` returns the historical memories now served by kioku.

**Whole-plan acceptance (the user-visible outcome).** Run `rei agent coach` (or any coaching
command). The prompt's `### Agent Memories` section lists memories, every one of which is now stored
in `kiroku.kioku_memories`; the section text is identical to pre-migration for the same memories;
and `rei agent memory list` still shows every memory the user ever recorded. The Rei test suite is
green throughout.


## Idempotence and Recovery

The build/migration steps are safe to repeat. `just run-migrations` and codd are idempotent (codd
records applied migrations); re-running it does not re-apply kioku's base migration. Adding the kioku
pin and build-deps is a pure source edit; reverting is `git checkout` of `cabal.project` and the
`.cabal` files.

The M3 stream copy is idempotent at the destination-stream level: for each Kioku stream, the tool
checks the existing destination stream version and appends only the missing source-event tail. A
complete re-run appends nothing and reapplies the inline projection, which is idempotent because it
upserts memory/session rows or repeats terminal status updates. If a copy is interrupted, re-run
`copy-all`; streams that completed are skipped and streams with missing tails continue from their
recorded destination version. If a destination stream has more events than the source stream, the
tool fails loudly rather than guessing how to reconcile divergent history.

Always rehearse M3 against a disposable local copy of prod data (the `MEMORY.md` rehearsal recipe:
`pg_dump` prod read-only → restore into the local disposable DB → set the DB-level `search_path` →
`just run-migrations`). Take a `pg_dump -Fc` backup before running `copy-all` against any DB you care
about. Rollback of a botched copy is: restore the backup, or (since the copy only *adds*
`kioku_*` streams/rows and never touches `agent_*`) drop the `kioku_memory`/`kioku_session` streams
and truncate `kioku_memories`/`kioku_sessions`, then re-run.

The decommission step (deleting old modules) is the only one-way change in the tree; it is gated on
`verify` passing and is recoverable via git. Do it last, in its own commit, so reverting it is a
single `git revert`.


## Interfaces and Dependencies

**Libraries/modules and why.** Rei depends on kioku (`kioku-api`, `kioku-core`, and, for the
migration runner and the one-shot tool, `kioku-migrations`/`kioku-cli`) — the reusable agent-memory
engine this plan migrates onto. It continues to depend on the kikan event-sourcing stack (keiki,
keiro, kiroku) at Rei's existing pins; kioku is pinned to be coherent with those (kiroku `4312aa8c`,
keiro `f1d67a01`, keiki `bc987f4`).

**kioku public API the adapter must consume (MasterPlan IP-1; restated from EP-1).** Treat EP-1's
source as authoritative if a signature differs; the shapes are:

```haskell
-- Kioku.Api.Scope
newtype Namespace = Namespace Text
newtype ScopeKind = ScopeKind Text
data MemoryScope = ScopeGlobal Namespace | ScopeEntity Namespace ScopeKind Text
scopeNamespaceText :: MemoryScope -> Text
scopeKindText      :: MemoryScope -> Maybe Text
scopeRefText       :: MemoryScope -> Maybe Text
scopeFromColumns   :: Text -> Maybe Text -> Maybe Text -> MemoryScope

-- Kioku.Api.Types
data MemoryRecord = MemoryRecord
  { memoryId :: Text, agentId :: Text, sessionId :: Maybe Text, scope :: MemoryScope
  , memoryType :: Text, content :: Text, priority :: Int, confidence :: Text
  , tags :: Set Text, status :: Text, createdAt :: UTCTime }

-- Kioku.Memory (write API; each runs runCommandWithProjections with the inline projection)
--   record / supersede / archive / updateTags / updateConfidence
-- Kioku.Session (write API)
--   start / complete / fail / recordInteractive / recordTurn
-- Kioku.Recall (read API; EP-1 placeholder = scoped SQL)
--   getActiveByScope :: MemoryScope -> Eff es [MemoryRecord]
--   getGlobal        :: Namespace  -> Eff es [MemoryRecord]
--   getBySession     :: Text -> Eff es [MemoryRecord]
--   getByType        :: Namespace -> Text -> Eff es [MemoryRecord]   -- (confirm arity in EP-1)
-- Kioku.Id
--   type MemoryId = KindID "kioku_memory"; type SessionId = KindID "kioku_session"
--   genMemoryId / genSessionId
```

**Rei types that MUST stay byte-stable (do not change their shapes or rendering).** The recall→prompt
contract lives in two Rei functions. First, `ContextBuilder.memoryRowToSummary` (which the adapter
feeds via `memoryRecordToRow`):

```haskell
data MemorySummary = MemorySummary
  { memoryId :: !Text, memoryType :: !Text, content :: !Text
  , confidence :: !Text, tags :: ![Text], recordedAt :: !UTCTime }

memoryRowToSummary :: AgentMemoryRow -> MemorySummary
memoryRowToSummary row = MemorySummary
  { memoryId = row ^. #memoryId, memoryType = row ^. #memoryType, content = row ^. #content
  , confidence = row ^. #confidence, tags = decodeTags (row ^. #tags), recordedAt = row ^. #createdAt }
```

Second, the byte-stable renderer `PromptRenderer.formatMemories :: [MemorySummary] -> Text`. Its
output is the contract; reproduced verbatim:

```haskell
formatMemories :: [MemorySummary] -> Text
formatMemories [] = "_No agent memories recorded_"
formatMemories memories =
  let grouped  = groupMemoriesByType memories
      sections = concatMap formatSection grouped
   in T.intercalate "\n\n" sections
  where
    formatSection (_, []) = []
    formatSection (typeName, mems) =
      [ T.concat ["### ", typeName, "\n", T.intercalate "\n" (map formatMemory mems)] ]
    formatMemory m =
      T.concat ["- [", m ^. #confidence, "] ", m ^. #content, " (", formatDate (m ^. #recordedAt), ")"]
    groupMemoriesByType mems =
      [ ("Facts",       filter (\m -> m ^. #memoryType == "fact") mems)
      , ("Patterns",    filter (\m -> m ^. #memoryType == "pattern") mems)
      , ("Preferences", filter (\m -> m ^. #memoryType == "preference") mems)
      , ("Constraints", filter (\m -> m ^. #memoryType == "constraint") mems) ]
-- formatDate = formatTime defaultTimeLocale "%Y-%m-%d" (UTC, date-only)
```

To keep this byte-stable, the adapter's `memoryRecordToRow` must preserve `content`, `confidence`
(the strings `"high"/"medium"/"low"`), `memoryType` (`"fact"/"pattern"/"preference"/"constraint"`),
and `createdAt` exactly, and the recall functions must return the same **set and order** of active
memories per scope as Rei's old queries did (M2's `take` caps and `deduplicateMemories` order live in
`ContextBuilder` and are unchanged).

**Adapter contract (the new types/functions that must exist at the end of M1).** In
`Rei.Modules.Agent.Memory.KiokuAdapter`:

```haskell
reiNamespace    :: Namespace
anchorToScope   :: MemoryAnchor -> MemoryScope
scopeToAnchor   :: MemoryScope -> Either Text MemoryAnchor
focusToText     :: CoachingFocusType -> Text
focusFromText   :: Text -> Maybe CoachingFocusType
memoryRecordToRow :: MemoryRecord -> AgentMemoryRow
sessionScope    :: Maybe IntentionId -> MemoryScope
-- recall wrappers used by ContextBuilder (same names/types it imports today):
getWorkspaceMemories          :: (recall constraint) => Eff es [AgentMemoryRow]
getActiveMemoriesForIntention :: (recall constraint) => IntentionId -> Eff es [AgentMemoryRow]
getActiveMemories             :: (recall constraint) => Eff es [AgentMemoryRow]
```

**Scope mapping (MasterPlan IP-2), exact:**
`AnchorToIntention iid → ScopeEntity (Namespace "rei") (ScopeKind "intention") (KindID.toText iid)`;
`AnchorToHabit hid → ScopeEntity (Namespace "rei") (ScopeKind "habit") (KindID.toText hid)`;
`WorkspaceGlobal → ScopeGlobal (Namespace "rei")`. Sessions:
`subjectRef = fmap KindID.toText intentionId`, `scope = sessionScope intentionId`, and the
`CoachingFocusType` maps to the snake_case `focus` string it already serializes to.

**Stream naming (M3 transform).** Source streams are `agent_memory-<typeid>` /
`agent_session-<typeid>` (category = text before the first `-`; the typeid separates prefix from id
with `_`). Destination streams are `kioku_memory-<kioku-typeid>` / `kioku_session-<kioku-typeid>`
with the same UUID body. EP-1 builds kioku streams as `kioku_memory-<MemoryId text>` /
`kioku_session-<SessionId text>` (`Kioku.Id`). The category strings `kioku_memory`/`kioku_session`
must be added to `Rei.Config.StreamCategories` for the retargeted filesystem reactor to subscribe.

**Cabal/pin dependencies.** `cabal.project` gains the kioku source-repository-package pin (tag = M0
hash, no extra kiroku/keiro pin — Rei's govern). `rei-core.cabal`: library gains `kioku-api`,
`kioku-core`; `rei-migrations` exe gains `kioku-migrations`; the new `rei-kioku-migrate` exe gains
`kioku-core`, `kiroku-store`, `hasql`, `optparse-applicative`, `containers`. Migration
composition appends kioku's exported migration value after the framework + Rei app migrations in the
`kiroku` schema.


---

*Revision note (2026-06-24, initial authoring):* This plan was drafted from the binding contracts in
MasterPlan #1 (IP-1 API surface, IP-2 scope mapping, IP-3 migration composition, IP-5 pin-set, IP-6
codec backward-compat) and EP-1 (`docs/plans/1`), and from a read of Rei's live AgentMemory/
AgentSession modules, their two consumers (`ContextBuilder.hs`, `PromptRenderer.hs`), and the CLI
handler. The most consequential discovery, recorded in Surprises, is that Rei's `rei-history-transform`/
`CutoverConfig` tooling has been **deleted** (commit `51a08f27`) since the original keiro migration
completed — so M3's data migration is a *new* one-shot executable modeled on the historical
`transform-context` shape, not an extension of live tooling. The pin reconciliation (kioku's kiroku
`322096c8` vs Rei's `4312aa8c`) is resolved by keeping Rei's pin (Decision Log). The byte-stable
contract is `PromptRenderer.formatMemories`, reproduced verbatim above.*

*Revision note (2026-06-24, M3 migration-tool slice):* Implementation corrected the M3 transform
from "raw stream rename with byte-identical event JSON" to "decode Rei legacy payload, re-encode
native Kioku event, append to Kioku stream, rebuild Kioku inline projection." The change is required
because Keiro checks the stored event-type tag before Kioku's compatibility payload parser and
because Kiroku event IDs are globally unique. Progress, Surprises, Decision Log, Plan of Work,
Idempotence, and dependency text were updated accordingly.

*Revision note (2026-06-24, M3 disposable rehearsal slice):* A focused disposable-Postgres test was
added for `rei-kioku-migrate`. It records legacy streams with Rei's old transducers, runs the copy
and verifier, checks key Kioku rows, and proves idempotency on a second copy run. The rehearsal
forced two correctness fixes: row-equivalence ID re-prefixing in the verifier and Kioku legacy
session focus normalization. Progress, Surprises, Decision Log, and Outcomes were updated with the
evidence and remaining production-copy rehearsal gap.*


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
- **Plan-specific:** EP-1's compatibility parsers understand Rei's historical `eventAesonOptions`
  payloads, but the M3 tool must call those payload parsers directly and then re-encode native
  Kioku events because Keiro checks the stored event-type tag before payload decoding. Rei already
  follows the same record and codec conventions, so the thin Rei-side adapters inherit them
  unchanged.
