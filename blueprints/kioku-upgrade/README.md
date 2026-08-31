# kioku-upgrade

> Agent-guided upgrade guidance for projects consuming Kioku, published as one
> edge per released version window that needs judgement work. The Keiro cohort
> edge is **entailed**, so a project that depends only on Kioku — and has never
> named Keiro — still crosses Keiro's edge, exactly once, in the right order.

**Version:** `0.1.0`

**Kind:** Blueprint migration (run with `seihou agent migrate`, not
`seihou agent run` — this blueprint declares no baseline and applies no modules)

## For consumers

Bump the Kioku dependency first, then migrate the source up to it:

```sh
seihou install https://github.com/shinzui/kioku.git  --module kioku-upgrade
seihou install https://github.com/shinzui/keiro.git  --module keiro-upgrade
seihou install https://github.com/shinzui/kiroku.git --module kiroku-upgrade

seihou agent --debug migrate kioku-upgrade --from 0.4.1.0   # preview
seihou agent migrate kioku-upgrade --from 0.4.1.0           # run
```

`--to` is inferred from the [version probe](#version-probe); `--from` is
inferred from your recorded receipts after the first run. The entailed
`keiro-upgrade` blueprint **must be installed** — a run that cannot resolve it
refuses rather than silently skipping a cohort member, because a half-migrated
project with no signal is worse than a stopped one. Install `kiroku-upgrade`
too: Keiro's own edges entail Kiroku's, and the chain is resolved at run time.

Start from a clean working tree. Agent edits are not transactional and Seihou
cannot roll them back; version control is the undo.

### This blueprint does not migrate your database

Two things in the 0.5.0.0 edge are operator actions, not source edits: the
one-time ledger re-baseline for the corrected `0011` payload, and applying the
composed plan itself. The edge establishes from read-only evidence whether they
apply to this project and reports the exact runbook — it stops there, by design.

A receipt records that a provider interaction returned, not that a database was
remediated. For a database holding production data, use the `cohort-migrate`
skill, which proves the remediation on a restored clone before production is
touched.

## Declared edges

| From | To | Entails |
|---|---|---|
| `0.4.1.0` | `0.5.0.0` | `keiro-upgrade` `0.13.0.0 -> 0.14.0.0` |
| `0.5.1.0` | `0.5.2.0` | `keiro-upgrade` `0.14.0.0 -> 0.15.0.0` |

Gaps between edges are deliberate and legal: they mean no agent intervention was
needed in that interval. `0.4.0.0 -> 0.4.1.0` is exactly such a gap — that
release was a bounds-only move onto the Baikai 0.5 cohort with no source change,
so a project coming from 0.4.0.0 crosses this edge and nothing else.
`0.5.0.0 -> 0.5.1.0` is another: the Baikai 0.6 move changed Kioku's internals
but nothing a consumer names.

Note what the `0.5.1.0 -> 0.5.2.0` edge shows: **a bounds-only Kioku release can
still need an edge.** Kioku itself requires nothing across that window, but
taking it drags a project onto Keiro 0.15.0.0, whose `keiro-dsl` record API
broke. A project depending on both Kioku and `keiro-dsl` would otherwise meet
that break as an unexplained compile error. The test for declaring an edge is
not "did Kioku change" but "does taking this release force a project onto an
upstream change" — which is what `entails` is for.

Edges are append-only — an edge stays correct for as long as the release it
describes exists, which is why this blueprint does not go stale the way a single
"migrate to the current cohort" document does.

Earlier edges may be added retroactively. `0.3.0.0 -> 0.4.0.0` is a real
candidate: it carried the projection relocation into the `kioku` schema, the
`RecallTarget` split, memory spaces, and the breaking `kioku recall --scope`
change. It is not declared here because this blueprint was introduced with
0.5.0.0 and an edge should be written from the evidence of the release it
describes, not reconstructed. Write it if a project on 0.3.0.0 needs it.

## Version probe

```
jq -r '."install-plan"[] | select(."pkg-name"|startswith("kioku-")) | ."pkg-version"' \
  dist-newstyle/cache/plan.json 2>/dev/null | sort -u | tail -1 | grep .
```

Read-only, fast, and honest: it reports the version this project's **build plan**
actually resolved, not a bound. It matches any `kioku-*` package because all five
share one version, so it works whether a project declares `kioku-core`,
`kioku-api` alone, or the whole set.

It requires a configured Cabal build — a project that has not run
`cabal build`/`configure`, or that has no `jq`, gets a warning and is asked for
`--to`. That is the intended degradation. A probe that guessed would be worse
than none, because a window off by one release runs the wrong edges against real
source.

## Reference files

Mounted read-only for every edge of this blueprint:

- `files/kioku-cohort-versions.md` — which upstream cohort each Kioku release
  pairs with, how to read what a project actually resolved, the composed
  migration plan's shape per release, and which releases require a ledger fixup.

## For maintainers

**Add an edge in the same change that cuts a release**, or this blueprint rots.
The release skill (`agents/skills/release/SKILL.md`) should carry this as a
step.

Kioku's five packages share one version, so a breaking change anywhere majors
everything. Most edges will therefore be "not applicable" for most projects —
write the precondition so that outcome is reached cheaply and honestly, rather
than after a project-wide search.

### Two Kioku-specific hazards to write for

**A narrowing of accepted input is invisible to the compiler.** The 0.5.0.0
Rei retirement changed no type — `parseMemoryEvent` is still
`Value -> Either Text Event` — but values that used to decode now return `Left`.
An edge describing this kind of change must tell the agent what to grep for,
because there is no build error to follow. Never let such an edge rest on "the
build passes."

**A corrected migration payload is not an additive migration.** When a release
changes the bytes of an already-released migration, every database that applied
the old bytes needs a one-time ledger re-baseline before its next `up` or
`verify`. Ship the script under `kioku-migrations/ledger-fixups/`, keep it in
`extra-source-files` so Hackage consumers get it, and have the edge **name the
script and stop**. Running it is the operator's decision on their own backup and
maintenance window.

### Entailment rules that are not visible from the field's type

When a release absorbs an upstream breaking change, declare the exact upstream
edge in `entails` rather than copying that library's guidance into this
repository.

- Entailed edges run **first**, and several run in declaration order.
- Expansion is **recursive**; a cycle is an authoring error. Kioku's chain is
  two links deep in practice — Kioku entails Keiro, and Keiro's own edges may
  entail Kiroku.
- The reference is to **one exact edge**, matched on both `from` and `to`.
  Seihou will not window-plan inside the entailed blueprint, because that would
  let a Kioku release silently change which upstream work it implies.
- The receipt is filed under the **entailed** blueprint's identity, which is
  what makes a shared edge crossed once from either entry point. A project that
  depends on both Kioku and Keiro directly crosses Keiro's `0.13 -> 0.14` once,
  whichever command it runs.
- The entailed blueprint's own `launch` declaration is ignored; provider, model,
  and effort stay a property of the command.

Write each edge's precondition explicitly. One blueprint serves projects in very
different states, and an edge that does not apply is a normal result — Seihou
records it as *not applicable* and plans it again later, rather than marking it
done. Never tell an edge to exit nonzero when it does not apply: that reports a
provider failure and halts every remaining edge.

Validate before publishing:

```sh
seihou validate-blueprint blueprints/kioku-upgrade
```

Validation checks everything resolvable without a filesystem search. Whether the
entailed blueprint exists and declares the named edge is resolved by
`seihou agent migrate`, so preview a real chain before shipping an edge that
entails one:

```sh
seihou agent --debug migrate kioku-upgrade --from 0.4.1.0 --to 0.5.0.0
```
