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

# Apply kiroku, keiro, and kioku's embedded read-model migrations.
migrate:
    #!/usr/bin/env bash
    set -euo pipefail
    touch kioku-migrations/kioku-migrations.cabal
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
