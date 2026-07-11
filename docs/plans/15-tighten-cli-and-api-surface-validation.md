---
id: 15
slug: tighten-cli-and-api-surface-validation
title: "Tighten CLI and API surface validation"
kind: exec-plan
created_at: 2026-07-07T14:58:23Z
intention: "intention_01kwyhabypepdt1mwemmf0dvqa"
master_plan: "docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md"
---

# Tighten CLI and API surface validation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The `kioku` command-line tool currently trusts its operator far too much. Today you can pass
a *memory* id where a *session* id is expected and the CLI silently rebrands the raw UUID and
runs a distillation pass against a session that does not exist. You cannot recall memories for
an entity whose reference contains a colon (a URL, a `host:port` pair) because the scope
grammar splits on every colon. `kioku worker --backfill --timers-once` silently ignores
`--backfill`. `kioku recall --limit -1` turns into a Postgres runtime error instead of a parse
error. And `kioku demo` appends *permanent, undeletable* event-sourced data to whatever
database `PG_CONNECTION_STRING` points at — under the production-looking scope
`rei/intention/intention_demo` — with no confirmation of any kind.

After this plan is implemented, every one of those footguns is gone and provably so: wrong-type
ids are rejected at parse time with an error naming both the expected and the received prefix;
scope refs may contain colons; conflicting worker flags are a parse error; `--limit` is bounded
at the parser with the valid range in the error message; the demo commands refuse to run
without an explicit `--yes-write-events` flag, print exactly what they will write and where
(with any password redacted) before writing, and write into a clearly demo-only `kioku_demo`
namespace. Two pieces of dead or misleading API surface are also removed: the unused
`embedBatched` function (whose `batchSize` argument changes nothing) and two undeclared-unused
dependencies (`generic-lens`, `uuid`) in `kioku-api.cabal`. A new pure test suite for the CLI
parsers (`kioku-cli-test`) locks all of this in; it needs no database and runs in milliseconds.

You can see it working by running, from the repository root:

