---
id: 5
slug: mori-agent-exec-with-kioku-memory
title: "mori agent exec with kioku Memory"
kind: exec-plan
created_at: 2026-06-24T16:31:00Z
intention: "intention_01kvx5py1yeanvyn7xh58epfnt"
master_plan: "docs/masterplans/1-kioku-reusable-agent-memory-session-library.md"
---

# mori agent exec with kioku Memory

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

**mori** is a command-line tool that knows about a *registry* of source-code repositories
("projects") on the machine and lets you organize them into named **groups**. It already has a
command, `mori registry exec --group GROUP -- <cmd>`, that runs an ordinary shell command once
inside each repository of a group. It also already has a family of `mori agent ...` commands that
launch the `claude` command-line program (Anthropic's "Claude Code" CLI agent) with a tailored
prompt and project context.

After this change a user can run **one** new command:

```bash
mori agent exec --group infra-libs -p "Audit each repo's CI workflow and note any flaky-test handling"
```

and mori will, for **every** repository in the group `infra-libs`, in sequence:

1. **Recall** what the agent has already learned — both group-wide learnings (e.g. "all these
   repos use the same `just ci` recipe") and repo-specific learnings from prior runs — out of a
   durable **memory** store, and inject those learnings into the prompt it hands to `claude`.
2. Launch `claude` with its working directory (`cwd`) set to that repository, the recalled
   memory in its system prompt, and permission to call back into `mori agent memory record` to
   **write new learnings**.
3. Move to the next repository, which now recalls the learnings the previous repository just
   recorded — so the run gets smarter as it proceeds.

The durable memory is provided by **kioku** (記憶, "memory"), a standalone event-sourced memory
library this initiative is building (see the MasterPlan
`docs/masterplans/1-kioku-reusable-agent-memory-session-library.md`). A second invocation of the
same command (or `mori agent exec --group infra-libs --follow-up -p "...now fix what you found"`)
recalls the *prior run's* session and memories, so a follow-up pass builds on the first.

The user-visible payoff, demonstrable end to end in a terminal transcript: a fact recorded while
processing repository #1 is visibly injected into the prompt for repository #2, and
`mori agent memory list --group infra-libs` prints the accumulated learnings after the run. That
observable behavior — cross-repo learning that accumulates and resurfaces — is the acceptance
criterion for this plan.

This plan (EP-5) is a **consumer integration**: it hard-depends on EP-1 (which builds kioku) and
soft-depends on EP-2 (which makes kioku's recall semantic/hybrid). EP-5 does not build kioku; it
*pins, links, and calls* kioku, and adds the new `mori agent exec` and `mori agent memory`
commands plus the wiring that records and recalls memory around each repo run.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0 (pin reconciliation): mori now consumes local `kioku-api`, `kioku-core`, and
      `kioku-migrations` packages, reconciles current `kioku-core`'s transitive `shikumi` and
      Baikai package needs under mori's pin-set, adds `kioku-api`/`kioku-core` to `mori-core`'s
      `build-depends`, and applies kioku's read-model schema in mori's test database setup.
      Verification: `cabal build mori-core`; `cabal test mori-core-test
      --test-options='-p TestSupport.Database'`, proving `kiroku.kioku_memories`,
      `kiroku.kioku_sessions`, and `kiroku.kioku_turns` exist in a freshly migrated mori test DB.
- [x] M1: add `AgentExec ExecOpts'` to `Mori.Command.Agent.AgentCommand`, a `command "exec"`
      stanza in `agentCommandParser`, and a handler in `runAgent` that resolves
      `--group GROUP` → repo paths (reusing `Mori.Command.Registry.Exec.selectProjects`) and runs
      `claude` once per repo **in sequence** with `cwd` set to each repo path. Observable:
      `mori agent exec --group <g> --dry-run` lists the repos; without `--dry-run` it visits each
      (verify with a trivial prompt and `--debug`). No memory yet. Completed 2026-06-24:
      `mori agent exec --group frontend --filter intentui/intentui --dry-run` listed the selected
      repo, `--debug` printed the per-repo prompt with path header, and a non-debug run with a
      temporary fake `claude` printed `/Users/shinzui/Keikaku/hub/ui-libraries/intentui-project`
      from the child process, proving `cwd` propagation. Verification: mori `cabal build mori-cli`;
      `cabal test mori-cli-test --test-options=-p --test-options=validateAgentExecIntent`;
      `cabal test mori-cli-test --test-options=-p --test-options=buildAgentExecPrompt`;
      `cabal test mori-cli-test` (317 tests).
- [ ] M2: add `mori agent memory record` and `mori agent memory list` subcommands over kioku's
      `Kioku.Memory.record` / `Kioku.Recall.getActiveByScope`. Record a memory in scope
      `mori/group/<gid>` from the CLI and list it back. Grant `claude` access to
      `mori agent memory record` via `--allowedTools` in the exec handler.
- [ ] M2: open a kioku **session** (`Kioku.Session.start`/`complete`/`failSession`) around each repo run,
      scope `mori/repo/<projectId>`, focus = the prompt/skill label, `subjectRef = <group name>`.
      A `psql` query shows one `kioku_sessions` row per repo, `status='completed'`.
- [ ] M3: before each repo run, recall group-scoped + repo-scoped memories and inject them into the
      `--append-system-prompt`. Demonstrate: a memory recorded while processing repo #1 is visibly
      present in the injected context for repo #2 (shown with `--debug`).
- [ ] M3 (follow-up): `--follow-up` recalls the prior run's session id (newest session for the
      group scope) and chains it via `previousSessionId`, and recalls the prior run's memories so a
      second invocation builds on the first. Demonstrate with two consecutive invocations.
- [ ] Tests: pure unit tests for repo-ordering, prompt-injection assembly, and scope mapping; a
      DB-gated integration test that records a memory in one scope and recalls it in another.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Current kioku-core pulls EP-3 dependencies.** Although EP-5 only needs the base memory/session
  API, current `kioku-core` imports the distillation stack introduced by EP-3: `shikumi`,
  `shikumi-trace`, `shikumi-cache`, `baikai-claude`, `baikai-effectful`, and `baikai-openai`.
  mori's build therefore needs those local/source packages available even for M0. Evidence:
  `cabal build mori-core`.

- **mori's Baikai pin is newer than kioku's standalone pin.** The existing mori Baikai revision
  `d0ac866907239189d8f30efc42ddb6cd14ba0e4d` is a descendant of kioku's standalone Baikai
  revision `a219b92278d8e475b0e45c602e65dbf108cf8dc1`, so M0 kept mori's consumer pin and
  expanded the Baikai `subdir` list instead of downgrading mori. Evidence: local Baikai
  `git merge-base --is-ancestor` checks and `cabal build mori-core`.

- **`claude-1.4.0` has a narrow `http-client-tls` bound conflict in mori.** mori already resolves
  `http-client-tls-0.4.0`, while `claude-1.4.0` declares `<0.4`; M0 added
  `allow-newer: claude:http-client-tls` to keep the consumer build on mori's existing plan.

- **`--dry-run` must bypass prompt/skill validation.** The first M1 smoke surfaced that
  `mori agent exec --group frontend --filter intentui/intentui --dry-run` failed because the
  handler validated `--prompt`/`--skill` before rendering the repo list. The handler now resolves
  projects and renders dry-run output before requiring an execution intent; non-dry-run still
  enforces the XOR rule.


## Decision Log

Record every decision made while working on the plan.

- Decision: The memory **capture mechanism** for v1 is the **explicit-tool path** (option (a) in
  the MasterPlan EP-5 brief): the spawned `claude` records its own learnings by calling
  `mori agent memory record`, which is granted via `--allowedTools`. The alternative
  post-run LLM extraction (option (b)) is deferred to EP-3 (the distillation pyramid).
  Rationale: the explicit-tool path mirrors how Rei's interactive agent calls `rei agent memory`
  (`rei-cli/src/Rei/Cli/Commands/Agent/`), needs no extra LLM round-trip, and makes the recorded
  memory deterministic and inspectable. Heavy unsupervised extraction is exactly what EP-3 is for.
  Date: 2026-06-24

- Decision: **`--jobs` defaults to `1` (sequential)** for `mori agent exec`, unlike
  `mori registry exec` whose default is also 1 but which is routinely run parallel. Here
  sequential is load-bearing: the cross-run learning effect ("repo #2 recalls what repo #1 just
  recorded") only holds when repos run one at a time. `--jobs N > 1` is permitted but documented
  as disabling the accumulate-as-you-go guarantee (each parallel worker only sees memories that
  existed at run start).
  Rationale: the headline value of this plan is sequential accumulation; parallelism is an escape
  hatch, not the default.
  Date: 2026-06-24

- Decision: mori's kiroku pin (`4312aa8c`) is **+2 commits ahead** of the kiroku pin EP-1 copies
  from kizashi (`322096c8` is kiroku origin/master, but the rei/mori-tested revision is
  `4312aa8`). EP-5 makes **mori the pin authority**: the `kioku` source-repository-package is
  added to mori's `cabal.project`, and mori's existing kiroku/keiki/keiro/shibuya pins
  (`kiroku 4312aa8`, `keiki bc987f46`, `keiro f1d67a01`, `shibuya 3f276ee1`) govern the whole
  build plan. keiki and keiro already match EP-1 exactly; the kiroku delta is +2 commits that do
  not touch `kiroku-store` (a `kiroku-metrics` release + a docs commit, per mori's own
  cabal.project comment), so kioku-core compiles unchanged against mori's kiroku pin.
  Rationale: a single repo's `cabal.project` must have one coherent pin-set; adding kioku to mori
  means kioku resolves against mori's already-reconciled stack, not a second one. This is exactly
  the IP-5 "consumer mid-keiro-migration must reconcile" obligation.
  Date: 2026-06-24

- Decision: kioku's read-model tables live in the **`kiroku` schema** (kizashi convention,
  `kioku_memories`/`kioku_sessions`/`kioku_turns`), while mori's own read models live in
  `public`. mori already opens its kiroku store with `extraSearchPath = ["public"]`
  (`Mori.Effects.Store.moriStoreConnectionSettings`), so the store pool's search path is
  `kiroku, public`. kioku's tables are in `kiroku` (first on the path) and mori's are in `public`
  — they coexist on one pool with no qualification conflicts. EP-5 therefore reuses mori's
  existing `KirokuStore` and `runMoriEffWithStore` to drive kioku writes/reads; it does **not**
  open a second store or pool.
  Rationale: one DB, one store, one pool keeps the integration minimal and lets a kioku memory
  write and a mori read share a connection. The schema separation is already enforced by kioku's
  base migration (`SET search_path TO kiroku`).
  Date: 2026-06-24

- Decision: EP-5 applies kioku's read-model schema the **same way mori applies kiroku/keiro
  framework schema** — by locating kioku's `sql-migrations` directory and running its `.sql`
  scripts as plain SQL (mori's `mori-core/test/TestSupport/Database.hs` already does this for
  kiroku and keiro), and by composing kioku's migration scripts into mori's production migration
  path. mori's production migrator (`mori-core/migrations/Main.hs`) runs TypeID + MessageDB + PGMQ
  + embedded hasql-migration scripts; the kiroku/keiro/kioku framework SQL is applied alongside.
  Rationale: kioku's tables are just more read-model DDL on the shared DB; reusing mori's existing
  "run the framework `sql-migrations`" plumbing avoids inventing a codd path mori does not yet
  have in its production migrator.
  Date: 2026-06-24

- Decision: `--prompt`/`-p` and `--skill` are mutually exclusive; exactly one must be supplied
  (mirroring how the existing agent commands take a single intent). `--skill NAME` is rendered
  into the prompt as an instruction to run that Claude Code skill (`/NAME`), reusing the skill
  directories already exposed via `Baikai.Kit.Session.agentDirsForSession`.
  Rationale: keeps the command shape simple and consistent with the other `mori agent` verbs.
  Date: 2026-06-24

- Decision: M0 consumes kioku through local `optional-packages` in mori's `cabal.project`, keeps
  mori's existing Baikai revision, and expands that Baikai pin's `subdir` list for the subpackages
  current `kioku-core` needs. It also includes local `shikumi`, `shikumi-cache`, and `shikumi-trace`
  packages and adds a narrow `allow-newer: claude:http-client-tls`.
  Rationale: mori is the consumer and pin authority for this integration; keeping one coherent
  build plan is less risky than introducing a second ecosystem pin-set.
  Date: 2026-06-24

- Decision: M1 keeps actual execution sequential even though the parser accepts `--jobs`; passing
  `--jobs > 1` emits a warning until the memory-aware M3 slice can make the parallel semantics
  explicit.
  Rationale: the plan's user-visible value depends on sequential accumulation, and the M1 command
  exists to prove repo selection, prompt assembly, and `cwd` propagation before adding memory.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-06-24: M0 completed in mori. mori now builds against local kioku packages, applies kioku's
  read-model SQL migrations in its ephemeral test DB after kiroku and keiro, and has an integration
  test proving the three kioku read-model tables are present. Verification:
  `cabal build mori-core`; `cabal test mori-core-test --test-options='-p TestSupport.Database'`.

- 2026-06-24: M1 completed in mori. `mori agent exec --group` now resolves a registry group via
  `Mori.Command.Registry.Exec.selectProjects`, supports prompt/skill XOR, dry-run, debug prompt
  printing, path-missing skips, fail-fast, and sequential non-debug `claude` launches with `cwd` set
  to each repo path. Verification: mori `cabal build mori-cli`; focused `mori-cli-test` patterns
  `validateAgentExecIntent` and `buildAgentExecPrompt`; full `cabal test mori-cli-test` (317
  tests); `mori agent exec --group frontend --filter intentui/intentui --dry-run`; `mori agent exec
  --group frontend --filter intentui/intentui -p "print your working directory" --debug`; and a
  non-debug smoke with a temporary fake `claude`.


## Context and Orientation

This section assumes you have never seen mori or kioku. Read it fully before editing.

### Where things live

- **mori** is a Haskell project at `/Users/shinzui/Keikaku/bokuno/mori-project/mori`, built with
  GHC 9.12.4 / the GHC2024 language edition, organized into cabal packages `mori-types`,
  `mori-core` (the domain and read models), and `mori-cli` (the `mori` binary). Its build plan is
  declared in `/Users/shinzui/Keikaku/bokuno/mori-project/mori/cabal.project`.
- **kioku** is the new memory library this initiative builds, at
  `/Users/shinzui/Keikaku/bokuno/kioku`, as four packages `kioku-api`, `kioku-core`, `kioku-cli`,
  `kioku-migrations`. EP-1 (`docs/plans/1-kioku-scaffold-and-core-extraction.md`) creates it.
  **This plan does not modify kioku; it consumes it.** If kioku is not yet built when you start,
  EP-1 is your hard dependency — stop and complete it first.
- This ExecPlan file lives in the **kioku** repo at `docs/plans/5-...md` for organizational
  reasons (the MasterPlan and its siblings are tracked there), but **all code changes in this plan
  are made in the mori repository**, not in this docs repo.

### Terms of art (defined in plain language)

- **Project / repository / namespace / qualified name.** mori's registry stores *projects*. Each
  project has a `namespace` (an owner-like label, e.g. `shinzui`), a `name`, and a filesystem
  `path` (where the repo is checked out). Its *qualified name* is `<namespace>/<name>`. A project
  is identified internally by a `ProjectId` (a TypeID — see below).
- **Group.** A named set of projects. mori models groups as an event-sourced aggregate in
  `mori-core/src/Mori/Modules/Group/`. A `GroupId` is `KindID "grp"`. The read-model query
  `getGroupMembers :: GroupId -> Eff es [ProjectId]` returns a group's member project ids, and
  `getGroupByName :: GroupName -> Eff es (Maybe GroupRow)` resolves a name to its row (carrying
  the `GroupId`). The higher-level query
  `getProjectsByGroupNameWithCount :: Text -> Eff es [ProjectListRow]` (in
  `mori-core/src/Mori/Modules/Project/Project.hs`) resolves a group name directly to its member
  projects-with-paths in one call.
- **`ProjectListRow`.** The read row returned by the project queries
  (`mori-core/src/Mori/Modules/Project/Infrastructure/Table.hs`). Its fields include
  `projectId :: ProjectId`, `namespace :: Text`, `name :: Text`, `path :: Text`, `projectType`,
  `origin`, and several counts. EP-5 needs `projectId` (for the repo memory scope), `namespace` +
  `name` (for display), and `path` (for `cwd`).
- **TypeID / KindID.** mori's id scheme. A `KindID "grp"` renders as text like `grp_01j…` and a
  `ProjectId` (a `KindID "project"` or similar prefix) renders as `project_01j…`. The function
  `Data.KindID.toText` turns a `KindID` into the `Text` that kioku's `MemoryScope` stores.
- **`claude` (Claude Code CLI).** The Anthropic command-line agent that mori launches as a
  subprocess. It is invoked as the program `claude` with flags assembled by
  `buildClaudeArgs :: [FilePath] -> [String] -> String -> [String]` in
  `mori-cli/src/Mori/Command/Agent.hs`. Those flags are: `--permission-mode acceptEdits`, one
  `--add-dir <dir>` per agent/skill directory, `--allowedTools <tool> ...` (which tools the agent
  may call without prompting), and `--append-system-prompt <text>` (extra system-prompt text the
  caller injects). The subprocess is created with `System.Process.proc "claude" args`, and its
  working directory is set by the `cwd` field of the `CreateProcess` record.
- **kiroku store / `KirokuStore` / event sourcing.** mori stores events in **kiroku**, a
  PostgreSQL-backed append-only event log, and derives queryable *read-model tables* from those
  events. A `KirokuStore` (from `Kiroku.Store.Connection`) bundles the connection pool. mori opens
  it with `moriStoreConnectionSettings` (schema `kiroku`, `extraSearchPath = ["public"]`) so that
  mori's `public.*` read-model tables are reachable on the same pool — see
  `mori-core/src/Mori/Effects/Store.hs`. **kioku's read-model tables live in the `kiroku` schema**
  and so are reachable on that same pool without extra configuration.
- **Effect runners.** mori interprets its effectful (`Effectful`) actions with two runners in
  `mori-core/src/Mori/Effects.hs`: `runMoriEffWithPool pool cats action` (the legacy message-db
  path, used by the read queries `mori agent exec` already calls) and `runMoriEffWithStore store
  cats action` (the kiroku-store path). kioku's write/read API runs in `Effectful` over the kiroku
  `Store`/`Hasql` effects, which is exactly the row `runMoriEffWithStore` provides — so EP-5 calls
  kioku through `runMoriEffWithStore`.
- **`MemoryScope`.** kioku's host-agnostic addressing of *whose* memory a row is, defined in
  `kioku-api` (`Kioku.Api.Scope`):

  ```haskell
  newtype Namespace = Namespace Text                 -- "mori"
  newtype ScopeKind = ScopeKind Text                 -- "group" | "repo"
  data MemoryScope
    = ScopeGlobal Namespace                           -- whole-namespace
    | ScopeEntity Namespace ScopeKind Text            -- kind tag + entity id as text
  ```

  EP-5 maps mori's ids into it: a group's learnings live at
  `ScopeEntity (Namespace "mori") (ScopeKind "group") (KindID.toText gid)`; a repo's at
  `ScopeEntity (Namespace "mori") (ScopeKind "repo") (KindID.toText projectId)`.

### What already exists (the machinery EP-5 reuses)

- **Multi-repo selection + per-repo loop**: `mori-cli/src/Mori/Command/Registry/Exec.hs`. Its
  `selectProjects :: Pool.Pool -> StreamCategories -> ExecOpts -> IO [ProjectListRow]` resolves a
  group (via `getProjectsByGroupNameWithCount`) to projects-with-paths and applies client-side
  filters. Its `runOne :: ExecOpts -> ProjectListRow -> IO ExecResult` spawns a subprocess with
  `cwd = Just (T.unpack (proj ^. #path))`, capturing stdout/stderr/exit, and skips missing paths
  (`doesDirectoryExist`). Its `runProjects`/`runSequentialFailFast`/`runBounded` drive the
  sequential, fail-fast, and bounded-parallel loops. EP-5 reuses `selectProjects` verbatim and the
  loop *shape* (a sequential traversal that calls a per-repo runner), but its per-repo runner
  launches `claude` (with memory) instead of a bare command.
- **Claude subprocess invocation**: `mori-cli/src/Mori/Command/Agent.hs` (~2700 lines).
  `runAgent :: Pool.Pool -> AgentCommand -> IO ()` dispatches each `AgentCommand` constructor to a
  handler. `buildClaudeArgs` assembles the `claude` flags. The handler `runAgentAsk` already
  demonstrates the exact pattern EP-5 needs: it builds `proc "claude" (buildClaudeArgs ...)` and
  sets `cwd = sessionCwd` on the `CreateProcess`, then `createProcess`/`waitForProcess`. Agent and
  skill directories are obtained via `Baikai.Kit.Session.agentDirsForSession` (imported as
  `KitSession`). Prompts are embedded with `Data.FileEmbed.embedStringFile`.
- **Group + Project read models**: `getGroupByName`, `getGroupMembers`, `getProjectByProjectId`
  (in `Mori.Modules.Group.Group` and `Mori.Modules.Project.*`), all run via `runMoriEffWithPool`.
- **CLI wiring**: `mori-cli/src/Mori/Cli.hs` has a top-level `data Command` whose `Agent
  !AgentCommand` arm is dispatched by `Agent agentCmd -> do pool <- setupPool; runAgent pool
  agentCmd`. `setupPool :: IO Pool.Pool` builds the pool from `MORI_PG_CONNECTION_STRING`. The
  `agent` subcommand is wired via `command "agent" (info (Agent <$> agentCommandParser) ...)`.
- **Cutover routing (background)**: mori is mid-migration from message-db to kiroku
  (`Mori.Config.CutoverConfig`, env `MORI_KIROKU_CONTEXTS`, `routeContext`/`BoundedContext`). EP-5
  does **not** add a new bounded context: kioku memory is not one of mori's seven aggregates; it is
  an auxiliary store EP-5 always writes to via the kiroku `Store`. The cutover gate governs mori's
  *own* aggregates, not kioku.

### What this plan creates

- A `kioku` pin in mori's `cabal.project` plus `kioku-api`/`kioku-core` build-deps in `mori-core`.
- A new `AgentExec ExecOpts'` constructor on `AgentCommand`, its parser, and its handler.
- New `mori agent memory record` / `mori agent memory list` subcommands and handlers.
- A small new module `mori-cli/src/Mori/Command/Agent/Exec.hs` (or a section of `Agent.hs`)
  holding the exec handler, the scope mapping, the recall-and-inject logic, and the session
  lifecycle.
- Application of kioku's schema in mori's test DB setup and production migrator.


## Plan of Work

The work is four milestones: M0 makes mori build against kioku and the kioku tables exist; M1
delivers `mori agent exec --group` running sequentially per-repo with `cwd` (no memory); M2 adds
the `mori agent memory` CLI and the per-repo kioku session; M3 wires recall-and-inject plus
follow-up chaining. Each milestone leaves mori building (`cabal build all` in the mori repo) and is
independently verifiable.

Unless stated otherwise, **run every command from
`/Users/shinzui/Keikaku/bokuno/mori-project/mori`** inside mori's nix dev shell (which exports the
PG env vars and `MORI_PG_CONNECTION_STRING`).

### Milestone M0 — Pin reconciliation and schema, mori builds against kioku

**Scope and result.** At the end of M0, mori's `cabal.project` pins `kioku`, `mori-core` depends
on `kioku-api` and `kioku-core`, `cabal build mori-core` succeeds, and the kioku read-model tables
(`kioku_memories`, `kioku_sessions`, `kioku_turns`) exist in a freshly migrated mori test database
in the `kiroku` schema. No new mori commands yet; the goal is a green build linking kioku and a
migrated schema.

**The pin.** Add to `/Users/shinzui/Keikaku/bokuno/mori-project/mori/cabal.project`, alongside the
existing keiro/kiroku stanzas, a kioku stanza. Because kioku and mori are sibling working
directories on the same machine and you want to iterate on both, pin kioku as a **local
optional-package path** the same way mori already pins its transitive `codd`/`hasql-notifications`
forks (the `optional-packages:` block at the top of mori's `cabal.project`). Add the four kioku
package `.cabal` files:

```text
optional-packages:
  /Users/shinzui/Keikaku/hub/haskell/codd-project/codd/codd.cabal
  /Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql-notifications/hasql-notifications.cabal
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-api/kioku-api.cabal
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-core/kioku-core.cabal
  /Users/shinzui/Keikaku/bokuno/kioku/kioku-migrations/kioku-migrations.cabal
```

(`kioku-cli` is not needed by mori and is omitted.) Once kioku is published as a git repo, this
can become a `source-repository-package` git pin with a tag that matches the same stack; for now
the local path is correct and lets EP-5 and EP-1 co-develop. Record in the Decision Log whichever
form you use.

**Pin coherence (IP-5).** kioku's own `cabal.project` (EP-1) pins keiki `bc987f46`, keiro
`f1d67a01`, kiroku `322096c8`, shibuya `3f276ee1`. mori already pins keiki `bc987f46` (match),
keiro `f1d67a01` (match), kiroku `4312aa8c` (mori is +2 commits ahead — those two commits are a
`kiroku-metrics` release and a docs commit that do not touch `kiroku-store`, per mori's own
cabal.project comment), and shibuya `3f276ee1` (match). When kioku is added as a local
`optional-packages` path, it has **no pins of its own in mori's plan** — it resolves entirely
against mori's `source-repository-package` set, which is the single source of truth for the
combined build. So the kiroku +2 delta is harmless: kioku-core's imports of `Kiroku.Store.*`,
`Keiro.*`, `Keiki.*` resolve against mori's pins. If the build surfaces an unexpected API
mismatch (e.g. a `kiroku-store` type kioku-core used that changed between `322096c8` and
`4312aa8c`), record it in Surprises & Discoveries and either (a) bump kioku-core's code to the
mori pin, or (b) bump mori's kiroku pin — prefer (a) since mori's pin is the rei/mori-tested one.

**The build-deps.** In `mori-core/mori-core.cabal`, add `kioku-api` and `kioku-core` to the
`library` stanza's `build-depends`. (Add them to `mori-cli` too only if the exec handler ends up
in `mori-cli` and imports kioku types directly; prefer putting the kioku-facing glue in
`mori-core` so `mori-cli` keeps depending on `mori-core` and gets kioku transitively.)

**The schema.** kioku's tables must exist in mori's database. Two places:

1. *Test DB setup* — `mori-core/test/TestSupport/Database.hs` already locates the kiroku and keiro
   `sql-migrations` directories and runs their `.sql` scripts (`runMigrationScripts`). Add a third
   call that locates kioku's `sql-migrations` directory (the EP-1 path
   `/Users/shinzui/Keikaku/bokuno/kioku/kioku-migrations/sql-migrations`, with the same
   relative-path candidate list pattern) and runs its scripts **after** the kiroku run (kioku's
   base migration does `SET search_path TO kiroku` and `CREATE TABLE IF NOT EXISTS`, so it only
   needs the `kiroku` schema to already exist, which the kiroku run created).
