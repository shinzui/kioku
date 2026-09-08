---
title: "Workspace mirroring of scenes and personas, with a refusing artifact migration"
type: Capability
description: "Mirror each scope's scene and persona to plain markdown under a per-space directory a coding agent can read without a database, and relocate the pre-partition tree with a dry-run-first command that copies, reports, and refuses to overwrite differing content."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-11
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kioku-core
  - kioku-cli
interface:
  - Kioku.Workspace
  - Kioku.Distill.L2
  - Kioku.Distill.L3
requires:
  - CAP-3
  - CAP-4
  - CAP-9
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/WorkspaceSpec.hs
    proves: "Two spaces never share an artifact root, no space id can escape .kioku/spaces, the historical tree is planned and copied and left in place, a second run is a no-op, and a stale plan cannot clobber a late differing destination but accepts an identical one."
  - kind: test
    resource: kioku-core/test/Kioku/DistillSpec.hs
    proves: "One worker serving two spaces keeps their mirrors disjoint, and an emptied scope deletes its mirror files along with its rows."
  - kind: guide
    resource: docs/user/distillation.md
    proves: "The mirror layout, how the slug and space directory are derived, why the files land in the worker's working directory, and that mirroring is best-effort."
  - kind: guide
    resource: docs/user/cli-reference.md
    proves: "The three verdicts kioku migrate-artifacts reports, its dry-run default, and its non-zero exit on a collision."
---

# Workspace mirroring of scenes and personas

Scenes and personas are written to the filesystem as plain markdown as well as to the
database, so a coding agent — or a person — can read them without issuing a query:

```text
.kioku/spaces/<space-dir>/scenes/<slug>.md
.kioku/spaces/<space-dir>/persona/<slug>.md
```

Both path components are derived, never taken literally. The slug is a readable
`namespace-kind-ref` prefix followed by ten hex characters of a SHA-256 of the scope's
true identity, because the readable prefix alone is not collision-free — see
[scope identity (CAP-3)](host-agnostic-memory-scopes.md). The space directory is built
the same way from [the memory space id (CAP-4)](memory-space-isolation.md), and for one more
reason: a `MemorySpaceId` is
validated for a database column rather than for a path, so `..` is a legal id, and
sanitising every character outside `A-Za-z0-9_-` is what makes it an ordinary directory
name instead of traversal. Two spaces holding the same scope get the same filename in
different directories.

`kioku migrate-artifacts` relocates the pre-partition tree, which was keyed by scope
alone so two spaces wrote to one file. It is a **dry run by default**, printing every
file, its destination, and one of three verdicts: `copy`, `migrated` (byte-identical
destination, which is what makes a second run a no-op), or `COLLISION` — different
content at the destination, refused and never overwritten, because the partitioned file
is what the running worker writes and the historical one is older. Any collision exits
non-zero, in dry run as well as under `--apply`. `--apply` revalidates each copy
atomically, staging complete copies under a hidden prefix before publication, and never
deletes the originals.

## Shape

```bash
kioku migrate-artifacts                                    # dry run
kioku migrate-artifacts --apply
KIOKU_MEMORY_SPACE=space_prod kioku migrate-artifacts --workspace /srv/agent --apply
```

## Limits

- Mirroring is **best-effort**. An unwritable workspace does not fail distillation; the
  database remains the source of truth and the mirror is a convenience cache.
- Files land in the working directory of the process that regenerates them — in practice
  wherever `kioku worker` was started. Run the worker from the workspace you want
  mirrored.
- `migrate-artifacts` copies; removing the old tree afterwards is the operator's
  decision, and this command deletes nothing.
- Do not construct mirror filenames by hand. Derive them from
  [the scene and persona helpers (CAP-9)](scenes-and-personas.md), or list the directory.
