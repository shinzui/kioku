#!/usr/bin/env bash
set -euo pipefail

readonly source_roots=(
  kioku-api/src
  kioku-core/src
  kioku-cli/src
  kioku-migrations/src
  kioku-migrations/test-support
  kioku-migrate/app
)
readonly cabal_files=(
  kioku-api/kioku-api.cabal
  kioku-core/kioku-core.cabal
  kioku-cli/kioku-cli.cabal
  kioku-migrations/kioku-migrations.cabal
  kioku-migrate/kioku-migrate.cabal
)

failed=0

reject_matches() {
  local description=$1
  local pattern=$2
  shift 2
  local matches

  matches=$(rg --line-number --glob '*.hs' "$pattern" "$@" || true)
  if [[ -n "$matches" ]]; then
    printf '%s\n%s\n' "$description" "$matches" >&2
    failed=1
  fi
}

reject_matches \
  'Use postpositive qualified imports (`import Module qualified as Alias`):' \
  '^[[:space:]]*import[[:space:]]+qualified[[:space:]]' \
  "${source_roots[@]}"

# Kioku.Prelude is the single intentional package-import boundary. PackageImports
# elsewhere bypasses that boundary and makes dependency ownership harder to see.
package_imports=$(rg --line-number --glob '*.hs' --glob '!kioku-api/src/Kioku/Prelude.hs' \
  '(LANGUAGE[[:space:]]+PackageImports|^[[:space:]]*import[[:space:]]+"[^"]+")' \
  "${source_roots[@]}" || true)
if [[ -n "$package_imports" ]]; then
  printf '%s\n%s\n' 'PackageImports is confined to kioku-api/src/Kioku/Prelude.hs:' "$package_imports" >&2
  failed=1
fi

reject_matches \
  'Use an explicit deriving stock, newtype, or anyclass strategy:' \
  '^[[:space:]]*deriving[[:space:]]*\(' \
  "${source_roots[@]}"

for cabal_file in "${cabal_files[@]}"; do
  for baseline in \
    'tested-with: ghc >=9.12 && <9.13' \
    'common warnings' \
    'common shared' \
    'default-language: GHC2024'; do
    if ! grep -qF "$baseline" "$cabal_file"; then
      printf '%s: missing package baseline `%s`\n' "$cabal_file" "$baseline" >&2
      failed=1
    fi
  done
done

if ((failed != 0)); then
  exit 1
fi

printf '%s\n' 'Haskell convention checks passed.'