2. *Production migrator* — `mori-core/migrations/Main.hs`. After the existing TypeID/MessageDB/PGMQ
   + embedded-script steps, add a step that applies the kioku read-model `.sql` scripts. The
   simplest reliable form: read the kioku `sql-migrations` files (located the same way as the test
   setup, or embedded via `Data.FileEmbed.embedDir` into a small `EmbeddedKiokuMigrations` module)
   and run each with the existing `runMigration` helper. Since kioku's base SQL is
   `CREATE TABLE IF NOT EXISTS`, re-running is a no-op. **Note the `embedDir` recompile caveat**
   (mori's `EmbeddedMigrations.hs` documents it): a newly added embedded file is silently missed
   until the embedding module is recompiled — `just run-migrations` already `rm -rf`s the
   migrations build dir to force this.

**Acceptance for M0.** From the mori repo: `cabal build mori-core` exits 0 (proving kioku links).
Run mori's test DB setup (e.g. the existing DB-integration test target, or a one-off `cabal repl`
that calls the test database bootstrap) and then
`psql "$MORI_PG_CONNECTION_STRING" -c '\dt kiroku.kioku_*'` lists `kioku_memories`,
`kioku_sessions`, `kioku_turns`.

### Milestone M1 — `mori agent exec --group` runs sequentially per-repo (no memory)

