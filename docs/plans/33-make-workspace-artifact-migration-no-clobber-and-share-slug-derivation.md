---
id: 33
slug: make-workspace-artifact-migration-no-clobber-and-share-slug-derivation
title: "Make workspace artifact migration no-clobber and share slug derivation"
kind: exec-plan
created_at: 2026-08-20T13:57:30Z
intention: "intention_01m0fpyzp4e2kbnhyvcm00zd9t"
master_plan: "docs/masterplans/7-remediate-the-kioku-0-3-0-0-to-0-4-0-0-release-range-review.md"
---

# Make workspace artifact migration no-clobber and share slug derivation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

An operator can dry-run `kioku migrate-artifacts`, leave workers running, and apply the recorded
plan without risking replacement of a scene or persona written in the meantime. A stale plan
either recognizes an identical destination as already migrated or fails visibly while preserving
the newer destination byte for byte. The workspace directory and scope filename encodings also
share one sanitise-plus-digest implementation, so the path-traversal defense cannot drift between
them.

The behavior is demonstrated by a regression that plans a `MoveReady`, creates the destination as
a worker would, then applies the stale plan and observes both a refusal and unchanged live
content. Existing traversal, case-folding, collision, copy, and idempotence tests remain green.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-21 17:08Z) Add the shared `slugWithDigest` primitive and make scope and workspace
  slugs consume it. Focused Workspace (10 tests) and Scope identity (7 tests) patterns pass.
- [x] (2026-08-21 17:11Z) Replace `copyFile` with an atomic no-replace publication path and
  handle a stale plan.
- [x] (2026-08-21 17:11Z) Add deterministic stale-plan, idempotence, permission, cleanup, and
  shared-slug regression tests. The focused Workspace pattern passes all 13 tests.
- [x] (2026-08-21 17:14Z) Update package metadata, changelog, and operator/library
  documentation; run the full affected suites. `kioku-core` passes all 215 tests and `kioku-cli`
  passes all 50 tests after both packages build successfully.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Publish a fully written temporary file with a same-directory hard link instead of
  checking and then calling `copyFile`.
  Rationale: a second existence check still has a race before `copyFile`, while POSIX hard-link
  creation fails atomically if the destination exists. Writing the temporary file first also
  avoids exposing a partial destination if the process fails mid-copy.
  Date: 2026-08-20

- Decision: Put `slugWithDigest` in `Kioku.Distill.ScopeIdentity` with separate readable and
  identity inputs.
  Rationale: a scope's human-readable prefix and injective identity are different strings, while
  a memory space uses the same text for both. A two-input primitive covers both without changing
  either persisted recipe.
  Date: 2026-08-20

- Decision: Compare artifact contents byte for byte in `Kioku.Workspace` instead of comparing
  SHA-256 digests.
  Rationale: moving the persisted slug digest into `slugWithDigest` leaves `Kioku.Workspace`
  independent of cryptographic implementation details, and exact equality is stronger than a
  digest comparison for classifying migration collisions.
  Date: 2026-08-21


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Completed on 2026-08-21. `slugWithDigest` now owns the persisted sanitise-plus-digest recipe used
by both scope mirror filenames and memory-space directories, with regression fixtures proving
the old bytes did not change. Artifact apply now stages complete bytes in the destination
directory, applies the source mode, and publishes with an atomic no-replace hard link. A late
byte-identical destination is idempotent; a late differing destination produces a named
`IOException` while both the live file and historical source remain unchanged.

`nix fmt`, `cabal build kioku-core kioku-cli`, the 215-test `kioku-core` suite, the 50-test
`kioku-cli` suite, and `git diff --check` all pass. The existing pgvector-dependent skips remain
environmental and Cabal reports both suites PASS. The completion distillation found no new ADR
to write: [the filesystem partition ADR](../adr/the-partition-reaches-the-filesystem-as-a-digest.md)
already owns the durable encoding and no-overwrite policy, while the temporary-file and hard-link
mechanics are replaceable implementation details.


## Context and Orientation

