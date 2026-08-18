# Automated Baikai cohort upgrades

A release of [baikai](mori://shinzui/baikai) raises Kioku's bounds by itself:
the bump is written, built, tested, and committed without anyone being asked.
This page says how that happens, what it deliberately refuses to do, and how to
take the wheel back.

The moving parts are two Mori automation configs and three shell scripts. All
five are checked in; nothing about this lives only in someone's crontab.

## The chain

```
shinzui/baikai            shinzui/kioku
─────────────────         ─────────────────────────────────────────────
tag baikai-*        →     signal BaikaiReleased
(RefObserved)             → wait 12h, debounced
                          → scripts/baikai-bump-needed.sh   (still needed?)
                          → just upgrade-baikai             (do it, prove it)
                          → commit on master
```

`mori.automation.dhall` in baikai turns any release tag into a `BaikaiReleased`
signal aimed at Kioku. `mori.automation.dhall` here turns that signal into one
scheduled run of `just upgrade-baikai`.

## The signal is only a wake-up

The single idea this design rests on: **the signal says nothing that is trusted,
and the scripts re-derive everything from Hackage at the moment they run.**

That is not fastidiousness, it is what makes the rest of it simple:

- **A release pushes one tag per package.** Baikai 0.5.0.0 pushed seven within
  seconds. Each is a `RefObserved` event and each triggers the reaction, so the
  reaction carries `coalesceKey = "baikai-cohort-bump"` and only the last
  schedule survives. Seven triggers, one run.
- **The cohort is wider than the tags.** Kioku pins `shikumi` and
  `shikumi-trace` too, because only their newest patches carry bounds admitting
  the new baikai — an earlier patch would give the solver a way to fall back off
  the cohort. Those are separate uploads from a separate repository that emits
  no signal here. The scripts read all five packages' preferred versions from
  Hackage and do not care which tag woke them.
- **A tag is not an upload.** Tags are pushed before the Hackage upload lands.
  Anything reading the tag itself would be reading the future.

Because nothing is trusted, every awkward case collapses into "look it up
again": a duplicate trigger, a replayed event, a bump already done by hand.

## What each piece decides

| Piece | Question it answers |
|---|---|
| `mori.automation.dhall` (baikai) | Did baikai release anything at all? |
| `after = "PT12H"` | Has the rest of the cohort had time to publish? |
| `coalesceKey` | Is this the last of the tags in one release? |
| `scripts/baikai-bump-needed.sh` | Is there still anything to do, twelve hours later? |
| `scripts/upgrade-baikai.sh` | Does the new cohort actually work? |
| `scripts/baikai-cohort.sh` | What is the cohort, and what does Hackage prefer? |

The twelve-hour delay is set from observed practice, not taste: baikai 0.5.0.0
and shikumi 0.3.0.2 are both dated 2026-08-05. The sibling releases land the
same working day.

## Outcomes

`upgrade-baikai.sh` separates "nothing to do" from "something is wrong", because
an unattended job that cries wolf gets ignored.

**Exit 0, nothing committed** — ordinary, and none of these are incidents:

- every bound already names the newest release;
- the working tree is dirty, or HEAD is not `master`;
- the solver finds no install plan, because the rest of the cohort has not been
  published yet. The cabal file is restored and the run waits to be woken again.

**Exit 0, committed** — bounds moved, `cabal build all --enable-tests` passed,
all four suites passed, `kioku-core/kioku-core.cabal` and `CHANGELOG.md` are
committed to `master`.

**Exit 1** — a bump was warranted and solvable but did not survive: the build
broke, a suite failed, Hackage could not be reached, or the pre-commit hook
refused the commit. Both touched files are restored and the index is reset, so a
red run leaves the tree exactly as it found it. This one wants a human.

## What it does not do

- **It does not push.** The commit sits on local `master` for you to read.
- **It does not read upstream changelogs.** Baikai 0.5.0.0 was a breaking
  release, and the judgment that none of its four breaking changes reached Kioku
  came from a person reading them. The automation cannot do that. Its commit
  message says so outright: treat such a commit as *verified, not reviewed*.
  Kioku's suites are the only thing standing between an automated bump and a
  breaking release.
- **It does not retry a late cohort.** If shikumi publishes more than twelve
  hours after baikai, the run backs out cleanly and nothing re-arms it. The next
  baikai release picks it up — or run `just upgrade-baikai` by hand.
- **It does not read the signal payload.** Not by preference: Mori's
  `buildContext` covers `ChangesetObserved`, `RefObserved`, and
  `WorkflowSignalReceived`, while a signal-triggered reaction is triggered by
  `SignalDeliverySucceeded` and falls through to the empty context. A
  `{{meta.tag}}` in the consumer's action reaches the command as those literal
  characters. The sibling `keiro`→`keiro-syntax` automation does exactly that
  and has failed on every run since it was written; this config carries an empty
  `env` and a comment saying why, so nobody helpfully adds one back.

## The environment it runs in

Mori wraps every `RunCommand` in `nix develop --command` with the working
directory set to the repo root, so the reaction gets this project's devShell.
The consequence worth writing down: **anything the scripts call must be in the
devShell**, because the daemon runs under launchd with a PATH of just
`/usr/bin:/bin:/usr/sbin:/sbin`.

`git` is in `flake.module.nix` for exactly this reason. macOS's `/usr/bin/git`
is an Xcode Command Line Tools shim: it is present, `command -v` finds it, and
it fails to execute inside `nix develop` with `error: tool 'git' not found`. An
interactive shell hides this. The first end-to-end run of this automation did
not — every git call failed, and the branch check read an empty string and
declined to do anything. Check that a tool *runs*, not that it resolves.

The rest — `curl`, `jq`, `just`, `cabal`, `awk`, `sed`, `pg_ctl` — was verified
to execute under that same stripped environment.

## Operating it

```bash
just upgrade-baikai                  # run the whole thing by hand, now
./scripts/baikai-bump-needed.sh      # just the question: is a bump warranted?

mori reaction scheduled list         # what is pending, and when it will run
mori reaction cancel <id>            # call off a pending run
mori reaction list                   # what has fired, and how it went
mori automate explain <position>     # why a given event did or did not match
mori automate list                   # confirm both configs are registered
```

After editing either `mori.automation.dhall`, push the change to the daemon —
it reads the registration, not the file on disk:

```bash
mori automate update --path .
mori automate update --path "$(mori path mori://shinzui/baikai)"
```

Use `update`, not `register`. `register` is create-only: run against an
already-registered repo it prints `already registered`, reports the *new* hash
in its output, and leaves the *old* config in place — so the daemon quietly goes
on running the version you thought you had just replaced. Confirm with
`mori automate list` that the hash it shows is the one you meant.

## Adding a package to the cohort

Edit `COHORT_PACKAGES` in `scripts/baikai-cohort.sh`. It must be a package Kioku
pins with a `^>=` bound in `kioku-core/kioku-core.cabal`; everything else —
detection, rewriting, the changelog entry, the commit message — follows from
that list.
