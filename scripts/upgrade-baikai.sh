#!/usr/bin/env bash
# Action for the `upgrade-baikai-cohort` mori reaction; also runnable by hand
# as `just upgrade-baikai`.
#
# Moves kioku-core's Baikai-cohort bounds to the newest releases Hackage
# prefers, proves the result builds and passes every test suite, and commits.
# On any failure the cabal file is restored, so a red run leaves the tree
# exactly as it found it.
#
# Exit codes are chosen for an unattended caller:
#
#   0 -- either the bump landed and is committed, or there was legitimately
#        nothing to do (already current, tree dirty, cohort not yet consistent).
#        None of those are incidents and none should page anyone.
#   1 -- the bump was warranted and available but did not survive verification,
#        or the environment is not fit to attempt it. This wants a human.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/baikai-cohort.sh
source scripts/baikai-cohort.sh

log() { printf '[upgrade-baikai] %s\n' "$*"; }
# Put everything this script touches back the way it found it, staged or not.
# CHANGELOG.md is in here because the commit itself can fail -- the repo installs
# a pre-commit hook -- and a half-applied bump left behind for someone to trip
# over tomorrow is worse than no bump at all.
restore() {
  git reset -q 2>/dev/null || true
  git checkout -- "$CABAL_FILE" CHANGELOG.md 2>/dev/null || true
}

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [[ $branch != master ]]; then
  log "on branch '${branch}', not master -- nothing to do"
  exit 0
fi

if [[ -n $(git status --porcelain) ]]; then
  log "working tree is not clean -- refusing to build, test, or commit on top of it"
  exit 0
fi

if ! advances=$(cohort_advances); then
  log "could not establish the cohort's current state from Hackage -- not acting on partial data"
  exit 1
fi

if [[ -z $advances ]]; then
  log "every cohort bound already names the newest release -- nothing to do"
  exit 0
fi

log "cohort advances available:"
while read -r pkg current latest; do
  log "  ${pkg}: ${current} -> ${latest}"
done <<< "$advances"

# --- rewrite ---------------------------------------------------------------
# One bullet per package rather than a comma-joined run-on: this text goes into
# both a commit body and a changelog entry, and neither wants a 200-column line.
moves=""
while read -r pkg current latest; do
  set_cabal_bound "$pkg" "$latest"
  moves+="- \`${pkg} ^>=${latest}\` (was ${current})
"
done <<< "$advances"
moves=${moves%$'\n'}

if git diff --quiet -- "$CABAL_FILE"; then
  log "bounds rewrite produced no change -- the cabal file does not look as expected"
  exit 1
fi

# --- can the cohort even be solved yet? ------------------------------------
# A baikai release and the shikumi patches that widen their bounds to admit it
# are separate uploads, and the tag that woke us fires on the first of them.
# Landing here before the rest of the cohort is published is expected, not a
# fault: back the change out and wait to be woken again.
log "refreshing the package index"
cabal update >/dev/null 2>&1 || { log "cabal update failed"; restore; exit 1; }

log "checking the solver can find a plan"
if ! plan=$(cabal build all --enable-tests --dry-run 2>&1); then
  log "no consistent install plan yet -- the rest of the cohort has not been published"
  log "solver said:"
  printf '%s\n' "$plan" | tail -20
  restore
  exit 0
fi

# --- verify ----------------------------------------------------------------
# Full output goes to a file and only the tail is echoed. A reaction that fails
# at 4am is read from `mori reaction show` hours later, and "which test failed"
# has to survive that trip -- piping straight to `tail` throws the answer away.
# Plain `mktemp`, not `mktemp -t upgrade-baikai`: this devShell's mktemp is GNU
# coreutils, whose -t wants a template containing XXXXXX and fails without one.
# It failed silently into an empty path, and `cabal build > ""` then reported
# itself as a build failure.
run_log=$(mktemp) || { log "cannot create a log file"; restore; exit 1; }
[[ -n $run_log ]] || { log "mktemp returned an empty path"; restore; exit 1; }
log "verification output: ${run_log}"

log "building"
if ! cabal build all --enable-tests > "$run_log" 2>&1; then
  log "BUILD FAILED -- restoring ${CABAL_FILE}; full output in ${run_log}"
  tail -40 "$run_log"
  restore
  exit 1
fi

# The suites need the dev database. Starting it is idempotent and it is left
# running afterwards, which is the state a developer's shell expects anyway.
if ! pg_ctl status -D "$PGDATA" >/dev/null 2>&1; then
  log "starting postgres"
  pg_ctl start -w -l "$PGLOG" -o "--unix_socket_directories='$PGHOST'" -o "-c listen_addresses=''" \
    || { log "could not start postgres"; restore; exit 1; }
fi
log "applying migrations"
just create-database >/dev/null 2>&1 || { log "migrations failed"; restore; exit 1; }

log "running the test suites"
if ! cabal test all --test-show-details=streaming > "$run_log" 2>&1; then
  log "TESTS FAILED -- restoring ${CABAL_FILE}; full output in ${run_log}"
  log "failing cases:"
  grep -E "FAIL|failed" "$run_log" | head -20
  restore
  exit 1
fi

# --- record and commit -----------------------------------------------------
entry="- **Cohort:** automated bounds bump. Bounds only; no Kioku source changed.
  Verified by a full \`cabal build\` and every test suite passing. No upstream
  changelog was read, so the suites are the only thing standing between this and
  a breaking release.

$(printf '%s' "$moves" | sed 's/^/  /')"

tmp=$(mktemp)
# Three shapes to land in, and each needs a different insertion point:
#   state 0 -> no Unreleased section yet: open the whole thing above the newest
#              released heading.
#   state 1 -> inside Unreleased, looking for its "### Changed". Append there if
#              one exists, or open one before the next heading if it does not.
#   state 2 -> inserted; copy the rest through untouched.
# An earlier version appended a second "### Changed" under one that already
# existed, which is why this is a state machine and not two patterns.
awk -v entry="$entry" '
  BEGIN { state = 0 }
  /^## Unreleased$/ && state == 0 { print; state = 1; next }
  state == 1 && /^### Changed$/ { print; print ""; print entry; state = 2; next }
  state == 1 && /^## / { print "### Changed"; print ""; print entry; print ""; print; state = 2; next }
  state == 0 && /^## / { print "## Unreleased"; print ""; print "### Changed"; print ""; print entry; print ""; print; state = 2; next }
  { print }
' CHANGELOG.md > "$tmp"
mv "$tmp" CHANGELOG.md

git add "$CABAL_FILE" CHANGELOG.md
if ! git commit -q -F - <<COMMIT
chore(deps): move onto the newest Baikai cohort

${moves}

Bounds only; no Kioku source changed. Raised automatically by the
upgrade-baikai-cohort mori reaction on a shinzui/baikai release tag, and
committed only after \`cabal build all --enable-tests\` and every test suite
passed against the new cohort.

Nothing read the upstream changelogs. A breaking change that Kioku's tests
do not cover would land here unremarked, so treat this commit as verified,
not reviewed.

Ref: mori://shinzui/baikai
COMMIT
then
  log "COMMIT REFUSED -- the pre-commit hook rejected it; backing the bump out"
  restore
  exit 1
fi

log "committed $(git rev-parse --short HEAD)"
log "NOT pushed -- review, then push when you are satisfied"