Kioku mirrors generated L2 scenes and L3 personas into a workspace. Current files live below
`.kioku/spaces/<space-dir>/{scenes,persona}/`; the old `.kioku/scenes` and `.kioku/persona`
trees are read only by the migration command. `kioku-core/src/Kioku/Workspace.hs` computes
`spaceDirectoryName`, plans each historical file as `MoveReady`, `MoveAlreadyMigrated`, or
`MoveCollision`, and applies every `MoveReady` with `System.Directory.copyFile`.

Planning and applying are separate operations. `planArtifactMigration` checks whether the
destination exists, then `applyArtifactMigration` later trusts the verdict. If a live worker
writes the destination between those calls, `copyFile` replaces it. A time-of-check/time-of-use
race means the state checked is not necessarily the state used.

`kioku-core/src/Kioku/Distill/ScopeIdentity.hs` computes `scopeSlugFromColumns` by sanitizing a
readable prefix and appending ten hexadecimal SHA-256 characters of the injective scope identity.
`Workspace.spaceDirectoryName` independently repeats the same sanitizer, safe-character table,
hash conversion, and truncation. Both recipes are persisted path identities and their output must
remain byte-for-byte stable.

`kioku-core/test/Kioku/WorkspaceSpec.hs` already proves empty migration, copy-with-source-retained,
second-run idempotence, plan-time collision refusal, ignored non-Markdown files, traversal
resistance, and case distinction. `kioku-core/test/Kioku/ScopeIdentitySpec.hs` proves scope-slug
collision resistance. `kioku-cli/src/Kioku/Cli/Commands/Artifacts.hs` prints the plan, applies it
only with `--apply`, and exits nonzero for collisions found at plan time.

[The filesystem partition ADR](../adr/the-partition-reaches-the-filesystem-as-a-digest.md) is
binding: no path may contain a raw space id, the output recipe stays sanitized prefix plus digest,
historical files are copied rather than moved, and a differing destination is refused rather than
overwritten. No other local ADR changes this work. Mori has no registered `unix` project, so its
lookup could not supply source. The authoritative Hackage index and upstream `v2.8.8.0` tag match
the compiler's installed `unix-2.8.8.0`; use the upstream `System.Posix.Files.createLink` API and
bound the direct dependency to the 2.8 series supported by this GHC 9.12.4 workspace.


## Plan of Work

### Milestone 1 — One persisted slug recipe

In `kioku-core/src/Kioku/Distill/ScopeIdentity.hs`, export
`slugWithDigest :: Text -> Text -> Text`. The first argument is the readable prefix to sanitize;
the second is the exact identity to hash. Move `sanitizeSlug`, the safe-character predicate, and
the ten-character SHA-256 rendering behind this function. Rewrite `scopeSlugFromColumns` to call
it with the existing readable text and `scopeIdentityFromColumns` identity.

In `kioku-core/src/Kioku/Workspace.hs`, remove its local crypto imports, sanitizer, and
safe-character predicate. Implement `spaceDirectoryName` as `slugWithDigest raw raw`, where `raw`
is `memorySpaceIdText space`. Extend `ScopeIdentitySpec` and `WorkspaceSpec` to prove the helper is
the common implementation and that all existing expected properties remain. Do not change the
digest length, case, character map, or scope identity input. Acceptance is byte stability for the
existing fixtures plus no duplicate sanitizer in `Workspace.hs`.

### Milestone 2 — Atomic no-clobber apply

Add `unix >=2.8.8 && <2.9` to the `kioku-core` library's direct dependencies in
`kioku-core/kioku-core.cabal`. In `Kioku.Workspace`, add a private copy helper that reads the
historical source, writes the complete bytes to a uniquely named temporary file in the
destination directory, closes it, copies the source's file permissions onto the temporary inode,
and calls `System.Posix.Files.createLink temporary destination`. Because temporary and destination
are in the same directory, publication is atomic and cannot cross filesystems. Always remove the
temporary name afterward. If the link reports that the destination already exists, compare source
and destination: identical content is an idempotent success; different content raises an
`IOException` whose message names the refused destination. Propagate all other I/O errors. Never
unlink, truncate, rename over, or chmod the destination after publication.

