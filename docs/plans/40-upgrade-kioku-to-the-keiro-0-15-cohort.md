---
id: 40
slug: upgrade-kioku-to-the-keiro-0-15-cohort
title: "Upgrade Kioku to the Keiro 0.15 cohort"
kind: exec-plan
created_at: 2026-08-31T12:13:37Z
intention: "intention_01m1bvtf8deckamyjk3hqzgyns"
---

# Upgrade Kioku to the Keiro 0.15 cohort

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kioku is a memory runtime for AI agents, written in Haskell. It stores what an agent
remembers as an event-sourced history in PostgreSQL. It does not implement event sourcing
itself: it composes a library called **Keiro**, which supplies the event store plumbing,
the read-model projections, the durable timers, and the SQL migrations that create Keiro's
own framework tables. Keiro publishes several packages under one shared version number, and
Kioku currently requires the `0.14` series of three of them: `keiro`, `keiro-core`, and
`keiro-migrations`.

Keiro released `0.15.0.0` on 2026-08-30. After this plan is done, a person who checks out
this repository and runs `cabal build all` will see Cabal resolve `keiro-0.15.0.0`,
`keiro-core-0.15.0.0`, and `keiro-migrations-0.15.0.0` instead of the `0.14` versions, every
test suite will still pass, and the composed database migration plan that `kioku-migrate`
applies will still contain exactly 55 migrations. In other words: the user-visible outcome
is that Kioku keeps doing exactly what it does today, while sitting on the current Keiro
release rather than a superseded one, so that a downstream application is not forced to hold
Keiro back in order to use Kioku.

There is a second, less obvious outcome, and it is the reason this plan is not simply a
one-line edit. Keiro `0.15.0.0` *is* a breaking release — just not for Kioku. Its break lives
entirely in `keiro-dsl`, a code-generation package that Kioku does not depend on. But a
downstream project that depends on Kioku **and** on `keiro-dsl` will be dragged onto
`keiro-dsl 0.15` the moment it takes Kioku's next release, and it will need real source
migration work to survive that. This repository publishes machine-readable upgrade guidance
for exactly this situation, under `blueprints/kioku-upgrade/`. So the second outcome is that
a downstream project running the upgrade tool across this version window is told, exactly
once and in the right order, to do Keiro's `0.14 → 0.15` migration work — instead of
discovering it as a compile error with no explanation.

This plan stops before publishing anything to Hackage. Cutting the release is a separate,
user-initiated step (see "What this plan deliberately excludes").


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

**Milestone 1 — move the bounds and prove the solve**

- [x] Confirm the working tree is clean and record the pre-change resolved Keiro version. (2026-08-31)
- [x] Raise `keiro` and `keiro-core` to `^>=0.15.0.0` in `kioku-core/kioku-core.cabal`
      (library stanza and test-suite stanza). (2026-08-31)
- [x] Raise `keiro-migrations` to `^>=0.15.0.0` in `kioku-migrations/kioku-migrations.cabal`
      (library stanza and test-suite stanza). (2026-08-31)
- [x] Raise the `keiro-pgmq` constraint to `^>=0.15.0.0` in `cabal.project`. (2026-08-31)
- [x] Run `cabal build all --dry-run` and confirm the plan names the three `0.15.0.0`
      packages and that no other cohort member moved. (2026-08-31)
- [x] Run `cabal build all` to a clean compile — exit 0, no errors. (2026-08-31)

**Milestone 2 — prove behavior, not just compilation**

- [x] Run `cabal test all` and record the result — four suites, 421 tests, all PASS. (2026-08-31)
- [x] Confirm the composed migration plan is still 55 migrations (Kiroku 11, Keiro 31,
      Kioku 13) — the assertions in `kioku-migrations/test/Main.hs` passed unchanged, and
      `kioku-migrate status` against the local database independently reports the same
      split with 0 pending and 0 issues. (2026-08-31)
- [x] Confirm no documentation migration count needed editing — all eight statements already read 55 / Keiro 31. (2026-08-31)

**Milestone 3 — write the changelogs**

- [x] Add an `## Unreleased` section to the root `CHANGELOG.md` describing the Keiro move. (2026-08-31)
- [x] Add matching entries to all five package changelogs. (2026-08-31)

**Milestone 4 — publish the upgrade guidance for downstream consumers**

- [x] Add the new edge file `blueprints/kioku-upgrade/migrations/0-5-1-0-to-0-5-2-0.md`. (2026-08-31)
- [x] Declare the edge in `blueprints/kioku-upgrade/blueprint.dhall` with the entailed
      `keiro-upgrade` `0.14.0.0 -> 0.15.0.0` edge. (2026-08-31)
- [x] Add the new rows to `blueprints/kioku-upgrade/files/kioku-cohort-versions.md` — runtime, migration, and composed-plan tables. (2026-08-31)
- [x] Add the edge to the table in `blueprints/kioku-upgrade/README.md`, with a note on why a bounds-only release can still owe an edge. (2026-08-31)
- [x] Validate the blueprint with `seihou validate-blueprint` — passed. (2026-08-31)
- [x] ~~Preview the chained migration with `seihou agent --debug migrate`.~~ Not possible
      from the producing repository; replaced by verifying the entailed edge exists,
      committed, in Keiro's repository with the exact `from`/`to`. Verified. See Surprises &
      Discoveries. (2026-08-31)

**Milestone 5 — commit and close out**

- [x] Commit with the `ExecPlan:`, `Intention:`, and `Refs: mori://shinzui/keiro` trailers — `1e96782` (deps) and `d30f6df` (blueprint). (2026-08-31)
- [x] Fill in Outcomes & Retrospective. (2026-08-31)
- [x] Run the ADR distillation pass described in "Validation and Acceptance" — no ADR created; reasoning recorded in Outcomes & Retrospective. (2026-08-31)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

The following were found during plan research, before any edit was made. They are recorded
here because they are the evidence the plan's scope rests on.

**Keiro's three Kioku-facing packages contain zero source changes in 0.15.0.0.** The release
touched only version numbers, changelogs, and one bound inside `keiro.cabal`:

```text
$ cd /Users/shinzui/Keikaku/bokuno/keiro
$ git diff --stat keiro-0.14.0.0..keiro-0.15.0.0 -- keiro keiro-core keiro-migrations
 keiro-core/CHANGELOG.md                 |  5 +++
 keiro-core/keiro-core.cabal             |  2 +-
 keiro-migrations/CHANGELOG.md           |  5 +++
 keiro-migrations/keiro-migrations.cabal |  2 +-
 keiro/CHANGELOG.md                      |  8 +++++
 keiro/keiro.cabal                       | 58 ++++++++++++++++-----------------
 6 files changed, 49 insertions(+), 31 deletions(-)
```

`keiro-core` and `keiro-migrations` both say so in their own changelogs: "No changes this
release. … republished at the shared version for the lockstep package set." The 58-line
`keiro.cabal` diff is the version line plus adding a lockstep `keiro-test-support` bound to
the test-suite and benchmark stanzas — components Kioku never builds.

**The upstream cohort under Keiro did not move.** Keiro `0.15.0.0` still declares
`keiki >=0.9 && <0.10`, `kiroku-store >=0.8 && <0.9`, `shibuya-core ^>=0.9.0.0`, and
`keiro-migrations` still declares `kiroku-store-migrations ^>=0.4.0.0` and
`pg-migrate ^>=1.1.0.0`. These are the same bounds the `0.14` series declared, which is why
this plan moves no other dependency.

