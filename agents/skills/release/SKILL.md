---
name: release
description: Release all kioku packages to Hackage following PVP
argument-hint: "[major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# kioku Release Skill

Release every kioku package to Hackage under a single shared version.

## Versioning Strategy

All five packages share the **same version number** and are released together. A single annotated git tag `v<version>` marks each release, and one GitHub release is cut per tag.

The Haskell PVP version format is `A.B.C.D`:

- `A.B` — **major**: breaking API changes (removed/renamed exports, changed types, changed semantics)
- `C` — **minor**: backwards-compatible API additions (new exports, new modules, new instances)
- `D` — **patch**: bug fixes, docs, internal-only changes, performance improvements

## Packages (in dependency order)

Publish in this order. Later packages depend on earlier ones, so an upstream failure blocks everything downstream.

1. **`kioku-api/`** — wire types, identifiers, prelude. No internal deps.
2. **`kioku-migrations/`** — pg-migrate component + `test-support` library. No internal deps.
3. **`kioku-core/`** — memory/session/recall/distillation runtime. Library depends on `kioku-api`; its test-suite depends on `kioku-migrations:test-support`, which is why `kioku-migrations` must be on Hackage first.
4. **`kioku-cli/`** — library + `kioku` executable. Depends on `kioku-api`, `kioku-core`.
5. **`kioku-migrate/`** — `kioku-migrate` executable, the migration entry point. Depends on `kioku-core`, `kioku-migrations`.

`kioku-cli` and `kioku-migrate` do not depend on each other; either may go last.

**Everything in `cabal.project` is released.** There are no example, benchmark, or test-only packages to exclude. If a new package is added to `cabal.project`, ask the user whether it is publishable before assuming.

## Arguments

`$ARGUMENTS` is optional:

- `major`, `minor`, or `patch` — forces the bump level.
- If omitted, derive the bump level from the changes (step 3).

## Steps

### 1. Pre-flight: Hackage packaging requirements

Run this **first**, before touching versions. These gaps exist in the repo today and `cabal check` will reject or warn on upload. Fix any that are still outstanding; skip the ones already done.

**a. LICENSE files.** Every cabal declares `license: BSD-3-Clause`, but no `LICENSE` file exists. For each package directory, ensure a BSD-3-Clause `LICENSE` file is present (copyright `2026 Nadeem Bitar`) and that the cabal file has:

```cabal
license-file:  LICENSE
```

**b. Repository metadata.** Each cabal should carry:

```cabal
homepage:      https://github.com/shinzui/kioku
bug-reports:   https://github.com/shinzui/kioku/issues

source-repository head
  type:     git
  location: https://github.com/shinzui/kioku.git
```

For the multi-package repo, add `subdir: <pkg-dir>` to the `source-repository head` stanza of each package.

**c. Internal dependency bounds.** Internal deps are currently declared *without bounds* (bare `, kioku-api`). Hackage requires upper bounds. Every internal dep must carry a PVP bound matching the release version — see step 4b for the full list of sites.

**d. Changelogs.** Only `kioku-migrations/CHANGELOG.md` exists (it has an `Unreleased` section). The other four packages need a `CHANGELOG.md`, plus `extra-doc-files: CHANGELOG.md` in their cabal file. A root `CHANGELOG.md` should also exist for the GitHub release notes.

Report what you fixed and confirm with the user before continuing.

### 2. Determine what changed since the last release

- Read the current version from any cabal file (all five share it).
- Find the latest tag matching `v*`: `git tag --list 'v*' --sort=-v:refname | head -1`.
- If there is **no tag**, this is the first release. Treat all of `git log --oneline` as the change set and default the release version to the current cabal version (`0.1.0.0`) rather than bumping — confirm this with the user.
- Otherwise run `git log --oneline <last-tag>..HEAD`. If there are no commits since the tag, tell the user there is nothing to release and stop.

Present a summary:

