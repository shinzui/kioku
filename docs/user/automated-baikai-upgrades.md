# Automated Baikai cohort upgrades

Kioku declares a Mori reaction for release signals from
[Baikai](mori://shinzui/baikai) and [Shikumi](mori://shinzui/shikumi). The action is
`just upgrade-baikai`, implemented by the checked-in shell scripts. This is a maintainer
workflow; it updates dependency bounds and can commit on local `master`.

## Current limits

The retained scripts predate the current Cabal layout and AI cohort. In Kioku 0.12.0.0:

- `scripts/baikai-cohort.sh` expects leading-comma `^>=` dependency lines. Current Cabal files
  use trailing commas, and `baikai` uses a range (`>=0.7.0.0 && <0.9`). Its `cabal_bound` helper
  therefore cannot read the current bounds and cohort discovery fails closed.
- The script lists five packages: `baikai`, `baikai-claude`, `baikai-effectful`, `shikumi`, and
  `shikumi-trace`. It does not include the required `baikai-openai` package or update the CLI's
  direct Baikai bound.
- `mori.automation.dhall` declares a twelve-hour delay, shared coalescing key, and idempotency
  check. Its recorded signal-router limitation says those schedule fields were bypassed; see
  `mori://shinzui/mori/okf/improvement-requests/concepts/IR-22`. Check the deployed Mori router
  before relying on delay or coalescing. The action repeats branch and clean-tree guards itself.

Until the parser and complete-cohort handling are updated, use the manual dependency workflow:
locate upstream source/docs with Mori, verify Hackage releases and upstream tags, review changes,
update all affected library/CLI/test bounds together, and build/test before committing.
Do not interpret an automation skip as evidence that dependencies are current.

## Declared signal chain

```text
BaikaiReleased  ─┐
                ├─ upgrade-baikai-cohort ─ just upgrade-baikai ─ local commit
ShikumiReleased ─┘
```

The local `mori.automation.dhall` selects signals from `mori://shinzui/baikai` and
`mori://shinzui/shikumi`. Both feed the same reaction and declared coalescing key,
`baikai-cohort-bump`. The Shikumi leg lets a later compatibility release wake the reaction
again after an earlier solver refusal.

The signal is a wake-up, not version evidence. `scripts/baikai-cohort.sh` reads each listed
package's preferred version from Hackage at execution time. A tag can precede an upload;
a partially published cohort may not solve yet.

## Scripts and outcomes

| File | Role |
|---|---|
| `mori.automation.dhall` | Signal selectors, action, and declared scheduling policy. |
| `scripts/baikai-bump-needed.sh` | Read-only branch, clean-tree, and cohort-advance check. Exit 0 means an upgrade is warranted; nonzero means skip. |
| `scripts/baikai-cohort.sh` | Shared package list, Hackage lookup, bound parsing and rewriting. |
| `scripts/upgrade-baikai.sh` | Recheck guards, rewrite bounds, solve, build, migrate the development database, test, and commit. |

The action's outcomes are:

- **Exit 0, no commit:** wrong branch, dirty tree, no newer cohort, or an unsolved partial cohort.
- **Exit 0, commit:** the bounds changed and the build plus all four suites passed; only the
  Core Cabal file and root changelog are committed.
- **Exit 1:** cohort discovery/network failure, build/test failure, or commit refusal.
  After rewriting, failures restore the two edited files and reset the index. The initial
  clean-tree guard is essential to that cleanup contract.

The action runs `cabal build all --enable-tests`, starts the development PostgreSQL instance if
needed, applies migrations through `just create-database`, then runs `cabal test all`.
Source-file cleanup does not undo database migrations or stop PostgreSQL. Use this workflow
only against its intended development database.

It does not push, publish packages, or review upstream breaking changes. A successful test run
supports a dependency bump; it does not replace review of exposed upstream APIs or database work.

## Operating the reaction

```bash
mori reaction scheduled list
mori reaction list
mori automate list
mori automate explain <position>
mori reaction cancel <id>
```

To inspect the current bound-parser limitation without a network lookup or mutation:

```bash
bash -c 'source scripts/baikai-cohort.sh; cabal_bound baikai'
```

An empty result is a parser failure, not an absent release. Once the limits above are repaired,
`./scripts/baikai-bump-needed.sh` checks for an advance and `just upgrade-baikai` runs the action.
The action requires a clean `master` and can commit; it leaves the commit local for review.

After changing the local automation config, update Mori's registered copy:

```bash
mori automate update --path .
```

Use `mori automate list` to confirm the registered configuration. To modify upstream signal
producers, locate their owning repositories with `mori path` and follow their own workflow.

## Extending the cohort

Update the package list, bound parser/rewriter, touched-file inventory, and verification as one
change. Support the actual Cabal syntax and ranges, including the CLI's direct dependency and
`baikai-openai`; adding a name to `COHORT_PACKAGES` alone is insufficient. Preserve the rule that
an unreadable bound or failed Hackage lookup prevents a mutation.