**Scope and result.** At the end of M1, `mori agent exec --group GROUP -p "<prompt>"` resolves the
group to its repos and launches `claude` once per repo in sequence, each with `cwd` set to that
repo's path. `--dry-run` lists the repos without running; `--debug` prints the assembled prompt
instead of launching. There is no memory yet. This is the observable "it visits each repo" result.

**The options type.** Add to `mori-cli/src/Mori/Command/Agent.hs` a new options record. Name it
`ExecOpts'` (with a prime) to avoid colliding with `Mori.Command.Registry.Exec.ExecOpts`, or place
the exec handler in a new module `mori-cli/src/Mori/Command/Agent/Exec.hs` and name it `ExecOpts`
locally. Fields:

```haskell
data ExecOpts' = ExecOpts'
  { groupName  :: !Text             -- required: which group's repos to run across
  , prompt     :: !(Maybe Text)     -- -p / --prompt : the instruction (XOR with skill)
  , skill      :: !(Maybe Text)     -- --skill NAME  : run a Claude Code skill (XOR with prompt)
  , filterGlob :: !(Maybe Text)     -- --filter GLOB : restrict <namespace>/<name>
  , jobs       :: !Int              -- --jobs N      : default 1 (sequential)
  , failFast   :: !Bool             -- --fail-fast
  , dryRun     :: !Bool             -- --dry-run
  , followUp   :: !Bool             -- --follow-up   : recall the prior run (M3)
  , debug      :: !Bool             -- --debug       : print the prompt, do not launch
  }
  deriving stock (Generic, Show)
```