**Keiro's migration manifest is unchanged at 31 files**, so the composed plan stays at 55:

```text
$ wc -l < /Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations/migrations/manifest
31
```

**The solve already works.** A non-mutating dry run, forcing Keiro to `0.15.0.0` via
`--allow-newer` without editing any file, produced a complete install plan:

```text
$ cabal build all --dry-run --builddir=<scratch> \
    --allow-newer=kioku-core:keiro,kioku-core:keiro-core,kioku-migrations:keiro-migrations \
    --constraint="keiro ==0.15.0.0" --constraint="keiro-core ==0.15.0.0" \
    --constraint="keiro-migrations ==0.15.0.0" --constraint="keiro-pgmq ^>=0.15.0.0"
Resolving dependencies...
Build profile: -w ghc-9.12.4 -O1
In order, the following would be built (use -v for more details):
 - baikai-0.6.0.1 (lib) (requires download & build)
 - kioku-api-0.5.1.0 (lib) (first run)
 - keiro-core-0.15.0.0 (lib) (requires download & build)
 - keiro-migrations-0.15.0.0 (lib) (requires download & build)
 …
 - keiro-0.15.0.0 (lib) (requires download & build)
 …
```

This matters because the usual failure mode of a cohort upgrade in this family of libraries
is not a compile error but an unsatisfiable solve, caused by a *middle* package that caps
something below what the new release needs. There is no such cap here.

**The dry run also surfaced `baikai-0.6.0.1`, a newer patch than the `0.6.0.0` this repo has
been building.** That is a different upgrade, owned by `just upgrade-baikai` and its Mori
automation. It is explicitly out of scope for this plan; see the Decision Log.

The following were found during implementation.

**The development shell's `sed` is GNU, not BSD, so the plan's original in-place edit
command was wrong.** Written as `sed -i '' 's/…/…/' file` — the BSD form, correct for stock
macOS — it failed four times over:

```text
sed: can't read s/\(keiro *\)\^>=0\.14\.0\.0/\1^>=0.15.0.0/: No such file or directory
```

GNU `sed` takes the backup suffix attached to `-i`, so the bare `''` was consumed as the
script and the real script became a filename. `perl -pi -e` is portable across both and is
what Concrete Steps now specifies. Nothing was modified by the failed attempt — the error is
a read failure before any write — so the retry started from the same clean state.

**The build plan resolved `baikai-0.6.0.1` as predicted, without any bound changing.** It
sits inside the existing `baikai ^>=0.6.0.0`, so Cabal simply preferred the newest patch. No
edit was made to chase it, per the Decision Log.

**The chained migration preview cannot be run from this repository, for two independent
reasons.** The plan asked for `seihou agent --debug migrate kioku-upgrade --from 0.5.1.0
--to 0.5.2.0` as the check that the entailment resolves. It does not work here:

```text
$ seihou agent --debug migrate kioku-upgrade --from 0.5.1.0 --to 0.5.2.0
[error] Blueprint 'kioku-upgrade' not found. Searched in:
  /Users/shinzui/Keikaku/bokuno/kioku/.seihou/modules
  /Users/shinzui/.config/seihou/modules
  /Users/shinzui/.config/seihou/installed
```

Seihou resolves a blueprint by *installed name*, not by path, and `seihou install` takes a
git URL — so the only `kioku-upgrade` it could find is a published one, which by definition
would not carry an edge that has not been pushed yet. A producing repository therefore cannot
preview its own new edge; that check belongs to a consumer after release.

The second reason is that the locally installed `keiro-upgrade` is stale. It declares only
`0.12.0.0 -> 0.13.0.0`, so even a resolvable chain would have failed to find the entailed
edge:

```text
$ grep -E 'from = |to = ' ~/.config/seihou/installed/keiro-upgrade/blueprint.dhall
        , from = "0.12.0.0"
        , to = "0.13.0.0"
```

The substitute check — and the one that actually matters, because it is the single thing
`validate-blueprint` cannot verify — is that the entailed edge exists in Keiro's own
repository with exactly the `from` and `to` this blueprint names. It does:

```text
$ grep -nE 'from = |to = ' /Users/shinzui/Keikaku/bokuno/keiro/blueprints/keiro-upgrade/blueprint.dhall
40:        , from = "0.14.0.0"
41:        , to = "0.15.0.0"
42:        , prompt = ./migrations/0-14-to-0-15.md as Text
```

That edge is committed in Keiro's `de574cdc chore(release): 0.15.0.0`, so a consumer running
`seihou install https://github.com/shinzui/keiro.git --module keiro-upgrade` will have it.
Recorded here so the next person does not read the "not found" error as an authoring
mistake.

**Piping `cabal test all` into `tail` silently hid both the results and the exit code.** The
plan's first draft of Concrete Steps Step 3 said `cabal test all 2>&1 | tail -40`. Run that
way, the retained output held only the last suite — three of the four `Test suite …: PASS`
lines had scrolled past — and the shell reported `tail`'s exit status, not Cabal's, so a
failing run would have looked identical to a passing one. The step now says to run it
unpiped, or to `set -o pipefail` and grep for the summary lines instead of truncating. Run
correctly, all four suites pass:

```text
All 125 tests passed (0.00s)   Test suite kioku-api-test: PASS
All  53 tests passed (7.95s)   Test suite kioku-cli-test: PASS
All  24 tests passed (17.28s)  Test suite kioku-migrations-test: PASS
All 219 tests passed (50.14s)  Test suite kioku-test: PASS
[cabal test all exit: 0]
```

**No flake this time.** The known intermittent failure — roughly one full run in four or five
— did not appear; the suites passed on the first complete run. Noted so the absence is not
read as evidence the flake is gone.

**The database check confirms the migration story independently of the test assertions.**
Running the freshly built `kioku-migrate` against the local development database:

```text
$ DATABASE_URL="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" cabal run -v0 kioku-migrate -- status
…
applied=55
pending=0
unknown=0
issues=0
```

Split by component: Kiroku 11, Keiro 31, Kioku 13. This is the stronger form of the claim in
Purpose — not "the assertions still say 55" but "a binary built against Keiro 0.15.0.0 reads
55 applied migrations out of a real database with nothing pending and no checksum issues."

**`docs/adr/` is not a profile-governed OKF bundle, though it looks like one.** The plan's
distillation step assumed it might be and pointed at
`okf validate docs/adr --profile docs/adr/profile.dhall`. That file does not exist, and
`mori.dhall` declares only three OKF bundles — `docs/improvement-requests`,
`docs/bug-reports`, and `docs/reviews`:

```text
$ ls docs/adr/ | grep -iE 'profile|index'      # no output
$ grep -n 'docs/adr' mori.dhall                # no output
```

The ADRs still carry OKF-shaped frontmatter including `docId: ADR-10` and the bundle has the
reserved `log.md`, so the corpus follows the convention without profile enforcement. The
distillation section now says so, and says to allocate a new `ADR-N` by reading existing
`docId` values rather than by running `okf id next` against a profile that is not there.


## Decision Log

Record every decision made while working on the plan.

- Decision: Move only `keiro`, `keiro-core`, `keiro-migrations`, and the forward-looking
  `keiro-pgmq` constraint. Leave `keiki`, `keiki-codec-json`, `kiroku-store`,
  `kiroku-store-migrations`, `shibuya-core`, `shibuya-kiroku-adapter`,
  `shibuya-pgmq-adapter`, the `pgmq-*` constraints, `pg-migrate`, and the Baikai/Shikumi
  packages exactly where they are.
  Rationale: Keiro `0.15.0.0` declares the same upstream bounds as `0.14.0.0` (verified by
  reading the published `.cabal` files), so nothing else is compelled to move. Widening a
  bound that the release did not require would admit a cohort Kioku was never built against.
  Date: 2026-08-31

