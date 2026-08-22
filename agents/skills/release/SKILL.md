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

### 0. Pre-flight: is a release already in flight?

**Run this before anything else.** A previous run can leave a fully staged release commit that was never tagged, pushed, or published — this happened to 0.4.0.0, where `chore(release): 0.4.0.0` sat on `master` unpushed and untagged while Hackage still showed 0.3.0.0. Detecting it up front avoids re-deriving a bump that is already correct.

```bash
git log --oneline -1                              # is HEAD a `chore(release): <ver>` commit?
git tag --list 'v*' --sort=-v:refname | head -3   # is there a tag for that version?
git status -sb | head -1                          # is it pushed?
grep -n '^version:' kioku-*/*.cabal               # what version is staged?
curl -s -o /dev/null -w '%{http_code}\n' \
  https://hackage.haskell.org/package/kioku-api-<staged-version>
```

If the staged version is untagged **and** 404s on Hackage, that version is unclaimed and the correct move is to **resume it** — keep the existing release commit, finish the gates, then tag, push, and publish. Do not bump again; bumping strands a version number and leaves a gap in the Hackage history. Confirm the resume with the user, then jump to step 5.

If it is tagged or already on Hackage, that release is done — proceed normally from step 1 and bump on top of it.

### 1. Pre-flight: Hackage packaging requirements

Run this before touching versions. **As of 0.4.0.0 every item below is already satisfied in all five packages** — this step is now a verification pass, not remediation. Confirm each still holds and move on; only fix what has actually regressed or what a newly added package is missing.

```bash
grep -rnE '^(license-file|homepage|bug-reports|extra-doc-files)' kioku-*/*.cabal
grep -rn -A3 'source-repository' kioku-*/*.cabal
ls kioku-*/LICENSE kioku-*/CHANGELOG.md CHANGELOG.md
```

**a. LICENSE files.** Each package directory has a BSD-3-Clause `LICENSE` (copyright `2026 Nadeem Bitar`) and declares `license-file: LICENSE`.

**b. Repository metadata.** Each cabal carries:

```cabal
homepage:      https://github.com/shinzui/kioku
bug-reports:   https://github.com/shinzui/kioku/issues

source-repository head
  type:     git
  location: https://github.com/shinzui/kioku.git
  subdir:   <pkg-dir>
```

The `subdir` is per-package and required, because this is a multi-package repo.

**c. Internal dependency bounds.** Every internal dep carries a PVP bound. Keeping them *current* is step 4b's job — this step only confirms none is bare.

**d. Changelogs.** All five packages have a `CHANGELOG.md` plus `extra-doc-files: CHANGELOG.md`, and a root `CHANGELOG.md` exists for the GitHub release notes.

If anything did regress, report what you fixed and confirm with the user before continuing.

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

Set every internal dep to `^>=<new-version>`. There are **16** bindable sites, by file and stanza:

| File | Stanza | Internal deps to bound |
|---|---|---|
| `kioku-api.cabal` | `test-suite kioku-api-test` | `kioku-api` |
| `kioku-core.cabal` | `library` | `kioku-api` |
| `kioku-core.cabal` | `test-suite kioku-test` | `kioku-api`, `kioku-core`, `kioku-migrations:test-support` |
| `kioku-migrations.cabal` | `library test-support` | `kioku-migrations` |
| `kioku-migrations.cabal` | `test-suite kioku-migrations-test` | `kioku-migrations` (`kioku-migrations:test-support` stays bare — see below) |
| `kioku-cli.cabal` | `library` | `kioku-api`, `kioku-core` |
| `kioku-cli.cabal` | `executable kioku` | `kioku-cli` |
| `kioku-cli.cabal` | `test-suite kioku-cli-test` | `kioku-api`, `kioku-cli`, `kioku-core`, `kioku-migrations:test-support` |
| `kioku-migrate.cabal` | `executable kioku-migrate` | `kioku-core`, `kioku-migrations` |

A stanza that depends on *its own* package's library or sublibrary (`kioku-api-test` on `kioku-api`, `kioku-cli`'s executable on `kioku-cli`, `kioku-migrations-test` on `kioku-migrations:test-support`) still needs the bound bumped. Cabal resolves same-package deps internally, so the bound never changes resolution — but a **stale** one is unsatisfiable against the new version and breaks `cabal build all`.

