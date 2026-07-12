# Create the dev database (idempotent) and apply the full schema.
# Relies on the PG* environment variables set by the nix devShell.
create-database:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! psql -h "$PGHOST" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$PGDATABASE'" | grep -q 1; then
      createdb -h "$PGHOST" "$PGDATABASE"
    fi
    just migrate

# Apply kiroku, keiro, and kioku's embedded read-model migrations, then reconcile
# keiro's read-model registry to the identity the compiled read models declare.
#
# pg-migrate embeds the ordered manifest and every listed SQL file. A new file is
# not part of the component until `new` appends it to the manifest atomically.
migrate:
    #!/usr/bin/env bash
    set -euo pipefail
    DATABASE_URL="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
      cabal run kioku-migrate -- up

# Scaffold the next manifest-ordered kioku migration through pg-migrate-cli.
new-migration name="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{name}}" ]; then
      echo "usage: just new-migration <slug>   (slug: [a-z0-9-])" >&2
      exit 1
    fi
    if ! printf '%s' "{{name}}" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
      echo "error: name must match [a-z0-9-] (got '{{name}}')" >&2
      exit 1
    fi
    manifest="kioku-migrations/migrations/manifest"
    last="$(tail -n 1 "$manifest")"
    prefix="${last%%-*}"
    if ! printf '%s' "$prefix" | grep -Eq '^[0-9]+$'; then
      echo "error: cannot infer numeric prefix from $last" >&2
      exit 1
    fi
    next="$((10#$prefix + 1))"
    basename="$(printf "%0${#prefix}d-%s" "$next" "{{name}}")"
    cabal run kioku-migrate -- new \
      --manifest "$manifest" \
      --description "{{name}}" \
      --name "$basename"