- Decision: Do not pick up `baikai-0.6.0.1` in this plan even though the solver offers it.
  Rationale: Baikai upgrades have their own entry point in this repository —
  `just upgrade-baikai`, driven by `scripts/upgrade-baikai.sh` and the `upgrade-baikai-cohort`
  Mori reaction declared in `mori.automation.dhall`. Mixing an unrelated cohort into a Keiro
  bump makes both harder to review and to revert. If the build happens to resolve `0.6.0.1`
  because Cabal prefers the newest patch within the existing `^>=0.6.0.0` bound, that is
  fine and requires no edit; what this plan will not do is *change a bound* to chase it.
  Date: 2026-08-31

- Decision: Expect no Kioku source changes, and treat any required source change as a signal
  to stop and re-scope.
  Rationale: The three Keiro packages Kioku consumes have byte-identical sources across
  `0.14.0.0` and `0.15.0.0`. If Haskell source in this repository has to change to compile
  against `0.15`, the premise of this plan is wrong and the implementer should record that in
  Surprises & Discoveries before proceeding.
  Date: 2026-08-31

- Decision: Write a `kioku-upgrade` blueprint edge for this version window, even though
  Kioku's own behavior does not change.
  Rationale: The blueprint's purpose is not to describe Kioku's diff; it is to make sure a
  downstream project crosses each upstream migration exactly once, in order. Keiro
  `0.15.0.0` breaks `keiro-dsl`, and a project that consumes both Kioku and `keiro-dsl` is
  forced onto the new `keiro-dsl` by taking Kioku's next release. Without an edge here, that
  project crosses nothing and gets no guidance. The edge is nearly all *entailment*: it
  declares `keiro-upgrade 0.14.0.0 -> 0.15.0.0` and otherwise reports itself not applicable.
  Date: 2026-08-31

- Decision: Target Kioku version `0.5.2.0` for the blueprint edge's `to` field.
  Rationale: The current version is `0.5.1.0` (all five packages share it). This change adds
  no API and breaks nothing in Kioku, but it does move a dependency's major series, which is
  the same shape as the `0.4.0.0 → 0.4.1.0` Baikai cohort move — released as a minor bump.
  The release skill at `agents/skills/release/SKILL.md` derives the level from Conventional
  Commit types and confirms with the user, so the number is not final until the release runs.
  If the release lands on a different version, rename the edge file and update the three
  places that name the version. See "Idempotence and Recovery".
  Date: 2026-08-31