**One site is permanently bare, by design.** `kioku-migrations.cabal:95`, `, kioku-migrations:test-support` — the `kioku-migrations-test` suite depending on its own package's sublibrary — **cannot** carry a bound: `cabal-fmt` strips the constraint off a same-package sublibrary self-dep, so `nix fmt` in step 5 silently reverts any bound you add. This was verified in 0.4.1.0 by adding the bound and watching two consecutive `nix fmt` runs delete it. It is harmless — Cabal resolves same-package deps internally and `cabal check` passes — so leave it bare and do not fight the formatter. Earlier revisions of this skill called it an oversight to fix on the next sweep; it is not.

That makes **16** bounded sites out of 17 dep entries. Verify with **all three** commands. Note that both greps must allow a `:sublibrary` suffix — an earlier version of this skill omitted it and silently missed the bare site:

```bash
# (1) no bare internal dep — must print ONLY the known-bare
#     kioku-migrations:test-support self-dep at kioku-migrations.cabal:95
grep -rnE '^\s*,\s*kioku-(api|core|cli|migrations|migrate)(:[a-z-]+)?\s*$' kioku-*/*.cabal

# (2) every internal bound is at the NEW version — must print nothing
grep -rnE ',\s*kioku-(api|core|cli|migrations|migrate)(:[a-z-]+)?\s+\^>=' kioku-*/*.cabal \
  | grep -v '\^>=<new-version>'

# (3) all bindable sites are bounded — must print 16
grep -rhE ',\s*kioku-[a-z:-]+\s+\^>=' kioku-*/*.cabal | wc -l
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

#### d. The `kioku-upgrade` blueprint edge

`blueprints/kioku-upgrade/` is the Seihou blueprint that guides a *consuming project* across a Kioku version window. It is a repo artifact, not part of any sdist, but it must be authored **in the release commit** — an edge written later is an edge reconstructed from hindsight, and the whole point of one-edge-per-window is that each edge is written from the evidence of the release it describes.

**First decide whether this release needs an edge at all.** Most do not.

An edge is needed when crossing this version window requires **judgement work in a consumer's own source or operations**. Ask:

- Did anything a consumer calls change what it accepts, returns, or requires?
- Did a released migration's payload change, so an existing database needs a ledger fixup?
- Did the composed migration plan's count change, breaking count assertions?
- Did an upstream cohort member move in a way that reaches consumers through Kioku?

If none of those, **declare no edge**. A gap between edges is deliberate and legal — it means no agent intervention was needed in that interval. `0.4.0.0 -> 0.4.1.0` is exactly such a gap: a bounds-only move onto the Baikai 0.5 cohort with no source change. Do not invent busywork to fill it, and do not add an edge merely because the version is major; a version shared across five packages goes major whenever *any* of them breaks, which is often not the package a given consumer uses.

**If an edge is needed**, add it to `blueprints/kioku-upgrade/blueprint.dhall` and write its prompt at `migrations/<from>-to-<to>.md`, dashed (`0-4-1-0-to-0-5-0-0.md`). Edges are append-only: never edit or delete a published edge, because a consumer's receipts are keyed to it.

**Determine `entails` from the cabal history, not from memory.** An entailed edge is one exact upstream edge, matched on both `from` and `to`, that this release's cohort move implies. Diff the bounds across the window:

```bash
LAST=$(git tag --list 'v*' --sort=-v:refname | head -1)
for f in kioku-core/kioku-core.cabal kioku-migrations/kioku-migrations.cabal; do
  echo "=== $f"; diff \
    <(git show "$LAST:$f"      | grep -E '^\s*,\s*(keiro|keiki|kiroku|shibuya|baikai|pg-migrate)' | sed 's/  */ /g' | sort -u) \
    <(cat "$f"                 | grep -E '^\s*,\s*(keiro|keiki|kiroku|shibuya|baikai|pg-migrate)' | sed 's/  */ /g' | sort -u)
