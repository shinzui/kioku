---
type: Architecture Decision Record
title: The memory-space partition reaches the filesystem as a sanitised digest, not as the space id
description: >-
  Workspace artifacts are rooted at .kioku/spaces/<sanitised-prefix>-<digest>/, because a memory
  space id is validated for a database column and is not safe as a path component.
timestamp: 2026-08-06T21:30:00Z
docId: ADR-7
status: accepted
date: 2026-08-06
---

# The memory-space partition reaches the filesystem as a sanitised digest, not as the space id

## Status

Accepted, 2026-08-06. Implemented by `kioku-core/src/Kioku/Workspace.hs`,
`kioku-core/src/Kioku/Distill/L2.hs`, `kioku-core/src/Kioku/Distill/L3.hs`, and
`kioku-cli/src/Kioku/Cli/Commands/Artifacts.hs`.

## Context

Kioku mirrors every L2 scene and L3 persona to a Markdown file so a coding agent can read it
without a database. Those files were named by scope alone:

```text
.kioku/scenes/<scope-slug>.md
.kioku/persona/<scope-slug>.md
```

[ADR-6](the-partition-is-a-column-not-a-schema.md) gave the scene and persona *rows* a composite
`(memory_space_id, …)` key, precisely because their ids are derived from a namespace and a scope
that two spaces are allowed to share. The filenames are derived from the same three components and
got no such treatment, so two spaces holding one scope still wrote to one file and whichever
regenerated last won. That is the database bug ADR-6 fixed, one layer out, with no constraint to
catch it.

The obvious fix — put the space in the path — has a problem that is easy to miss.
`Kioku.Api.Access.mkMemorySpaceId` validates an identifier for a database column and a
relationship tuple: it rejects `:`, `#`, `%`, `/`, whitespace, and control characters, and nothing
else. `..` is a legal memory space id. So is `.`. A host that lets an untrusted caller name a
space could therefore name one that walks straight out of `.kioku/spaces`. And on the
case-insensitive filesystems this project is developed on, `space_A` and `space_a` are two memory
spaces and one directory.

## Decision

Workspace artifacts are rooted per space:

```text
.kioku/spaces/<space-dir>/scenes/<scope-slug>.md
.kioku/spaces/<space-dir>/persona/<scope-slug>.md
```

`<space-dir>` is **not** the space id. It is a sanitised readable prefix — every character outside
`[A-Za-z0-9_-]` mapped to `-` — followed by `-` and the first ten hex characters of a SHA-256 of
the exact space id. This is deliberately the same construction
`Kioku.Distill.ScopeIdentity.scopeSlugFromColumns` already uses for the filename, and it is the
right one for the same two reasons plus a third:

- the readable half lets a human tell the directories apart;
- the digest is what actually separates them, including two ids that differ only in case;
- mapping `.` to `-` is what makes `..` an ordinary directory name rather than traversal. No
  encoding of any space id can contain a path separator or a dot segment.

Three consequences of that layout are part of the decision rather than incidental:

**Nothing writes to the pre-partition tree.** `.kioku/scenes` and `.kioku/persona` become history
the moment this ships. `kioku migrate-artifacts` reports exactly what would move where and writes
nothing without `--apply`; it *copies* rather than moves, so a failed verification still has the
originals, and it refuses a destination whose content differs rather than replacing what the
running worker wrote with an older snapshot. Removing the old tree is the operator's decision and
is not something Kioku will do.

**Deletion is the one exception.** When every memory in a scope is forgotten, the legacy space's
historical mirror is unlinked along with the partitioned one. A merely out-of-date file is visible
in the migration plan and can wait; forgotten content surviving on disk is not out of date, it is
a retention failure, and a host agent would keep reading it.

**The memory space goes on traces and never on a metric label.** Each timer fire carries
`kioku.memory_space_id` on a `kioku.timer.fire` span, and every dead-lettered timer's `last_error`
is prefixed with the space its payload named. No instrument is labelled by the space or by a
principal, and none may be: a space id is caller-supplied text with no bound on how many distinct
values exist, so a counter keyed on it is an unbounded time series per tenant and an identity leak
into a metrics backend. Bounded outcome and reason labels are fine; identifiers are not.

## Consequences

An upgraded deployment's host agents keep reading the old paths and see files that stop being
updated. That is the cost of "new writes go to the partitioned layout only", and it is paid
deliberately: the alternative — dual-writing the legacy space forever — means the partition never
actually reaches the filesystem for the space that most needs it. The migration command exists so
the window is short and the operator can see exactly what is in it.

Filesystem isolation is now as strong as the database's, and provable the same way. A single
fixture with two spaces holding one namespace, one scope, and one derived filename shows a
regression as the wrong tenant's content in the wrong file, rather than as a subtle metadata
mismatch.

Any future artifact kind must be rooted through `Kioku.Workspace.spaceArtifactRoot` rather than
by joining a space id onto a path. That is the whole point of the module: there is one place that
knows how a memory space becomes a directory.

## Alternatives rejected

**Use the space id directly as the path component.** Rejected: `..` is a valid space id, and case
folding merges distinct spaces on macOS and Windows.

**Keep one flat directory and fold the space into the filename.** Rejected: it works, but it makes
"list this tenant's artifacts" a string-prefix scan of every tenant's files, and it puts two
independently-derived identities into one name where a mistake in either is invisible.

**Tighten `mkMemorySpaceId` to reject `.` instead.** Rejected: the constructor's job is to
validate an identifier for a column and a relationship tuple, and narrowing it for the benefit of
one consumer's filesystem would reject space ids a host's directory legitimately issues. The
encoding belongs where the path is built.

**Dual-write the legacy space to both layouts during a compatibility window.** Rejected: it leaves
the legacy space — the one every upgraded deployment is in — unpartitioned on disk for as long as
the window lasts, and windows do not close on their own.

**Label metrics by memory space.** Rejected: unbounded cardinality and identity leakage. Traces
are sampled and per-incident, which is where a caller-chosen identifier belongs.

## References

- `kioku-core/src/Kioku/Workspace.hs` — the layout, the encoding, and the migration planner
- `kioku-core/test/Kioku/WorkspaceSpec.hs` — traversal, case folding, and migration verdicts
- `kioku-core/test/Kioku/DistillSpec.hs` — one worker, two spaces, one scope, disjoint artifacts
- `docs/user/upgrading-to-memory-spaces.md` — the operator-facing ordering
- [ADR-2](namespace-is-not-a-security-boundary.md), [ADR-3](legacy-data-lands-in-one-explicit-space.md),
  [ADR-6](the-partition-is-a-column-not-a-schema.md)
