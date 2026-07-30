---
id: 21
slug: release-kioku-for-the-keiki-0-4-keiro-0-4-baikai-0-4-and-shikumi-cohort
title: "Release Kioku for the Keiki 0.4, Keiro 0.4, Baikai 0.4 and Shikumi cohort"
kind: exec-plan
created_at: 2026-07-30T20:15:51Z
intention: "intention_01kytapemyezfakpdf0ke73cgw"
---

# Release Kioku for the Keiki 0.4, Keiro 0.4, Baikai 0.4 and Shikumi cohort

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kioku is a Haskell library family that gives an AI agent a durable memory: it records what
happened in a session, distills it into higher-level summaries, and recalls the relevant
pieces later. It is published on Hackage (Haskell's public package repository) as five
packages, all currently at version `0.1.0.0`.

Kioku is built on a stack of the author's own libraries. Two of them matter here. **Keiki**
is a library for describing a state machine (a "transducer") whose transitions can be
checked by a solver before the program runs. **Keiro** is an event-sourcing framework and
workflow engine built on top of Keiki: it stores every change as an append-only event, then
rebuilds current state by replaying those events. A third, **Baikai**, is a provider-neutral
interface to large language models, and **Shikumi** is a typed program layer on top of
Baikai that Kioku uses for its distillation prompts.

Today the released `kioku-core-0.1.0.0` declares in its package metadata that it works with
`keiki` in the `0.2.x` range and `keiro`/`keiro-core` in the `0.3.x` range. Meanwhile Keiro
has released `0.4.0.1`, and that release requires `keiki >=0.4 && <0.5`. Because a Cabal
"solver plan" must satisfy every declared version range simultaneously, **there is no
released combination of packages that pairs Kioku with the current Keiro and Keiki.** A
downstream project that wants both — Shikigami is the concrete one, per
`docs/improvement-requests/release-kioku-for-keiki-0-4-and-keiro-0-4.md` — is forced either
to pass `--allow-newer` (a flag that tells Cabal to ignore declared upper bounds, discarding
the guarantee that the combination was ever tested) or to pin raw Git commits, which cannot
be audited or reproduced from Hackage alone.

The same story is true one layer over: Kioku declares `baikai ^>=0.3.0.0` and `shikumi
^>=0.3.0.0`, while the current releases are `baikai-0.4.1.0`, `baikai-claude-0.4.0.0`,
`shikumi-0.3.0.1`, and `shikumi-trace-0.2.0.1`.

After this plan is done, a person can create an empty directory, write a `.cabal` file that
depends on `kioku-core`, `keiro`, and `keiki`, run `cabal build`, and watch Cabal resolve
`kioku-core-0.2.0.0` together with `keiki-0.4.0.0`, `keiro-0.4.0.1`, `baikai-0.4.1.0`, and
`shikumi-0.3.0.1` — with no `allow-newer`, no Git pins, and no local package overrides. They
can point `kioku-migrate` at a database that was migrated by the *old* Kioku and watch it
apply exactly the two new Keiro migrations and nothing else, leaving every existing row
untouched. And they can read a changelog that names every breaking change.

One thing this plan deliberately does *not* do is finish removing codd. Kioku already left
codd behind as a migration runner — that was plan 20 — and what remains is a one-time import
bridge that lets a downstream database with a codd ledger cross over without re-running any
DDL. The intent is to delete it, but verification found that Shikigami, the only real
downstream consumer, has not crossed yet. So this plan deprecates the bridge, writes down the
exact condition for deleting it, and leaves the deletion to a follow-up. The reasoning and
evidence are in the Decision Log and in Surprises & Discoveries items 9 and 10.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

### Milestone 0 — Unblock the Baikai/crypton conflict upstream ✅ (2026-07-30)

- [x] (2026-07-30) Confirm the conflict still reproduces. It does, but only *after* Kioku's own
      stale bounds are lifted — see Discovery 11. Verbatim solver output in Discovery 12.
- [x] (2026-07-30) Confirm `baikai-claude` only uses `Crypto.Hash (Digest, SHA256)`. Exactly two
      import lines, both in `Baikai/Provider/Claude/Transport.hs`, as predicted.
- [x] (2026-07-30) Widen the bound to `crypton >=1.0 && <1.2` and publish. Shipped as the
      **fallback path**: the user released `baikai-claude-0.4.0.1` rather than a metadata
      revision. See the Decision Log entry dated 2026-07-30 (revision → point release).
- [x] (2026-07-30) Prove the fix: `cabal build --dry-run all` resolves the full cohort with no
      `--allow-newer` on the command line and none in `cabal.project`.

### Milestone 1 — Move the package bounds onto the released cohort ✅ (2026-07-30)

- [x] (2026-07-30) Bump `keiki` → `^>=0.4.0.0`, `keiro`/`keiro-core` → `^>=0.4.0.1` in
      `kioku-core/kioku-core.cabal` (library and test-suite).
- [x] (2026-07-30) Bump `keiro-migrations` → `^>=0.4.0.1` in `kioku-migrations/kioku-migrations.cabal`.
- [x] (2026-07-30) Bump `baikai` → `^>=0.4.1.0`, `baikai-claude` → `^>=0.4.0.1`,
      `baikai-effectful` → `^>=0.3.0.2`, `shikumi` → `^>=0.3.0.1`, `shikumi-trace` → `^>=0.2.0.1`.
      The two counter-intuitive bounds carry an explanatory comment above `build-depends`, because
      cabal-fmt strips comments from inside a dependency list (Discovery 13).
- [x] (2026-07-30) Bump `keiki-codec-json` → `^>=0.4.0.0` and `keiro-pgmq` → `^>=0.4.0.1` in
      `cabal.project`, and rewrite the stale comment above the constraint block.
- [x] (2026-07-30) `cabal build --dry-run all` resolves with no `allow-newer`, selecting the
      expected cohort. Commits `9f026f7` and `efdd391`.

### Milestone 2 — Compile and fix the API port ✅ (2026-07-30)

- [x] (2026-07-30) `cabal build all` succeeds.
- [x] (2026-07-30) **Zero source changes were required.** Not one line of Haskell needed editing
      to move from Keiki 0.2/Keiro 0.3 to Keiki 0.4/Keiro 0.4. Discoveries 4, 5 and 6 predicted
      this and were correct in full. No commit was made for this milestone, per §2's instruction.

### Milestone 3 — Migrations absorb Keiro 0019 and 0020 ✅ (2026-07-30)

- [x] (2026-07-30) Update the migration-count assertions in `kioku-migrations/test/Main.hs`:
      `36` → `38` in two places, two new ids appended to `expectedForwardMigrationIds`, and the
      test's own label corrected from "six forward migrations" to "eight".
      The three assertions the plan said must *not* move (30, 10, and the effect count of 5) did
      not move — the effect-count SQL probes neither new column, as predicted.
- [x] (2026-07-30) `cabal test kioku-migrations` passes — all 7 tests.
- [x] (2026-07-30) Demonstrate the forward upgrade on a database migrated by the *old* Kioku.
      Full transcript in Discovery 14: exactly two migrations applied, byte-identical row
      digests before and after, `verification ok applied=38 pending=0 unknown=0`.

### Milestone 4 — Runtime, replay, and codec compatibility evidence ✅ (2026-07-30)

- [x] (2026-07-30) `cabal test kioku-core` passes — 130 tests.
- [x] (2026-07-30) `cabal test kioku-cli` passes — 36 tests.
- [x] (2026-07-30) Add `kioku-core/test/Kioku/CodecCompatSpec.hs`: 13 literal fixtures (6
      `MemoryEvent` + 7 `SessionEvent` constructors) plus 2 tests pinning the native/legacy
      fallback. Proven non-vacuous per §4.4. Commit `4c79e4f`.

### Milestone 5 — Dispose of the codd import path ✅ (2026-07-30)

- [x] (2026-07-30) Verify whether any downstream still needs the codd import path. **It does** —
      see Surprises & Discoveries item 10. Removal is therefore deferred, not cancelled.
- [x] (2026-07-30) Re-confirm the gate at implementation time (§5.1). Shikigami is unchanged:
      still `codd >=0.1.8 && <0.2`, `codd-extras`, and the `hasql-migration` / `codd-project`
      source-repository stanzas. Deprecation remains the correct call.
- [x] (2026-07-30) Deprecate `Kioku.Migrations.History.Codd` (module-header `{-# DEPRECATED #-}`)
      and the `kioku-migrate import` subcommand (`progDesc`). Note: the subcommand is named
      `import`, **not** `import-codd` as this plan stated throughout — see Discovery 15.
- [x] (2026-07-30) Record the removal gate in `kioku-migrations/codd-upgrade/README.md`, naming
      all seven things that must be deleted together.
- [x] (2026-07-30) Confirm Kioku is already free of `hasql-migration` — confirmed, no matches.
- [x] (2026-07-30) Chose `-Wno-deprecations` scoped to the two stanzas that implement and
      rehearse the bridge (§5's open question). Commit `1865be6`.

### Milestone 6 — Document, version, tag, and publish ✅ (2026-07-30)

The pause recorded here was lifted by the user on 2026-07-30, who then authorised the full
release — commit, tag, push, and Hackage publish — in answer to an explicit four-option question.

- [x] (2026-07-30) Write per-package changelog entries naming every breaking change and the
      deprecation. Six files: the five packages plus the root. Commit `ddbf338`.
- [x] (2026-07-30) Bump all five packages to `0.2.0.0`, together with all fourteen internal
      dependency bounds. Commit `5765f98`.
- [x] (2026-07-30) Run the release skill's steps by hand (it is `disable-model-invocation: true`,
      so it cannot be invoked as a skill — see Discovery 17). Pre-flight found nothing outstanding:
      LICENSE files, repository metadata, internal bounds and changelogs were all already in place.
      All four gates green: `nix fmt` clean, `cabal build all`, `cabal test all` (130 + 36 + 7),
      `nix flake check`, plus `cabal check` clean for all five packages.
- [x] (2026-07-30) Tag `v0.2.0.0`, push, publish to Hackage in dependency order, and cut the
      GitHub release at https://github.com/shinzui/kioku/releases/tag/v0.2.0.0. One upload needed a
      workaround — see Discovery 18.
- [x] (2026-07-30) Confirm the negative check from Validation and Acceptance: the plan selects
      `shikumi-0.3.0.1` and `baikai-0.4.1.0`, not the `0.3.0.0`/`0.3.1.0` fallbacks Discovery 7
      warned about.
- [x] (2026-07-30) Verify the released cohort resolves from Hackage in a scratch project (§6.3).
      **Passed** — full transcript in Discovery 19. This is the improvement request's second
      acceptance criterion and the last item in the plan.


## Surprises & Discoveries

Findings from the validation research that produced this plan. Each carries its evidence.

**1. The improvement request understated the blocker — `keiki-codec-json` is now in the
build closure.** `cabal.project` pins `keiki-codec-json ^>=0.2.0.0` under a comment claiming
these packages "are not in Kioku's current build closure". That was true against Keiro 0.3.
Keiro 0.4 depends on `keiki-codec-json` directly, so the stale constraint is now a hard
solver failure:

```text
[__1] trying: keiro-0.4.0.1 (dependency of kioku-core)
[__2] next goal: keiki-codec-json (dependency of keiro)
[__2] rejecting: keiki-codec-json; 0.4.0.0, 0.3.1.0, 0.3.0.0
      (constraint from cabal.project requires ^>=0.2.0.0)
[__2] rejecting: keiki-codec-json-0.2.0.0 (conflict: keiro => keiki-codec-json>=0.4 && <0.5)
```

**2. Upgrading Baikai to 0.4 is impossible today — an upstream `crypton` bound makes it
unsolvable.** `baikai-claude-0.4.0.0` declares `crypton ^>=1.0`, which in Cabal's caret
syntax means `>=1.0 && <1.1`. `pg-migrate-1.1.0.0`, which `kioku-migrate` and
`kioku-migrations` both require, declares `crypton >=1.1 && <1.2`. The two ranges do not
overlap, and Kioku needs both packages:

```text
[__1] trying: crypton-1.0.6
[__3] rejecting: pg-migrate-1.1.0.0 (conflict: crypton==1.0.6, pg-migrate => crypton>=1.1 && <1.2)
```

with the mirror-image failure when crypton 1.1.4 is chosen first:

```text
[__3] rejecting: baikai-claude-0.4.0.0 (conflict: crypton==1.1.4, baikai-claude => crypton^>=1.0)
```

This is why Milestone 0 exists and must come first. It is an upstream metadata bug, not a
Kioku problem: `baikai-claude` uses only `Crypto.Hash (Digest, SHA256)` from crypton, an API
that is identical in 1.0 and 1.1.

**3. Once that single upstream bound is widened, the whole target cohort resolves cleanly.**
Simulating the fix with `--allow-newer=baikai-claude:crypton` produced a complete plan:

```text
 - baikai-0.4.1.0            - keiki-0.4.0.0          - keiro-core-0.4.0.1
 - baikai-claude-0.4.0.0     - keiki-codec-json-0.4.0.0 - keiro-0.4.0.1
 - baikai-effectful-0.3.0.2  - kiroku-store-0.3.1.0   - keiro-migrations-0.4.0.1
 - baikai-openai-0.4.0.0     - shikumi-0.3.0.1        - shikumi-trace-0.2.0.1
 - shikumi-cache-0.1.2.1     - pg-migrate-1.1.0.0     - shibuya-kiroku-adapter-0.4.0.0
```

**4. Keiro 0.4's headline breaking changes do not touch Kioku.** Three of the four API breaks
listed in Keiro's changelog are in code Kioku never calls. Evidence — these greps over
`kioku-core`, `kioku-cli`, `kioku-api`, `kioku-migrate` return nothing:

```text
$ grep -rn "scheduleTimerOnce\|markChildFailed\|ChildRow" --include="*.hs" kioku-core kioku-cli kioku-api kioku-migrate
$ grep -rn "StateCodec\|stateShapeHash\|withFoldFingerprint" --include="*.hs" kioku-core kioku-cli
```

Kioku uses `scheduleTimerTx`, not `scheduleTimerOnceTx`; it has no durable workflows and
therefore no child links; and both of its event streams disable snapshots outright —
`kioku-core/src/Kioku/Memory/EventStream.hs:41` and
`kioku-core/src/Kioku/Session/EventStream.hs` both set `snapshotPolicy = Never` and
`stateCodec = Nothing`. The snapshot `state_shape_hash` invalidation therefore has nothing to
invalidate. The fourth break — stricter validated event-stream assembly — does apply, and is
the one to watch in Milestone 2.

**5. Keiki 0.3's and 0.4's breaking changes are pattern-match breaks Kioku is not exposed
to.** Keiki 0.3 added a `mode` field to `Edge`, and 0.4 added a `TFieldProj` constructor to
`Term` plus new validation-warning constructors. These break code that constructs `Edge`
records literally or matches `Term`/warning types exhaustively. Kioku does neither — it uses
only the builder DSL and a narrow slice of the core:

```text
import Keiki.Builder ((=:))
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer, lit, (.==), (.||))
import Keiki.Generics (emptyRegFile)
import Keiki.Generics.TH (deriveAggregate)
```

**6. The Shikumi and Baikai upgrades are bounds-only from Kioku's perspective.** `shikumi
0.3.0.1` and `shikumi-trace 0.2.0.1` both changed nothing but dependency bounds (their
changelogs say "Dependency bounds only — no changes to the exported API"). Baikai 0.4's two
breaking changes are the `claudeCliCommand`/`codexCliCommand` signatures and two new
`ThinkingLevel` constructors; Kioku touches neither — its only Claude-provider use is
`ClaudeApi.register` at `kioku-core/src/Kioku/Distill/Runtime.hs:74`.

**7. `kioku-core` already declares `shikumi ^>=0.3.0.0`, a range that silently spans the
Baikai major boundary.** `shikumi-0.3.0.0` requires `baikai >=0.3 && <0.4`; `shikumi-0.3.0.1`
requires `baikai >=0.4 && <0.5`. Today's solve quietly backtracks to `shikumi-0.3.0.0`
because that is the only version compatible with Kioku's `baikai ^>=0.3.0.0`. Tightening
Kioku's Baikai bound is what actually pulls Shikumi forward.

**8. Keiro 0.4 adds two migrations, so three hard-coded counts in the migration test go
stale.** `keiro-migrations 0.4.0.0` appends `0019-keiro-snapshots-state-shape-hash.sql` and
`0020-keiro-workflow-children-failure-reason.sql`. Kioku's test asserts a post-migration
total of 36 (`kioku-migrations/test/Main.hs:268`) and enumerates the forward migrations
through `keiro/0018` (`kioku-migrations/test/Main.hs:345`).

**9. Kioku is already fully on pg-migrate, and already free of `hasql-migration`.** Plan 20
(`docs/plans/20-move-kioku-off-codd-onto-pg-migrate-and-upgrade-the-keiro-kiroku-cohort.md`)
completed that cutover. There is no codd *runner* left anywhere in this repository —
`kioku-migrate up`, `status`, and `verify` all go through pg-migrate — and a repository-wide
search finds no `hasql-migration` at all:

```text
$ grep -rn "hasql-migration" --include="*.cabal" --include="*.hs" --include="*.project" .
(no output)
```

What remains of codd is strictly the *one-time import path* plan 20 shipped so that a
downstream database with an existing codd ledger could cross over without re-running DDL. It
is five things: the module `kioku-migrations/src/Kioku/Migrations/History/Codd.hs`, the
`kioku-migrate import-codd` subcommand (`kioku-migrate/app/Main.hs:66-157`), the three SQL
fixups in `kioku-migrations/codd-upgrade/`, the `pg-migrate-import-codd ^>=1.1.0.0`
dependency in three cabal stanzas, and the `testCoddCohortImport` rehearsal
(`kioku-migrations/test/Main.hs:203`).

**10. That import path cannot be removed yet — Shikigami, the only downstream consumer of
Kioku, has not crossed over and is still on codd.** `mori registry dependents shinzui/kioku`
names two projects, `shinzui/kikan` and `shinzui/shikigami`. Kikan turns out not to depend on
any `kioku-*` package at all (no match in its cabal files), so Shikigami is the sole real
consumer. Shikigami at `/Users/shinzui/Keikaku/bokuno/shikigami` is squarely pre-cutover:

```text
shikigami-migrations/shikigami-migrations.cabal:27:    , codd              >=0.1.8  && <0.2
shikigami-migrations/shikigami-migrations.cabal:28:    , codd-extras
shikigami-migrations/shikigami-migrations.cabal:30:    , kioku-migrations
cabal.project:138:  location: https://github.com/shinzui/hasql-migration
cabal.project:148:  location: https://github.com/shinzui/codd-project.git
```

It composes `kioku-migrations` into its own migration plan, still Git-pins `hasql-migration`
and `codd`, and pins Kioku itself by raw commit `8bcfc282484dd59b0a0b25530cca4f3ad9034ce1` —
a pre-pg-migrate commit. That pin is exactly the "old copied set of raw commit pins" the
improvement request complains about. Shikigami already has its own plans for both halves of
this: `docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md` and
`docs/plans/47-upgrade-shikigami-to-the-coherent-july-2026-dependency-cohort.md`, the latter
being the "Shikigami plan 47" the improvement request says this work blocks.

The consequence is concrete: Shikigami's plan 38 will need `kioku-migrate import-codd` and
the `codd-upgrade/*.sql` fixups to move its live database across. Deleting them from Kioku
`0.2.0.0` would remove the bridge before the only consumer has walked over it.

---

*Findings 11 onward were recorded during implementation on 2026-07-30.*

**11. Concrete Step §0.1 does not reproduce the crypton conflict as written — Kioku's own
bounds mask it.** The plan's §0.1 command expects a solver rejection naming `crypton`. It
instead fails one level earlier, on Kioku's stale `keiro-core ^>=0.3.0.0`:

```text
[__1] rejecting: keiro-core-0.4.0.1 (conflict: kioku-core => keiro-core^>=0.3.0.0)
[__1] rejecting: keiro-core; 0.3.0.0, 0.2.0.0 (constraint from command line flag requires >=0.4)
```

Lifting those with `--allow-newer` then hits the *`cabal.project`* constraint from Discovery 1,
which outranks a command-line constraint:

```text
[__2] rejecting: keiki-codec-json-0.4.0.0 (constraint from cabal.project requires ^>=0.2.0.0)
```

Only after both layers are cleared does crypton surface. The practical consequence is that
Milestone 1's edits must land *before* Milestone 0 can be demonstrated, inverting the plan's
stated order. This is a documentation defect in the plan, not a problem with the analysis —
Discovery 2's diagnosis was exactly right, it was just three layers down rather than one.

**12. With Kioku's bounds corrected, the crypton conflict reproduces verbatim as Discovery 2
predicted.** After Milestone 1's edits, a plain `cabal build --dry-run all`:

```text
[__1] trying: crypton-1.1.4 (dependency of kioku-core)
[__2] rejecting: baikai-claude-0.4.0.0 (conflict: crypton==1.1.4, baikai-claude => crypton^>=1.0)
[__2] skipping: baikai-claude; 0.3.0.2, 0.3.0.1 (has the same characteristics ...)
```

**13. cabal-fmt strips comments from inside a `build-depends` list.** Explanatory comments
placed next to the `baikai-effectful` and `shikumi` bounds — exactly where Milestone 1 asks for
them, "because a future reader will otherwise 'fix' it" — were hoisted by the `treefmt`
pre-commit hook out of the dependency list and left stranded above the *next stanza*, where they
read as documentation of the test-suite. They survive only above the `build-depends` keyword
itself, which is where they now live.

**14. The forward-upgrade rehearsal (§3.3) passes with zero data loss.** Run against a scratch
database (`kioku_plan21_rehearsal`), migrated to completion by the pre-upgrade `kioku-migrate`
built from commit `d76800e` in a separate worktree, then seeded with rows in both tables the new
migrations alter, then upgraded by the new binary:

```text
$ kioku-migrate up          # new binary, database migrated by the old one
keiro/0019-keiro-snapshots-state-shape-hash        outcome=applied_now duration_ms=2
keiro/0020-keiro-workflow-children-failure-reason  outcome=applied_now duration_ms=1
# (every other migration reported already_applied)

$ diff rows-before.txt rows-after.txt
IDENTICAL -- no rows or values changed

$ kioku-migrate verify
verification ok
applied=38
pending=0
unknown=0
```

The snapshot compared per-table live-row counts across the `kioku`, `kiroku` and `keiro` schemas
*and* md5 digests over the full contents of `keiro.keiro_snapshots`,
`keiro.keiro_workflow_children` and `kiroku.streams` — so this is a content-level check, not
merely a count. The two new columns arrived as specified: `state_shape_hash` defaulting to `''`
and `failure_reason` nullable.

**15. The subcommand is `kioku-migrate import`, not `kioku-migrate import-codd`.** The plan
names it `import-codd` in six places, including the Milestone 5 acceptance criterion. The actual
`Opt.command` string at `kioku-migrate/app/Main.hs:87` is `"import"`. Anyone following the plan
literally would find no such subcommand.

**16. `mkEventStreamOrThrow` did not throw — the risk flagged in Milestone 2 did not
materialise.** Keiro 0.4's stricter validated event-stream assembly was the one break the plan
expected to reach Kioku, surfacing as a runtime crash rather than a compile error. Both streams
built and every suite ran green, so both codecs satisfy the tightened `mkCodec`.

---

*Findings 17 onward were recorded during Milestone 6 on 2026-07-30.*

**17. The release skill cannot be invoked as a skill.** §6.2 says to run `/release major`, but
`agents/skills/release/SKILL.md` carries `disable-model-invocation: true` in its frontmatter, so
the Skill tool will not load it. Its steps were read and followed by hand instead. This is a
fourth defect in this plan's Concrete Steps, of the same species as Discoveries 11, 13 and 15 —
a command that was written but never run.

The skill's step 1 pre-flight is also stale in Kioku's favour: it describes LICENSE files,
repository metadata, internal dependency bounds and changelogs as "gaps that exist in the repo
today". All four were already in place, so the pre-flight was a no-op. `cabal check` reported
"No errors or warnings" for all five packages.

**18. Hackage rejects the `kioku-migrations` documentation tarball, because a sublibrary's name
contains a colon.** A plain `cabal haddock --haddock-for-hackage` on `kioku-migrations` builds
docs for both the main library and the `test-support` sublibrary, and the resulting tarball
carries a file named after the component:

```text
Error: Invalid documentation tarball
Invalid windows file name in tar archive:
"kioku-migrations-0.2.0.0-docs\\test-support\\kioku-migrations:test-support.txt"
```

Hackage validates archive entries against Windows filename rules, which forbid `:`. The package
itself had already uploaded successfully — only the docs upload failed, and no dependent was
blocked. The fix is to scope the haddock build to the main library, which is the only component
whose docs belong on Hackage anyway:

```bash
cabal haddock lib:kioku-migrations --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump
```

The re-built tarball contains no `:` at all and uploaded cleanly. `lib:<pkg>` was used for
`kioku-core` and `kioku-cli` too, for consistency. `kioku-migrate` has no library, so
`cabal haddock` correctly generates nothing and there is no docs tarball to upload — that is
expected, not a failure.

**19. §6.3 passes, but the solve is very slow on a cold package database — slow enough to look
hung.** The first attempt was abandoned after roughly 25 minutes with no output. A second run of
the identical command completed successfully inside a 420-second timeout, which suggests the
first was making progress the whole time rather than being stuck; the scratch directory has no
`~/.cabal` plan cache to draw on and the transitive closure here is large. Anyone re-running this
check should give it a generous timeout and not interpret silence as failure.

The plan resolved from Hackage alone — no `cabal.project`, no `--allow-newer`, no local package
overrides, in a directory outside the repository containing only `check.cabal`:

```text
Build profile: -w ghc-9.12.4 -O1
In order, the following would be built:
 - blake3-0.3.1 (lib) (requires build)
 - kioku-api-0.2.0.0 (lib) (requires download & build)
 - keiro-core-0.4.0.1 (lib) (requires build)
 - shikumi-cache-0.1.2.1 (lib) (requires build)
 - keiro-0.4.0.1 (lib) (requires build)
 - shikumi-trace-0.2.0.1 (lib) (requires build)
 - kioku-core-0.2.0.0 (lib) (requires download & build)
 - check-0 (lib) (first run)
```

The full component graph confirms the rest of the cohort came along at the intended versions.
Cabal abbreviates package names in `-v2` graph output, so read them with care —
`kk-0.4.0.0` is `keiki`, while `kk-cr-0.2.0.0` and `kk-p-0.2.0.0` are `kioku-core` and
`kioku-api`:

```text
include kk-0.4.0.0        (keiki)              include bk-0.4.1.0       (baikai)
include kr-0.4.0.1        (keiro)              include bk-cld-0.4.0.1   (baikai-claude)
include kr-cr-0.4.0.1     (keiro-core)         include bk-ffctfl-0.3.0.2 (baikai-effectful)
include krk-str-0.3.1.0   (kiroku-store)       include shkm-0.3.0.1     (shikumi)
include krk-dptr-0.4.0.0  (shibuya-kiroku-adapter)  include shkm-trc-0.2.0.1 (shikumi-trace)
```

Note what is *absent*: `keiki-codec-json` does not appear in this plan at all. Its `>=0.4`
requirement comes from `keiro-migrations`, which only `kioku-migrations` depends on, and this
scratch project depends on `kioku-core` alone. That confirms the `cabal.project` constraint
corrected in Milestone 1 was a build-closure concern for this repository rather than something
visible in a downstream consumer's solve.


## Decision Log

- Decision: Fix the `crypton` conflict with a Hackage **metadata revision** of
  `baikai-claude-0.4.0.0` rather than a new `0.4.0.1` release, with a new release as the
  documented fallback.
  Rationale: A revision changes only the `.cabal` metadata that Hackage serves to the solver;
  it needs no code change, no version bump, and no downstream re-pin, and every already-
  published consumer of `baikai-claude-0.4.0.0` benefits immediately. The change is exactly
  what revisions exist for — a too-tight upper bound on a dependency whose used API
  (`Crypto.Hash (Digest, SHA256)`) is identical across the boundary. A fresh release would
  work too but forces every consumer to re-pin for no functional gain.
  Date: 2026-07-30

- Decision: Do **not** solve the conflict inside Kioku with an `allow-newer` stanza in
  `cabal.project`.
  Rationale: `cabal.project` is a build-time file that is not published to Hackage. An
  `allow-newer` there would make Kioku's own build work while leaving every downstream
  consumer with the identical unsolvable plan — which is precisely the failure mode the
  improvement request asks us to end. Acceptance criterion 2 of the request ("bounds admit
  the cohort without `allow-newer`") is not satisfiable this way.
  Date: 2026-07-30

- Decision: Release Kioku as `0.2.0.0`, a PVP major bump, even though the amount of Kioku
  source that changes may be zero.
  Rationale: Kioku's `release` skill (`agents/skills/release/SKILL.md`) versions all five
  packages together and derives the bump from Conventional Commit types, where a `feat!:` or
  `BREAKING CHANGE:` footer forces a major. A consumer that links `kioku-core` also links
  `keiro`, and the Keiro 0.4 breaks (stricter event-stream assembly, snapshot invalidation,
  the two new migrations) are visible through Kioku's own API surface and its migration plan.
  Handing them a version whose PVP major is unchanged would be a lie about compatibility.
  Date: 2026-07-30

- Decision: Widen `kioku-core`'s Shikumi bound to `^>=0.3.0.1` rather than leaving
  `^>=0.3.0.0`.
  Rationale: Discovery 7 — `^>=0.3.0.0` admits `shikumi-0.3.0.0`, which is pinned to the
  Baikai 0.3 series and would give the solver a way to silently fall back off the intended
  cohort. Naming the exact patch level that carries the Baikai 0.4 bounds makes the cohort
  explicit and auditable, which is the whole point of the request.
  Date: 2026-07-30

- Decision: Keep `kiroku-store` at `^>=0.3.0.1`.
  Rationale: `keiro-core-0.4.0.1` itself declares `kiroku-store >=0.3 && <0.4`, and the
  current release is `0.3.1.0`. Kioku's existing bound already admits it; there is no Kiroku
  0.4 to move to. The improvement request's mention of "Kiroku bounds" is satisfied by
  confirming rather than changing.
  Date: 2026-07-30

- Decision: Deprecate Kioku's codd import path in `0.2.0.0` and remove it in a follow-up
  plan, gated on Shikigami completing its own plan 38 — rather than removing it now.
  Rationale: The stated intent was removal, and verification was requested first. The
  verification came back negative (Surprises & Discoveries item 10): Shikigami is the only
  real downstream consumer, it still depends on `codd` and `codd-extras`, still Git-pins
  `hasql-migration`, still pins Kioku at a pre-pg-migrate commit, and its own
  `docs/plans/38-migrate-shikigami-database-evolution-from-codd-to-pg-migrate.md` has not
  run. Kioku's `import-codd` subcommand and `codd-upgrade/*.sql` fixups are the bridge that
  plan 38 needs. Deleting them now would strand a live database with no forward-only path
  across, and a migration ledger has no unapply. Deprecating instead keeps the bridge
  standing, publishes the intent, and gives a precise trigger for removal.
  Date: 2026-07-30

- Decision: Do not treat "migrate to pg-migrate" as in scope, because it is already done.
  Rationale: Plan 20 completed the cutover; `kioku-migrate` has run exclusively on
  pg-migrate since, and there is no `hasql-migration` anywhere in the repository
  (Discovery 9). The only pg-migrate work this plan carries is absorbing the two new Keiro
  migrations that arrive with `keiro-migrations 0.4.0.1`, which is Milestone 3.
  Date: 2026-07-30

- Decision: Ship the crypton fix as `baikai-claude-0.4.0.1`, a point release, rather than the
  planned Hackage metadata revision. Kioku therefore declares `baikai-claude ^>=0.4.0.1`.
  Rationale: This is the fallback the plan already documented. The upload is irreversible and
  outward-facing, so it was put to the user rather than performed unilaterally; the user
  uploaded `0.4.0.1` directly. The consequence is the one the plan anticipated — Kioku names
  `^>=0.4.0.1` instead of `^>=0.4.0.0` — and nothing else in the plan is affected.
  Date: 2026-07-30

- Decision: Run Milestone 1's bound edits *before* demonstrating Milestone 0's fix, inverting
  the plan's stated milestone order.
  Rationale: Discovery 11 — Kioku's own stale bounds, and then `cabal.project`'s stale
  `keiki-codec-json` constraint, both mask the crypton conflict, so §0.1 as written fails for
  the wrong reason. The bound edits are pure metadata and independent of the upstream fix, so
  landing them first is safe and is the only way to make the crypton conflict observable. The
  upstream change itself still preceded any claim that the cohort resolves.
  Date: 2026-07-30

- Decision: Run the §3.3 migration rehearsal against a purpose-made scratch database
  (`kioku_plan21_rehearsal`), not the shared dev database the plan's commands name.
  Rationale: The plan's own Idempotence and Recovery section says to rehearse against a scratch
  database first, and §3.3's literal commands (`just create-database`, `$PGDATABASE`) target
  the developer's live `kioku` database. A scratch database gives identical evidence with no
  exposure. It was additionally *seeded* with rows in `keiro.keiro_snapshots` and
  `keiro.keiro_workflow_children` — the two tables the new migrations alter — because an empty
  database would have made the before/after comparison vacuous.
  Date: 2026-07-30

- Decision: Capture the Milestone 4 codec fixtures from the current tree rather than from a
  pre-upgrade build, and verify equivalence by source diff instead.
  Rationale: §4.1 wants fixtures that are "genuine historical bytes rather than round-trips of
  the new code". The concern is that the encoder changed across the upgrade. It provably did
  not: `git diff --name-only d76800e HEAD -- kioku-core/src kioku-api/src` returns zero files,
  so the encoders are byte-identical and the two capture routes cannot differ. A pre-upgrade
  capture was attempted first and abandoned only after it required rebuilding the entire Keiro
  0.3 / Keiki 0.2 stack from source. The equivalence argument is a stronger guarantee than the
  capture it replaces, since it covers every fixture at once.
  Date: 2026-07-30

- Decision: Leave Milestone 3's test-assertion changes folded into the Milestone 5 commit
  (`1865be6`) rather than rewriting history to split them out.
  Rationale: A `git add -A` in the Milestone 5 commit swept up
  `kioku-migrations/test/Main.hs`, so the planned separate `test(migrations):` commit does not
  exist. Every commit still leaves the tree building and testing green, which is the property
  the plan actually requires. Rewriting published-shaped history for cosmetic attribution is a
  worse trade than recording the fact here.
  Date: 2026-07-30

- Decision: Follow the release skill's steps by hand rather than invoking it, and treat its
  step-1 pre-flight as a checklist to verify rather than work to do.
  Rationale: The skill is marked `disable-model-invocation: true`, so §6.2's `/release major` is
  not executable (Discovery 17). Its steps were read and executed in order instead, which is what
  the plan's "read that file before starting; it is the authority" instruction asks for anyway.
  The pre-flight items it describes as outstanding gaps were all already satisfied, so verifying
  each and moving on was the correct reading.
  Date: 2026-07-30

- Decision: Build Hackage documentation with `cabal haddock lib:<pkg>` rather than bare
  `cabal haddock`.
  Rationale: Discovery 18 — the unscoped form includes the `test-support` sublibrary for
  `kioku-migrations`, producing an archive entry containing a `:` that Hackage rejects outright.
  Only the main library's documentation belongs on Hackage, so scoping is both the fix and the
  more correct command. Applied uniformly to the three packages that have libraries.
  Date: 2026-07-30

- Decision: Put the scope of the release to the user as an explicit four-option choice — commit
  only, commit and tag and push, or the full publish — rather than proceeding on the strength of
  the `/exec-plan implement` invocation alone.
  Rationale: The plan records that Milestone 6 was paused at the user's instruction with an
  explicit stop before the version bump, tag, and Hackage publish. A Hackage version cannot be
  reused and a pushed tag is permanent, so the stop was worth honouring explicitly even though
  the implement invocation could be read as lifting it. The user chose the full publish. All
  reversible work — changelogs, version bump, and the four gates — was completed before asking,
  so the question was asked with everything ready rather than as a blocking checkpoint.
  Date: 2026-07-30

- Decision: Treat the improvement request's "connection-settings application environment"
  clause as *document, do not change*.
  Rationale: Kioku's connection settings enter through `Kioku.App.AppEnv.connectionSettings`
  (`kioku-core/src/Kioku/App.hs:29`), a `Kiroku.Store.Connection.ConnectionSettings` handed to
  `withKirokuStore`. `kiroku-store` is not moving major versions in this cohort, so nothing
  about that path changes. The deliverable is a changelog sentence confirming it, not a
  refactor.
  Date: 2026-07-30


## Outcomes & Retrospective

**Status as of 2026-07-30: complete. All six milestones are done and Kioku 0.2.0.0 is published.**

Kioku `0.2.0.0` is on Hackage as five packages — `kioku-api`, `kioku-migrations`, `kioku-core`,
`kioku-cli`, `kioku-migrate` — tagged `v0.2.0.0` and released at
https://github.com/shinzui/kioku/releases/tag/v0.2.0.0.

All five of the improvement request's acceptance criteria are met, each with the evidence the
Validation and Acceptance section asked for:

1. *Builds and tests against released Keiki 0.4 and Keiro 0.4.* `cabal build all` and
   `cabal test all` green — 130 tests in `kioku-core`, 36 in `kioku-cli`, 7 in `kioku-migrations`.
2. *Bounds admit the cohort without `allow-newer`.* Proven by the §6.3 scratch project, outside
   this repository with no project file and therefore no possible escape hatch, resolving
   `kioku-core-0.2.0.0` with `keiro-0.4.0.1` and `keiki-0.4.0.0` from Hackage alone
   (Discovery 19). This is the criterion the in-repository dry-run could not prove.
3. *Existing fixtures remain readable.* The green session, awaiting, timer, distillation and Rei
   compatibility suites, plus the new `Kioku.CodecCompatSpec` decoding thirteen literal
   pre-upgrade payloads, proven non-vacuous by deliberate corruption (§4.4).
4. *Migrations compose through released pg-migrate.* `cabal test kioku-migrations` green against
   `keiro-migrations-0.4.0.1` and `pg-migrate-1.1.0.0`, and the Discovery 14 rehearsal: exactly
   two migrations applied to a pre-existing database, byte-identical row digests before and after,
   `verification ok applied=38 pending=0 unknown=0`.
5. *Tagged release and notes identify all breaking changes.* `v0.2.0.0`, five packages on Hackage,
   and changelogs naming the Keiki/Keiro/Baikai moves, the two new Keiro migrations, the
   deprecation, and the unchanged connection-settings path.

The negative check also passed: the solve selects `shikumi-0.3.0.1` and `baikai-0.4.1.0`, not the
`shikumi-0.3.0.0`/`baikai-0.3.1.0` fallbacks Discovery 7 warned could be taken silently.

**The pattern in this plan's mistakes held to the end.** Four of the plan's Concrete Steps turned
out to be wrong — §0.1 cannot reproduce the conflict it claims to (11), the comment placement is
undone by the formatter (13), the subcommand is `import` not `import-codd` (15), and the release
skill cannot be invoked as `/release major` (17). Every one is a *command that was never run*.
Not one of the plan's *claims about the code* was wrong: Discoveries 4, 5 and 6 predicted zero
source changes and there were zero; all six migration-test assertion predictions were right,
including the subtle one about the effect count staying at 5. The lesson from the first
implementation session — that a plan's commands deserve the same verification as its claims —
was confirmed rather than learned.

Two things the plan did not anticipate at all, both in the publish itself: Hackage rejects a
documentation tarball containing a sublibrary whose name has a colon in it (18), and a
cold-cache Hackage solve can run long enough to look hung (19).

---

*The section below records the state at the earlier pause, and is kept for the history.*

**Status as of 2026-07-30: Milestones 0 through 5 complete. Milestone 6 not started, paused for
go-ahead before any version bump, tag, or Hackage publish.**

What the repository looks like now. `cabal build --dry-run all` resolves `keiki-0.4.0.0`,
`keiro-0.4.0.1`, `keiro-core-0.4.0.1`, `keiro-migrations-0.4.0.1`, `keiki-codec-json-0.4.0.0`,
`baikai-0.4.1.0`, `baikai-claude-0.4.0.1`, `baikai-effectful-0.3.0.2`, `shikumi-0.3.0.1`,
`shikumi-trace-0.2.0.1`, `kiroku-store-0.3.1.0` and `pg-migrate-1.1.0.0` — with no
`--allow-newer` on the command line and none in `cabal.project`. `cabal build all` and
`cabal test all` are green: 130 tests in `kioku-core`, 36 in `kioku-cli`, 7 in
`kioku-migrations`. The codd import bridge is deprecated and still working.

The forecasting was unusually good. The plan predicted that Milestone 2 would need "few or no"
source changes; it needed **none at all** — Discoveries 4, 5 and 6 each held exactly. It
predicted which three migration-test assertions would move and which three would not; all six
predictions were right, including the subtle one about `forwardMigrationEffectCountStatement`
staying at 5 because its SQL happens not to probe the new columns.

Where the plan was wrong, it was wrong about *process*, not analysis. Three of the four
implementation-time surprises are defects in the plan's own instructions rather than in its
understanding of the code: §0.1 cannot reproduce the conflict it claims to (Discovery 11), the
subcommand is called `import` rather than `import-codd` (Discovery 15), and the comment
placement Milestone 1 requests is silently undone by the repository's own formatter
(Discovery 13). The lesson worth carrying forward is that a plan's *commands* deserve the same
verification as its *claims* — the claims here were checked against the code and were right; the
commands were not run, and three of them were wrong.

The one genuinely irreversible step, widening `baikai-claude`'s crypton bound on Hackage, was
put to the user rather than performed unilaterally, and shipped by the documented fallback path.

**What remains.** Milestone 6 only: changelogs, the `0.2.0.0` bump across five packages, the
`v0.2.0.0` tag, publication in dependency order, and the §6.3 scratch-project check that is the
literal statement of the improvement request's second acceptance criterion. Note that the
in-repository dry-run is a *weaker* check than §6.3, because a `cabal.project` is present; the
criterion is not proven until §6.3 runs against Hackage alone.

*(All of the above was completed on 2026-07-30; see the current status at the top of this
section.)*

**Cleanup owed.** The rehearsal artifacts are still on disk and should be removed once the
evidence is no longer needed: the scratch database `kioku_plan21_rehearsal`, and the git
worktree holding the pre-upgrade build under the session scratchpad
(`git worktree remove <path>`). Neither affects the repository. This remains outstanding.

**Follow-up owed.** The codd-removal ExecPlan described at the end of Milestone 5 has not been
opened. It is gated on Shikigami's plan 38 and should not start before then.


## Context and Orientation

This repository, at `/Users/shinzui/Keikaku/bokuno/kioku`, holds five Haskell packages listed
in `cabal.project`. Read that file first; it is short. In dependency order the packages are:

`kioku-api/` holds the wire types — identifiers, memory-scope types, the custom prelude. It
depends on nothing else in the repo. `kioku-migrations/` owns the database schema evolution:
ten SQL files under `kioku-migrations/migrations/`, listed in apply order in the plain-text
file `kioku-migrations/migrations/manifest`, embedded into the library at compile time. It
also ships a second, publicly visible library component called `test-support` that spins up a
throwaway PostgreSQL server for tests. `kioku-core/` is the runtime: memory and session
aggregates, recall, and the distillation pipeline. `kioku-cli/` is the command-line front
end. `kioku-migrate/` is a standalone executable that applies the migrations; it lives in its
own package because `kioku-core`'s test-suite depends on `kioku-migrations:test-support`, and
putting the executable inside `kioku-migrations` would close a package-level dependency cycle
that Cabal's solver rejects even though the component graph is acyclic. The header comment in
`kioku-migrate/kioku-migrate.cabal` explains this.

Some terms used throughout:

A **Cabal solver plan** is the set of exact package versions Cabal picks to satisfy every
declared dependency range at once. `cabal build --dry-run` computes one and prints it without
compiling anything, which makes it a fast way to prove that a set of bounds is satisfiable.

**PVP** is the Haskell Package Versioning Policy. A version `A.B.C.D` breaks compatibility
when `A.B` changes, adds API when `C` changes, and fixes bugs when `D` changes. The operator
`^>=0.3.0.0` is shorthand for `>=0.3.0.0 && <0.4`, and `^>=1.0` is shorthand for `>=1.0 &&
<1.1`. That second reading is the crux of Milestone 0 and is easy to misread.

**`allow-newer`** is a Cabal escape hatch that tells the solver to ignore declared upper
bounds. It lives in a `cabal.project` file, which is a local build configuration file and is
**not** uploaded to Hackage. That is why an `allow-newer` cannot fix a downstream consumer's
problem: they never see it.

A **Hackage metadata revision** is an edit to a published package's `.cabal` file — and only
its `.cabal` file — uploaded after the fact. The package's version number and source tarball
stay exactly the same; Hackage serves the revised metadata to the solver. Revisions are the
standard remedy for a dependency bound that turned out to be too tight. You upload one from
the package's Hackage page under "edit package information", or with
`cabal upload --publish` against a revised `.cabal`.

**pg-migrate** is the migration runner Kioku uses. Unlike its predecessor, codd, it keys each
migration by a stable logical identity of the form `component/name` and stores a SHA-256
checksum of the applied SQL, so it can verify after the fact that nobody edited an applied
migration. Kioku's migration plan, built in `kioku-migrations/src/Kioku/Migrations.hs` by
`kiokuMigrationPlan`, composes three components in dependency order: Kiroku's, then Keiro's,
then Kioku's own. Because Keiro's component is compiled in from the `keiro-migrations`
package, upgrading that package is what brings Keiro's two new migrations into Kioku's plan.

The **cohort** is the phrase this repository uses for the set of upstream packages that must
move together: Keiki, Keiro, Kiroku, Shibuya, Shikumi, Baikai, and pg-migrate. The
improvement request that motivates this plan is
`docs/improvement-requests/release-kioku-for-keiki-0-4-and-keiro-0-4.md`. The prior plan that
moved Kioku onto pg-migrate is
`docs/plans/20-move-kioku-off-codd-onto-pg-migrate-and-upgrade-the-keiro-kiroku-cohort.md`;
this plan is its direct successor and does not repeat its work.

Every commit made under this plan must carry two git trailers, separated from the body by a
blank line:

```text
ExecPlan: docs/plans/21-release-kioku-for-the-keiki-0-4-keiro-0-4-baikai-0-4-and-shikumi-cohort.md
Intention: intention_01kytapemyezfakpdf0ke73cgw
```

Commit messages follow Conventional Commits (`feat:`, `fix:`, `chore:`, with `!` or a
`BREAKING CHANGE:` footer for breaks). Commit directly to the current branch; do not create a
feature branch.


## Plan of Work

### Milestone 0 — Unblock the Baikai/crypton conflict upstream

**Scope.** Nothing in this repository changes. The work happens in the Baikai repository at
`/Users/shinzui/Keikaku/bokuno/baikai` and on Hackage. At the end of this milestone,
`baikai-claude-0.4.0.0` as served by Hackage admits `crypton` 1.1.x, and a dry-run solve of
Kioku against the full 0.4 cohort succeeds with no escape hatches.

**Why this must be first.** Every later milestone assumes the cohort is solvable. It is not,
today, for the reason recorded in Surprises & Discoveries item 2: `baikai-claude-0.4.0.0`
caps `crypton` below 1.1 while `pg-migrate-1.1.0.0` requires at least 1.1, and Kioku needs
both. No change confined to this repository can reconcile that.

**The change.** In `/Users/shinzui/Keikaku/bokuno/baikai/baikai-claude/baikai-claude.cabal`,
line 54 currently reads `, crypton            ^>=1.0`. It becomes `, crypton            >=1.0
&& <1.2`. That is the entire edit. It is safe because the only crypton import anywhere in
`baikai-claude` is `Crypto.Hash (Digest, SHA256)` at
`baikai-claude/src/Baikai/Provider/Claude/Transport.hs:22-23`, and that module's API is
byte-identical between crypton 1.0 and 1.1.

Publish it as a metadata revision of the existing `0.4.0.0` (see Decision Log). If the
revision path is unavailable for any reason, cut `baikai-claude-0.4.0.1` containing only this
bound change and a changelog entry saying so; the rest of this plan is unaffected apart from
writing `^>=0.4.0.1` instead of `^>=0.4.0.0` in Kioku's cabal file.

**Acceptance.** The dry-run in Concrete Steps §0.4 resolves with no `--allow-newer`.

### Milestone 1 — Move the package bounds onto the released cohort

**Scope.** Six files change, all of them dependency metadata. At the end of this milestone
`cabal build --dry-run all` selects the target cohort with no escape hatches, but nothing has
been compiled yet.

In `kioku-core/kioku-core.cabal`, the `library` stanza's `build-depends` currently contains
`keiki ^>=0.2.0.0`, `keiro ^>=0.3.0.0`, `keiro-core ^>=0.3.0.0`, `baikai ^>=0.3.0.0`,
`baikai-claude ^>=0.3.0.0`, `baikai-effectful ^>=0.3.0.0`, `shikumi ^>=0.3.0.0`, and
`shikumi-trace ^>=0.2.0.0`. These become `keiki ^>=0.4.0.0`, `keiro ^>=0.4.0.1`, `keiro-core
^>=0.4.0.1`, `baikai ^>=0.4.1.0`, `baikai-claude ^>=0.4.0.0`, `baikai-effectful ^>=0.3.0.2`,
`shikumi ^>=0.3.0.1`, and `shikumi-trace ^>=0.2.0.1`. Note that `baikai-effectful` has no 0.4
release — its newest is `0.3.0.2`, which itself depends on `baikai ^>=0.4.0`. That asymmetry
is correct, not a mistake; leave a short comment in the cabal file saying so, because a
future reader will otherwise "fix" it.

The same file's `test-suite kioku-test` stanza repeats `keiro ^>=0.3.0.0`, `keiro-core
^>=0.3.0.0`, `baikai ^>=0.3.0.0`, `shikumi ^>=0.3.0.0`, and `shikumi-trace ^>=0.2.0.0`. Apply
the identical bumps there. `crypton ^>=1.1.4` and `kiroku-store ^>=0.3.0.1` stay exactly as
they are; `shibuya-core >=0.8.0.1 && <0.9` and `shibuya-kiroku-adapter ^>=0.4.0.0` likewise
already name the current releases.

In `kioku-migrations/kioku-migrations.cabal`, the `library` stanza has `keiro-migrations
^>=0.3.0.0`; it becomes `^>=0.4.0.1`. `kiroku-store-migrations ^>=0.3.0.0` and the five
`pg-migrate*` bounds stay put — `keiro-migrations-0.4.0.1` declares those same ranges itself.

In `cabal.project`, the `constraints:` block pins optional integrations that Kioku does not
build. Two of its entries are now wrong: `keiki-codec-json ^>=0.2.0.0` must become
`^>=0.4.0.0`, and `keiro-pgmq ^>=0.3.0.0` must become `^>=0.4.0.1`. The comment above the
block claims these packages "are not in Kioku's current build closure"; that is no longer
true of `keiki-codec-json`, which Keiro 0.4 depends on directly, so rewrite the comment to
say that `keiki-codec-json` is now pulled in transitively by Keiro while the PGMQ entries
remain forward-looking pins.

**Acceptance.** Concrete Steps §1.2 prints a plan containing `keiki-0.4.0.0`,
`keiro-0.4.0.1`, `keiro-core-0.4.0.1`, `keiro-migrations-0.4.0.1`, `keiki-codec-json-0.4.0.0`,
`baikai-0.4.1.0`, `baikai-claude-0.4.0.0`, `baikai-effectful-0.3.0.2`, `shikumi-0.3.0.1`, and
`shikumi-trace-0.2.0.1`, with no `--allow-newer` on the command line and none in
`cabal.project`.

### Milestone 2 — Compile and fix the API port

**Scope.** Whatever source changes the new APIs demand. Research says this should be small or
empty, but the compiler is the authority, and this milestone exists to let it speak.

The three upstream changes that could plausibly reach Kioku's source are these. First, Keiro
0.4 makes validated event-stream assembly reject an event codec whose schema version, event
tags, or upcaster chain fail `mkCodec`. Kioku builds two streams through
`Keiro.EventStream.Validate.mkEventStreamOrThrow` — `memoryEventStream` at
`kioku-core/src/Kioku/Memory/EventStream.hs:33` and `sessionEventStream` at
`kioku-core/src/Kioku/Session/EventStream.hs:33`. Both codecs declare `schemaVersion = 1`, a
non-empty `eventTypes` list, and `upcasters = []`, which should pass; but `mkEventStreamOrThrow`
throws at *evaluation* time rather than compile time, so a failure here surfaces as a test
crash in Milestone 4, not a build error. Watch for it in both places.

Second, Keiki 0.4 extends the `Term` type and the validation-warning types. This breaks
exhaustive pattern matches, and Kioku has none (Discovery 5). Third, Baikai 0.4 changed
`claudeCliCommand`'s signature and extended `ThinkingLevel`; Kioku's only Claude-provider
contact is `ClaudeApi.register` at `kioku-core/src/Kioku/Distill/Runtime.hs:74`, which is
untouched by both.

If the compiler does surface something, fix it in place and record both the error and the fix
under Surprises & Discoveries with the exact GHC message. Do not paper over a type error with
a bound relaxation.

**Acceptance.** `cabal build all` completes. Record the result in Progress either way.

### Milestone 3 — Migrations absorb Keiro 0019 and 0020

**Scope.** `kioku-migrations/test/Main.hs` learns about Keiro's two new migrations, and the
forward upgrade is demonstrated against a database that was migrated by the old Kioku.

`keiro-migrations 0.4.0.0` appends two files to Keiro's component:
`0019-keiro-snapshots-state-shape-hash.sql`, which adds a `state_shape_hash` column to
`keiro.keiro_snapshots`, and `0020-keiro-workflow-children-failure-reason.sql`, which adds a
nullable `failure_reason` column to Keiro's workflow-children table. Both are additive column
additions on Keiro-owned tables. Kioku writes to neither table — it has no snapshots
(Discovery 4) and no durable workflows — so the effect on a Kioku database is two ALTER TABLE
statements against tables Kioku never reads.

Three assertions in `kioku-migrations/test/Main.hs` go stale. `expectedForwardMigrationIds`
(line 337) lists the migrations that a database imported from the old codd ledger still needs
to apply; it currently ends at `migrationId "keiro" "0018"` and gains `"0019-keiro-snapshots-state-shape-hash"`
and `"0020-keiro-workflow-children-failure-reason"` — take the exact identifier strings from
`keiro-migrations`' embedded manifest rather than guessing them, because pg-migrate matches on
the logical name and a typo produces a confusing "unknown migration" rather than a mismatch.
`length appliedMigrations @?= 36` (line 268) becomes `38`, and the `AlreadyApplied` count on
line 274 likewise becomes `38`.

Two assertions must **not** change, and if they do it means something is wrong. `length (toList
cohortCoddHistoryMappings) @?= 30` (line 93) counts migrations that existed in the historical
codd ledger; 0019 and 0020 are native pg-migrate migrations that never had a codd filename, so
30 stands. `length (toList kiokuCoddHistoryMappings) @?= 10` counts Kioku's own, which are
untouched. The `forwardMigrationEffectCountStatement` assertion at line 267 counts observable
schema effects of the forward migrations; whether it moves depends on whether that statement's
SQL probes the new columns, so read it before assuming — if it does not mention snapshots or
workflow children, it stays at 5.

**Acceptance.** `cabal test kioku-migrations` passes, and the manual rehearsal in Concrete
Steps §3.3 shows exactly two migrations applied to a pre-existing database with every
pre-existing row intact.

### Milestone 4 — Runtime, replay, and codec compatibility evidence

**Scope.** Prove that data written by the released `kioku-*-0.1.0.0` is still readable. The
improvement request's third acceptance criterion asks for exactly this: existing session,
memory, timer, and distillation fixtures must remain readable or have an explicit migration
path.

Run the existing suites first. `kioku-core`'s suite (`kioku-core/test/`) already covers the
ground that matters: `Kioku.SchemaSpec` checks the physical schema, `Kioku.ReadModelReconcileSpec`
checks that Keiro's read-model registry reconciles to what the compiled read models declare,
`Kioku.SessionLineageSpec` and `Kioku.AwaitingSpec` exercise session state and resume,
`Kioku.TimerWorkerSpec` exercises timers, `Kioku.DistillSpec` exercises the distillation
pyramid, and `Kioku.ReiCompatSpec` already exists to check compatibility with data written by
Kioku's predecessor. A green run of these against the 0.4 cohort is the bulk of the evidence.

Then add the piece that is genuinely new. Keiro 0.4 tightened codec validation, so the risk
worth pinning down in a test is that an event payload written by the old Kioku still decodes
under the new one. Add a test module `kioku-core/test/Kioku/CodecCompatSpec.hs` that holds
literal JSON payloads — one per constructor of `MemoryEvent` and one per constructor of
`SessionEvent`, captured from the current `encode` before the upgrade — and asserts that
`Kioku.Memory.EventStream.parseMemoryEvent` and the session equivalent return `Right` for each,
with the expected value. Capture the payloads *before* changing bounds, by running the encoders
under the current cohort, so the fixtures are genuine historical bytes rather than
round-trips of the new code. Register the module in the `other-modules:` list of the
`test-suite kioku-test` stanza in `kioku-core/kioku-core.cabal`.

Note that `parseMemoryEvent` already has a legacy fallback path
(`kioku-core/src/Kioku/Memory/EventStream.hs:70-77`): it tries the native parser, then a
`parseLegacyMemoryEvent`, and reports both errors on failure. The new test should cover both
arms so a future upgrade cannot silently delete the fallback.

**Acceptance.** `cabal test all` passes, and the new codec test fails if you deliberately
corrupt one of its fixture payloads — check that once, then revert.

### Milestone 5 — Dispose of the codd import path

**Scope.** Kioku's remaining codd surface is deprecated but left working, and the condition
for deleting it is written down where the next contributor will find it. No behavior changes.

**Why not simply delete it.** The intent is removal, and this milestone's first step was to
verify that removal is safe. It is not, yet. Surprises & Discoveries item 10 records the
evidence: `mori registry dependents shinzui/kioku` names Kikan and Shikigami; Kikan does not
actually depend on any `kioku-*` package; and Shikigami still declares `codd >=0.1.8 && <0.2`
and `codd-extras`, still Git-pins `hasql-migration` and `codd-project`, and still pins Kioku
at pre-pg-migrate commit `8bcfc282484dd59b0a0b25530cca4f3ad9034ce1`. Its database has a live
codd ledger, and `kioku-migrate import-codd` plus `kioku-migrations/codd-upgrade/*.sql` are
the only supported way across. A migration ledger is forward-only — there is no unapply — so
removing the bridge before the crossing is not a recoverable mistake.

**The change.** Mark the surface deprecated so the intent is public and the compiler says so.
Add a `{-# DEPRECATED #-}` pragma to `Kioku.Migrations.History.Codd` in
`kioku-migrations/src/Kioku/Migrations/History/Codd.hs`, worded to name both the reason and
the trigger — something like "one-time codd import bridge; scheduled for removal once
Shikigami plan 38 completes its cutover". Extend the `progDesc` for the `import-codd`
subcommand in `kioku-migrate/app/Main.hs:90` with the same note, so an operator reading
`kioku-migrate --help` sees it. Then add a short section to
`kioku-migrations/codd-upgrade/README.md` stating the removal gate in plain terms: the
directory, the module, the subcommand, the `pg-migrate-import-codd` dependency in three cabal
stanzas, and the `testCoddCohortImport` rehearsal all go together, in one commit, once
Shikigami's database no longer has a codd ledger.

Everything keeps building and testing. `testCoddCohortImport` still runs — it must, because
the bridge must still work — which is why its assertions are updated in Milestone 3 rather
than deleted.

Note that GHC will warn on the deprecated import inside Kioku's own test and
`kioku-migrate/app/Main.hs`. Confine the pragma to the module header rather than to
individual exports, or add a targeted `-Wno-deprecations` to those two stanzas, so the build
does not turn noisy; `kioku-core`'s `common warnings` block does not enable `-Werror`, so
this is cosmetic either way. Decide when you see the actual output and record which you chose.

**Acceptance.** `cabal build all` still succeeds, `cabal test kioku-migrations` still passes
including `testCoddCohortImport`, and `cabal run kioku-migrate -- --help` shows the
deprecation note on the `import-codd` subcommand.

**The follow-up.** After this plan ships, open a new ExecPlan for the removal itself. It
should delete `kioku-migrations/src/Kioku/Migrations/History/Codd.hs`,
`kioku-migrations/codd-upgrade/`, the `import-codd` subcommand and its options parser, the
`pg-migrate-import-codd` dependency from `kioku-migrations.cabal` (both the library and the
test-suite stanzas) and `kioku-migrate.cabal`, the `extra-doc-files`/`extra-source-files`
entries for `codd-upgrade/`, and `testCoddCohortImport` together with its fixture
`kioku-migrations/test/fixtures/pre-cutover-schema.sql` and helpers `coddV5Ledger` and
`coddSnapshotStatement`. It must also retire `.claude/skills/cohort-migrate`, which is built
entirely on this bridge. That plan cannot start until Shikigami's plan 38 has run against
every live Shikigami database — check for a surviving `codd.sql_migrations` table before
believing otherwise.

### Milestone 6 — Document, version, tag, and publish

**Scope.** The release itself, driven by the repository's own release skill at
`agents/skills/release/SKILL.md`. Read that file before starting; it is the authority on the
ordering and the pre-flight checks, and this milestone deliberately does not restate its
steps.

Two things the skill will need from you. First, the changelogs. Every package has a
`CHANGELOG.md` with an `Unreleased` section. Write the entries before running the skill, in
the "Keep a Changelog" style the rest of the cohort uses — a `### Breaking Changes` heading
followed by prose. `kioku-core`'s entry must name: the move to Keiki 0.4 and Keiro 0.4 and
what that implies for a consumer (stricter validated event-stream assembly at startup, and
the fact that any consumer of Kioku now links Keiro 0.4's snapshot and timer API changes); the
move to the Baikai 0.4 / Shikumi 0.3.0.1 cohort; and a sentence confirming that the
connection-settings path through `Kioku.App.AppEnv.connectionSettings` is unchanged.
`kioku-migrations`' entry must name the two new Keiro migrations by filename and state that
they are additive column additions on Keiro-owned tables that Kioku does not read.
`kioku-migrate`'s entry must state that an existing database picks up exactly those two
migrations on the next `up`. Both `kioku-migrations` and `kioku-migrate` need a
`### Deprecated` heading announcing the codd import bridge's scheduled removal and naming the
trigger, so a downstream reading only the changelog learns it must cross over. `kioku-api`
and `kioku-cli` get a "no API change; released in lockstep" entry. The root `CHANGELOG.md`
gets the summary used for the GitHub release.

Second, the version. Tell the skill `major`, giving `0.2.0.0` (see Decision Log for why a
major bump is right even if no Kioku source changed). The skill bumps all five cabal files
and the internal `^>=0.1.0.0` cross-dependencies together; let it, rather than editing by
hand, because those internal bounds appear in seven places across four files and are easy to
miss.

**Acceptance.** `git tag --list 'v*'` shows `v0.2.0.0`, all five packages are visible on
Hackage at `0.2.0.0`, and the scratch-project check in Concrete Steps §6.3 resolves the whole
cohort from Hackage alone.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/kioku` unless stated otherwise.

### §0 — Milestone 0

**§0.1 Reproduce the conflict.** This is expected to *fail*, and its failure is the evidence
that Milestone 0 is needed.

```bash
cabal build --dry-run all \
  --constraint="keiki >=0.4" --constraint="keiro >=0.4" --constraint="keiro-core >=0.4" \
  --constraint="keiro-migrations >=0.4" --constraint="baikai >=0.4" \
  --constraint="shikumi >=0.3.0.1"
```

Expect a solver rejection naming `crypton`, `baikai-claude`, and `pg-migrate`:

```text
[__3] rejecting: baikai-claude-0.4.0.0 (conflict: crypton==1.1.4, baikai-claude => crypton^>=1.0)
```

**§0.2 Confirm the API-stability claim.** In `/Users/shinzui/Keikaku/bokuno/baikai`:

```bash
grep -rn "Crypto\." --include="*.hs" baikai-claude/src
```

Expect exactly two lines, both in `Baikai/Provider/Claude/Transport.hs`, importing
`Crypto.Hash (Digest, SHA256)`. If any other crypton module appears, stop and re-evaluate —
the bound may be load-bearing after all, and this plan's Milestone 0 would need rethinking.

**§0.3 Widen the bound.** Edit
`/Users/shinzui/Keikaku/bokuno/baikai/baikai-claude/baikai-claude.cabal` line 54:

```diff
-    , crypton            ^>=1.0
+    , crypton            >=1.0    && <1.2
```

Publish it as a Hackage metadata revision of `baikai-claude-0.4.0.0`. Commit the same edit to
the Baikai repository so the source of truth and Hackage agree, with a Conventional Commit
such as `fix(baikai-claude)!: widen crypton bound to admit 1.1.x`. Note that the commit lives
in the Baikai repository, so it carries no `ExecPlan:` trailer — that trailer names a path in
*this* repository and would dangle there. Mention this plan in the commit body in prose
instead.

**§0.4 Prove the fix.** Back in the Kioku directory, re-run §0.1. It should now print a
complete build plan. Until the revision is live on Hackage, you can prove the same thing
locally by appending `--allow-newer='baikai-claude:crypton'`; that is a rehearsal only and
must not be committed anywhere.

Expected plan excerpt:

```text
 - baikai-0.4.1.0 (lib) (requires build)
 - keiki-0.4.0.0 (lib) (requires build)
 - baikai-effectful-0.3.0.2 (lib) (requires build)
 - baikai-claude-0.4.0.0 (lib) (requires build)
 - keiki-codec-json-0.4.0.0 (lib) (requires build)
 - keiro-core-0.4.0.1 (lib) (requires download & build)
 - shikumi-0.3.0.1 (lib) (requires build)
 - keiro-0.4.0.1 (lib) (requires download & build)
 - shikumi-trace-0.2.0.1 (lib) (requires build)
 - keiro-migrations-0.4.0.1 (lib) (requires download & build)
```

### §1 — Milestone 1

**§1.1 Apply the bound edits** described in Plan of Work Milestone 1 to
`kioku-core/kioku-core.cabal`, `kioku-migrations/kioku-migrations.cabal`, and `cabal.project`.

**§1.2 Prove the bounds are self-sufficient.** The point of this command is that it carries
*no* `--constraint` and *no* `--allow-newer` — the declared bounds alone must produce the
cohort.

```bash
cabal build --dry-run all
```

Expect the same plan excerpt shown in §0.4. If the solver instead selects `shikumi-0.3.0.0`
or `baikai-0.3.1.0`, a bound was missed — most likely in the `test-suite kioku-test` stanza,
which repeats several of the same dependencies.

**§1.3 Commit.**

```text
feat(deps)!: move bounds onto the Keiki 0.4, Keiro 0.4, Baikai 0.4 cohort

Bump keiki to 0.4, keiro/keiro-core/keiro-migrations to 0.4.0.1, and the
baikai/shikumi cohort to their current releases. Correct the stale
keiki-codec-json constraint in cabal.project, which Keiro 0.4 now pulls into
the build closure directly.

BREAKING CHANGE: kioku no longer builds against Keiki 0.2 or Keiro 0.3.

ExecPlan: docs/plans/21-release-kioku-for-the-keiki-0-4-keiro-0-4-baikai-0-4-and-shikumi-cohort.md
Intention: intention_01kytapemyezfakpdf0ke73cgw
```

### §2 — Milestone 2

```bash
cabal build all 2>&1 | tail -40
```

Fix whatever GHC reports, one error at a time, and record each fix in Surprises &
Discoveries with the verbatim message. Commit as `fix(core): port to the Keiro 0.4 API`, or —
if nothing needed changing — skip the commit and record that fact in Progress, which is itself
a useful finding.

### §3 — Milestone 3

**§3.1 Read the new migration identifiers** rather than guessing them. After §1 the new
`keiro-migrations` is in the store; find its embedded manifest:

```bash
find ~/.cabal ~/.local/state/cabal -path '*keiro-migrations-0.4.0.1*' -name manifest 2>/dev/null | head -1 | xargs tail -4
```

Expect the last two entries to be `0019-keiro-snapshots-state-shape-hash.sql` and
`0020-keiro-workflow-children-failure-reason.sql`. The pg-migrate logical name is the
filename with the `.sql` suffix removed.

**§3.2 Update the assertions** in `kioku-migrations/test/Main.hs` as described in Plan of Work
Milestone 3, then:

```bash
cabal test kioku-migrations
```

Expect `All N tests passed`. A failure of the form `expected: 38 but got: 36` means the new
`keiro-migrations` was not picked up; re-check §1.2.

**§3.3 Rehearse the forward upgrade on a pre-existing database.** This is the step that
proves existing data survives, and it is the one a reviewer will want to see. Using the
repository's dev database via `just create-database` and `just migrate` (both defined in
`Justfile`, both relying on the `PG*` variables from the nix devShell):

```bash
# From a checkout at the pre-upgrade commit, create and fully migrate a database.
git stash && just create-database && git stash pop

# Capture the row counts you must not lose.
psql -h "$PGHOST" -d "$PGDATABASE" -tAc \
  "SELECT relname, n_live_tup FROM pg_stat_user_tables
   WHERE schemaname IN ('kioku','kiroku','keiro') ORDER BY relname" > /tmp/rows-before.txt

# Now apply the upgraded plan.
DATABASE_URL="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" cabal run kioku-migrate -- up
```

Expect the `up` output to report exactly two migrations applied — the Keiro 0019 and 0020
identifiers from §3.1 — and everything else already applied. Then confirm nothing was lost:

```bash
psql -h "$PGHOST" -d "$PGDATABASE" -tAc \
  "SELECT relname, n_live_tup FROM pg_stat_user_tables
   WHERE schemaname IN ('kioku','kiroku','keiro') ORDER BY relname" > /tmp/rows-after.txt
diff /tmp/rows-before.txt /tmp/rows-after.txt
```

Expect `diff` to print nothing. Finally, confirm the checksummed state is coherent:

```bash
DATABASE_URL="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" cabal run kioku-migrate -- verify
```

Expect a report with no issues, no pending migrations, and no unknown migrations. Paste the
transcript of all three commands into Surprises & Discoveries as the migration-compatibility
evidence the improvement request asks for.

**§3.4 Commit** as `test(migrations): absorb keiro 0019 and 0020 into the plan assertions`.

### §4 — Milestone 4

**§4.1 Capture historical payloads before they can drift.** If you have not already done this
at the pre-upgrade commit, do it now from a stashed-clean tree using the old cohort, and save
the JSON literals into the new test module. Each payload is the output of the codec's `encode`
for one event constructor.

**§4.2 Write `kioku-core/test/Kioku/CodecCompatSpec.hs`** and register it in the
`other-modules:` list of `test-suite kioku-test` in `kioku-core/kioku-core.cabal`.

**§4.3 Run everything.**

```bash
cabal test all
```

Expect every suite green. Note that the `kioku-core` and `kioku-migrations` suites start
throwaway PostgreSQL servers through `ephemeral-pg`, so the first run is slow.

**§4.4 Prove the new test has teeth.** Corrupt one fixture payload (change a field name),
re-run `cabal test kioku-core`, confirm the codec test fails with a decode error naming both
the native and legacy parse failures, then revert the corruption and re-run to green.

**§4.5 Commit** as `test(core): pin pre-upgrade event payload decoding`.

### §5 — Milestone 5

**§5.1 Re-confirm the gate before writing anything.** The verification recorded in this plan
was taken on 2026-07-30; confirm it still holds, because if Shikigami has crossed over in the
meantime this milestone becomes a deletion instead of a deprecation.

```bash
grep -n "codd\|hasql-migration" /Users/shinzui/Keikaku/bokuno/shikigami/shikigami-migrations/shikigami-migrations.cabal \
                               /Users/shinzui/Keikaku/bokuno/shikigami/cabal.project
```

Expect matches on `codd >=0.1.8 && <0.2`, `codd-extras`, and the `hasql-migration` and
`codd-project` source-repository stanzas. If they are all gone, stop and revisit the Decision
Log entry — removal may now be the right call, and it should be re-decided with the user
rather than assumed.

**§5.2 Add the deprecation pragmas and README gate** as described in Plan of Work Milestone 5.

**§5.3 Confirm nothing broke.**

```bash
cabal build all && cabal test kioku-migrations
cabal run kioku-migrate -- --help
```

Expect the build and test green, and the `import-codd` line of the help output to carry the
deprecation note.

**§5.4 Commit** as `chore(migrations)!: deprecate the codd import bridge`, with a body naming
Shikigami plan 38 as the removal trigger.

### §6 — Milestone 6

**§6.1 Write the changelog entries** described in Plan of Work Milestone 6, then commit as
`docs(changelog): describe the 0.2.0.0 cohort upgrade`.

**§6.2 Run the release skill** with an explicit major bump. It will present the proposed
version and reasoning and wait for confirmation before changing anything:

```text
/release major
```

Follow its steps for versioning, tagging `v0.2.0.0`, and uploading the five packages in the
order it specifies: `kioku-api`, `kioku-migrations`, `kioku-core`, `kioku-cli`,
`kioku-migrate`.

**§6.3 Verify from Hackage alone.** In a scratch directory outside this repository, with no
`cabal.project` and no local package overrides:

```bash
mkdir -p /tmp/kioku-cohort-check && cd /tmp/kioku-cohort-check
cabal update
cat > check.cabal <<'EOF'
cabal-version: 3.0
name:          check
version:       0
build-type:    Simple

library
  default-language: GHC2024
  build-depends: base, kioku-core ^>=0.2.0.0, keiro ^>=0.4.0.1, keiki ^>=0.4.0.0
EOF
cabal build --dry-run
```

Expect a complete plan naming `kioku-core-0.2.0.0`, `keiro-0.4.0.1`, and `keiki-0.4.0.0`. This
is the literal statement of the improvement request's second acceptance criterion, and it is
the last thing to check before declaring the plan done.


## Validation and Acceptance

The improvement request states five acceptance criteria. Each maps to something observable.

*"All Kioku packages build and test with released Keiki 0.4 and Keiro 0.4 packages."* Observe
`cabal build all` and `cabal test all` completing green from a clean checkout, with the
dry-run plan naming `keiki-0.4.0.0` and `keiro-0.4.0.1`. Steps §2 and §4.3.

*"Package bounds admit the cohort without `allow-newer`."* Observe §6.3: a scratch project
outside this repository, with no project file and therefore no possible escape hatch,
resolving `kioku-core-0.2.0.0` together with `keiro-0.4.0.1` and `keiki-0.4.0.0`. Note that
`cabal build --dry-run all` inside this repository is a weaker check, because a `cabal.project`
is present; §6.3 is the criterion that actually holds.

*"Existing session, memory, timer, and distillation fixtures remain readable or have an
explicit migration path."* Observe two things. The green run of `Kioku.SessionLineageSpec`,
`Kioku.AwaitingSpec`, `Kioku.TimerWorkerSpec`, `Kioku.DistillSpec`, and `Kioku.ReiCompatSpec`
under the new cohort; and the new `Kioku.CodecCompatSpec` decoding genuine pre-upgrade JSON
payloads, proven non-vacuous by §4.4.

*"The migration package composes through released pg-migrate APIs."* Observe `cabal test
kioku-migrations` green with `keiro-migrations-0.4.0.1` and `pg-migrate-1.1.0.0` in the plan,
and the §3.3 transcript: exactly two migrations applied to a pre-existing database, an
identical row-count diff before and after, and a clean `kioku-migrate verify`.

*"A tagged/Hackage release and release notes identify all breaking API changes."* Observe
`git tag --list 'v*'` containing `v0.2.0.0`, five packages at `0.2.0.0` on Hackage, and
changelog entries naming the Keiki 0.4 / Keiro 0.4 / Baikai 0.4 moves, the two new Keiro
migrations, and the unchanged connection-settings path.

Beyond the request, one negative check is worth running because it is the failure this plan
was written to prevent: confirm that `cabal build --dry-run all` does **not** silently select
`shikumi-0.3.0.0` or `baikai-0.3.1.0`. Discovery 7 explains how that fallback happens
invisibly.


## Idempotence and Recovery

Milestones 1 through 4 are ordinary source edits under version control. Every step is
re-runnable, and `git checkout -- <file>` undoes any of them. `cabal build --dry-run` and
`cabal build` have no side effects outside `dist-newstyle/`, which can be deleted and
rebuilt at any time.

Milestone 0 has one irreversible component: a Hackage metadata revision cannot be withdrawn.
It can, however, be superseded by a further revision, so a mistake is correctable by
uploading a corrected `.cabal` — no version is burned and no consumer is stranded. Widening a
bound is additive and cannot break an existing consumer's solve, only admit more plans.
Verify the diff carefully before uploading; the risk is uploading the *wrong* edit, not the
edit itself.

Milestone 3's database rehearsal is the one step that touches real data. It is safe by
construction: `keiro-migrations` 0019 and 0020 are both `ALTER TABLE ... ADD COLUMN` on
Keiro-owned tables, additive and non-destructive, and pg-migrate records each migration's
checksum so re-running `up` on an already-migrated database is a no-op that reports
`AlreadyApplied`. Run the rehearsal against a scratch database first. If you must run it
against something you care about, take a `pg_dump` beforehand — recovery is restore-from-dump,
because a forward-only migration ledger has no unapply path. The `/tmp/rows-before.txt`
snapshot in §3.3 exists precisely so that data loss is detectable rather than assumed absent.
If `kioku-migrate verify` reports issues after the upgrade, do not re-run `up`; capture the
report and diagnose, because a checksum mismatch means an applied migration's bytes changed,
which no amount of re-running fixes.

Milestone 6 is irreversible in the same way all publishing is: a Hackage version number
cannot be reused, and a pushed git tag should be treated as permanent. Run the release skill's
pre-flight checks fully, and do not tag until §4.3 is green. If a package uploads and a later
one in the chain fails, the recovery is to fix the problem and publish the remaining packages
under the same version — the skill's dependency ordering exists so that a partial publish
leaves the already-published packages usable rather than broken.


## Interfaces and Dependencies

At the end of Milestone 1, `kioku-core/kioku-core.cabal`'s library `build-depends` names
`keiki ^>=0.4.0.0`, `keiro ^>=0.4.0.1`, `keiro-core ^>=0.4.0.1`, `baikai ^>=0.4.1.0`,
`baikai-claude ^>=0.4.0.0`, `baikai-effectful ^>=0.3.0.2`, `shikumi ^>=0.3.0.1`, and
`shikumi-trace ^>=0.2.0.1`, with `crypton ^>=1.1.4`, `kiroku-store ^>=0.3.0.1`, `shibuya-core
>=0.8.0.1 && <0.9`, and `shibuya-kiroku-adapter ^>=0.4.0.0` unchanged; the `test-suite
kioku-test` stanza carries the same versions for the dependencies it repeats.
`kioku-migrations/kioku-migrations.cabal` names `keiro-migrations ^>=0.4.0.1` alongside
unchanged `kiroku-store-migrations ^>=0.3.0.0` and `pg-migrate*` `^>=1.1.0.0` bounds.
`cabal.project`'s constraint block names `keiki-codec-json ^>=0.4.0.0` and `keiro-pgmq
^>=0.4.0.1`.

At the end of Milestone 2, these existing signatures must still hold, because Kioku's public
surface is not intended to change in this plan:

```haskell
-- kioku-core/src/Kioku/Memory/EventStream.hs
memoryEventStream
  :: ValidatedEventStream (HsPred MemoryRegs MemoryCommand) MemoryRegs MemoryVertex MemoryCommand MemoryEvent
parseMemoryEvent :: Value -> Either Text MemoryEvent

-- kioku-core/src/Kioku/App.hs
data AppEnv = AppEnv
  { connectionSettings :: !ConnectionSettings   -- from Kiroku.Store.Connection
  , tracer             :: !Tracer
  , metrics            :: !(Maybe KeiroMetrics)
  }
runAppIO :: AppEnv -> Eff AppEffects a -> IO (Either StoreError a)

-- kioku-migrations/src/Kioku/Migrations.hs
kiokuMigrationPlan :: Either PlanError MigrationPlan
```

If any of these must change to compile, that is a finding, not a routine edit: record it in
Surprises & Discoveries, note the consumer impact in the Decision Log, and make sure the
changelog names it in Milestone 6.

At the end of Milestone 4, `kioku-core/test/Kioku/CodecCompatSpec.hs` exists and exports a
`tests :: TestTree` wired into `kioku-core/test/Main.hs` alongside the existing specs, and the
module is listed in `other-modules:` of `test-suite kioku-test`.

The external packages this plan depends on, and why each is named rather than any other:
`keiki-0.4.0.0` because `keiro-core-0.4.0.1` requires `keiki >=0.4 && <0.5`;
`keiro-0.4.0.1`/`keiro-core-0.4.0.1`/`keiro-migrations-0.4.0.1` because they are the current
releases and `0.4.0.0` was tagged but never published; `keiki-codec-json-0.4.0.0` because
Keiro 0.4 depends on it directly; `kiroku-store-0.3.1.0` because `keiro-core-0.4.0.1` bounds
it at `>=0.3 && <0.4` and there is no Kiroku 0.4; `baikai-effectful-0.3.0.2` because it is the
newest release and, despite its `0.3` version, is the one that requires `baikai ^>=0.4.0`;
`shikumi-0.3.0.1` and `shikumi-trace-0.2.0.1` because they are the bounds-only releases that
carry the Baikai 0.4 cohort; and `pg-migrate-1.1.0.0` unchanged, because it is what
`keiro-migrations-0.4.0.1` itself requires.


## Revision Notes

**2026-07-30 — added the codd disposition as Milestone 5; renumbered the release milestone to 6.**

The plan as first written covered only the cohort upgrade. Two follow-up requests arrived:
migrate Kioku to pg-migrate, and remove codd and `hasql-migration` everywhere.

Checking both against the repository showed the first was already satisfied — plan 20
completed the pg-migrate cutover, and `hasql-migration` appears nowhere in Kioku (Surprises &
Discoveries item 9). That is recorded as a Decision Log entry rather than a milestone, so a
future reader does not re-open settled work.

The second was scoped and then verified before acting, at the user's direction. Verification
found that Kioku's remaining codd surface is a one-time import bridge, and that Shikigami —
the sole real downstream consumer, since Kikan turns out not to depend on any `kioku-*`
package — still runs on codd, still Git-pins `hasql-migration`, and still pins Kioku at a
pre-pg-migrate commit (item 10). Deleting the bridge in `0.2.0.0` would strand a live database
with no forward-only route across, and migration ledgers have no unapply. Milestone 5
therefore deprecates rather than deletes, records the removal trigger where the next
contributor will find it, and names the follow-up plan's exact contents. The changelog work in
Milestone 6 grew a `### Deprecated` requirement so downstreams are told, and Concrete Steps
§5.1 re-checks the gate at implementation time in case Shikigami has crossed over by then.

**2026-07-30 — implementation of Milestones 0 through 5; Milestone 6 paused.**

Recorded the actual course of the work. Progress now reflects six completed milestones with
dates and commit hashes. Six new findings (11–16) were added to Surprises & Discoveries, three
of which are defects in this plan's own Concrete Steps rather than discoveries about the code:
§0.1 cannot reproduce the conflict it claims to because Kioku's own bounds mask it, the
`import-codd` subcommand is really called `import`, and the dependency-list comments Milestone 1
asks for are stripped by the repository's formatter. Five decisions taken during implementation
were added to the Decision Log, the largest being that the crypton fix shipped as the documented
fallback (`baikai-claude-0.4.0.1`) rather than as a metadata revision, which moves Kioku's bound
to `^>=0.4.0.1`.

Milestone 6 is deliberately untouched. The user authorised Milestones 2–5 to run unattended and
asked for an explicit stop before the version bump, tag, and Hackage publish.

**2026-07-30 — implementation of Milestone 6; the plan is complete.**

The pause was lifted and the full release ran: changelogs (`ddbf338`), the `0.2.0.0` bump across
five packages and fourteen internal bounds (`5765f98`), the `v0.2.0.0` tag, publication of all
five packages to Hackage in dependency order, and the GitHub release. The §6.3 scratch-project
check passed, which is the first time the improvement request's second acceptance criterion is
actually proven rather than approximated.

Three new findings (17–19) were recorded. One is another defect in this plan's Concrete Steps —
the release skill cannot be invoked as `/release major` because it is marked
`disable-model-invocation: true` — bringing that tally to four, every one of them a command that
was written but never run. The other two are genuinely new: Hackage rejects a documentation
tarball containing a sublibrary whose name has a colon in it, which cost one retry on
`kioku-migrations`, and a cold-cache Hackage solve can run long enough to be mistaken for a hang.
Three decisions were added to the Decision Log, including the choice to put the release scope to
the user as an explicit question rather than reading the implement invocation as blanket
authority to publish.

Outcomes & Retrospective now carries the completion status, the evidence for each of the five
acceptance criteria, and the two remaining housekeeping items — the rehearsal artifacts still on
disk, and the codd-removal follow-up plan that stays gated on Shikigami.
