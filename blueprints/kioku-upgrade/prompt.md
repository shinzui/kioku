You are upgrading a project that consumes **Kioku** — an agent memory runtime
for Haskell, built on event-sourced history — across one released version edge.

## The package set moves together

Kioku publishes five packages under **one shared version**: `kioku-api`,
`kioku-migrations`, `kioku-core`, `kioku-cli`, and `kioku-migrate`. They are
released as a set and their internal bounds are locked to each other, so a
project cannot hold `kioku-core` at one release and `kioku-migrations` at
another. An edge labelled `0.4.1.0 -> 0.5.0.0` therefore moves **every** Kioku
package this project depends on.

Because the version is shared, a release is major whenever *any* package breaks.
A project that depends only on `kioku-api` will find most edges report nothing
to do — that is a correct outcome, not a missed step.

Use `files/kioku-cohort-versions.md` to see which upstream cohort each Kioku
release pairs with.

## Kioku sits on top of other libraries

Kioku composes Keiro (event sourcing and durable workflows), which itself
composes Kiroku (the event store), Keiki (the pure functional core), and Shibuya
(message transport). Kioku also uses Baikai for model access. A breaking change
in any of them reaches this project through Kioku's version space, and most
projects on Kioku have never named those libraries directly.

You do not have to know that map. When a Kioku edge requires an upstream
library's edge, it declares that edge, and Seihou will have run it **before**
this one, under that library's own prompt and reference files. So:

- **Assume the entailed work is already done.** Do not re-apply an upstream
  edge's instructions from inside a Kioku edge, and do not "fix" a change you
  find already made — it was made deliberately, by the step before you.
- **State overlaps explicitly.** Where a Kioku edge's guidance depends on an
  upstream change having landed, it says so; if you find that it has not, stop
  and report rather than doing the upstream work yourself.

## What a Kioku project looks like

Kioku projects vary widely in which surfaces they use, and an edge often touches
only one:

- **Memory writes and lineage** — recording, superseding, merging, archiving,
  and the permission/space/actor context those writes are authorized under.
- **Recall** — targets (`ExactScope`, `NamespaceWide`), strategies, and limits.
- **Sessions and turns** — session lifecycle, resume, turn recording.
- **Distillation** — L1 extraction, L2/L3 consolidation, watermarks, and the
  timer workers that fire them.
- **Embeddings** — the embedding worker and its backfills.
- **Memory spaces** — the partition every read and write is scoped by, and the
  `kioku_legacy` space that pre-partition history lands in.
- **Event codecs** — `parseMemoryEvent` and `parseSessionEvent`, and anything
  that replays raw event JSON.
- **Migrations** — `kioku-migrate`, or an application runner that composes
  Kioku's migration plan after Keiro's and Kiroku's.
- **The CLI** — `kioku` commands, and the `KIOKU_MEMORY_SPACE` / `KIOKU_ACTOR`
  environment that decides what they read, write, and attribute.

Find which of these the project actually uses before assuming an edge's
instruction applies to it. Reporting an edge not applicable because the project
has not adopted the surface it changes is a correct, useful outcome.

## Foreign event history is the consumer's, not Kioku's

Kioku's codecs decode **Kioku's own** history. That includes Kioku's native
backwards compatibility: pre-partition payloads still land in `kioku_legacy`,
and session-resume payloads written before the `force` field still default it.
Those rules stay for as long as the durable history can exist.

What Kioku does **not** own is another application's wire format. If this
project needs to translate a foreign event language into Kioku values, that
translation belongs to this project as a finite migration tool — it may use
Kioku's domain constructors and native encoders, but the foreign tag dispatch
and identifier normalization do not live inside Kioku's parsers. See ADR-11,
`consumers-own-one-time-foreign-event-migration-codecs`.

If an edge narrows what a parser accepts, do not work around it by pattern
matching on error text or by re-encoding foreign payloads to look native. Both
produce silent data corruption. Build or recover the consumer-owned decoder, or
report that the project needs one.

## Database work stops at the runbook

Kioku owns SQL migrations, applied by `kioku-migrate` or by an application
runner that composes Kioku's plan. **You do not migrate a database that holds
real data.** Establish from read-only evidence whether this project has one and
whether an edge affects it, then report exactly what its operator must run — and
stop. A local, disposable database the project's own tooling recreates from
scratch is the exception.

This matters more for Kioku than for a library with only additive migrations.
Some Kioku releases correct the payload of an **already-released** migration,
which changes its recorded checksum and requires a one-time ledger fixup before
the next `up` or `verify`. An edge that carries one says so explicitly and names
the script. Running the fixup is the operator's decision on their own backup and
maintenance window, not yours.

## Ground rules

- **Read before you edit.** Kioku's surface is large and this project uses a
  small part of it. Find real call sites before assuming a symbol is in use.
- **A clean build is not a search.** Some changes in this cohort add
  constructors to exported sum types, and some narrow what a function *accepts*
  without changing its type at all. A narrowing of accepted input is invisible
  to the compiler — grep for the call sites and reason about the values that
  reach them.
- **Do not widen the change.** Fix what this edge names. Unrelated warnings,
  formatting, and other libraries' version bumps are out of scope.
- **Prove it with the project's own commands.** Use the build and test commands
  this repository actually defines. Report any you could not run, and why,
  rather than claiming a pass.