**The constructor.** Add `AgentExec !ExecOpts'` to the `data AgentCommand` sum in `Agent.hs`
(after `AgentAsk !AskOpts`), and export it.

**The parser stanza.** In `agentCommandParser`, add:

```haskell
<> command "exec"
     ( info
         (AgentExec <$> agentExecOptsParser)
         (progDesc "Run a prompt or skill against every repo in a group, sequentially, accumulating memory")
     )
```

with a parser:

```haskell
agentExecOptsParser :: Parser ExecOpts'
agentExecOptsParser =
  ExecOpts'
    <$> strOption (long "group" <> metavar "GROUP" <> help "Run across the repos in GROUP")
    <*> optional (strOption (long "prompt" <> short 'p' <> metavar "TEXT" <> help "Instruction to run in each repo"))
    <*> optional (strOption (long "skill" <> metavar "NAME" <> help "Claude Code skill to run in each repo"))
    <*> optional (strOption (long "filter" <> metavar "GLOB" <> help "Restrict to <namespace>/<name> matching GLOB"))
    <*> option auto (long "jobs" <> short 'j' <> metavar "N" <> value 1 <> showDefault <> help "Parallel repos (default 1; >1 disables accumulate-as-you-go)")
    <*> switch (long "fail-fast" <> help "Stop after the first repo that fails")
    <*> switch (long "dry-run" <> help "List the repos without running")
    <*> switch (long "follow-up" <> help "Recall the prior run's session and memories")
    <*> switch (long "debug" <> help "Print the assembled prompt instead of launching claude")
```