done
```

`diff` exits 1 when it finds differences — here that is the *useful* outcome, not a failure. Empty output with exit 0 means no upstream member moved and nothing is entailed.

Every upstream library that moved is a candidate. Declare the edge in *that* library's own version space and blueprint (`keiro-upgrade`, `kiroku-upgrade`) rather than copying its guidance here — Seihou runs entailed edges first, expands them recursively, and files the receipt under the entailed blueprint's identity, so a shared edge is crossed exactly once no matter which command the consumer ran.

**Two Kioku-specific hazards the edge must be written for:**

- **A narrowing of accepted input is invisible to the compiler.** `parseMemoryEvent` kept the type `Value -> Either Text Event` across 0.5.0.0 while values that used to decode began returning `Left`. There is no build error to follow, so such an edge must tell the agent what to grep for and must explicitly refuse to treat a passing build as evidence.
- **A corrected migration payload is not an additive migration.** When a release changes the bytes of an already-released migration, every database that applied the old bytes needs a one-time ledger re-baseline before its next `up` or `verify`. The edge **names the script and stops** — running it is the operator's decision on their own backup and maintenance window, and a Seihou receipt records that a provider interaction returned, not that a database was remediated. Point at the `cohort-migrate` skill for databases holding real data.

Also update `blueprints/kioku-upgrade/files/kioku-cohort-versions.md`: add a row to both bound tables, a row to the composed-plan table if the count moved, and an entry under "Releases requiring a ledger fixup" if this release corrected a payload.

Show the user **all** changes — version bumps, dependency bounds, changelog entries, and any blueprint edge — for review before committing.

### 5. Verify

Run every gate. All five are mandatory; the sixth applies only if step 4d added a blueprint edge.

```bash
nix fmt              # treefmt: fourmolu, cabal-fmt, nixpkgs-fmt
cabal build all
cabal test all
nix flake check
for p in kioku-api kioku-migrations kioku-core kioku-cli kioku-migrate; do
  echo "=== $p ==="; (cd "$p" && cabal check); done

