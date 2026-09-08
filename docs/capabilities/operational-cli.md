---
title: "Operational CLI for recall, distillation, and workers"
type: Capability
description: "Drive a Kioku database from the terminal — recall against any of the three targets, run or force a distillation pass, print scenes and personas, run the supervised worker, and relocate artifacts — with permanent writes gated behind an explicit opt-in and ambiguous scope input refused rather than reinterpreted."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-15
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-cli
interface:
  - kioku
  - Kioku.Cli
requires:
  - CAP-5
  - CAP-10
  - CAP-11
evidence:
  - kind: test
    resource: kioku-cli/test/Kioku/Cli/ParserSpec.hs
    proves: "Scope strings split on the first two colons only so URL and host:port refs survive, empty components are rejected, and an id of the wrong prefix is refused naming both prefixes."
  - kind: test
    resource: kioku-cli/test/Kioku/Cli/RecallEndToEndSpec.hs
    proves: "Each target flag reaches the database as its own target inside one memory space, an explicit AI file overrides the environment, and credentials alone do not enable AI."
  - kind: guide
    resource: docs/user/cli-reference.md
    proves: "Every command and flag, the runtime environment variables, and the exit behaviour of each mode."
  - kind: guide
    resource: docs/user/getting-started.md
    proves: "A working first memory in under five minutes, from database setup to a keyword recall."
---

# Operational CLI for recall, distillation, and workers

`kioku` is the runtime CLI: `demo`, `demo-session`, `recall`, `distill session`, `scenes`,
`persona`, `worker` (with `--backfill`, `--timers-once`, and the `deferred` subcommands),
and [`migrate-artifacts` (CAP-11)](workspace-artifact-mirroring.md). `kioku-migrate` is the
separate schema executable described in
[the migration component (CAP-13)](embedded-migration-component.md).

The CLI is the reference trusted-in-process host: it mints its access context with
`assumeAuthorizedMemoryContext` from two environment values — `KIOKU_MEMORY_SPACE`
(default `kioku_legacy`) and `KIOKU_ACTOR` (default `kioku_cli`) — and a malformed value
is a **startup error, not a silent fallback**, because a typo in a space name must not
quietly send writes somewhere else or hide the rows a read was meant to return.

Two design choices are worth stating because they are what the tests pin:

- **Permanent writes are opted into.** The event log has no delete, so `demo` and
  `demo-session` require `--yes-write-events`; without it the command is a parse error
  and the environment is not even read. Both print the target connection string with the
  password redacted before writing, and the demo writes only into the isolated
  `kioku_demo` namespace.
- **Ambiguity is refused, not reinterpreted.** `--scope mori` used to mean namespace-wide
  to `recall` and the global bucket to `scenes` — the same text, the opposite meaning. It
  is now a parse error that names both replacements, `--global-bucket` and
  `--namespace-wide`, per [recall targets (CAP-5)](hybrid-recall-with-explicit-targets.md).
  Every recall run announces what it searched on stderr, so a widening is visible in a
  terminal while a script reading stdout sees the lines it always saw.

Mutually exclusive worker modes are parse errors rather than a silent winner, and the
continuous worker exits `1` with a reason when either pipeline stops, so a supervisor
restarts it instead of leaving a process that looks alive with half its work dead.

## Shape

```bash
export PG_CONNECTION_STRING='host=localhost dbname=kioku user=me'
kioku demo --yes-write-events
kioku recall "concise answers" --scope kioku_demo:demo:demo --strategy keyword
kioku worker
```

## Limits

- The CLI is a trusted in-process host. It performs no authentication and grants itself
  every permission on the configured space; a multi-tenant deployment authorizes through
  [the access context (CAP-4)](memory-space-isolation.md) in its own service instead.
- `kioku recall`, `kioku scenes`, and `kioku persona` return nothing outside
  `KIOKU_MEMORY_SPACE`. The worker is deliberately not pinned to one space: it claims
  timers for whatever space they were scheduled in.
- The CLI exposes no vector-channel starvation signal; that is a library affordance —
  see [CAP-6](starvation-resistant-vector-recall.md).
- `--candidates` and `--limit` on `distill session` govern the CLI only; the production
  timer path uses its own fixed settings, per
  [timer-driven distillation (CAP-10)](distillation-timers.md).
