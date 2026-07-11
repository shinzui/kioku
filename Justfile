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
# This used to `touch kioku-migrations.cabal` in the hope of forcing Template Haskell to
# re-read sql-migrations/. It never worked: GHC's recompilation check is content-based, so
# touching a file changes nothing. `just new-migration` edits Migrations.hs for real, and
# `cabal test kioku-migrations-test` fails if the embed is stale anyway.
migrate:
    #!/usr/bin/env bash
    set -euo pipefail
    CODD_CONNECTION="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
    CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
    CODD_EXPECTED_SCHEMA_DIR=unused-for-unverified-embedded-migrations \
    CODD_SCHEMAS=kiroku \
      cabal run kioku-migrate

# Scaffold a new timestamped kioku migration in codd's filename format.
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
    ts="$(date -u '+%Y-%m-%d-%H-%M-%S')"
    dest="kioku-migrations/sql-migrations/${ts}-{{name}}.sql"
    if [ -e "$dest" ]; then
      echo "error: $dest already exists" >&2
      exit 1
    fi
    cat > "$dest" <<EOF
    -- codd: in-txn

    -- Migration: {{name}}
    -- Created: ${ts} UTC
    -- Write idempotent DDL (CREATE ... IF NOT EXISTS) so re-application is safe.
    SET search_path TO kiroku, pg_catalog;
    EOF
    echo "Created $dest"

    # The migrations are embedded into the binary by Template Haskell, and file-embed can
    # only register as compilation dependencies the files that already existed when the
    # module last compiled. A brand-new file is invisible to GHC, so without this the
    # binary would silently ship without the migration. `touch` does NOT help: GHC's
    # recompilation check is content-based, so the module's bytes must actually change.
    hs="kioku-migrations/src/Kioku/Migrations.hs"
    if ! grep -q '^-- Last added: ' "$hs"; then
      echo "error: no '-- Last added:' line in $hs; the embed cannot be invalidated" >&2
      exit 1
    fi
    tmp="$(mktemp)"
    sed "s|^-- Last added: .*|-- Last added: ${ts:0:10} {{name}}.|" "$hs" > "$tmp"
    mv "$tmp" "$hs"
    echo "Bumped the 'Last added' note in $hs so Template Haskell re-embeds it"