# only if this release added a blueprint edge (step 4d)
seihou validate-blueprint blueprints/kioku-upgrade
dhall format --check blueprints/kioku-upgrade/blueprint.dhall
```

**Run `cabal check` here, before the tag** — not in step 7 as this skill previously said. A packaging error found after tagging and pushing leaves a published tag pointing at a tree that cannot be uploaded; found here, it costs nothing. All five should report "No errors or warnings could be found in the package."

Notes:

- **`cabal test all` needs a live Postgres.** The test suites spin up ephemeral databases via `kioku-migrations:test-support`. Do **not** interpret a connection failure as a passing suite. Check and start it with:

  ```bash
  PC_SOCK="${TMPDIR}kioku-pc.sock"

  pg_isready
  process-compose up -t=false -U -u "$PC_SOCK"   # run in background
  ```

  **Always talk to process-compose over a unix socket, never a TCP port.** `-U/--use-uds` makes the server bind `$PC_SOCK` and skip the HTTP listener entirely, so there is no port to collide with — the default admin port 8080 is already taken on this machine by an unrelated service, and chasing that costs a round of debugging every time. Pass `-U -u "$PC_SOCK"` to **every** client command too; the default socket path embeds the client's own PID, so a bare `process-compose process list` will not find the server:

  ```bash
  process-compose process list -U -u "$PC_SOCK"   # create_schema, postgres, sanity_check
  process-compose down -U -u "$PC_SOCK"           # tears down and removes the socket
  ```

  Two other traps: `process-compose up -d` does **not** detach — `-d` is `--hide-disabled`; it tries to start the TUI and dies with `open /dev/tty: device not configured` under an agent, so use `-t=false` and background the command. And a client pointed at the wrong endpoint reports a bogus `invalid character '<'` rather than a connection error. Postgres is usually ready within a second or two; poll `process-compose process list` until it answers rather than sleeping blindly.

- **Confirm every suite, not just the last one.** `cabal test all` output is long and the tail shows only the final package. There are four suites — `kioku-api-test`, `kioku-migrations-test`, `kioku-cli-test`, `kioku-test` (core); `kioku-migrate` has none. Summarize with:

  ```bash
  cabal test all 2>&1 | grep -E 'Test suite|tests passed|tests failed|FAIL'
  ```

  As of 0.5.0.0 that is 421 tests: api 125, migrations 24, cli 53, core 219. (0.4.0.0 was 397: api 119, migrations 18, cli 50, core 210.) Treat the count as a floor that drifts upward, not a target — a *lower* number than the last release means a suite silently stopped running, which is worth investigating before publishing.

- **`nix flake check` only sees git-tracked files.** Any newly created file (LICENSE, new CHANGELOG.md, a new blueprint edge) must be `git add`-ed before Nix evaluation will pick it up.

- **`seihou validate-blueprint` does not check the edge you just wrote.** It validates name, version, prompt body, reference-file existence, tags, and tools — it reports nothing about `migrations`, `entails`, or `versionProbe`, so a passing run is *not* evidence your edge parsed. Confirm those separately:

  ```bash
  echo '(./blueprint.dhall).migrations' | dhall | grep -A2 entails   # from blueprints/kioku-upgrade/
  echo '(./blueprint.dhall).versionProbe' | dhall
  ```

  Then run the probe itself against this repo's own build plan and check it prints the new version — it is the one part of the blueprint that can be tested here rather than in a consumer:

  ```bash
  jq -r '."install-plan"[] | select(."pkg-name"|startswith("kioku-")) | ."pkg-version"' \
    dist-newstyle/cache/plan.json 2>/dev/null | sort -u | tail -1 | grep .
  ```

  `seihou` and `dhall` live in the user profile, not this flake's devShell. If neither is available, say so rather than claiming the blueprint was validated.

  Whether the *entailed* blueprint actually declares the edge you named is resolved only at `seihou agent migrate` time, in a project that has both installed — it cannot be checked from this repo. Verify by reading the upstream blueprint's own `blueprint.dhall` and matching `from`/`to` exactly.
- The flake exposes `checks` / `devShells` / `formatter` only — there is no `packages.default`, so `nix flake check` is the gate, not `nix build`.
- If any gate fails, **stop** and fix it. Never proceed to publish on a failing gate.

### 6. Commit, tag, and push

- Stage the modified `.cabal`, `CHANGELOG.md`, any new `LICENSE` files, and any blueprint edge from step 4d.
- Create one commit with a Conventional Commits message: `chore(release): <new-version>`. The body should summarize what's in the release and justify the chosen bump level.
- Create one annotated tag: `git tag -a v<version> -m "Release <version>"`
- Push: `git push && git push --tags`

The commit and tag are created **only after** the user approves the changes from step 4.

### 7. Publish to Hackage (in dependency order)

`cabal check` already ran in step 5. Build every source tarball up front — `cabal sdist all` does all five at once and has no side effects:

```bash
cabal sdist all      # writes dist-newstyle/sdist/<pkg>-<ver>.tar.gz
```

Sanity-check the `kioku-migrations` tarball before uploading, since that package is worthless without its SQL:

```bash
tar tzf dist-newstyle/sdist/kioku-migrations-<ver>.tar.gz | grep -cE 'migrations/.*\.sql'  # expect 13 as of 0.5.0.0
tar tzf dist-newstyle/sdist/kioku-migrations-<ver>.tar.gz | grep 'migrations/manifest'
```

Then, for each package in order — `kioku-api` → `kioku-migrations` → `kioku-core` → `kioku-cli` → `kioku-migrate`:

1. `cabal upload --publish dist-newstyle/sdist/<pkg>-<ver>.tar.gz`
2. `cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump <pkg>`
3. `cabal upload --publish --documentation <docs-tarball-path>`
4. Report the Hackage URL.

**If an upload fails, stop.** Do not upload any package that depends on the one that failed — a dependent published against an absent dependency is broken on Hackage and cannot be withdrawn. A *documentation* failure is different: the package itself is already published, so it does not block downstream packages. Fix the tarball and re-upload the docs.

#### Documentation upload quirks

Two failures are reproducible every release. Both cost a debugging round in 0.4.0.0.

**Let `cabal haddock` finish before inspecting anything it wrote.** The docs tarball is not final until the command exits: for a multi-library package cabal writes the main-library tarball first and then *overwrites* it with the sublibrary tree on completion. Inspecting mid-build shows a clean, colon-free, correctly-rooted archive and hides the quirk below entirely — that happened in 0.5.0.0, where a `tar tzf` run against the in-progress file reported 7 HTML files and zero `test-support` entries, and the upload then 400'd on the colon anyway. If `cabal haddock` was backgrounded or timed out into the background, wait for its exit before drawing any conclusion from the tarball. Note also that cabal buffers its output, so an empty log file is not evidence that nothing is happening — check for a running process instead.

**`kioku-migrate` has no library**, so `cabal haddock` correctly prints *"No documentation was generated as this package does not contain a library."* There is no docs tarball to upload. Expected — not a failure to chase.

**macOS `tar` writes GNU format**, which Hackage rejects with `Error: Invalid documentation tarball / Archive is in the GNU tar format`. Any hand-repacked tarball needs ustar:

```bash
COPYFILE_DISABLE=1 tar --format=ustar -czf <pkg>-<ver>-docs.tar.gz <pkg>-<ver>-docs
```

`COPYFILE_DISABLE=1` stops bsdtar smuggling in AppleDouble `._` entries. Paths run ~75 chars, well under ustar's 100-char limit.

**`kioku-migrations` needs a hand-repack**, because it is the only multi-library package. `cabal haddock --haddock-for-hackage kioku-migrations` selects the *sublibrary* tree:

```text
dist-newstyle/build/<arch>/ghc-<ver>/kioku-migrations-<ver>/l/test-support/doc/html/kioku-migrations-<ver>-docs
```

which nests a `test-support/` dir containing `kioku-migrations:test-support.txt`. Hackage 400s with `Invalid windows file name in tar archive` over the `:`. The main library's haddocks are built correctly but live elsewhere, and that tree is already colon-free and correctly rooted:

```text
dist-newstyle/build/<arch>/ghc-<ver>/kioku-migrations-<ver>/doc/html/kioku-migrations-<ver>-docs
```

Ignore cabal's own tarball, copy that directory to a scratch dir, and repack it with the ustar command above. Verify before uploading:

```bash
tar tzf <tarball> | grep ':' || echo clean      # no colon filenames
tar tzf <tarball> | grep '/\._' || echo clean   # no AppleDouble entries
tar tzf <tarball> | grep -c '\.html$'           # expect 7 as of 0.5.0.0
tar tzf <tarball> | grep -c 'test-support'      # expect 0 — the sublibrary tree must not be in here
```

After all uploads succeed, present a summary:

| Package | Version | Hackage URL |
|---------|---------|-------------|
| kioku-api | X.Y.Z.W | https://hackage.haskell.org/package/kioku-api-X.Y.Z.W |
| kioku-migrations | X.Y.Z.W | https://hackage.haskell.org/package/kioku-migrations-X.Y.Z.W |
| kioku-core | X.Y.Z.W | https://hackage.haskell.org/package/kioku-core-X.Y.Z.W |
| kioku-cli | X.Y.Z.W | https://hackage.haskell.org/package/kioku-cli-X.Y.Z.W |
| kioku-migrate | X.Y.Z.W | https://hackage.haskell.org/package/kioku-migrate-X.Y.Z.W |

### 8. Create the GitHub release

After all Hackage uploads succeed (`gh` is authed against `shinzui/kioku`).

Extract this version's root changelog section rather than retyping it, and pass it via `--notes-file` — the notes are long and multi-paragraph, so a heredoc inside `--notes` is easy to mangle:

```bash
awk '/^## <new-version>/{f=1} /^## <previous-version>/{f=0} f' CHANGELOG.md > notes-body.md
```

Prepend the package table, then `gh release create v<version> --title "v<version>" --notes-file <file>`. The table and body:

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

- **Check step 0 first.** A staged-but-unpublished release commit means resume that version, not bump past it.
- Always ask the user to confirm the version bump and the changelogs before committing.
- Always publish in dependency order: `kioku-api` → `kioku-migrations` → `kioku-core` → `kioku-cli` → `kioku-migrate`.
- Never skip `cabal check`, the test suites, or `nix flake check`. Run `cabal check` **before** tagging.
- A test suite that fails to reach Postgres is a **failure**, not a skip. Start Postgres and re-run — over a unix socket (`-U -u "$PC_SOCK"`), never a TCP port. Tear the stack down with `process-compose down -U -u "$PC_SOCK"` when the release is finished.
- Confirm all four test suites reported PASS, not just the one at the end of the output.
- Internal bounds must be swept to the new version at **all 16 bindable sites**, including same-package self-deps. A stale self-dep bound breaks the build. The 17th, `kioku-migrations:test-support` in `kioku-migrations-test`, stays bare — `cabal-fmt` strips that bound every time.
- If any step fails, stop and report the error rather than continuing.
- If a Hackage *package* upload fails, do **not** continue uploading packages that depend on it. A *docs* upload failure does not block downstream.
- `kioku-migrations` docs always need a hand-repack (ustar, main-library tree). `kioku-migrate` has no docs at all. Never judge a docs tarball before `cabal haddock` has exited — it is rewritten on completion, and an in-progress read makes the repack look unnecessary.
- Because all packages share a version, a breaking change anywhere majors everything. That is also why a major bump does **not** by itself mean the `kioku-upgrade` blueprint needs an edge — decide from consumer-visible judgement work (step 4d), not from the version digit.
- A blueprint edge, when one is needed, is authored **in the release commit** and is append-only. Never edit or delete a published edge: consumer receipts are keyed to it.
- Run `nix fmt` before committing, and `git add` new files before `nix flake check`.
- The commit and tag are created only after the user approves all changes.