```bash
cabal test kioku-cli:test:kioku-cli-test   # new pure parser tests, all pass
cabal run kioku -- distill session kioku_memory_01h455vb4pex5vsknk084sn02q   # parse error naming both prefixes
cabal run kioku -- demo                    # refuses: Missing: --yes-write-events
```


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Rename `parseIdAnyPrefix` to `parseIdLenient` in `kioku-api/src/Kioku/Id.hs` with a Haddock explaining its laxity and legitimate uses. — 2026-07-11
- [x] M1: Update the lenient call sites in kioku-core (`Kioku/Memory/EventStream.hs`, `Kioku/Session/EventStream.hs`, `Kioku/Distill/L1.hs`, **`Kioku/Distill/Consolidate.hs`** — a fifth site EP-1 created, not in the plan's list — `Kioku/Distill/Timer/Worker.hs`) and the test use in `kioku-core/test/Kioku/DistillSpec.hs` to the new name (behavior unchanged). — 2026-07-11
- [x] M1: Switch `kioku-cli/src/Kioku/Cli/Commands/Distill.hs` `parseSessionId` to the strict `parseId`. — 2026-07-11
- [x] M1: Add the `kioku-cli-test` test suite scaffold (`kioku-cli/test/Main.hs`, `kioku-cli/test/Kioku/Cli/ParserSpec.hs`, cabal stanza) with strict-id tests. — 2026-07-11 (3 tests pass)
- [x] M1: Update `docs/user/cli-reference.md` line 125 ("any id prefix is accepted"). — 2026-07-11
- [x] M2: Rewrite `parseScope` in `kioku-cli/src/Kioku/Cli/Scope.hs` to split on the first two colons only; add parser tests; update `--help` text and docs. — 2026-07-11 (14 tests pass; `scenes --scope 'ops:host:db.internal:5432'` now reaches the store)
- [x] M3: Add `Kioku.Cli.Options` with `boundedIntReader`; bound `--limit` in Recall.hs (1–100) and Distill.hs (1–50); add tests; update docs. — 2026-07-11 (22 tests pass; `recall --limit -1` is now `LIMIT must be between 1 and 100 (got -1)`)
- [ ] M4: Demo guard: required `--yes-write-events` flag for `demo` and `demo-session`, `kioku_demo` namespace, preflight print with redacted connection string; add tests; update docs.
- [ ] M5: Make `worker --backfill` / `--timers-once` mutually exclusive (`WorkerOptions` becomes a three-way sum); add tests; update docs. Check whether docs/plans/11 has landed first (soft dependency).
- [ ] M6: Remove `embedBatched` (and its private helper `chunksOf`) from `kioku-core/src/Kioku/Memory/Embedding.hs`; remove `generic-lens` and `uuid` from `kioku-api/kioku-api.cabal` after re-verifying they are still unused; final docs sweep; full build and test.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (Pre-implementation research, 2026-07-07.) The strict parser we need for Finding 1 already
  exists: `Kioku.Id.parseId` delegates to `Data.KindID.V7.parseString @prefix`, and
  mmzk-typeid's `TypeIDErrorPrefixMismatch` `Show` instance already produces exactly the
  error we want: `Expected prefix "kioku_session" but got "kioku_memory"!` (verified in the
  mmzk-typeid source, `Data/TypeID/Error.hs`). No new error-rendering code is needed at the
  CLI boundary — the fix is a one-word change plus the rename.
- (Pre-implementation research, 2026-07-07.) `mori registry dependents shinzui/kioku
  --packages` lists two dependents, `shinzui/kikan` (/Users/shinzui/Keikaku/bokuno/kikan) and
  `shinzui/shikigami` (/Users/shinzui/Keikaku/bokuno/shikigami). Grepping both trees found
  zero uses of `parseIdAnyPrefix` or `embedBatched`, so the rename and the removal break no
  registered consumer. Re-verify at implementation time (see Concrete Steps).

- (M1, 2026-07-11.) **The lenient parser had six call sites, not the four the plan lists.**
  EP-1 (docs/plans/9-…) extracted L1's consolidation step into a new module
  `kioku-core/src/Kioku/Distill/Consolidate.hs`, which parses LLM-echoed memory ids at
  `Consolidate.hs:82` — a legitimate lenient use of exactly the kind Decision 2 describes, but
  one that did not exist when this plan was written. The rename is compile-checked, so the
  extra site announced itself immediately; recorded because it is the concrete form of the
  MasterPlan's warning that sibling plans reshape this plan's files under it. No behavior
  changed at any site.


## Decision Log

Record every decision made while working on the plan.

- Decision: CLI id parsing is strict-by-default. `kioku distill session` accepts only ids with
  the `kioku_session` prefix; any other prefix (including legacy Rei `agent_session_*` ids and
  bare UUID suffixes) is a parse error that names both the expected and the received prefix.
  Rationale: an operator copies session ids out of kioku's own read model, where they always
  carry the canonical prefix (`Kioku.Id.idText` of a `SessionId`). Accepting a memory id and
  silently rebranding its UUID (the current behavior) runs a distillation pass against a
  nonexistent session — a pure footgun with no legitimate use at this boundary. Legacy-prefix
  acceptance exists for *event-stream decoding* of migrated Rei data, not for operator input.
  Date: 2026-07-07

- Decision: Keep the lenient parser but rename it `parseIdLenient` and document its laxity.
  Do not change the behavior of any existing lenient call site.
  Rationale: three in-tree uses are legitimate and deliberate: decoding legacy Rei events
  whose ids carry `agent_memory_*`/`agent_session_*` prefixes
  (`kioku-core/src/Kioku/Memory/EventStream.hs:151,154`,
  `kioku-core/src/Kioku/Session/EventStream.hs:137`), parsing memory ids echoed back by the
  LLM during L1 consolidation (`kioku-core/src/Kioku/Distill/L1.hs:352-354` — L1 semantics are
  owned by docs/plans/9-make-l1-distillation-idempotent-and-debounce-distillation-timers.md
  and must not change here), and parsing timer correlation ids
  (`kioku-core/src/Kioku/Distill/Timer/Worker.hs:40`). The name `parseIdAnyPrefix` hides the
  rebranding; `parseIdLenient` plus a Haddock warning makes every future call site an explicit
  choice. No registered dependent uses the old name (see Surprises & Discoveries), so no
  deprecation shim is kept.
  Date: 2026-07-07

- Decision: Fix the scope grammar by splitting on the first two colons only
  (`NAMESPACE:KIND:REST-WHICH-MAY-CONTAIN-COLONS`), rather than adding a quoting syntax.
  Rationale: namespace and kind are short identifier-like labels by convention throughout the
  codebase ("rei", "mori", "intention", "repo"); only the ref is open-ended. Positional
  splitting makes every ref expressible with zero escaping rules and zero interaction with
  shell quoting; a quoting layer would add a second grammar for a problem the first two
  fields do not have. Character-set validation of namespace/kind (if any) belongs to
  docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md,
  which owns scope-identity hygiene; this plan only changes how the CLI string is split.
  Date: 2026-07-07

- Decision: `kioku worker --backfill --timers-once` becomes a parse error via mutually
  exclusive `flag'` alternatives; no combined meaning is defined. `WorkerOptions` becomes a
  three-constructor sum (`WorkerContinuous | WorkerBackfill | WorkerTimersOnce`).
  Rationale: the two one-shot modes are unrelated (embedding backfill vs. firing one
  distillation timer); a combined meaning would be an invented feature, and the masterplan
  scopes this plan to removing footguns, not adding behavior. optparse-applicative's
  alternative composition gives the conflict error for free. The change is deliberately
  parser-level plus a small dispatch `case`, because
  docs/plans/11-harden-worker-resilience-with-ack-policy-bounded-retries-and-loop-supervision.md
  owns the structure of `runWorker` and its loops (soft dependency: prefer landing this
  milestone after that plan; see Interfaces and Dependencies).
  Date: 2026-07-07

- Decision: Bound `--limit` at the parser: `kioku recall --limit` accepts 1–100 (default 8);
  `kioku distill session --limit` accepts 1–50 (default 5). Out-of-range values produce a
  parse error stating the valid range and the received value.
  Rationale: both values reach SQL `LIMIT` (recall) or size LLM prompt context (distill merge
  candidates); negative values are Postgres runtime errors today, and unbounded large values
  are cost/latency footguns. 100 is far above any human-readable recall listing; 50 merge
  candidates is an order of magnitude above the default 5 and already an extreme prompt. The
  maxima are CLI ergonomics, not API limits — library callers are unaffected.
  Date: 2026-07-07

- Decision: The demo guard is an explicit, *required* `--yes-write-events` flag on both
  `kioku demo` and `kioku demo-session`, enforced at the optparse level (omitting it is a
  parse error). Before writing, the commands print what will be written and where, with any
  password in the connection string redacted. The demo scope changes from
  `rei/intention/intention_demo` to `kioku_demo/demo/demo`.
  Rationale (mechanism): a required flag was chosen over a `KIOKU_ALLOW_DEMO=1` environment
  variable (hidden, sticky state that outlives the moment of consent — exactly how accidents
  happen in a shell where it was exported once) and over a database-name pattern check
  (heuristics give false confidence: a production database named `kioku-dev-mirror` would
  pass). A parse-level requirement is visible in `--help`, testable purely with
  `execParserPure`, and consumed at the exact invocation being consented to.
  Rationale (namespace): the events are permanent (kioku has no delete), and today they land
  in the same `rei` namespace real Rei data uses and feed the distillation timers. A
  `kioku_demo` namespace makes demo residue unmistakable and keeps distillation of demo data
  confined to a namespace nothing else reads.
  Date: 2026-07-07

- Decision: Remove `embedBatched` outright (together with its private helper `chunksOf`)
  rather than keeping a documented sequential helper.
  Rationale: it embeds strictly one text at a time (`traverse` of `embedWithRetry` inside
  each chunk), so its `batchSize` parameter changes nothing except the shape of an
  intermediate list — the name promises batched-request behavior the implementation does not
  have. It has zero call sites in this repository and zero in the registered dependents
  (kikan, shikigami). Dead API that lies about its behavior is worse than no API.
  Date: 2026-07-07

- Decision: Remove `generic-lens` and `uuid` from `kioku-api/kioku-api.cabal`, with a
  mandatory re-check at implementation time.
  Rationale: no module under `kioku-api/src` imports either package (verified by grepping all
  imports; UUID handling comes via `mmzk-typeid`, and the lens re-export in
  `Kioku/Prelude.hs` comes from the `lens` package, whose comment explicitly says
  generic-lens's `Data.Generics.Labels` is *not* re-exported). The caveat:
  docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md
  may add scope-validation code to kioku-api that could plausibly want these packages. The
  Concrete Steps therefore re-run the import grep immediately before editing the cabal file
  and skip the removal for any package that has gained a use.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

kioku is an event-sourced agent memory and session library written in Haskell (GHC 9.12,
built with `cabal`). "Event-sourced" means every write is an immutable event appended to a
Postgres-backed event store; there is no delete, which is why the demo guard in this plan
matters. The repository root is the working directory for every command in this plan and
contains four cabal packages, declared in `cabal.project`:

- `kioku-api` — wire types: the custom prelude (`kioku-api/src/Kioku/Prelude.hs`), typed
  identifiers (`kioku-api/src/Kioku/Id.hs`), memory scopes
  (`kioku-api/src/Kioku/Api/Scope.hs`), and shared records
  (`kioku-api/src/Kioku/Api/Types.hs`).
- `kioku-core` — the engine: memory/session aggregates, recall, embeddings
  (`kioku-core/src/Kioku/Memory/Embedding.hs`), and the L1/L2/L3 distillation pipeline. It
  has an existing tasty test suite (`kioku-test`) that spins up an ephemeral Postgres.
- `kioku-cli` — the `kioku` executable. `kioku-cli/app/Main.hs` delegates to
  `Kioku.Cli.main` (`kioku-cli/src/Kioku/Cli.hs`), which wires seven subcommands via
  optparse-applicative: `demo`, `demo-session`, `distill`, `persona`, `recall`, `scenes`,
  `worker`, each implemented in `kioku-cli/src/Kioku/Cli/Commands/*.hs`. Scope strings are
  parsed by `kioku-cli/src/Kioku/Cli/Scope.hs`. This package currently has **no test suite**.
- `kioku-migrations` — codd-driven SQL migrations; untouched by this plan.

Two vocabulary items. A **TypeID** is a typed identifier of the form
`prefix_01h455vb4pex5vsknk084sn02q`: a lowercase prefix, an underscore, and a base32-encoded
UUIDv7. kioku uses the `mmzk-typeid` library's `KindID`, which carries the prefix in the
*type*: `type SessionId = KindID "kioku_session"` and `type MemoryId = KindID "kioku_memory"`
(`kioku-api/src/Kioku/Id.hs:21-23`). A **memory scope** is where a memory lives:
`ScopeGlobal namespace` or `ScopeEntity namespace kind ref`
(`kioku-api/src/Kioku/Api/Scope.hs:24-28`), rendered on the CLI as `NAMESPACE` or
`NAMESPACE:KIND:REF`.

The eight findings this plan fixes, verified against the working tree on 2026-07-07:

1. `parseIdAnyPrefix` (`kioku-api/src/Kioku/Id.hs:44-52`) parses the input as a *generic*
   TypeID (`Data.TypeID.V7.parseText`, which accepts any prefix, including none), throws the
   prefix away, and rebrands the UUID via `KindID.decorateKindID`. The CLI uses it for the
   `distill session` argument (`kioku-cli/src/Kioku/Cli/Commands/Distill.hs:86-90`), so
   `kioku distill session kioku_memory_01...` "succeeds" at parse time and then runs a
   distillation pass against a nonexistent session. The strict `parseId` two definitions
   above it already rejects wrong prefixes with an error naming both prefixes.
2. `parseScope` (`kioku-cli/src/Kioku/Cli/Scope.hs:9-18`) uses `Text.splitOn ":"`, so any ref
   containing a colon produces four or more segments and the parse fails. Entity refs that
   are URLs or `host:port` pairs are unreachable from `recall`, `scenes`, `persona` (all use
   `parseScope` via `eitherReader`).
3. `runWorker` (`kioku-cli/src/Kioku/Cli/Commands/Worker.hs:47-56`) checks `opts.timersOnce`
   first, so `--timers-once` silently wins when `--backfill` is also passed.
4. Both `--limit` options use `option auto` with no bounds
   (`kioku-cli/src/Kioku/Cli/Commands/Recall.hs:48-54`,
   `kioku-cli/src/Kioku/Cli/Commands/Distill.hs:53-59`); `--limit -1` becomes a Postgres
   runtime error (`LIMIT must not be negative`).
5. `runDemo` (`kioku-cli/src/Kioku/Cli/Commands/Demo.hs:19-53`) and `runDemoSession`
   (`kioku-cli/src/Kioku/Cli/Commands/DemoSession.hs:17-74`) append permanent events to
   whatever `PG_CONNECTION_STRING` points at, under
   `ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_demo"`, with no
   confirmation. Completing the demo session also schedules a real L1 distillation timer.
6. `embedBatched` (`kioku-core/src/Kioku/Memory/Embedding.hs:74-76`) is exported, unused, and
   misleading: it chunks the input list but embeds each text individually, so `batchSize`
   changes nothing observable.
7. `kioku-api/kioku-api.cabal:48,53` declare `generic-lens` and `uuid`; no module in
   `kioku-api/src` imports either.
8. None of the above is tested: kioku-cli has no test suite at all.

optparse-applicative parsers are pure values, so all the parser fixes are testable without a
database via `Options.Applicative.execParserPure`. The existing kioku-core test suite shows
the house style: tasty + tasty-hunit, one `tests :: TestTree` per spec module, aggregated in
`test/Main.hs` (see `kioku-core/test/Main.hs`).

Sibling plans (referenced by path only; at the time of writing all are unstarted skeletons):
docs/plans/9-make-l1-distillation-idempotent-and-debounce-distillation-timers.md owns L1
distillation semantics including how LLM-returned ids are treated;
docs/plans/11-harden-worker-resilience-with-ack-policy-bounded-retries-and-loop-supervision.md
owns the structure of `kioku-cli/src/Kioku/Cli/Commands/Worker.hs`;
docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md
owns scope-identity validation and may add code to kioku-api. The MasterPlan is
docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md (this plan
is its EP-7).


## Plan of Work

The work is six milestones. Each lands one user-visible behavior change (or, for M6, a
verified removal), extends the new pure test suite so the change is locked in, and updates
`docs/user/cli-reference.md` in the same commit so documentation never trails behavior.
Milestones are independent and individually shippable; M5 is deliberately last among the
behavior changes because of the soft dependency on the worker-resilience plan.

**Milestone 1 — strict ids at the CLI boundary, explicit laxity in the API, test scaffold.**
Rename `parseIdAnyPrefix` to `parseIdLenient` in `kioku-api/src/Kioku/Id.hs` and give it a
Haddock comment stating plainly that it accepts *any* prefix (or none), discards it, and
rebrands the UUID into the target type; that this is intentional for decoding legacy Rei
event streams, LLM-echoed ids, and timer correlation ids; and that it must never be used to
parse operator input. Update the five in-tree references (four in kioku-core sources, one in
`kioku-core/test/Kioku/DistillSpec.hs`) — a pure rename, zero behavior change, so L1
semantics owned by docs/plans/9 are untouched. In
`kioku-cli/src/Kioku/Cli/Commands/Distill.hs`, change `parseSessionId` to call the strict
`Kioku.Id.parseId`, whose error already names both prefixes. Create the `kioku-cli-test`
tasty suite (new `test-suite` stanza in `kioku-cli/kioku-cli.cabal`, `kioku-cli/test/Main.hs`,
`kioku-cli/test/Kioku/Cli/ParserSpec.hs`) with tests proving a `kioku_session` id parses, a
`kioku_memory` id is rejected, and the rejection message contains both prefixes. Update
`docs/user/cli-reference.md` (the `SESSION_ID` row currently says "any id prefix is
accepted"). At the end: `cabal build all` passes, the new suite passes, and
`cabal run kioku -- distill session kioku_memory_...` prints a prefix-mismatch parse error.

**Milestone 2 — scope grammar that can express colons.** Rewrite `parseScope` in
`kioku-cli/src/Kioku/Cli/Scope.hs` to split on the first two colons only, using
`Text.breakOn`: no colon means global scope; otherwise the text before the first colon is the
namespace, the text between the first and second colons is the kind, and *everything* after
the second colon (colons included) is the ref; all three parts must be nonempty. Update the
error message and the `--help` text of every `--scope` option (`Recall.hs`, `Scenes.hs`,
`Persona.hs`) to say the ref may contain colons, and document the grammar in
`docs/user/cli-reference.md`. Add parser tests covering a URL-bearing ref, a `host:port` ref,
the global form, and the rejected shapes (`a:b`, trailing colon, empty parts). At the end:
`kioku recall "q" --scope 'mori:repo:github.com/shinzui/kioku'` parses (it fails later only
if the database is unreachable, which proves parsing succeeded).

**Milestone 3 — bounded limits.** Add a new module `kioku-cli/src/Kioku/Cli/Options.hs`
exporting `boundedIntReader :: String -> Int -> Int -> ReadM Int`, an optparse reader that
parses an `Int` and rejects values outside the inclusive range with a message of the form
`LIMIT must be between 1 and 100 (got -1)`. Use it for `--limit` in `Recall.hs` (range
1–100, default 8 unchanged) and `Distill.hs` (range 1–50, default 5 unchanged). Extend the
help texts with the range, document the ranges in `docs/user/cli-reference.md`, and add tests
for both ends of each range, one in-range value, and the defaults. At the end:
`kioku recall q --scope mori --limit -1` is a parse error showing the valid range; the
Postgres `LIMIT must not be negative` error is unreachable from the CLI.

**Milestone 4 — demo guard.** Give `demo` and `demo-session` real options records
(`DemoOptions`, `DemoSessionOptions`) whose parsers require the flag `--yes-write-events`
(built with `flag' ()`, so omitting it is a parse error listed as `Missing:
--yes-write-events` in the usage output). Move both commands' hard-coded scope to
`ScopeEntity (Namespace "kioku_demo") (ScopeKind "demo") "demo"`. Before appending any event,
print a preflight notice: that the command appends permanent events (kioku has no delete),
the target connection string with any password redacted (helper
`redactConnectionString :: Text -> Text` in `Kioku.Cli.Options`, handling both
`password=...` keyword form and `user:pass@` URI form best-effort), the scope, and — for
`demo-session` — that completing the session schedules a real distillation timer which a
running worker will process (an LLM call). Wire the new parsers into
`kioku-cli/src/Kioku/Cli.hs` (the `Command` constructors gain payloads). Add tests that the
bare invocations fail to parse and the flagged invocations succeed, plus unit tests for
`redactConnectionString`. Update `docs/user/cli-reference.md`,
`docs/user/getting-started.md` (its transcript shows the old scope and bare `kioku demo`),
and `docs/user/README.md:71`. At the end: `kioku demo` refuses without touching the network
or database; `kioku demo --yes-write-events` prints the preflight then behaves as before but
in the `kioku_demo` namespace.

**Milestone 5 — worker flag conflict.** Replace the two-`Bool` record `WorkerOptions` in
`kioku-cli/src/Kioku/Cli/Commands/Worker.hs` with a sum
`data WorkerOptions = WorkerContinuous | WorkerBackfill | WorkerTimersOnce`, parsed as
`flag' WorkerBackfill (...) <|> flag' WorkerTimersOnce (...) <|> pure WorkerContinuous`, and
change `runWorker`'s entry dispatch to a `case`. Passing both flags now fails to parse
(optparse consumes one branch and reports the other flag as invalid). Keep the change
strictly to the option type, the parser, and the top-level dispatch — the loop bodies
(`runBackfill`, `runContinuousWorker`, `runTimerOnce`, `runTimerLoop`) are owned structurally
by docs/plans/11 and are not touched. Before starting, check `git log` /
docs/plans/11-harden-worker-resilience-with-ack-policy-bounded-retries-and-loop-supervision.md
progress: if that plan has landed, apply this milestone to the restructured file (same
parser-level idea). Add tests for all three modes and the conflict; document mutual
exclusivity in `docs/user/cli-reference.md`.

**Milestone 6 — dead and misleading API, cabal hygiene, final sweep.** Delete `embedBatched`
and the now-unused private `chunksOf` from `kioku-core/src/Kioku/Memory/Embedding.hs` and its
export list, after re-running the dependents check (`mori registry dependents shinzui/kioku
--packages`, then grep each dependent tree). Re-grep `kioku-api/src` for `generic-lens` and
`uuid` imports (docs/plans/13 may have added some by the time this executes); remove each
package from `kioku-api/kioku-api.cabal` build-depends only if still unused. Sweep
`docs/user/` for stale statements (grep for `any id prefix`, `intention_demo`,
`embedBatched`). Run the full build and both test suites; record transcripts here.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/kioku`. The
project builds with `cabal` (GHC 9.12.4 per `cabal.project`); enter the nix devShell first if
you are not already in an environment with the toolchain. Format edited Haskell files with
`fourmolu -i <file>` (config: `fourmolu.yaml`). Commit at the end of each milestone with the
Conventional Commits message given below.

### M1 — strict ids, lenient rename, test scaffold

1. Edit `kioku-api/src/Kioku/Id.hs`: in the export list change `parseIdAnyPrefix` to
   `parseIdLenient`; rename the function (type unchanged) and add this Haddock above it:

   ```haskell
   -- | Lenient TypeID parsing: accepts /any/ prefix (or none), discards it, and
   -- rebrands the UUID into the target 'KindID' type. This exists for decoding
   -- legacy Rei event streams (@agent_memory_*@ \/ @agent_session_*@ ids), ids
   -- echoed back by an LLM, and timer correlation ids — places where the UUID is
   -- trusted but the prefix may be stale or absent. Never use it to parse
   -- operator input; use the strict 'parseId', which rejects wrong prefixes.
   parseIdLenient ::
     forall prefix.
     (ToPrefix prefix, ValidPrefix (PrefixSymbol prefix)) =>
     Text ->
     Either Text (KindID prefix)
   parseIdLenient t =
     case TypeID.parseText t of
       Left err -> Left (Text.pack (show err))
       Right tid -> Right (KindID.decorateKindID (TypeID.getUUID tid))
   ```

2. Rename the references (import lines and uses) in:
   `kioku-core/src/Kioku/Memory/EventStream.hs` (lines 20, 151, 154),
   `kioku-core/src/Kioku/Session/EventStream.hs` (lines 20, 137),
   `kioku-core/src/Kioku/Distill/L1.hs` (lines 40, 354),
   `kioku-core/src/Kioku/Distill/Timer/Worker.hs` (lines 24, 40),
   `kioku-core/test/Kioku/DistillSpec.hs` (lines 37, 302). A global check that nothing is
   missed:

   ```bash
   grep -rn "parseIdAnyPrefix" --include="*.hs" .
   ```

   Expected output after the rename: nothing.

3. Edit `kioku-cli/src/Kioku/Cli/Commands/Distill.hs`: change the import on line 13 to
   `import Kioku.Id (SessionId, idText, parseId)` and the parser to:

   ```haskell
   parseSessionId :: String -> Either String SessionId
   parseSessionId raw =
     case parseId (Text.pack raw) of
       Left err -> Left (Text.unpack err)
       Right sid -> Right sid
   ```

   Also update the `SESSION_ID` argument's surroundings if you add help text; the metavar
   stays `SESSION_ID`.

4. Add the test suite. Append to `kioku-cli/kioku-cli.cabal`:

   ```cabal
   test-suite kioku-cli-test
     import:         warnings, shared
     type:           exitcode-stdio-1.0
     main-is:        Main.hs
     hs-source-dirs: test
     other-modules:  Kioku.Cli.ParserSpec
     build-depends:
       , base                  >=4.21 && <5
       , kioku-api
       , kioku-cli
       , kioku-core
       , optparse-applicative  >=0.18
       , tasty                 >=1.5
       , tasty-hunit           >=0.10
       , text                  >=2.1
   ```

   Create `kioku-cli/test/Main.hs`:

   ```haskell
   module Main where

   import Kioku.Cli.ParserSpec qualified as ParserSpec
   import Test.Tasty (defaultMain)

   main :: IO ()
   main = defaultMain ParserSpec.tests
   ```

   Create `kioku-cli/test/Kioku/Cli/ParserSpec.hs` with a pure driver and the first tests.
   The driver runs any exported parser against an argument list without touching the real
   process environment:

   ```haskell
   module Kioku.Cli.ParserSpec (tests) where

   import Data.Text qualified as Text
   import Kioku.Id (genMemoryId, genSessionId, idText)
   import Options.Applicative
   import Test.Tasty (TestTree, testGroup)
   import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

   parseWith :: Parser a -> [String] -> Either String a
   parseWith p args =
     case execParserPure defaultPrefs (info (p <**> helper) mempty) args of
       Success a -> Right a
       Failure failure -> Left (fst (renderFailure failure "kioku"))
       CompletionInvoked _ -> Left "unexpected completion"
   ```

   First test group, "distill session id parsing": generate a real id with `genSessionId`
   and assert `parseWith distillOptionsParser ["session", Text.unpack (idText sid)]`
   succeeds; generate a `genMemoryId` and assert the same call with its text fails and the
   rendered failure contains both `kioku_session` and `kioku_memory` (use
   `Data.List.isInfixOf` on the error string, or `Text.isInfixOf` after packing).

5. Edit `docs/user/cli-reference.md` line 125: replace "(any id prefix is accepted)" with
   "(must carry the `kioku_session` prefix; other prefixes are rejected with an error naming
   both prefixes)".

6. Validate and commit:

   ```bash
   cabal build all
   cabal test kioku-cli:test:kioku-cli-test
   cabal run kioku -- distill session kioku_memory_01h455vb4pex5vsknk084sn02q
   ```

   The third command must exit nonzero; its stderr contains (formatting by
   optparse-applicative may add usage text around it):

   ```text
   Expected prefix "kioku_session" but got "kioku_memory"!
   ```

   Commit: `feat(cli)!: strict session-id parsing; rename parseIdAnyPrefix to parseIdLenient`
   (breaking because a `kioku-api` export is renamed and the CLI rejects previously accepted
   input).

### M2 — scope grammar

1. Replace the body of `parseScope` in `kioku-cli/src/Kioku/Cli/Scope.hs`:

   ```haskell
   -- | Parse a CLI scope string. Grammar: @NAMESPACE@ (global scope) or
   -- @NAMESPACE:KIND:REF@ (entity scope). Only the first two colons split;
   -- REF may itself contain colons (URLs, host:port). All parts must be nonempty.
   parseScope :: String -> Either String MemoryScope
   parseScope raw =
     case Text.breakOn ":" (Text.pack raw) of
       (ns, "")
         | not (Text.null ns) -> Right (ScopeGlobal (Namespace ns))
       (ns, afterNs) ->
         case Text.breakOn ":" (Text.drop 1 afterNs) of
           (_, "") -> Left scopeGrammarError
           (kind, afterKind)
             | not (Text.null ns),
               not (Text.null kind),
               ref <- Text.drop 1 afterKind,
               not (Text.null ref) ->
                 Right (ScopeEntity (Namespace ns) (ScopeKind kind) ref)
           _ -> Left scopeGrammarError

   scopeGrammarError :: String
   scopeGrammarError =
     "expected NAMESPACE or NAMESPACE:KIND:REF (REF may contain ':'; NAMESPACE and KIND may not)"
   ```

   Export `scopeGrammarError` alongside `parseScope` if the tests want to compare exactly, or
   keep it private and match on a substring.

2. Update the `--scope` help strings in `Recall.hs`, `Scenes.hs`, `Persona.hs` to append
   "; REF may contain ':'". Update the grammar block in `docs/user/cli-reference.md`
   (lines 29–34) with the same sentence and one URL example.

3. Add a "scope grammar" test group to `ParserSpec.hs` exercising `parseScope` directly
   (it is pure — no optparse needed):
   `parseScope "mori"` yields `ScopeGlobal (Namespace "mori")`;
   `parseScope "mori:repo:github.com/shinzui/kioku"` yields ref `"github.com/shinzui/kioku"`;
   `parseScope "ops:host:db.internal:5432"` yields ref `"db.internal:5432"`;
   `parseScope "rei:url:https://example.com:8080/x"` yields ref `"https://example.com:8080/x"`;
   `parseScope "a:b"`, `parseScope "a:b:"`, `parseScope ":b:c"`, `parseScope "a::c"`, and
   `parseScope ""` are all `Left`.

4. Validate and commit:

   ```bash
   cabal test kioku-cli:test:kioku-cli-test
   PG_CONNECTION_STRING='host=127.0.0.1 dbname=nonexistent' \
     cabal run kioku -- scenes --scope 'ops:host:db.internal:5432'
   ```

   The second command must get *past parsing*: it fails (or succeeds with `(no scenes)` if
   you point it at a real dev database) with a store/connection error, **not** with
   `expected NAMESPACE or NAMESPACE:KIND:REF`. Before this milestone the same invocation
   fails at parse time.

   Commit: `feat(cli): allow colons in scope refs by splitting on the first two colons only`

### M3 — bounded limits

1. Create `kioku-cli/src/Kioku/Cli/Options.hs` (add it to `exposed-modules` in
   `kioku-cli/kioku-cli.cabal`):

   ```haskell
   module Kioku.Cli.Options
     ( boundedIntReader,
     )
   where

   import Options.Applicative

   -- | An integer option reader that enforces an inclusive range at parse time.
   -- @label@ names the value in the error message, e.g. \"LIMIT\".
   boundedIntReader :: String -> Int -> Int -> ReadM Int
   boundedIntReader label lo hi = do
     n <- auto
     if n >= lo && n <= hi
       then pure n
       else
         readerError
           (label <> " must be between " <> show lo <> " and " <> show hi <> " (got " <> show n <> ")")
   ```

2. In `Recall.hs`, replace `auto` in the `--limit` option with
   `boundedIntReader "LIMIT" 1 100` and extend the help to
   `"Maximum hits to return (1-100)"`. In `Distill.hs`, use
   `boundedIntReader "LIMIT" 1 50` with help
   `"Maximum merge candidates per extracted atom (1-50)"`. Add the imports.

3. Tests: through `parseWith recallOptionsParser` assert `--limit 0`, `--limit -1`,
   `--limit 101` fail with an error containing `between 1 and 100`; `--limit 1`,
   `--limit 100` succeed; omitting `--limit` yields 8. Mirror for
   `distillOptionsParser` (`["session", sid, "--limit", "51"]` fails with
   `between 1 and 50`; default 5).

4. Update the two `--limit` rows in `docs/user/cli-reference.md` with the ranges.

5. Validate and commit:

   ```bash
   cabal test kioku-cli:test:kioku-cli-test
   cabal run kioku -- recall q --scope mori --limit -1
   ```

   Expected (exit nonzero, no database contact):

   ```text
   option --limit: LIMIT must be between 1 and 100 (got -1)
   ```

   Commit: `feat(cli): bound --limit values at the parser`

### M4 — demo guard

1. Add to `Kioku.Cli.Options`:

   ```haskell
   yesWriteEventsFlag :: Parser ()
   yesWriteEventsFlag =
     flag'
       ()
       ( long "yes-write-events"
           <> help
             "Required confirmation: this command appends PERMANENT events (kioku has no delete) to the database at PG_CONNECTION_STRING"
       )

   -- | Best-effort password redaction for printing a libpq connection string.
   -- Handles the keyword form (password=... word) and the URI form (user:pass@host).
   redactConnectionString :: Text -> Text
   redactConnectionString conn =
     case Text.stripPrefix "postgres://" conn of
       Just rest -> "postgres://" <> redactUserInfo rest
       Nothing ->
         case Text.stripPrefix "postgresql://" conn of
           Just rest -> "postgresql://" <> redactUserInfo rest
           Nothing -> Text.unwords (map redactPair (Text.words conn))
     where
       redactPair kv
         | "password=" `Text.isPrefixOf` kv = "password=REDACTED"
         | otherwise = kv
       redactUserInfo rest =
         case Text.breakOn "@" rest of
           (_, "") -> rest
           (userinfo, hostPart) ->
             case Text.breakOn ":" userinfo of
               (_, "") -> userinfo <> hostPart
               (user, _) -> user <> ":REDACTED" <> hostPart
   ```

   (Import `Data.Text (Text)` and `Data.Text qualified as Text`.)

2. In `Demo.hs`: export `DemoOptions (..)` and `demoOptionsParser`; define
   `data DemoOptions = DemoOptions deriving stock (Eq, Show)` and
   `demoOptionsParser = DemoOptions <$ yesWriteEventsFlag`; change
   `runDemo :: DemoOptions -> IO ()`. Change the scope to
   `ScopeEntity (Namespace "kioku_demo") (ScopeKind "demo") "demo"` and the success message
   to name `kioku_demo/demo/demo`. Immediately after reading `PG_CONNECTION_STRING` and
   before `withStore`, print the preflight:

   ```haskell
   putStrLn "kioku demo appends permanent memory events (kioku has no delete)."
   putStrLn ("Target: " <> Text.unpack (redactConnectionString (Text.pack connStr)))
   putStrLn "Scope:  kioku_demo/demo/demo"
   ```

3. In `DemoSession.hs`: mirror step 2 with `DemoSessionOptions`/`demoSessionOptionsParser`
   and `runDemoSession :: DemoSessionOptions -> IO ()`; scope and `subjectRef` become the
   demo values (`subjectRef = Just "demo"`); the preflight additionally prints:

   ```haskell
   putStrLn "Note: completing this session schedules a distillation timer; a running worker will process it (an LLM call)."
   ```

4. In `Kioku.Cli` (`kioku-cli/src/Kioku/Cli.hs`): change the `Command` constructors to
   `Demo DemoOptions` and `DemoSession DemoSessionOptions`, wire
   `command "demo" (info (Demo <$> (helper <*> demoOptionsParser)) ...)` (same for
   `demo-session`), and update `run`.

5. Tests: `parseWith demoOptionsParser []` is `Left` containing
   `Missing: --yes-write-events`; `parseWith demoOptionsParser ["--yes-write-events"]` is
   `Right DemoOptions`; same pair for `demoSessionOptionsParser`; plus
   `redactConnectionString` cases:
   `"host=x dbname=y password=hunter2"` → contains `password=REDACTED` and not `hunter2`;
   `"postgres://me:hunter2@db:5432/kioku"` → contains `me:REDACTED@db:5432` and not
   `hunter2`; a string with no password is unchanged.

6. Docs: rewrite the `kioku demo` / `kioku demo-session` sections of
   `docs/user/cli-reference.md` (flag, preflight, new scope, permanence warning); update the
   demo transcript and scope in `docs/user/getting-started.md` (lines ~70–120) and the bare
   `kioku demo` at `docs/user/README.md:71`; check `docs/user/library-api.md:108` ("mirrors
   `kioku demo`") still reads correctly.

7. Validate and commit:

   ```bash
   cabal test kioku-cli:test:kioku-cli-test
   cabal run kioku -- demo
   ```

   Expected from the second command (exit nonzero, nothing written, no env vars needed):

   ```text
   Missing: --yes-write-events

   Usage: kioku demo --yes-write-events
     Run the memory/session demonstration
   ```

   Optionally, against a disposable dev database:

   ```bash
   PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
     cabal run kioku -- demo --yes-write-events
   ```

   ```text
   kioku demo appends permanent memory events (kioku has no delete).
   Target: host=... dbname=... user=...
   Scope:  kioku_demo/demo/demo
   Recorded memory kioku_memory_01... in scope kioku_demo/demo/demo
   - kioku_memory_01... [preference/high] prefers concise answers
   ```

   Commit: `feat(cli)!: require --yes-write-events for demo commands and write to kioku_demo scope`

### M5 — worker flag conflict

0. First check whether
   docs/plans/11-harden-worker-resilience-with-ack-policy-bounded-retries-and-loop-supervision.md
   has landed (read its Progress section and `git log --oneline --
   kioku-cli/src/Kioku/Cli/Commands/Worker.hs`). If it has, apply the same parser-level
   change to the restructured file; the instructions below describe the file as of
   2026-07-07.

1. In `Worker.hs`, replace the options type and parser:

   ```haskell
   data WorkerOptions
     = WorkerContinuous
     | WorkerBackfill
     | WorkerTimersOnce
     deriving stock (Eq, Show)

   workerOptionsParser :: Parser WorkerOptions
   workerOptionsParser =
     flag'
       WorkerBackfill
       ( long "backfill"
           <> help "Run one embedding backfill pass and exit (conflicts with --timers-once)"
       )
       <|> flag'
         WorkerTimersOnce
         ( long "timers-once"
             <> help "Claim and fire at most one due kioku distillation timer, then exit (conflicts with --backfill)"
         )
       <|> pure WorkerContinuous
   ```

   Replace the nested `if` at the top of `runWorker` with a `case opts of` that calls
   `runTimerOnce env` for `WorkerTimersOnce`, and for the other two constructors keeps the
   existing capability-detection block followed by `runBackfill`/`runContinuousWorker`.
   Do not touch `runBackfill`, `runContinuousWorker`, `runTimerOnce`, `runTimerLoop`.

2. Tests: `parseWith workerOptionsParser []` yields `WorkerContinuous`; `["--backfill"]`
   yields `WorkerBackfill`; `["--timers-once"]` yields `WorkerTimersOnce`;
   `["--backfill", "--timers-once"]` and the reverse order are `Left` (assert the error
   mentions the conflicting flag name).

3. Docs: in the `kioku worker` section of `docs/user/cli-reference.md`, state the two
   one-shot flags are mutually exclusive and that passing both is an error.

4. Validate and commit:

   ```bash
   cabal test kioku-cli:test:kioku-cli-test
   cabal run kioku -- worker --backfill --timers-once
   ```

   Expected (exit nonzero, no database contact):

   ```text
   Invalid option `--timers-once'

   Usage: kioku worker [--backfill | --timers-once]
   ```

   Commit: `feat(cli): make worker --backfill and --timers-once mutually exclusive`

### M6 — dead API and cabal hygiene

1. Re-verify nothing uses `embedBatched`:

   ```bash
   grep -rn "embedBatched" --include="*.hs" .
   mori registry dependents shinzui/kioku --packages
   grep -rn "embedBatched\|parseIdAnyPrefix" /Users/shinzui/Keikaku/bokuno/kikan /Users/shinzui/Keikaku/bokuno/shikigami --include="*.hs"
   ```

   (Adjust the dependent paths if `mori` reports different or additional dependents.) All
   greps must return only the definition site (first command) or nothing (third command).
   Then delete `embedBatched` and `chunksOf` from
   `kioku-core/src/Kioku/Memory/Embedding.hs` and remove `embedBatched` from the export
   list. `chunksOf` is private and only used by `embedBatched`; if the compiler reports it
   still used, stop and investigate.

2. Re-verify the kioku-api dependencies are still unused (docs/plans/13 may have landed code
   in the meantime):

   ```bash
   grep -rn "Data.Generics\|generic-lens" kioku-api/src
   grep -rn "Data.UUID" kioku-api/src
   ```

   For each package with no hits, delete its line from the `build-depends` of
   `kioku-api/kioku-api.cabal` (lines 48 and 53 as of writing: `generic-lens  >=2.2` and
   `uuid          >=1.3`). If either has gained a use, leave that line and record the fact
   in Surprises & Discoveries. Note the comment in `kioku-api/src/Kioku/Prelude.hs` about
   generic-lens refers to a deliberately *not* re-exported module and is not a use.

3. Docs sweep:

   ```bash
   grep -rn "any id prefix\|parseIdAnyPrefix\|embedBatched" docs/user
   grep -rn "rei:intention:intention_demo\|rei/intention/intention_demo" docs/user
   ```

   The first must return nothing. For the second, update any remaining hit that describes
   the *demo commands*; hits that merely use the string as an example scope for `recall`
   (for example `docs/user/cli-reference.md` recall examples) may stay but prefer switching
   them to `kioku_demo/demo/demo` for consistency.

4. Full validation and commit:

   ```bash
   cabal build all
   cabal test kioku-cli:test:kioku-cli-test
   cabal test all   # runs kioku-core's kioku-test too; needs the ephemeral-Postgres tooling from the devShell
   ```

   Commit: `chore!: remove dead embedBatched and unused kioku-api dependencies`
   (breaking: removes a public kioku-core export).

5. Update this plan's Progress, Surprises & Discoveries, and Outcomes & Retrospective
   sections and the EP-7 row/Progress entries in
   docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md.


## Validation and Acceptance

Everything below is observable behavior; run all commands from the repository root.

Build and pure tests (no database, no network):

```bash
cabal build all
cabal test kioku-cli:test:kioku-cli-test
```

Expected: the build succeeds with no warnings introduced by this plan (`-Wall` is on), and
the test run ends with a line like:

```text
All N tests passed
```

where N covers: strict id acceptance/rejection (M1), scope grammar positive and negative
cases (M2), limit bounds for recall and distill (M3), demo/demo-session refusal and
acceptance plus redaction (M4), and worker modes plus conflict (M5).

Behavioral acceptance, one probe per finding (none of these needs a reachable database —
each fails at parse time, which is the point; only the last two touch a database):

1. Wrong-type id is a parse error naming both prefixes:

   ```bash
   cabal run kioku -- distill session kioku_memory_01h455vb4pex5vsknk084sn02q
   ```

   Exit nonzero; output contains `Expected prefix "kioku_session" but got "kioku_memory"!`.
   A genuine session id (copy one from `kioku demo-session --yes-write-events` output or the
   read model) still parses and proceeds to the database stage.

2. Colon-bearing refs parse:

   ```bash
   PG_CONNECTION_STRING='host=127.0.0.1 dbname=definitely_missing' \
     cabal run kioku -- scenes --scope 'ops:host:db.internal:5432'
   ```

   The failure (if any) is a store/connection error, not
   `expected NAMESPACE or NAMESPACE:KIND:REF`. With a real dev database it prints
   `(no scenes)`.

3. Conflicting worker flags error:

   ```bash
   cabal run kioku -- worker --backfill --timers-once
   ```

   Exit nonzero; output contains ``Invalid option `--timers-once'`` and the usage line
   showing `[--backfill | --timers-once]`.

4. Limits are bounded:

   ```bash
   cabal run kioku -- recall q --scope mori --limit -1
   cabal run kioku -- distill session kioku_session_01h455vb4pex5vsknk084sn02q --limit 0
   ```

   Both exit nonzero with `LIMIT must be between 1 and 100 (got -1)` and
   `LIMIT must be between 1 and 50 (got 0)` respectively; no Postgres error text appears.

5. Demo refuses without opt-in and is loud with it:

   ```bash
   cabal run kioku -- demo
   cabal run kioku -- demo-session
   ```

   Both exit nonzero with `Missing: --yes-write-events` and never read
   `PG_CONNECTION_STRING`. Against a disposable dev database,
   `kioku demo --yes-write-events` first prints the three preflight lines (permanence
   warning, redacted target, `Scope:  kioku_demo/demo/demo`) and then the recorded-memory
   output in the `kioku_demo` scope; the password never appears if the connection string
   contains one.

6. Dead API is gone: `grep -rn "embedBatched" --include="*.hs" .` returns nothing, and
   `cabal build all` still succeeds — proving nothing depended on it.

7. Cabal hygiene: `cabal build kioku-api` succeeds after the `build-depends` removal, which
   is the proof the dependencies were unused.

Full-suite regression (requires the nix devShell's ephemeral-Postgres tooling, since
kioku-core's tests migrate a throwaway database):

```bash
cabal test all
```

Expected: both `kioku-test` (kioku-core) and `kioku-cli-test` pass. The kioku-core suite
exercises the renamed `parseIdLenient` at its legacy-decoding call sites, demonstrating the
rename changed no behavior.


## Idempotence and Recovery

Every step in this plan is an ordinary source edit plus a build/test run; all of it is safe
to repeat. No SQL migrations are added, no data is transformed, and nothing writes to a
database except the two optional demo probes — which, by design, now require
`--yes-write-events` and write only into the `kioku_demo` namespace of whatever disposable
database you point them at. If you must exercise the demo write path, use the dev database
from the nix devShell (`just create-database` provisions it), never a shared one.

The renames (M1) and type change (M5) are compile-checked: if any reference is missed,
`cabal build all` fails naming the exact site, so a half-applied milestone cannot silently
persist — finish the rename or `git checkout -- <file>` to back out. Each milestone is a
single commit, so `git revert <sha>` cleanly undoes any one of them; M1 and M4 are marked
breaking (`!`) because they rename a `kioku-api` export and change CLI acceptance, and
reverting them restores the old surface exactly. If M6's grep re-checks show a dependency or
function has gained a user since this plan was written, skip that removal, record it in
Surprises & Discoveries, and proceed — the milestones do not depend on each other.


## Interfaces and Dependencies

Libraries used, all already in the build plan — no new dependencies are added anywhere:
`optparse-applicative >=0.18` (CLI parsing; the pure `execParserPure`/`renderFailure` pair
drives the tests), `mmzk-typeid >=0.7` (TypeID/KindID parsing; its
`Data.KindID.V7.parseString` supplies the strict prefix check and its `TypeIDError` `Show`
instance supplies the two-prefix error message), `tasty`/`tasty-hunit` (test framework,
matching kioku-core's house style), and `text`. The `kioku-cli-test` suite additionally
depends on `kioku-core` only because `RecallOptions` embeds `Kioku.Recall.RecallStrategy`.

Signatures that must exist at the end of each milestone (full module paths):

- M1: `Kioku.Id.parseIdLenient :: (ToPrefix prefix, ValidPrefix (PrefixSymbol prefix)) =>
  Text -> Either Text (KindID prefix)` exported from `kioku-api/src/Kioku/Id.hs`;
  `parseIdAnyPrefix` no longer exists anywhere in the repository;
  `Kioku.Cli.Commands.Distill.parseSessionId :: String -> Either String SessionId` delegates
  to `Kioku.Id.parseId`. Test suite `kioku-cli-test` exists in `kioku-cli/kioku-cli.cabal`.
- M2: `Kioku.Cli.Scope.parseScope :: String -> Either String MemoryScope` (unchanged type,
  first-two-colons semantics).
- M3: `Kioku.Cli.Options.boundedIntReader :: String -> Int -> Int -> ReadM Int` in the new
  exposed module `Kioku.Cli.Options` of kioku-cli.
- M4: `Kioku.Cli.Options.yesWriteEventsFlag :: Options.Applicative.Parser ()` and
  `Kioku.Cli.Options.redactConnectionString :: Text -> Text`;
  `Kioku.Cli.Commands.Demo.DemoOptions`, `demoOptionsParser :: Parser DemoOptions`,
  `runDemo :: DemoOptions -> IO ()`; `Kioku.Cli.Commands.DemoSession.DemoSessionOptions`,
  `demoSessionOptionsParser :: Parser DemoSessionOptions`,
  `runDemoSession :: DemoSessionOptions -> IO ()`.
- M5: `Kioku.Cli.Commands.Worker.WorkerOptions` is the sum
  `WorkerContinuous | WorkerBackfill | WorkerTimersOnce` (deriving `Eq`, `Show`);
  `workerOptionsParser :: Parser WorkerOptions`; `runWorker :: WorkerOptions -> IO ()`.
- M6: `Kioku.Memory.Embedding` no longer exports `embedBatched`; its remaining exports
  (`EmbeddingConfig (..)`, `EmbedError (..)`, `resolveEmbeddingConfig`, `toEmbeddingModel`,
  `embedWithRetry`, `sha256Hex`) are unchanged. `kioku-api/kioku-api.cabal` lists neither
  `generic-lens` nor `uuid` (unless the implementation-time re-check found a new use, which
  must then be recorded in Surprises & Discoveries).

Cross-plan constraints (sibling plans referenced by path; both were unstarted skeletons when
this plan was authored, so re-read their Progress sections before starting the affected
milestones):

- `kioku-cli/src/Kioku/Cli/Commands/Worker.hs` is structurally owned by
  docs/plans/11-harden-worker-resilience-with-ack-policy-bounded-retries-and-loop-supervision.md
  and also locally edited by
  docs/plans/9-make-l1-distillation-idempotent-and-debounce-distillation-timers.md
  (candidate wiring). Soft dependency: prefer landing M5 after the resilience plan; if M5
  lands first, it must stay confined to the options type, the parser, and the top-level
  dispatch `case` so the resilience plan rebases trivially. The masterplan's "Worker CLI
  wiring" integration point records the same ownership split.
- L1 distillation id-parsing semantics (how `kioku-core/src/Kioku/Distill/L1.hs` treats
  LLM-returned memory ids) are owned by docs/plans/9-…; this plan only renames the function
  those sites call, changing no behavior. The same applies to the timer correlation-id parse
  in `kioku-core/src/Kioku/Distill/Timer/Worker.hs`, a file docs/plans/9 and docs/plans/11
  both touch — the rename is a one-token change that rebases in either direction.
- docs/plans/13-harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes.md
  owns scope-identity validation (namespace/kind character sets, collision-proof rendering)
  and may add kioku-api code; M2 deliberately changes only the CLI-side string split, and
  M6's cabal removals are gated on an implementation-time re-grep for exactly this reason.
- The rename in M1 and the removal in M6 alter public exports of `kioku-api` and
  `kioku-core`. Registered dependents were checked on 2026-07-07 via
  `mori registry dependents shinzui/kioku --packages` (kikan, shikigami; neither uses the
  affected symbols); rerun that check at implementation time as specified in Concrete Steps.