Make `applyArtifactMigration` use this helper for every original `MoveReady`. A verdict that was
already `MoveAlreadyMigrated` or `MoveCollision` remains untouched. Add two deterministic tests:
plan a ready move, create a different destination, apply and assert the exception plus preserved
bytes; then repeat with an identical destination and assert success. These tests require no
thread timing because creating the destination after planning is the exact race window.

### Milestone 3 — Public behavior and full verification

Update `kioku-core/CHANGELOG.md`, `docs/user/library-api.md`,
`docs/user/upgrading-to-memory-spaces.md`, and the `migrate-artifacts` section of
`docs/user/cli-reference.md`. State that `--apply` revalidates publication atomically, treats an
identical late destination as migrated, and exits nonzero without replacement for a differing
late destination. Keep the command a copy, not a move. Format and run the core and CLI tests. The
observable acceptance is that the stale-plan test fails against the old `copyFile` implementation
and passes with the live destination unchanged.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/kioku`.

Confirm the dependency source and currently selected release before editing bounds:

```bash
mori registry search unix
ghc-pkg latest unix
cabal info unix
git ls-remote --tags https://github.com/haskell/unix.git | rg 'v2\.8\.8\.0'
```

The first command currently finds no `unix` package project. The remaining evidence should name
`unix-2.8.8.0` and upstream tag `v2.8.8.0`; if they no longer agree, inspect the authoritative
release before choosing the bound rather than copying this plan's observation.

After editing, format and run focused tests:

```bash
nix fmt
cabal test kioku-core:kioku-test --test-options='-p Workspace'
cabal test kioku-core:kioku-test --test-options='-p "Scope identity"'
```

Expected focused output ends with:

```text
All 1 tests passed
```

Tasty's pattern may select a group containing several cases; the important result is zero
failures. Then run the complete affected suites and package build:

```bash
cabal build kioku-core kioku-cli
cabal test kioku-core:kioku-test kioku-cli:kioku-cli-test
git diff --check
```


## Validation and Acceptance

Acceptance requires all of the following behavior.

`WorkspaceSpec` first writes a historical source, calls `planArtifactMigration`, and observes
`MoveReady`. It then creates the destination with different live content and calls
`applyArtifactMigration`. The call fails, the destination still contains the live content, and
the historical source still exists. Repeating with byte-identical late content succeeds and a
fresh plan reports `MoveAlreadyMigrated`.

Existing migration tests continue to prove ordinary copy, copy-not-move, dry-run collision, and
second-run idempotence. Traversal and case-folding fixtures produce the same directory names as
before. Scope slug fixtures produce the same persistent filenames as before. An ordinary copied
artifact retains the source's permissions.

The library and CLI suites pass, documentation no longer claims only plan-time refusal, and
`kioku-core/kioku-core.cabal` carries a direct bounded `unix` dependency rather than relying on a
transitive boot package.


## Idempotence and Recovery

Applying the same migration repeatedly is safe. A completed destination compares identical and
does no further write. A differing destination is never modified. The historical source remains
available for operator recovery.

Temporary files must be removed on normal success and every caught exception. A process killed
between temporary-file creation and cleanup may leave a hidden temporary sibling; it cannot
replace or masquerade as the canonical destination. Document the prefix so an operator can
identify and remove such debris after verifying no migration process is running. If hard-link
creation is unsupported by the destination filesystem, the command fails before publishing;
retain the historical source and run on a supported local filesystem rather than falling back to
replacement-prone `copyFile`.


## Interfaces and Dependencies

`Kioku.Distill.ScopeIdentity` exports:

```haskell
slugWithDigest :: Text -> Text -> Text
```

`scopeSlugFromColumns` and `Kioku.Workspace.spaceDirectoryName` retain their existing public
signatures and output. `planArtifactMigration` and `applyArtifactMigration` also retain their
signatures; late collision is reported through `IOException`, which fits the existing `IO ()`
contract and makes the CLI exit nonzero.

The only new library dependency is `unix >=2.8.8 && <2.9`, used for
`System.Posix.Files.createLink`. Continue using `bytestring` for exact content reads,
`directory` for directory and cleanup operations, and `base` for temporary-file handles and I/O
error classification. No database or network service is involved.