**The dispatch.** In `runAgent`, add `AgentExec opts -> runAgentExec pool opts`.

**The handler (M1 form, no memory yet).** Add `runAgentExec :: Pool.Pool -> ExecOpts' -> IO ()`.
Its M1 body:

1. Validate `prompt`/`skill` are not both `Nothing` and not both `Just` (die with a clear message
   otherwise — reuse the `TIO.hPutStrLn stderr` + `exitFailure` pattern already used in `Agent.hs`).
2. Resolve repos: build a `Mori.Command.Registry.Exec.ExecOpts` carrying only
   `groupName = Just (opts ^. #groupName)` and `filterGlob = opts ^. #filterGlob` (the rest default
   via `Mori.Command.Registry.Exec.defaultExecOpts`), then call
   `Mori.Command.Registry.Exec.selectProjects pool getStreamCats execOpts` to get
   `[ProjectListRow]`. (`getStreamCats` already exists in `Agent.hs`.)
3. If `opts ^. #dryRun`: print the qualified names + paths (reuse the shape of
   `Exec.renderDryRun`) and return.
4. Otherwise loop **sequentially** over the repos in order. For each repo `proj`:
   - Skip if `T.null (proj ^. #path)` or `not <$> doesDirectoryExist (T.unpack (proj ^. #path))`
     (print a "skipped: path missing" line, mirroring `Exec.runOne`).
   - Build the per-repo prompt: in M1 just the raw `prompt` (or, for `--skill NAME`, a line like
     `"Run the /NAME skill in this repository."`), with a header naming the repo
     (`<namespace>/<name>` and its path).
   - Get `agentDirs <- KitSession.agentDirsForSession` (so skills resolve) and a tool allow-list
     (M1: a conservative read-mostly set, e.g. the same `allowedTools` an existing agent verb uses;
     M2 adds the memory tool).
   - If `opts ^. #debug`: `TIO.putStrLn prompt` and continue to the next repo.
   - Else launch claude exactly like `runAgentAsk` does:

     ```haskell
     let cp = (proc "claude" (buildClaudeArgs agentDirs tools (T.unpack prompt)))
                { cwd = Just (T.unpack (proj ^. #path)), delegate_ctlc = True }
     (_, _, _, ph) <- createProcess cp
     ec <- waitForProcess ph
     ```

     Record the exit code; honor `--fail-fast` by stopping the loop when a repo exits non-zero
     (reuse the `runSequentialFailFast` *idea*; you can inline a simple recursive loop here since
     the per-repo action is interactive rather than captured).
   - When `opts ^. #jobs > 1`, you may use `Exec.runBounded` for parallelism, but print the
     decision-log warning that accumulate-as-you-go is disabled. For M1, sequential is enough.
5. After the loop, print a one-line summary (`N repos visited, M failed`).

**Acceptance for M1.** `mori agent exec --group <real-or-test-group> --dry-run` prints the repos.
`mori agent exec --group <g> -p "echo hi" --debug` prints the assembled per-repo prompt for each
repo (proving the loop and the cwd/header assembly run). With a real prompt and no `--debug`,
`claude` launches once per repo with the working directory set to each repo (verify by giving a
prompt like "print the absolute path of your current directory" and observing distinct paths).

### Milestone M2 — `mori agent memory` CLI + per-repo kioku session

**Scope and result.** At the end of M2, mori can record and list kioku memories from the command
line, the spawned `claude` is granted the record tool, and each repo run opens and closes a kioku
*session*. Observable: record a memory under a group scope and list it back; after an exec run,
`kioku_sessions` has one completed row per repo.

**The memory subcommands.** Add to `Agent.hs` two more `AgentCommand` constructors and their
parsers, mirroring Rei's `rei agent memory` shape
(`rei-cli/src/Rei/Cli/Commands/Agent/Parser.hs` `memoryCmd`):

```haskell
  | AgentMemoryRecord !MemoryRecordOpts
  | AgentMemoryList   !MemoryListOpts
```

```haskell
data MemoryRecordOpts = MemoryRecordOpts
  { content   :: !Text                 -- the learning, positional
  , scopeFlag :: !MemScopeFlag         -- --group G | --repo PROJECT_ID
  , memType   :: !Text                 -- --type (default "fact")
  , tags      :: ![Text]               -- --tag (repeatable)
  } deriving stock (Generic, Show)

data MemoryListOpts = MemoryListOpts
  { scopeFlag :: !MemScopeFlag
  , memType   :: !(Maybe Text)
  } deriving stock (Generic, Show)

data MemScopeFlag = ScopeGroupFlag !Text | ScopeRepoFlag !Text
  deriving stock (Generic, Show)
```

Wire them under a `memory` subgroup in `agentCommandParser`:

```haskell
<> command "memory"
     ( info (memorySubparser <**> helper)
            (progDesc "Record and list agent memories accumulated by exec runs") )
```

where `memorySubparser` is an `hsubparser` of `command "record" ...` and `command "list" ...`. The
`--group`/`--repo` flags parse into `MemScopeFlag`; `--group` is the common case (cross-repo
learnings), `--repo` takes a `ProjectId` text.

**Scope mapping.** Add a small helper (in the new `Agent/Exec.hs` or near the handler):

```haskell
groupScope :: GroupId -> MemoryScope
groupScope gid = ScopeEntity (Namespace "mori") (ScopeKind "group") (KindID.toText gid)

repoScope :: ProjectId -> MemoryScope
repoScope pid = ScopeEntity (Namespace "mori") (ScopeKind "repo") (KindID.toText pid)
```

For `mori agent memory record --group G`, resolve `G` to its `GroupId` via
`getGroupByName (GroupName G)` (run through `runMoriEffWithPool`) and use `groupScope`.