- Current version
- Last release tag (or "none — first release")
- Number of commits since the last release
- Which package directories have changes (`git diff --stat <last-tag>..HEAD -- kioku-*/`)

### 3. Determine the next version using PVP

Rules:

- If `$ARGUMENTS` is `major`, `minor`, or `patch`, use that bump level.
- Otherwise analyze the commits. This repo follows [Conventional Commits](https://www.conventionalcommits.org/), so read the types directly:
  - `feat!:`, `fix!:`, or a `BREAKING CHANGE:` footer → **major**
  - `feat:` → **minor**
  - `fix:`, `docs:`, `refactor:`, `chore:`, `test:`, `perf:` → **patch**
- The bump is the **highest** level found across all commits since the tag.
- Because packages share a version, a breaking change in *any* package majors *all* of them.

Increment:

- **major**: increment `B`, reset `C` and `D` to 0 (`0.2.0.1` → `0.3.0.0`)
- **minor**: increment `C`, reset `D` to 0 (`0.2.0.1` → `0.2.1.0`)
- **patch**: increment `D` (`0.2.0.1` → `0.2.0.2`)

Present the proposed bump **and the reasoning** to the user, and get explicit confirmation before proceeding.

### 4. Update versions, bounds, and changelogs

#### a. Version fields

Set `version: <new-version>` in all five cabal files:

- `kioku-api/kioku-api.cabal`
- `kioku-migrations/kioku-migrations.cabal`
- `kioku-core/kioku-core.cabal`
- `kioku-cli/kioku-cli.cabal`
- `kioku-migrate/kioku-migrate.cabal`

#### b. Internal dependency bounds

Set every internal dep to `^>=<new-version>`. All the sites, by file and stanza:

| File | Stanza | Internal deps to bound |
|---|---|---|
| `kioku-core.cabal` | `library` | `kioku-api` |
| `kioku-core.cabal` | `test-suite kioku-test` | `kioku-api`, `kioku-core`, `kioku-migrations:test-support` |
| `kioku-migrations.cabal` | `library test-support` | `kioku-migrations` |
| `kioku-migrations.cabal` | `test-suite kioku-migrations-test` | `kioku-migrations`, `kioku-migrations:test-support` |
| `kioku-cli.cabal` | `library` | `kioku-api`, `kioku-core` |
| `kioku-cli.cabal` | `executable kioku` | `kioku-cli` |
| `kioku-cli.cabal` | `test-suite kioku-cli-test` | `kioku-api`, `kioku-cli`, `kioku-core` |
| `kioku-migrate.cabal` | `executable kioku-migrate` | `kioku-core`, `kioku-migrations` |

Grep to confirm nothing was missed — no bare internal dep should remain:

```bash
grep -rnE '^\s*,\s*kioku-(api|core|cli|migrations|migrate)\s*$' kioku-*/*.cabal
```

#### c. Changelogs

For each package's `CHANGELOG.md`, add a section for the new version above previous entries, dated today in `YYYY-MM-DD`:

```markdown
## <version> — <YYYY-MM-DD>
```

- Move any content from an `Unreleased` section into the new version section. (`kioku-migrations/CHANGELOG.md` currently has a populated `Unreleased` section — do not lose it.)
- Summarize commits since the last release, grouped under only the headings that have entries:
  - **Breaking Changes** (if major)
  - **Added** (if minor or major)
  - **Fixed**
  - **Changed** (docs, refactoring, internal)
- Attribute each entry to the package it actually affects; don't copy the same list into all five.
- Update the root `CHANGELOG.md` with a combined summary for the release.

Show the user **all** changes — version bumps, dependency bounds, changelog entries — for review before committing.

### 5. Verify

Run every gate. All four are mandatory.

```bash
nix fmt              # treefmt: fourmolu, cabal-fmt, nixpkgs-fmt
cabal build all
cabal test all
nix flake check
```

Notes:

- **`cabal test all` needs a live Postgres.** The test suites spin up ephemeral databases via `kioku-migrations:test-support`. The dev shell's `process-compose` provides Postgres; if the tests fail to connect, start it (`process-compose up -d`, or `just create-database` for a fresh dev DB) and re-run. Do **not** interpret a connection failure as a passing suite.
- **`nix flake check` only sees git-tracked files.** Any newly created file (LICENSE, new CHANGELOG.md) must be `git add`-ed before Nix evaluation will pick it up.
- The flake exposes `checks` / `devShells` / `formatter` only — there is no `packages.default`, so `nix flake check` is the gate, not `nix build`.
- If any gate fails, **stop** and fix it. Never proceed to publish on a failing gate.

### 6. Commit, tag, and push

- Stage the modified `.cabal`, `CHANGELOG.md`, and any new `LICENSE` files.
- Create one commit with a Conventional Commits message: `chore(release): <new-version>`. The body should summarize what's in the release and justify the chosen bump level.
- Create one annotated tag: `git tag -a v<version> -m "Release <version>"`
- Push: `git push && git push --tags`

The commit and tag are created **only after** the user approves the changes from step 4.

### 7. Publish to Hackage (in dependency order)

For each package, in order — `kioku-api` → `kioku-migrations` → `kioku-core` → `kioku-cli` → `kioku-migrate`:

1. `cd <pkg-dir>`
2. `cabal check` — verify no packaging issues.
3. `cabal sdist`, then `cabal upload --publish <tarball-path>`.
4. `cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump`, then `cabal upload --publish --documentation <docs-tarball-path>`.
5. Report the Hackage URL.

**If an upload fails, stop.** Do not upload any package that depends on the one that failed — a dependent published against an absent dependency is broken on Hackage and cannot be withdrawn.

After all uploads succeed, present a summary:

| Package | Version | Hackage URL |
|---------|---------|-------------|
| kioku-api | X.Y.Z.W | https://hackage.haskell.org/package/kioku-api-X.Y.Z.W |
| kioku-migrations | X.Y.Z.W | https://hackage.haskell.org/package/kioku-migrations-X.Y.Z.W |
| kioku-core | X.Y.Z.W | https://hackage.haskell.org/package/kioku-core-X.Y.Z.W |
| kioku-cli | X.Y.Z.W | https://hackage.haskell.org/package/kioku-cli-X.Y.Z.W |
| kioku-migrate | X.Y.Z.W | https://hackage.haskell.org/package/kioku-migrate-X.Y.Z.W |

### 8. Create the GitHub release

After all Hackage uploads succeed (`gh` is authed against `shinzui/kioku`):

```bash
gh release create v<version> --title "v<version>" --notes "$(cat <<'EOF'
## Packages

| Package | Hackage |
|---------|---------|
| kioku-api | https://hackage.haskell.org/package/kioku-api-X.Y.Z.W |
| kioku-migrations | https://hackage.haskell.org/package/kioku-migrations-X.Y.Z.W |
| kioku-core | https://hackage.haskell.org/package/kioku-core-X.Y.Z.W |
| kioku-cli | https://hackage.haskell.org/package/kioku-cli-X.Y.Z.W |
| kioku-migrate | https://hackage.haskell.org/package/kioku-migrate-X.Y.Z.W |

## What's Changed

<the root CHANGELOG.md entries for this version>
EOF
)"
```

Report the GitHub release URL when done.

## Important

- Always ask the user to confirm the version bump and the changelogs before committing.
- Always publish in dependency order: `kioku-api` → `kioku-migrations` → `kioku-core` → `kioku-cli` → `kioku-migrate`.
- Never skip `cabal check`, the test suites, or `nix flake check`.
- A test suite that fails to reach Postgres is a **failure**, not a skip. Start Postgres and re-run.
- If any step fails, stop and report the error rather than continuing.
- If a Hackage upload fails, do **not** continue uploading packages that depend on it.
- Because all packages share a version, a breaking change anywhere majors everything.
- Run `nix fmt` before committing, and `git add` new files before `nix flake check`.
- The commit and tag are created only after the user approves all changes.
