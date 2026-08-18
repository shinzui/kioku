#!/usr/bin/env bash
# Shared vocabulary for the Baikai cohort automation.
#
# Sourced by baikai-bump-needed.sh (the reaction's idempotency check) and by
# upgrade-baikai.sh (the reaction's action). Not executable on its own.
#
# The cohort is every Hackage package whose version Kioku pins BECAUSE of
# baikai. That is wider than "the packages named baikai-*": shikumi and
# shikumi-trace re-release with widened baikai bounds on each baikai major, and
# only those newest patches carry them, so a bump that moved baikai without
# moving them would give the solver a way to fall back off the cohort. See the
# comment above the build-depends block in kioku-core/kioku-core.cabal.

COHORT_PACKAGES=(
  baikai
  baikai-claude
  baikai-effectful
  shikumi
  shikumi-trace
)

CABAL_FILE="kioku-core/kioku-core.cabal"

# The version Hackage currently prefers, i.e. the newest non-deprecated release.
# Prints nothing and fails if Hackage cannot be reached or returns nothing
# usable -- callers must treat an empty answer as "do not act", never as
# "no releases exist".
hackage_latest() {
  local pkg=$1 body
  body=$(curl -fsS --max-time 30 -H 'Accept: application/json' \
    "https://hackage.haskell.org/package/${pkg}/preferred" 2>/dev/null) || return 1
  printf '%s' "$body" | jq -er '."normal-version"[0]' 2>/dev/null
}

# The lower bound Kioku currently pins for a package, read out of the library
# stanza. Every cohort bound is written as a `^>=` caret bound; a package that
# is not pinned that way prints nothing.
cabal_bound() {
  local pkg=$1
  awk -v pkg="$pkg" '
    $1 == "," && $2 == pkg && $3 ~ /^\^>=/ {
      sub(/^\^>=/, "", $3); print $3; exit
    }
  ' "$CABAL_FILE"
}

# Rewrite every `^>=` bound for one package across ALL stanzas (kioku-core has
# the cohort in both its library and its test-suite). Only the version token
# after `^>=` changes, so the `^>=` column -- which cabal-fmt aligns off the
# longest package NAME, not the version -- stays byte-identical and the file
# remains cabal-fmt stable without needing a formatter on PATH.
set_cabal_bound() {
  local pkg=$1 version=$2 tmp
  tmp=$(mktemp)
  awk -v pkg="$pkg" -v ver="$version" '
    $1 == "," && $2 == pkg && $3 ~ /^\^>=/ {
      sub(/\^>=[0-9][0-9.]*/, "^>=" ver)
    }
    { print }
  ' "$CABAL_FILE" > "$tmp"
  mv "$tmp" "$CABAL_FILE"
}

# Compare two dotted version strings. Exits 0 when $1 is strictly newer than
# $2. Written in awk because macOS `sort` has no -V and coreutils is not in
# this devShell.
version_gt() {
  awk -v a="$1" -v b="$2" '
    BEGIN {
      n = split(a, x, "."); m = split(b, y, ".")
      len = (n > m ? n : m)
      for (i = 1; i <= len; i++) {
        p = (i <= n ? x[i] + 0 : 0)
        q = (i <= m ? y[i] + 0 : 0)
        if (p > q) exit 0
        if (p < q) exit 1
      }
      exit 1
    }
  '
}

# Emit "<pkg> <current> <latest>" for each cohort member that has a strictly
# newer release on Hackage than Kioku pins. Returns non-zero if any Hackage
# lookup failed, so a network blip can never read as "nothing to do".
cohort_advances() {
  local pkg current latest failed=0
  for pkg in "${COHORT_PACKAGES[@]}"; do
    current=$(cabal_bound "$pkg")
    if [[ -z $current ]]; then
      echo "cannot read a ^>= bound for ${pkg} from ${CABAL_FILE}" >&2
      failed=1
      continue
    fi
    if ! latest=$(hackage_latest "$pkg") || [[ -z $latest ]]; then
      echo "cannot read the preferred version of ${pkg} from Hackage" >&2
      failed=1
      continue
    fi
    if version_gt "$latest" "$current"; then
      printf '%s %s %s\n' "$pkg" "$current" "$latest"
    fi
  done
  return $failed
}