**The record/list handlers.** These drive kioku through the kiroku store, so they open the store
and use `runMoriEffWithStore`:

```haskell
runAgentMemoryRecord :: Pool.Pool -> MemoryRecordOpts -> IO ()
runAgentMemoryRecord _pool opts = do
  connStr <- getMoriConnStr                              -- MORI_PG_CONNECTION_STRING
  withStore (moriStoreConnectionSettings connStr) $ \store -> do
    scope <- resolveScope (opts ^. #scopeFlag)           -- IO; group name -> GroupId via pool
    res <- runMoriEffWithStore store getStreamCats $ do
             mid <- genMemoryId
             Kioku.Memory.record (recordInput mid scope opts)
    either dieMori (const (TIO.putStrLn "recorded")) res
```

`Kioku.Memory.record` is kioku's write API (IP-1; EP-1 `kioku-core/src/Kioku/Memory.hs`); its
input carries `scope :: MemoryScope`, `content :: Text`, `memoryType`, `tags`, optional
`agentId`/`sessionId`/`priority`. The exact field record name is fixed by EP-1 — read
`kioku-core/src/Kioku/Memory.hs` for `record`'s argument shape and construct it accordingly;
if EP-1 exposes a smart constructor (e.g. `mkRecordMemory`) use it.

`runAgentMemoryList` calls `Kioku.Recall.getActiveByScope scope` (EP-1's placeholder scoped query;
EP-2 upgrades `Kioku.Recall` to hybrid but keeps `getActiveByScope`), printing each
`MemoryRecord`'s id, type, tags, and content.