- Decision: Stop before cutting the Hackage release.
  Rationale: Requested scope. The precedent commit pair `5ab7aee` ("chore(deps): upgrade
  Baikai and Shikumi cohort") followed by `d071aea` ("chore(release): 0.5.1.0") shows the
  repository already separates a dependency move from the release that ships it, with the
  dependency commit writing its changelog entry under an `## Unreleased` heading that the
  release commit later renames.
  Date: 2026-08-31


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

### Completed 2026-08-31

Both outcomes stated in Purpose were achieved, and the plan's central prediction — that this
would be bounds-only — held exactly.

**Kioku sits on the current Keiro release.** Seven lines changed across three files;
`cabal build all` compiles clean and the build plan resolves `keiro 0.15.0.0`,
`keiro-core 0.15.0.0`, and `keiro-migrations 0.15.0.0`. **No Haskell source changed** — the
Decision Log's stop condition ("treat any required source change as a signal to stop and
re-scope") was never triggered. All four suites pass: 421 tests across `kioku-api-test` (125),
`kioku-cli-test` (53), `kioku-migrations-test` (24), and `kioku-test` (219). The composed
migration plan is unchanged at 55 (Kiroku 11, Keiro 31, Kioku 13), proved twice — by the
unedited assertions in `kioku-migrations/test/Main.hs`, and independently by `kioku-migrate
status` against the local database reporting `applied=55 pending=0 unknown=0 issues=0`.

**Downstream consumers are routed through Keiro's edge.** `blueprints/kioku-upgrade` now
declares `0.5.1.0 -> 0.5.2.0`, entailing `keiro-upgrade 0.14.0.0 -> 0.15.0.0`, validated by
`seihou validate-blueprint`. The entailed edge was confirmed to exist in Keiro's repository
with exactly that `from`/`to`, committed in `de574cdc`.

Shipped in two commits, `1e96782 chore(deps)` and `d30f6df docs(blueprint)`, both carrying the
`ExecPlan:`, `Intention:`, and `Refs: mori://shinzui/keiro` trailers. Pre-commit `treefmt`
passed on both.

**What remains.** Cutting the release, which was deliberately excluded. The changelogs are
staged under `## Unreleased` headings for the release skill to rename. The version this plan
assumed, `0.5.2.0`, is not final until that skill runs — if it lands elsewhere, follow the
recovery path in Idempotence and Recovery before publishing, because a blueprint edge whose
`to` names no real release will never match a consumer's version probe.

**Lessons.**

Three of the plan's own commands were wrong, all in the same way: each assumed an environment
detail rather than checking it. `sed -i ''` assumed BSD sed where the dev shell provides GNU
sed. `cabal test all | tail -40` assumed the pipe was cosmetic, when it discarded three of
four suite results *and* replaced Cabal's exit status with `tail`'s — a failing run would have
looked identical to a passing one, which is the more dangerous half. `okf validate --profile
docs/adr/profile.dhall` assumed a profiled ADR bundle that this repository does not have. All
three are corrected in place. The pattern worth carrying forward: a plan's *verification*
commands deserve more scepticism than its edit commands, because a broken edit command fails
loudly while a broken verification command reports success.

The `seihou agent --debug migrate` preview turned out to be structurally impossible from the
producing repository — Seihou resolves blueprints by installed name from a git URL, so a
repository cannot preview an edge it has not published. That is not a defect to fix; it means
the check belongs to a consumer after release, and the producer's substitute is verifying the
entailed edge's `from`/`to` directly against the upstream repository.

### ADR distillation pass

Run 2026-08-31. **No ADR created**, and the reasoning is recorded here rather than left
implicit.

Reviewing the Decision Log, Surprises & Discoveries, and the outcomes above, one candidate was
genuinely durable: *the test for declaring a `kioku-upgrade` edge is not "did Kioku change"
but "does taking this release force a project onto an upstream change"*. That is a
project-level judgment about Kioku's consumer contract, and it is easy to get wrong — the
blueprint README's own note that gaps are legal "when no agent intervention was needed"
actively invites the opposite conclusion after a bounds-only release.

It was not promoted to an ADR because it already has a better home. The rule is now written
into `blueprints/kioku-upgrade/README.md`, immediately beside the edge table that
demonstrates it and inside the "For maintainers" material a person reads precisely when they
are about to make this decision. An ADR would duplicate it further from the point of use. If
the rule ever generalizes beyond this blueprint — to how Kioku decides any consumer-facing
obligation — that is when it earns a record in `docs/adr/`.

Everything else distilled to task-local execution notes: the three corrected commands, the
absence of the known test flake on this run, and the Seihou preview limitation. All stay in
this plan.


## Context and Orientation

### What this repository is

`/Users/shinzui/Keikaku/bokuno/kioku` is a Haskell project built with Cabal (not Stack) on
GHC 9.12.4, pinned by the `with-compiler:` line in `cabal.project`. It publishes five
packages, all sharing one version number, currently `0.5.1.0`:

- `kioku-api/` — wire types, identifiers, and a small prelude. No internal dependencies.
- `kioku-migrations/` — the SQL migration component plus a `test-support` sub-library.
- `kioku-core/` — the runtime: memory writes, recall, sessions, distillation, embeddings.
- `kioku-cli/` — a library and the `kioku` executable.
- `kioku-migrate/` — the `kioku-migrate` executable, which applies database migrations.

A Nix development shell provides the toolchain and a local PostgreSQL. `Justfile` holds the
short commands (`just migrate`, `just create-database`, `just new-migration`,
`just upgrade-baikai`). Note that this repository has **no** `just verify` recipe; the
validation commands are the plain Cabal ones given later in this plan.

### The library stack under Kioku, in plain terms

Four libraries sit under Kioku. You do not need to understand them deeply to do this work,
but you need to know they exist and that they move as a set:

- **Keiro** — event sourcing and durable workflows. Kioku uses `keiro` (the runtime),
  `keiro-core` (pure types and codecs), and `keiro-migrations` (Keiro's own SQL). Keiro also
  publishes `keiro-dsl`, `keiro-ops`, `keiro-pgmq`, and `keiro-test-support`, **none of which
  Kioku depends on**. All Keiro packages share one version number and are released together
  — this is called a *lockstep* release, and it means you cannot hold one at `0.14` while
  another is at `0.15`.
- **Kiroku** — the event store itself (`kiroku-store`, `kiroku-store-migrations`), plus
  `shibuya-kiroku-adapter`, which despite its name lives in the Kiroku repository.
- **Keiki** — the pure functional core (`keiki`, `keiki-codec-json`).
- **Shibuya** — message transport (`shibuya-core`).

Kioku also uses **Baikai** for model access and **Shikumi** for prompt/tooling support. Those
are a separate cohort with their own automation and are not touched here.

*Cohort* is the word this repository uses for "the set of upstream versions a given Kioku
release was built against". `blueprints/kioku-upgrade/files/kioku-cohort-versions.md` is the
table that records it, one row per Kioku release.

### Where the Keiro bounds actually live

Only two `.cabal` files and one project file name a Keiro package. A Cabal bound written
`^>=0.14.0.0` means "at least 0.14.0.0 and less than 0.15" — so raising to `0.15` is a real
edit in every one of these places, not something the solver will do on its own.

`kioku-core/kioku-core.cabal`, library stanza (around line 128):

```cabal
    , keiki                   ^>=0.9.0.0
    , keiro                   ^>=0.14.0.0
    , keiro-core              ^>=0.14.0.0
    , kioku-api               ^>=0.5.1.0
    , kiroku-store            ^>=0.8.0.0
```

`kioku-core/kioku-core.cabal`, test-suite stanza (around line 187):

```cabal
    , keiro                          ^>=0.14.0.0
    , keiro-core                     ^>=0.14.0.0
    , kioku-api                      ^>=0.5.1.0
```

`kioku-migrations/kioku-migrations.cabal`, library stanza (around line 62):

```cabal
    , keiro-migrations         ^>=0.14.0.0
    , kiroku-store-migrations  ^>=0.4.0.0
    , pg-migrate               ^>=1.1.0.0
```

`kioku-migrations/kioku-migrations.cabal`, test-suite stanza (around line 96):

```cabal
    , keiro-migrations               ^>=0.14.0.0
    , kioku-migrations               ^>=0.5.1.0
```

`cabal.project`, in the `constraints:` block:

```cabal
constraints:
  http-client-tls ^>=0.4.0,
  keiki-codec-json ^>=0.9.0.0,
  keiro-pgmq ^>=0.14.0.0,
  pgmq-core ^>=0.5.0.0,
  …
```

`keiro-pgmq` is **not** in Kioku's build closure. The comment above that block explains why
the entries are there anyway: they are forward-looking pins for optional integrations, kept
explicit so a consumer cannot revive an older PGMQ stack. `keiki-codec-json` is different —
that one *is* in the closure, because Keiro depends on it directly, and Keiro `0.15` still
wants `keiki-codec-json >=0.9 && <0.10`, so its `^>=0.9.0.0` constraint stays as it is.

`kioku-cli/kioku-cli.cabal` and `kioku-migrate/kioku-migrate.cabal` name `kiroku-store` but
no Keiro package, so they need no edit; Keiro reaches them through `kioku-core`.

### What changed in Keiro 0.15.0.0

Keiro's changelog records one breaking change and it is confined to `keiro-dsl`: generated
and package-authored record types dropped their field selector functions and owner-prefixed
labels in favor of repeated labels with `DuplicateRecordFields`, `NoFieldSelectors`, and
`OverloadedRecordDot`; and existing generated projects must explicitly adopt an
`idiomatic-v2` generated-Haskell edition before their next scaffold run. The changelog states
plainly that `.keiro` syntax, serialized identities, and runtime behavior are unchanged, and
that the release "entails no upstream edge because the Kiroku, Keiki, and Shibuya cohorts are
unchanged."

Kioku does not depend on `keiro-dsl` — verified by grep across every `.cabal` file — so none
of that reaches this repository's source.

### Relevant ADRs

Following the ADR workflow in `.claude/skills/exec-plan/ADR.md`, the twelve records under
`docs/adr/` were scanned by filename and heading. They cover memory-space partitioning
(`the-partition-is-a-column-not-a-schema.md`, `the-aggregate-enforces-the-partition.md`,
`the-partition-reaches-the-filesystem-as-a-digest.md`,
`legacy-data-lands-in-one-explicit-space.md`), recall targeting
(`an-explicit-recall-target-replaces-the-overloaded-scope.md`,
`each-recall-target-gets-its-own-statement.md`), identity and authorization boundaries
(`kioku-owns-memory-not-identity.md`, `namespace-is-not-a-security-boundary.md`,
`historical-attribution-is-marked-never-invented.md`), schema ownership
(`projections-live-in-the-kioku-schema.md`), and event codec ownership
(`consumers-own-one-time-foreign-event-migration-codecs.md`).

**No existing ADR governs dependency bounds or cohort upgrade policy.** Two are adjacent and
worth knowing about, though neither constrains this work:

- [`docs/adr/projections-live-in-the-kioku-schema.md`](../adr/projections-live-in-the-kioku-schema.md)
  records that Kioku shares the host's event store but owns its projections in a dedicated
  `kioku` PostgreSQL schema, with Keiro's framework tables living in a `keiro` schema. It
  matters here only as the reason the composed migration plan has three segments whose counts
  this plan must confirm are unchanged.
- [`docs/adr/consumers-own-one-time-foreign-event-migration-codecs.md`](../adr/consumers-own-one-time-foreign-event-migration-codecs.md)
  records that translating another application's event format is the consumer's job, not
  Kioku's. It is referenced by the existing `kioku-upgrade` blueprint prompt and is worth
  reading before editing anything under `blueprints/`, so the new edge's tone matches.

Whether this plan should *create* an ADR is answered in "Validation and Acceptance": only if
implementation turns up durable project judgment, which a clean bounds-only bump will not.

### What this plan deliberately excludes

Publishing to Hackage. `agents/skills/release/SKILL.md` owns that, it is invoked by the user,
and it has its own pre-flight gates. This plan leaves the repository in a state where that
skill can run: bounds moved, tests green, changelogs written under an `## Unreleased`
heading that the release commit renames to the chosen version.


## Plan of Work

The work is five milestones. The first two are the upgrade proper and are strictly
sequential. The third and fourth are documentation and downstream guidance, and could be
done in either order. The fifth commits.

### Milestone 1 — Move the bounds and prove the solve

**Scope.** Change five lines across three files, then prove Cabal resolves the new Keiro
release and GHC compiles every component against it.

**What will exist at the end.** A working tree in which `cabal build all` completes and
`dist-newstyle/cache/plan.json` names `keiro-0.15.0.0`, `keiro-core-0.15.0.0`, and
`keiro-migrations-0.15.0.0`.

The edits are mechanical. In `kioku-core/kioku-core.cabal`, change `keiro` and `keiro-core`
from `^>=0.14.0.0` to `^>=0.15.0.0` in **both** the library `build-depends` and the
test-suite `build-depends` — there are four occurrences in that one file, two per stanza.
In `kioku-migrations/kioku-migrations.cabal`, change `keiro-migrations` from `^>=0.14.0.0`
to `^>=0.15.0.0` in both its library and test-suite `build-depends`, two occurrences. In
`cabal.project`, change the `keiro-pgmq ^>=0.14.0.0` constraint to `^>=0.15.0.0`.

Preserve the existing column alignment in the `.cabal` files. Cabal does not care, but this
repository aligns the `^>=` operators into a column and a misaligned line will show up as
noise in review. `0.14.0.0` and `0.15.0.0` are the same width, so a careful in-place
substitution keeps alignment automatically.

Do not touch any other bound. In particular `shibuya-pgmq-adapter ^>=0.14.0.0` in
`cabal.project` looks like it should move alongside `keiro-pgmq`, and it must not: that
`0.14` is Shibuya's version number, not Keiro's, `0.14.0.0` is the newest published
`shibuya-pgmq-adapter`, and Keiro's own `keiro-pgmq 0.15.0.0` declares
`shibuya-pgmq-adapter ^>=0.14.0.0` itself.

**Acceptance.** `cabal build all --dry-run` lists the three Keiro packages at `0.15.0.0` and
lists no other cohort member at a version different from what the tree resolved before the
edit. Then `cabal build all` finishes without errors.

### Milestone 2 — Prove behavior, not just compilation

**Scope.** Run the full test suite and confirm the database-facing invariant that a Keiro
upgrade can silently break: the shape of the composed migration plan.

**What will exist at the end.** Recorded evidence that all suites pass and that the composed
plan is still 55 migrations.

Two things make this more than a formality. First, compiling is not enough in this codebase:
`mkEventStreamOrThrow` validates Kioku's event stream definitions against Keiki at *runtime*
and calls `error` if validation returns warnings, so a Keiro/Keiki mismatch surfaces as a
test failure rather than a type error. Second, `kioku-migrations/test/Main.hs` hardcodes the
composed migration count and the full ordered list of migration ids, including
`migrationId "keiro" "0031"`. If Keiro `0.15` had added a migration, those assertions would
fail and several documents would need editing. Research says it did not — Keiro's manifest
still holds 31 entries — so the expected outcome is that these assertions pass untouched.

The tests provision their own ephemeral PostgreSQL databases and do not touch the `./db`
development database, so this step is safe to run repeatedly.

Be aware of a known intermittent failure: roughly one full `cabal test all` run in four or
five fails with no reproducible case. If a suite fails, re-run it before concluding that the
bump broke something, and record what you saw in Surprises & Discoveries either way.

**Acceptance.** `cabal test all` reports every suite passing. The count assertions in
`kioku-migrations/test/Main.hs` (`@?= 55`, four sites) and `expectedForwardMigrationIds` pass
without modification. A grep confirms no documentation count needs changing.

### Milestone 3 — Write the changelogs

**Scope.** One `## Unreleased` entry in the root changelog and one in each of the five
package changelogs.

**What will exist at the end.** A reader of any package's changelog can see, before the
release is cut, that the Keiro dependency moved and that nothing else did.

The root `CHANGELOG.md` gets a new `## Unreleased` section above `## 0.5.1.0 — 2026-08-29`,
with a `### Changed` subsection. This matches exactly what commit `5ab7aee` did for the
Baikai cohort move, which the subsequent release commit then renamed to `## 0.5.1.0`.

Each package changelog gets its own entry, phrased for that package. `kioku-core` and
`kioku-migrations` are the two that actually declare Keiro bounds and should say what moved.
`kioku-api`, `kioku-cli`, and `kioku-migrate` should say what their sibling entries said for
the Baikai move: a version bump only, to stay on Kioku's shared version, with their own
source and API unchanged. `kioku-migrations` should additionally state that the composed plan
is unchanged at 55 migrations, since that is the fact a downstream operator will look for.

**Acceptance.** All six changelogs carry an `## Unreleased` section describing the move, and
none of them claims a behavior change that did not happen.

### Milestone 4 — Publish the upgrade guidance for downstream consumers

**Scope.** Add one edge to the `kioku-upgrade` blueprint and update its two reference
documents.

**What will exist at the end.** A downstream project that runs
`seihou agent migrate kioku-upgrade` across this version window is routed through Keiro's
`0.14.0.0 → 0.15.0.0` migration edge before being told that Kioku itself requires nothing.

Some vocabulary first, because none of it is ordinary English. A **blueprint** is a directory
of agent-readable upgrade instructions, described by a Dhall file. An **edge** is one
`from → to` version window inside a blueprint, with a Markdown prompt telling an agent what
to do to cross it. An edge **entails** another blueprint's edge when crossing the first
requires crossing the second first; Seihou runs entailed edges before the edge that declares
them, and files the receipt under the entailed blueprint's identity, so a project that
depends on both Kioku and Keiro crosses the shared Keiro edge exactly once no matter which
command it ran. A **precondition** section tells the agent when to report the edge *not
applicable*, which is a normal, successful outcome — never an error exit.

The blueprint's own README states the maintainer rule this milestone satisfies: "Add an edge
in the same change that cuts a release, or this blueprint rots." It also states that gaps
between edges are legal when no agent intervention was needed. This window is not such a gap,
for the reason recorded in the Decision Log: the entailment is the whole point.

Four files change. A new
`blueprints/kioku-upgrade/migrations/0-5-1-0-to-0-5-2-0.md` carries the prompt. The
`migrations` list in `blueprints/kioku-upgrade/blueprint.dhall` gains a second
`S.BlueprintMigration::{…}` record with `from = "0.5.1.0"`, `to = "0.5.2.0"`, the new prompt,
and an `entails` list holding one `S.EntailedEdge::{ blueprint = "keiro-upgrade",
from = "0.14.0.0", to = "0.15.0.0" }`. `blueprints/kioku-upgrade/files/kioku-cohort-versions.md`
gains a `0.5.2.0` row at the top of both the runtime and migration cohort tables, and a
`0.5.1.0` row in the composed-migration-plan table which currently starts at `0.5.0.0`. The
README's "Declared edges" table gains a row.

The edge prompt itself should be short and mostly negative space, because that is what is
true. It should say that the entailed Keiro edge has already run and must not be redone; that
no other cohort member moves; that Kioku's own API, migrations, and runtime behavior are
unchanged in this window, so the honest outcome for a project that does not use `keiro-dsl`
is *not applicable*; and that a project which pins a Hackage index-state predating these
uploads must advance the pin, since no correct source edit can compensate for a solver that
cannot see the release. Model the structure on the existing
`blueprints/kioku-upgrade/migrations/0-4-1-0-to-0-5-0-0.md`, which already contains an
index-state section worth reusing nearly verbatim.

**Acceptance.** `seihou validate-blueprint blueprints/kioku-upgrade` passes, and the entailed
`keiro-upgrade` edge is confirmed to exist, committed, in Keiro's repository with exactly
`from = "0.14.0.0"` and `to = "0.15.0.0"`. A live chain preview is not available from the
producing repository; Concrete Steps Step 7 explains why and gives the substitute check.

### Milestone 5 — Commit and close out

**Scope.** One commit, then the living-section updates and the ADR distillation pass.

The repository follows Conventional Commits and commits directly to the current branch
(`master`) — do not create a feature branch. The precedent for this exact kind of change is
`5ab7aee`, `chore(deps): upgrade Baikai and Shikumi cohort`, which carried a `Refs:` trailer
naming the upstream project by its canonical Mori URI. Do the same for Keiro.

Whether the blueprint work belongs in the same commit or a separate one is a judgment call.
A single commit is defensible because the edge documents the bump. Two commits — `chore(deps)`
then `docs(blueprint)` — match the repository's habit of separating them (`5c031d7`,
`docs(blueprint): add the kioku-upgrade blueprint`, is its own commit). Prefer two, and give
both the same trailers.

**Acceptance.** `git log --oneline -2` shows the commits, `git show --stat` shows only the
intended files, and every commit message carries the `ExecPlan:` and `Intention:` trailers.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/kioku`, inside the
Nix development shell (direnv loads it on `cd`; if the toolchain is missing, run `nix develop`
first).

### Step 0 — Establish the starting point

```bash
git status --short
git log --oneline -1
grep -rn "keiro" --include="*.cabal" kioku-*/ ; grep -n "keiro-pgmq" cabal.project
```

Expected: a clean working tree, `HEAD` at `d071aea chore(release): 0.5.1.0` or later, and six
`^>=0.14.0.0` Keiro bounds across `kioku-core/kioku-core.cabal` (four),
`kioku-migrations/kioku-migrations.cabal` (two), plus the `keiro-pgmq ^>=0.14.0.0` line in
`cabal.project`.

If the working tree is dirty, stop and resolve that first. Blueprint tooling and any later
`git show --stat` check both assume a clean starting point.

### Step 1 — Raise the bounds

```bash
perl -pi -e 's/(keiro(?:-core)? +)\^>=0\.14\.0\.0/${1}^>=0.15.0.0/' kioku-core/kioku-core.cabal
perl -pi -e 's/(keiro-migrations +)\^>=0\.14\.0\.0/${1}^>=0.15.0.0/' kioku-migrations/kioku-migrations.cabal
perl -pi -e 's/keiro-pgmq \^>=0\.14\.0\.0/keiro-pgmq ^>=0.15.0.0/' cabal.project
```

`perl -pi -e` is used rather than `sed -i` deliberately. This is macOS, but the development
shell puts **GNU** `sed` on `PATH`, and the two disagree about in-place editing: BSD `sed`
requires a separate backup-suffix argument (`sed -i '' …`) while GNU `sed` takes the suffix
attached to the flag and reads a bare `''` as the script. The BSD form therefore fails here
with `sed: can't read s/…/: No such file or directory`. `perl -pi -e` behaves the same either
way. See Surprises & Discoveries.

Confirm the result, and confirm nothing else moved:

```bash
git diff --stat
git diff
```

Expected: exactly three files changed, seven lines total (four in `kioku-core.cabal`, two in
`kioku-migrations.cabal`, one in `cabal.project`), every one of them a `0.14.0.0` → `0.15.0.0`
substitution on a line naming `keiro`, `keiro-core`, `keiro-migrations`, or `keiro-pgmq`.

If `git diff` shows a change to a line naming `shibuya-pgmq-adapter`, `kiroku-store`, or any
other package, revert it — that is the mistake this step is written to prevent.

### Step 2 — Prove the solve, then build

```bash
cabal build all --dry-run
```

Expected: `Resolving dependencies...` followed by a plan naming `keiro-0.15.0.0`,
`keiro-core-0.15.0.0`, and `keiro-migrations-0.15.0.0`. If instead you see a
`cabal: Could not resolve dependencies` message, do **not** reach for `--allow-newer` or a
source repository override. Read the conflict text, find which package caps Keiro, and record
it in Surprises & Discoveries — a cap would contradict this plan's research and the plan needs
rescoping, not a workaround.

```bash
cabal build all 2>&1 | tail -20
```

Expected: the three Keiro packages download and build, then the five Kioku packages compile.
No errors. Warnings are acceptable; this codebase carries a large number of deprecation
warnings from Keiro's long-standing compatibility surface, and they are pre-existing and out
of scope.

Confirm what actually resolved, using the same probe the blueprint uses:

```bash
jq -r '."install-plan"[] | select(."pkg-name"|startswith("keiro")) | ."pkg-name" + " " + ."pkg-version"' \
  dist-newstyle/cache/plan.json | sort -u
```

Expected:

```text
keiro 0.15.0.0
keiro-core 0.15.0.0
keiro-migrations 0.15.0.0
```

### Step 3 — Run the tests

```bash
cabal test all
```

Run it **unpiped**. Piping into `tail` — the obvious way to shorten the output — hides two
things at once: the per-suite `PASS`/`FAIL` lines for the first three suites scroll out of the
retained window, and the shell reports the exit status of `tail` rather than of `cabal`, so a
failing run still looks like a success. If the output must be shortened, set `pipefail` first
and grep for the summary lines rather than truncating:

```bash
set -o pipefail
cabal test all 2>&1 | grep -E "^Test suite .*(PASS|FAIL)|^All [0-9]+ tests passed|test suites"
```

Expected: four `Test suite …: PASS` lines — `kioku-api-test`, `kioku-migrations-test`,
`kioku-cli-test`, and `kioku-test` — each preceded by its `All N tests passed` line. The
suites start ephemeral PostgreSQL instances; they do not use the `./db` development database,
so this does not disturb local state and can be repeated.

If a suite fails, re-run just that suite before drawing conclusions — this repository has a
known intermittent failure of roughly one full run in four or five with no reproducible case:

```bash
cabal test kioku-core:test:kioku-test 2>&1 | tail -20
```

Record both the failure and the re-run outcome in Surprises & Discoveries regardless of which
way it goes.

### Step 4 — Confirm the migration plan is unchanged

The count assertions are the authority, and Step 3 already ran them. Confirm they were not
edited, and confirm the documented counts still match:

```bash
git diff --stat kioku-migrations/test/Main.hs
grep -rn "55 migrations\|Keiro 31" docs/user/*.md kioku-*/CHANGELOG.md CHANGELOG.md
```

Expected: no diff to `Main.hs`, and the grep lists the existing statements in
`docs/user/getting-started.md`, `docs/user/upgrading-to-the-kioku-schema.md`,
`kioku-migrations/CHANGELOG.md`, `kioku-migrate/CHANGELOG.md`, and the root `CHANGELOG.md`,
all saying 55 (Kiroku 11, Keiro 31, Kioku 13). None of them needs editing.

If a count assertion *did* fail in Step 3, Keiro added a migration after all. Stop, recount
from `/Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations/migrations/manifest`, and treat
updating the assertions plus all five documents as a new milestone rather than a quiet fix.

### Step 5 — Write the changelogs

Edit the six changelogs by hand. The root `CHANGELOG.md` gains this above the `## 0.5.1.0`
heading:

```markdown
## Unreleased

### Changed

- **Keiro cohort:** moved `keiro`, `keiro-core`, and `keiro-migrations` to `^>=0.15.0.0`,
  and aligned the forward-looking `keiro-pgmq` constraint with the same lockstep release.
  Keiro 0.15.0.0's only breaking change is in `keiro-dsl`, which Kioku does not depend on;
  the three packages Kioku consumes are republished at the shared version with no source
  change. No other cohort member moves — `keiki`, `kiroku-store`, `kiroku-store-migrations`,
  `shibuya-core`, `shibuya-kiroku-adapter`, and `pg-migrate` keep their existing bounds — and
  the composed migration plan stays at 55 migrations (Kiroku 11, Keiro 31, Kioku 13). This is
  a bounds-only change: no Kioku source changed and nothing any package exports moved.
```

Then add the per-package entries described in Milestone 3. Verify all six were touched:

```bash
git diff --stat -- CHANGELOG.md kioku-*/CHANGELOG.md
```

Expected: six files changed.

### Step 6 — Add the blueprint edge

Create `blueprints/kioku-upgrade/migrations/0-5-1-0-to-0-5-2-0.md` following the structure of
the existing `0-4-1-0-to-0-5-0-0.md`: a heading naming the window, a paragraph stating the
entailment and forbidding redoing it, a `## Precondition` section, and numbered steps. Then
add the migration record to `blueprints/kioku-upgrade/blueprint.dhall`:

```dhall
      , S.BlueprintMigration::{
        , from = "0.5.1.0"
        , to = "0.5.2.0"
        , prompt = ./migrations/0-5-1-0-to-0-5-2-0.md as Text
        , entails =
          [ S.EntailedEdge::{
            , blueprint = "keiro-upgrade"
            , from = "0.14.0.0"
            , to = "0.15.0.0"
            }
          ]
        }
```

Add to `blueprints/kioku-upgrade/files/kioku-cohort-versions.md` a runtime-cohort row and a
migration-cohort row for `0.5.2.0`. They are identical to the `0.5.1.0` rows except that the
Keiro columns read `^>=0.15.0.0`:

```markdown
| 0.5.2.0 | `^>=0.15.0.0` | `^>=0.8.0.0` | `^>=0.9.0.0` | `^>=0.9.0.0` | `^>=0.5.1.1` | `^>=0.6.0.0` |
```

```markdown
| 0.5.2.0 | `^>=0.15.0.0` | `^>=0.4.0.0` | `^>=1.1.0.0` |
```

The composed-migration-plan table in the same file currently stops at `0.5.0.0`; add rows for
`0.5.1.0` and `0.5.2.0`, both `55 | 11 | 31 | 13`, so a reader on either release finds their
row rather than inferring it.

Finally add the README row:

```markdown
| `0.5.1.0` | `0.5.2.0` | `keiro-upgrade` `0.14.0.0 -> 0.15.0.0` |
```

### Step 7 — Validate the blueprint

```bash
seihou validate-blueprint blueprints/kioku-upgrade
```

Expected: a success message ending `Blueprint 'kioku-upgrade' is valid.` Validation resolves
the Dhall, checks that each declared prompt file exists, and checks the edge shape. It cannot
check whether the entailed blueprint declares the named edge — and, as implementation found,
neither can a live chain preview from this repository, because Seihou resolves blueprints by
installed name from a git URL and this repository's new edge is not published yet.

Verify the entailment directly against Keiro's own repository instead. This is the check that
matters: Seihou matches an entailed edge on **both** `from` and `to`, so a typo in either
field produces a chain that fails at run time in a consumer's project.

```bash
grep -nE 'from = |to = ' /Users/shinzui/Keikaku/bokuno/keiro/blueprints/keiro-upgrade/blueprint.dhall
```

Expected: among the edges listed, exactly `from = "0.14.0.0"` followed by `to = "0.15.0.0"`.
Confirm it is committed there, so a consumer's `seihou install` will see it:

```bash
git -C /Users/shinzui/Keikaku/bokuno/keiro log --oneline -1 -- blueprints/keiro-upgrade
```

Do not delete or weaken the `entails` list to make anything pass — an edge that silently
skips a cohort member is the failure this mechanism exists to prevent.

### Step 8 — Commit

```bash
git add cabal.project kioku-core/kioku-core.cabal kioku-migrations/kioku-migrations.cabal \
        CHANGELOG.md kioku-*/CHANGELOG.md
git commit -F - <<'EOF'
chore(deps): upgrade Kioku to the Keiro 0.15 cohort

Move keiro, keiro-core, and keiro-migrations to ^>=0.15.0.0 and align the
forward-looking keiro-pgmq constraint. Keiro 0.15.0.0's only break is in
keiro-dsl, which Kioku does not depend on, so this is bounds-only: no Kioku
source changed, no other cohort member moved, and the composed migration plan
stays at 55 migrations.

Refs: mori://shinzui/keiro

ExecPlan: docs/plans/40-upgrade-kioku-to-the-keiro-0-15-cohort.md
Intention: intention_01m1bvtf8deckamyjk3hqzgyns
EOF
```

Then the blueprint commit:

```bash
git add blueprints/kioku-upgrade
git commit -F - <<'EOF'
docs(blueprint): declare the Keiro 0.15 upgrade edge

Add the 0.5.1.0 -> 0.5.2.0 edge to kioku-upgrade, entailing keiro-upgrade
0.14.0.0 -> 0.15.0.0 so a project consuming both Kioku and keiro-dsl crosses
Keiro's record-API migration exactly once, in order. Record the new cohort row.

Refs: mori://shinzui/keiro

ExecPlan: docs/plans/40-upgrade-kioku-to-the-keiro-0-15-cohort.md
Intention: intention_01m1bvtf8deckamyjk3hqzgyns
EOF
```

Finally, commit the plan file itself with its filled-in Progress and Outcomes sections, using
a `docs(plan):` type and the same trailers.


## Validation and Acceptance

Acceptance is behavioral, and there are four things a person can check by hand.

**The build resolves the new Keiro.** From the repository root, `cabal build all` completes,
and the probe below prints `0.15.0.0` three times. Before this change it printed `0.14.0.0`.

```bash
jq -r '."install-plan"[] | select(."pkg-name"|startswith("keiro")) | ."pkg-name" + " " + ."pkg-version"' \
  dist-newstyle/cache/plan.json | sort -u
```

**Kioku still behaves identically.** `cabal test all` passes every suite. This is the check
that matters most, because compilation alone would not catch a Keiro/Keiki event-stream
validation mismatch — `mkEventStreamOrThrow` raises that at runtime, inside the tests, not at
compile time.

**The database story is unchanged.** The composed migration plan is still 55 migrations. The
strongest proof is that the assertions in `kioku-migrations/test/Main.hs` — four `@?= 55`
sites and the full ordered `expectedForwardMigrationIds` list ending at
`migrationId "keiro" "0031"` — pass without being edited. A second, independent check is to
apply the plan against a local database and read the count back:

```bash
just create-database
DATABASE_URL="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" cabal run kioku-migrate -- status
```

Expected: a status report listing 55 applied migrations. This uses the local development
database in `./db` and is safe to repeat; `just create-database` creates it only if absent
and then runs `just migrate`.

**A downstream project gets routed through Keiro's edge.** `seihou validate-blueprint
blueprints/kioku-upgrade` passes, and `seihou agent --debug migrate kioku-upgrade
--from 0.5.1.0 --to 0.5.2.0` previews the Keiro edge first, then the Kioku edge.

### ADR distillation

Before marking this plan complete, review the Decision Log, Surprises & Discoveries, and
Outcomes & Retrospective and ask whether anything durable emerged.

The expected answer is no. A bounds-only cohort move that requires no source change produces
execution notes, not architectural judgment, and `docs/adr/` holds no record about dependency
bounds today.

**Before writing any ADR, note what implementation established about this bundle.**
`docs/adr/` is **not** a profile-governed OKF bundle in this repository. `mori.dhall` declares
three OKF bundles — `docs/improvement-requests`, `docs/bug-reports`, and `docs/reviews`, each
with its own `profile.dhall` — and `docs/adr` is not among them. There is no
`docs/adr/profile.dhall`. The records nonetheless carry OKF-shaped frontmatter (`type`,
`title`, `description`, `timestamp`, `docId: ADR-N`, `status`, `date`) and the directory has
the reserved `log.md`, so the corpus follows the shape without being enforced by a profile.

Per `.claude/skills/exec-plan/ADR.md`, that means preserving the established filesystem
convention: match the existing frontmatter exactly, allocate the next unused `ADR-N` by
reading the `docId` values already present rather than by counting files, and add the `log.md`
entry by hand. Do **not** run `okf validate … --profile docs/adr/profile.dhall` — that file
does not exist and the command will fail. Do not register the bundle in `mori.dhall` or add
profile metadata as an incidental edit of this plan; adopting the shared profile is separate
work, and `ADR.md` names the `adopt-architecture-decisions` blueprint for it.

Record either outcome — "no ADR needed, and why" is itself worth writing down in Outcomes &
Retrospective.


## Idempotence and Recovery

Every step here is safe to repeat.

The bound edits are `sed` substitutions from `0.14.0.0` to `0.15.0.0` on lines that name a
Keiro package. Running them a second time matches nothing and changes nothing. To undo them
entirely before committing:

```bash
git checkout -- cabal.project kioku-core/kioku-core.cabal kioku-migrations/kioku-migrations.cabal
```

`cabal build` and `cabal test` are idempotent by construction and write only into
`dist-newstyle/`. If a build gets into a confusing state, delete that directory and rebuild;
nothing in it is precious. If Cabal cannot see `keiro-0.15.0.0` at all — which presents as a
resolution failure naming Keiro — run `cabal update` first, because the local Hackage index
may predate the 2026-08-30 upload.

The test suites create and drop their own ephemeral databases and never write to `./db`, so a
failed or interrupted test run leaves no state to clean up. `just create-database` is
explicitly idempotent: it checks `pg_database` before creating and then runs `just migrate`,
which is itself a forward-only migration runner that skips already-applied migrations.

The blueprint edits are additive: a new file plus appended rows and one new Dhall record.
`seihou validate-blueprint` and `seihou agent --debug migrate` are both read-only — the
`--debug` form previews without applying. Running them repeatedly costs nothing.

**The one recovery path worth planning for is a version-number change.** This plan writes the
blueprint edge with `to = "0.5.2.0"`, but the release skill derives the actual version from
the commit history and confirms it with the user, so the release could land on something else
— `0.6.0.0`, for example, if another change gets folded in first. If that happens, three
things must be corrected together, before the release is published: rename
`blueprints/kioku-upgrade/migrations/0-5-1-0-to-0-5-2-0.md`, update the `to` field and the
`prompt = ./migrations/…` path in `blueprints/kioku-upgrade/blueprint.dhall`, and update the
version in the README table and in both cohort tables in `kioku-cohort-versions.md`. Then
re-run `seihou validate-blueprint`. An edge whose `to` does not match a real published
version is worse than no edge, because a downstream project's version probe will never match
it and the guidance will silently never run.

Nothing in this plan touches a production database or publishes anything. Until the release
skill runs, every effect is confined to this working tree.


## Interfaces and Dependencies

No Haskell interface, type, or function signature changes in this plan. That is the claim it
must defend, and the way to defend it is that the three Keiro packages Kioku consumes have
byte-identical library sources across `0.14.0.0` and `0.15.0.0`.

**Dependencies that move:**

- `keiro` — Keiro's runtime library. Used by `kioku-core` (library and test-suite). Moves
  `^>=0.14.0.0` → `^>=0.15.0.0`.
- `keiro-core` — Keiro's pure types and codecs, re-exported into `keiro` through Cabal's
  module reexport mechanism. Used by `kioku-core` (library and test-suite). Same move.
- `keiro-migrations` — Keiro's embedded SQL migration component, which
  `kioku-migrations` composes after Kiroku's and before Kioku's own. Used by
  `kioku-migrations` (library and test-suite). Same move.
- `keiro-pgmq` — a `cabal.project` constraint only, not in the build closure. Moves for
  consistency with the lockstep release, so a downstream consumer that does enable the PGMQ
  integration cannot pair Keiro `0.15` with `keiro-pgmq 0.14`.

**Dependencies that explicitly do not move**, with the reason each stays:

- `keiki ^>=0.9.0.0` and the `keiki-codec-json ^>=0.9.0.0` constraint — Keiro `0.15` still
  declares `>=0.9 && <0.10` for both.
- `kiroku-store ^>=0.8.0.0` — Keiro `0.15` still declares `>=0.8 && <0.9`.
- `kiroku-store-migrations ^>=0.4.0.0` — `keiro-migrations 0.15` still declares `^>=0.4.0.0`.
- `shibuya-core ^>=0.9.0.0` — Keiro `0.15` still declares `^>=0.9.0.0`.
- `shibuya-kiroku-adapter ^>=0.5.1.1` — unrelated to this release. Note that this package
  lives in the Kiroku repository despite its name, and that it has historically been the
  package that blocks a Keiro upgrade by capping `shibuya-core`. It does not block this one:
  Keiro `0.15` wants the same `shibuya-core 0.9` that `0.14` did.
- `shibuya-pgmq-adapter ^>=0.14.0.0` — a Shibuya version, not a Keiro one, and already the
  newest published. `keiro-pgmq 0.15.0.0` itself declares `^>=0.14.0.0` for it.
- `pg-migrate ^>=1.1.0.0` and the `pgmq-*` constraints — untouched by this release.
- `baikai`, `baikai-claude`, `baikai-effectful`, `shikumi`, `shikumi-trace` — a different
  cohort with its own entry point, `just upgrade-baikai`.

**Packages this repository does not depend on and must not start depending on here:**
`keiro-dsl`, `keiro-ops`, and `keiro-test-support`. `keiro-dsl` is where Keiro `0.15`'s entire
breaking change lives, and adding it would enlarge Kioku's surface for no benefit to this
plan.

**Tooling relied on:** `cabal` and `ghc-9.12.4` from the Nix development shell; `jq` for
reading `dist-newstyle/cache/plan.json`; `just` for the database recipes; `seihou` for
blueprint validation and migration preview; `okf` and `mori` only if the distillation pass
concludes an ADR is warranted.

**Upstream reference:** `mori://shinzui/keiro`. Its working tree is at
`/Users/shinzui/Keikaku/bokuno/keiro`, and the release is tagged `keiro-0.15.0.0` (Keiro tags
are per-package and unprefixed by `v`, unlike this repository's `v<version>` tags). All three
packages are published on Hackage, confirmed with `cabal list --simple-output keiro`.