**Grant the tool to claude.** In `runAgentExec`'s tool allow-list, add the memory record command
so the spawned agent can write its own learnings. mori's existing agent verbs allow shelling out;
grant `Bash(mori agent memory record:*)` (the Claude Code allow-list syntax for "the `mori agent
memory record` command via Bash"). Append to the per-repo system prompt a short instruction block
telling the agent: *"When you learn something reusable about this repo or the group, record it with
`mori agent memory record --repo <THIS_PROJECT_ID> \"<learning>\"` (repo-specific) or `--group
<GROUP> \"<learning>\"` (applies to every repo in this run)."* Substitute the concrete
`<THIS_PROJECT_ID>` (the repo's `KindID.toText projectId`) and `<GROUP>` into the prompt per repo.

**Per-repo session.** Wrap each repo run in a kioku session (`Kioku.Session`, EP-1
`kioku-core/src/Kioku/Session.hs`):

- Before launching claude: `sid <- genSessionId; Kioku.Session.start (startInput sid)` where the
  start input carries `focus = <prompt-or-skill label>`, `scope = repoScope projectId`,
  `subjectRef = Just (opts ^. #groupName)`, and (M3) `previousSessionId = mPrev`.
- After `waitForProcess`: on exit 0 `Kioku.Session.complete sid (summary)`, on non-zero
  `Kioku.Session.failSession sid (errMsg)`. Run both through `runMoriEffWithStore`.

Open the store **once** at the top of `runAgentExec` (one `withStore`) and thread it through the
loop, rather than re-opening per repo, so all repos share one pool and one connection budget.

**Acceptance for M2.** `mori agent memory record --group testg "all repos use just ci"` prints
`recorded`; `mori agent memory list --group testg` prints that memory. After an exec run over a
2-repo group, `psql "$MORI_PG_CONNECTION_STRING" -c "SELECT focus, scope_kind, scope_ref, status
FROM kiroku.kioku_sessions ORDER BY started_at;"` shows two rows with `scope_kind='repo'` and
`status='completed'`. (Use `--debug` to avoid a live claude during automated checks; the session
start/complete still run around the no-op launch when you exercise the non-debug path manually.)

### Milestone M3 — recall-and-inject + follow-up chaining

**Scope and result.** At the end of M3, before each repo run mori recalls the group-scoped and
repo-scoped memories and injects them into the prompt, so repo #2 sees what repo #1 recorded; and
`--follow-up` recalls the prior run's session and memories so a second invocation builds on the
first. This is the headline acceptance: cross-repo and cross-run accumulation.

**Recall-and-inject.** In `runAgentExec`'s per-repo step, *before* building the prompt and *after*
the previous repo finished (sequential ordering guarantees the previous repo's recorded memories
are committed), do:

```haskell
groupMems <- runRecall store (Kioku.Recall.getActiveByScope (groupScope gid))
repoMems  <- runRecall store (Kioku.Recall.getActiveByScope (repoScope (proj ^. #projectId)))
let memorySection = renderMemorySection groupMems repoMems
    prompt        = basePrompt <> "\n\n" <> memorySection
```

`renderMemorySection` formats the recalled `MemoryRecord`s as a Markdown block, e.g.:

```text
## Accumulated learnings

### Group-wide (mori/group/<gid>)
- [fact] all repos use `just ci`
- [pattern] flaky tests are retried via the `retry` wrapper

### This repo (mori/repo/<pid>)
- [constraint] do not touch generated files under gen/
```

Inject it via `buildClaudeArgs`'s `--append-system-prompt`. When EP-2 is available, swap
`getActiveByScope` for `Kioku.Recall.recall` with the user's prompt as the query and
`strategy = Hybrid` so the injected memories are *relevant to the task*, not just newest-in-scope;
EP-2's `recall` is fail-open, so an embedding outage degrades to keyword/FTS and never blocks the
run. Until EP-2 lands, `getActiveByScope` (newest-in-scope) is the placeholder, exactly as the
MasterPlan's soft-dependency on EP-2 anticipates.

**Why sequential makes this work.** Because the loop is sequential (`--jobs 1`, the default) and a
kioku memory write is committed in its append transaction before `record` returns, by the time
repo #(k+1)'s recall runs, every memory repo #1…#k recorded under the **group** scope is visible.
That is the "subsequent runs more efficient" effect, made concrete: a learning recorded in repo #1
surfaces in repo #2's prompt.

**Follow-up chaining.** When `opts ^. #followUp`:

- Find the most recent prior session for this group. Add a small kioku-side query or a direct
  read-model statement: `SELECT session_id FROM kiroku.kioku_sessions WHERE subject_ref = $group
  ORDER BY started_at DESC LIMIT 1` (run via the store's `Hasql` effect). Pass that id as the
  `previousSessionId` of the **first** repo's new session this run, chaining the runs. (Within a
  single run, each repo's session may chain to the previous repo's session id; across runs, the
  first repo chains to the prior run's last session.)
- The recall already surfaces the prior run's recorded memories automatically, because they live in
  the same group/repo scopes and `getActiveByScope`/`recall` is not time-boxed. So `--follow-up`'s
  distinctive behavior is the session chain (provenance) plus an added prompt line: *"This is a
  follow-up to a prior run; build on the learnings below and the prior session
  <previousSessionId>."*

**Acceptance for M3.** Run, over a test group of at least two repos, an exec where repo #1's prompt
instructs the agent to record a group memory (or pre-seed one with `mori agent memory record
--group testg "<fact>"`). With `--debug`, observe that repo #2's printed prompt **contains** the
`## Accumulated learnings` section listing that fact. Then run the command a second time with
`--follow-up` and observe that the prior run's memories are present in repo #1's prompt and that the
new sessions carry a non-null `previous_session_id` (`SELECT session_id, previous_session_id FROM
kiroku.kioku_sessions ORDER BY started_at;`).


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/mori-project/mori` inside mori's nix dev
shell unless noted. The shell exports `MORI_PG_CONNECTION_STRING` for the local development
Postgres.

**Step 0 — confirm EP-1 is done.** kioku must build first:

```bash
( cd /Users/shinzui/Keikaku/bokuno/kioku && cabal build all )
```

If this fails, complete EP-1 (`docs/plans/1-kioku-scaffold-and-core-extraction.md`) before
continuing.

**Step 1 — M0: pin, deps, schema.** Edit `cabal.project` (the `optional-packages:` block) and
`mori-core/mori-core.cabal` (`build-depends`) per Milestone M0, edit
`mori-core/test/TestSupport/Database.hs` to also run kioku's `sql-migrations`, and edit
`mori-core/migrations/Main.hs` to apply kioku's schema in production. Then:

```bash
cabal build mori-core
```

Expected: a clean build. Apply migrations and verify the tables:

```bash
just run-migrations
psql "$MORI_PG_CONNECTION_STRING" -c '\dt kiroku.kioku_*'
```

Expected tail:

```text
 kiroku | kioku_memories | table | ...
 kiroku | kioku_sessions | table | ...
 kiroku | kioku_turns    | table | ...
```

**Step 2 — M1: the exec command.** Add the constructor/parser/handler. Build and dry-run:

```bash
cabal build mori-cli
cabal run mori -- agent exec --group <your-group> --dry-run
```

Expected (example):

```text
Would visit 2 project(s):
  shinzui/repo-a   /Users/shinzui/Keikaku/bokuno/repo-a
  shinzui/repo-b   /Users/shinzui/Keikaku/bokuno/repo-b
```

Then prove the loop assembles a per-repo prompt with the right cwd header:

```bash
cabal run mori -- agent exec --group <your-group> -p "print your working directory" --debug
```

Expected: two printed prompt blocks, each naming a different repo and path.

**Step 3 — M2: memory CLI + session.** Add the `memory` subcommands and the per-repo session.
Build and exercise:

```bash
cabal run mori -- agent memory record --group <your-group> "all repos use 'just ci'"
cabal run mori -- agent memory list --group <your-group>
```

Expected:

```text
recorded
- [fact] all repos use 'just ci'   #tags:
```

Run a real (non-debug) exec over the group with a trivial prompt, then inspect sessions:

```bash
cabal run mori -- agent exec --group <your-group> -p "list the files in this repo"
psql "$MORI_PG_CONNECTION_STRING" \
  -c "SELECT focus, scope_kind, scope_ref, status FROM kiroku.kioku_sessions ORDER BY started_at;"
```

Expected: one row per repo, `scope_kind = repo`, `status = completed`.

**Step 4 — M3: recall-and-inject + follow-up.** Add recall before each repo run. Demonstrate
cross-repo injection with `--debug` (so no live agent is needed):

```bash
cabal run mori -- agent memory record --group <your-group> "CI lives in .github/workflows/ci.yml"
cabal run mori -- agent exec --group <your-group> -p "audit CI" --debug
```

Expected: the printed prompt for **every** repo contains:

```text
## Accumulated learnings

### Group-wide (mori/group/grp_...)
- [fact] CI lives in .github/workflows/ci.yml
```

Then follow-up:

```bash
cabal run mori -- agent exec --group <your-group> --follow-up -p "fix the CI issues you found" --debug
psql "$MORI_PG_CONNECTION_STRING" \
  -c "SELECT session_id, previous_session_id FROM kiroku.kioku_sessions ORDER BY started_at;"
```

Expected: the follow-up run's first session has a non-null `previous_session_id` pointing at the
prior run's last session, and the learnings block is present in the prompt.


## Validation and Acceptance

Acceptance is behavioral and demonstrated by the Step 1–4 transcripts plus tests.

**The three observable facts (headline acceptance):**

1. *Sequential per-repo execution.* `mori agent exec --group G -p "..."` visits each repo in `G`
   in order with `cwd` set to the repo path. Proven by the Step 2 `--dry-run` list and the
   distinct working directories printed when the prompt asks the agent to report its cwd.
2. *Cross-repo accumulation.* A memory recorded under the group scope (by repo #1, or pre-seeded)
   appears in the injected `## Accumulated learnings` section of a later repo's prompt (Step 4,
   `--debug`). `mori agent memory list --group G` prints the accumulated learnings.
3. *Follow-up builds on the prior run.* A second `--follow-up` invocation chains the new sessions
   to the prior run (`previous_session_id` non-null) and re-injects the prior run's learnings.

**Tests (`cabal test` in the mori repo):**

- *Pure unit tests* (no DB): repo-ordering preserves input order; the prompt-assembly function
  produces the expected `## Accumulated learnings` block from a list of `MemoryRecord`s (including
  the empty-list case → no section); the `prompt`/`skill` XOR validation rejects both-set and
  none-set; `groupScope`/`repoScope` map ids to the expected `ScopeEntity` values.
- *DB-gated integration test* (guarded like mori's existing DB suites, using the test database
  bootstrap that now applies kioku's schema): record a memory under
  `ScopeEntity "mori" "group" gtext` via `Kioku.Memory.record` through `runMoriEffWithStore`, then
  `Kioku.Recall.getActiveByScope` for that scope returns it; record one under a repo scope and
  assert the group recall does **not** return it (scope isolation); start→complete a session and
  assert the `kioku_sessions` row is `status='completed'`.

Acceptance is met when `cabal build all` and `cabal test` pass in the mori repo and the Step 1–4
transcripts reproduce.


## Idempotence and Recovery

Every step is safe to repeat.

- **M0 pin/schema.** The pin edit is declarative. kioku's base schema is `CREATE TABLE IF NOT
  EXISTS`, so re-running `just run-migrations` is a no-op for kioku tables. If a newly added
  embedded migration file is "missed", it is the `embedDir` recompile caveat — `just
  run-migrations` already `rm -rf`s the migrations build dir to force re-embedding.
- **Memory records.** `Kioku.Memory.record` appends an event with a fresh `MemoryId` each time, so
  re-running `mori agent memory record` creates a new memory rather than overwriting — that is the
  intended append-only semantics. To avoid duplicates in a script, list first or supersede. (EP-3
  adds LLM consolidation/merge; EP-5 does not dedup.)
- **Sessions.** Each repo run opens a fresh session id; a crashed run leaves a `running` session,
  which a later run does not disturb. `--follow-up` selects the newest by `started_at`, so a
  dangling `running` session is harmless (it is just an unfinished provenance node).
- **Exec runs.** Re-running an exec is safe: it recalls current memory and launches the agent
  again. `--dry-run` and `--debug` are side-effect-free except for the session start/complete in
  the non-debug path (which are additive event appends).

**Rollback.** The change is additive: removing the `kioku` pin + build-deps and reverting the new
`AgentExec`/`AgentMemory*` constructors and handlers returns mori to its prior state. The kioku
read-model tables (`kioku_*` in the `kiroku` schema) can be dropped with `DROP TABLE` if a clean
removal is wanted; they are independent of mori's own tables.


## Interfaces and Dependencies

Name the libraries, modules, and services used and the signatures that must exist at each
milestone. Use full module paths.

**Libraries and services.**

- **kioku** (`/Users/shinzui/Keikaku/bokuno/kioku`), the hard dependency (EP-1). EP-5 consumes only
  the top-level public API (MasterPlan IP-1) — never `Kioku.*.Domain.*` internals:
  - `Kioku.Api.Scope` — `Namespace(..)`, `ScopeKind(..)`, `MemoryScope(..)`.
  - `Kioku.Api.Types` — `MemoryRecord(..)`, `MemoryType`, `Confidence`.
  - `Kioku.Id` — `MemoryId`, `SessionId`, `genMemoryId`, `genSessionId`.
  - `Kioku.Memory` — the write API (`record`, and as needed `supersede`/`archive`/`updateTags`).
  - `Kioku.Session` — `start`, `complete`, `failSession` (and `recordTurn` if EP-5 later opts into turns).
  - `Kioku.Recall` — `getActiveByScope` (EP-1 placeholder); `recall` + `RecallRequest`/
    `RecallStrategy` once EP-2 lands (soft dependency).
  Read the exact argument records of `record`/`start`/`complete`/`failSession` in EP-1's
  `kioku-core/src/Kioku/Memory.hs` and `Kioku/Session.hs` and construct them accordingly; if EP-1
  exposes smart constructors, use them rather than raw records.
- **mori** existing modules:
  - `Mori.Command.Registry.Exec` — `selectProjects`, `ExecOpts(..)`, `defaultExecOpts`,
    `ProjectListRow` re-export; the loop helpers `runSequentialFailFast`/`runBounded` (reused or
    paralleled).
  - `Mori.Command.Agent` — `buildClaudeArgs`, `getStreamCats`, `runAgent`, `AgentCommand`,
    `agentCommandParser`; `Baikai.Kit.Session.agentDirsForSession` (as `KitSession`).
  - `Mori.Modules.Project.Infrastructure.Table` — `ProjectListRow(..)` (`projectId`, `namespace`,
    `name`, `path`).
  - `Mori.Modules.Group.Group` — `getGroupByName`, `getGroupMembers`, `GroupRow(..)`, `GroupName`,
    `GroupId`.
  - `Mori.Effects` — `runMoriEffWithPool`, `runMoriEffWithStore`, `MoriStoreEff`.
  - `Mori.Effects.Store` — `moriStoreConnectionSettings`, `withStore`, `KirokuStore`.
  - `Mori.Cli` — `setupPool`; the `Agent` dispatch arm (unchanged: it already routes
    `AgentExec`/`AgentMemory*` through `runAgent`).
- **keiro/kiroku/keiki/shibuya** — pinned by mori's `cabal.project`; kioku resolves against them.
- **`System.Process`** — `proc`, `CreateProcess(..)` (`cwd`, `delegate_ctlc`), `createProcess`,
  `waitForProcess`. **`optparse-applicative`** — the parser stanzas. **`Data.KindID`
  (`mmzk-typeid`)** — `KindID.toText` for scope refs.

**Signatures that must exist at the end of each milestone (full paths in `mori-cli`/`mori-core`).**

End of M0:

- mori's `cabal.project` pins kioku; `mori-core.cabal` `build-depends` includes `kioku-api`,
  `kioku-core`; `mori-core/test/TestSupport/Database.hs` applies kioku's `sql-migrations`;
  `mori-core/migrations/Main.hs` applies kioku's schema in production.

End of M1 (in `Mori.Command.Agent` or a new `Mori.Command.Agent.Exec`):

- `data ExecOpts'` (fields per Plan of Work); `AgentExec !ExecOpts'` on `AgentCommand`;
  `agentExecOptsParser :: Parser ExecOpts'`; the `command "exec"` stanza in `agentCommandParser`;
  `runAgentExec :: Pool.Pool -> ExecOpts' -> IO ()` and its dispatch in `runAgent`.

End of M2:

- `AgentMemoryRecord !MemoryRecordOpts`, `AgentMemoryList !MemoryListOpts` on `AgentCommand`;
  `MemoryRecordOpts`, `MemoryListOpts`, `MemScopeFlag`; the `command "memory"` subparser;
  `runAgentMemoryRecord :: Pool.Pool -> MemoryRecordOpts -> IO ()`,
  `runAgentMemoryList :: Pool.Pool -> MemoryListOpts -> IO ()`;
  `groupScope :: GroupId -> MemoryScope`, `repoScope :: ProjectId -> MemoryScope`;
  per-repo session start/complete/fail wired into `runAgentExec`; the memory record tool granted
  via `buildClaudeArgs`' allow-list and the prompt instruction block.

End of M3:

- recall-and-inject in `runAgentExec` (`getActiveByScope`/`recall` for group + repo scopes,
  `renderMemorySection :: [MemoryRecord] -> [MemoryRecord] -> Text`); `--follow-up` resolving the
  prior session (`previous_session_id` chained on the new sessions) and re-injecting prior
  memories.

**Dependency on prior work.** Hard-depends on EP-1
(`docs/plans/1-kioku-scaffold-and-core-extraction.md`) for the kioku API, types, write/read
modules, and migrations. Soft-depends on EP-2
(`docs/plans/2-kioku-hybrid-retrieval-pgvector-fts-rrf.md`) for hybrid `Kioku.Recall.recall`; EP-5
uses EP-1's `getActiveByScope` placeholder until EP-2 lands, then swaps to `recall`. No dependency
on EP-3/EP-4/EP-6.


## Revision History

- 2026-06-24 — Initial authoring of the full plan from the skeleton. Filled every prose section and
  seeded the Progress checklist; frontmatter left untouched. Grounded against: MasterPlan #1
  (IP-1 API surface, IP-2 `MemoryScope` mapping, IP-3 migrations in the `kiroku` schema, IP-5 pin
  reconciliation); EP-1 (`docs/plans/1-…`) for the kioku public API and base schema; EP-2
  (`docs/plans/2-…`) for the future hybrid `recall`; mori source read directly —
  `mori-cli/src/Mori/Command/Registry/Exec.hs` (selectProjects + per-repo loop + cwd),
  `mori-cli/src/Mori/Command/Agent.hs` (AgentCommand/agentCommandParser/runAgent/buildClaudeArgs/
  runAgentAsk cwd pattern), `mori-cli/src/Mori/Cli.hs` (Command + Agent dispatch + setupPool),
  `mori-core/src/Mori/Modules/Group/Group.hs` + `Mori/Modules/Project/Infrastructure/Table.hs`
  (group/project read models, `ProjectListRow`/`GroupId`/`ProjectId`), `mori-core/src/Mori/
  Effects.hs` + `Mori/Effects/Store.hs` (`runMoriEffWithStore`, `moriStoreConnectionSettings`,
  `extraSearchPath=["public"]`), `mori-core/migrations/Main.hs` +
  `mori-core/test/TestSupport/Database.hs` (how mori applies framework SQL), and mori's
  `cabal.project` (the keiki/keiro/kiroku/shibuya pins reconciled against EP-1's). Rei's
  `rei-cli/src/Rei/Cli/Commands/Agent/` was read for the `agent memory record/list` CLI shape that
  the explicit-tool capture path mirrors. Reason: convert the binding MasterPlan EP-5 brief into a
  self-contained, novice-followable execution plan for `mori agent exec --group` with kioku memory.


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
- **CLI conventions (design-affecting):** build the `mori agent exec` parser with option groups
  (`cli/option-groups.md`). Critically, `cli/agents/claude-cli-pitfalls.md`: when spawning
  `claude -p`, terminate the argv with `["--", userPrompt]` (or feed the prompt via stdin), because
  `--add-dir` is a variadic option that greedily consumes the positional prompt without a `--`
  separator — a short prompt errors with "Input must be provided", a large prompt **hangs
  indefinitely**. Reuse mori's existing `buildClaudeArgs`, but verify (and add a contract test for)
  the `--`-terminator/stdin behaviour on the new exec path, and leave the mandatory explanatory
  comment so the workaround survives refactors.
