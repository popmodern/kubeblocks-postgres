#!/bin/bash

set -euo pipefail

MODE=full
if [ "${1:-}" = "--custom-only" ]; then
    MODE=custom-only
    shift
fi

TARGET_DB=${1:-postgres}
SUPABASE_ROOT=/usr/share/supabase/postgres
INIT_SCRIPTS_DIR=${SUPABASE_ROOT}/migrations/db/init-scripts
MIGRATIONS_DIR=${SUPABASE_ROOT}/migrations/db/migrations
CUSTOM_MIGRATIONS_DIR=${SUPABASE_CUSTOM_MIGRATIONS_DIR:-/etc/postgresql.schema.d}
CUSTOM_MIGRATION_FILE=${SUPABASE_CUSTOM_MIGRATION_FILE:-/etc/postgresql.schema.sql}
CURRENT_STAGE=initialization

log_supabase() {
    echo "Supabase migrations: mode=${MODE} target_db=${TARGET_DB} stage=${CURRENT_STAGE} - $*"
}

report_error() {
    local exit_code=$?

    echo "ERROR: Supabase migrations failed: mode=${MODE} target_db=${TARGET_DB} stage=${CURRENT_STAGE} exit=${exit_code}" >&2
    exit "$exit_code"
}

trap report_error ERR

sql_literal() {
    printf "%s" "$1" | sed "s/'/''/g"
}

require_sql_dir() {
    local dir_path=$1

    if [ ! -d "$dir_path" ]; then
        echo "ERROR: missing Supabase migration directory: ${dir_path}" >&2
        exit 1
    fi

    log_supabase "found required directory ${dir_path}"
}

sql_files() {
    local dir_path=$1

    find "$dir_path" -maxdepth 1 -type f -name '*.sql' | LC_ALL=C sort
}

optional_sql_files() {
    local dir_path=$1

    if [ ! -d "$dir_path" ]; then
        return 0
    fi

    sql_files "$dir_path"
}

latest_sql_version() {
    local dir_path=$1
    local last_file

    last_file=$(sql_files "$dir_path" | tail -n 1)
    basename "$last_file" .sql
}

is_migration_complete() {
    local latest_version=$1

    psql -v ON_ERROR_STOP=1 -X -d "$TARGET_DB" -tAc "SELECT to_regclass('public.schema_migrations') IS NOT NULL AND EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = '${latest_version}')"
}

bootstrap_supabase_admin() {
    psql -v ON_ERROR_STOP=1 -X -d "$TARGET_DB" <<'SQL'
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_admin') THEN
        CREATE ROLE supabase_admin WITH LOGIN SUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS;
    ELSE
        ALTER ROLE supabase_admin WITH LOGIN SUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS;
    END IF;
END
$$;
SQL
}

ensure_schema_migrations_table() {
    psql -v ON_ERROR_STOP=1 -X -d "$TARGET_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
    version character varying(255) PRIMARY KEY
);
SQL
}

ensure_custom_migrations_table() {
    psql -v ON_ERROR_STOP=1 -X -d "$TARGET_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS public.spilo_supabase_custom_migrations (
    identifier text PRIMARY KEY,
    checksum text NOT NULL,
    applied_at timestamp with time zone NOT NULL DEFAULT now()
);
SQL
}

ensure_pgbouncer_auth_schema() {
    psql -v ON_ERROR_STOP=1 -X -d "$TARGET_DB" <<'SQL'
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer') THEN
        CREATE ROLE pgbouncer LOGIN;
    END IF;
END
$$;

REVOKE ALL PRIVILEGES ON SCHEMA public FROM pgbouncer;
CREATE SCHEMA IF NOT EXISTS pgbouncer AUTHORIZATION pgbouncer;
ALTER SCHEMA pgbouncer OWNER TO pgbouncer;

CREATE OR REPLACE FUNCTION pgbouncer.get_auth(p_usename text)
RETURNS TABLE(username text, password text)
AS $$
BEGIN
    RAISE WARNING 'PgBouncer auth request: %', p_usename;

    RETURN QUERY
    SELECT usename::text, passwd::text
      FROM pg_catalog.pg_shadow
     WHERE usename = p_usename;
END;
$$ LANGUAGE plpgsql
SET search_path = ''
SECURITY DEFINER;

REVOKE ALL ON FUNCTION pgbouncer.get_auth(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(text) TO pgbouncer;
SQL
}

ensure_stat_extension_schema() {
    psql -v ON_ERROR_STOP=1 -X -d "$TARGET_DB" <<'SQL'
CREATE SCHEMA IF NOT EXISTS extensions;

DO $$
DECLARE
    current_schema text;
BEGIN
    SELECT n.nspname
      INTO current_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
     WHERE e.extname = 'pg_stat_statements';

    IF current_schema IS NULL THEN
        CREATE EXTENSION pg_stat_statements WITH SCHEMA extensions;
    ELSIF current_schema <> 'extensions' THEN
        ALTER EXTENSION pg_stat_statements SET SCHEMA extensions;
    END IF;
END
$$;
SQL
}

run_tracked_sql_file() {
    local role_name=$1
    local sql_file=$2
    local version_name
    local already_applied

    version_name=$(basename "$sql_file" .sql)
    already_applied=$(psql -v ON_ERROR_STOP=1 -X -d "$TARGET_DB" -tAc "SELECT EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = '${version_name}')")
    if [ "$already_applied" = "t" ]; then
        return 0
    fi

    echo "Running Supabase migration ${version_name} as ${role_name}"
    psql -v ON_ERROR_STOP=1 -X -d "$TARGET_DB" <<SQL
BEGIN;
SET LOCAL ROLE ${role_name};
\i ${sql_file}
INSERT INTO public.schema_migrations(version) VALUES ('${version_name}');
COMMIT;
SQL
}

run_sql_dir_as_role() {
    local role_name=$1
    local dir_path=$2
    local sql_file

    while IFS= read -r sql_file; do
        run_tracked_sql_file "$role_name" "$sql_file"
    done < <(sql_files "$dir_path")
}

file_checksum() {
    local sql_file=$1

    sha256sum "$sql_file" | awk '{print $1}'
}

run_custom_sql_file() {
    local identifier=$1
    local sql_file=$2
    local checksum
    local escaped_identifier
    local escaped_checksum
    local already_applied

    checksum=$(file_checksum "$sql_file")
    escaped_identifier=$(sql_literal "$identifier")
    escaped_checksum=$(sql_literal "$checksum")
    already_applied=$(psql -v ON_ERROR_STOP=1 -X -d "$TARGET_DB" -tAc "SELECT EXISTS (SELECT 1 FROM public.spilo_supabase_custom_migrations WHERE identifier = '${escaped_identifier}' AND checksum = '${escaped_checksum}')")
    if [ "$already_applied" = "t" ]; then
        return 1
    fi

    echo "Running Supabase custom SQL ${identifier} on ${TARGET_DB}"
    psql -v ON_ERROR_STOP=1 -X -d "$TARGET_DB" <<SQL
BEGIN;
SET LOCAL ROLE supabase_admin;
\i ${sql_file}
INSERT INTO public.spilo_supabase_custom_migrations(identifier, checksum)
VALUES ('${escaped_identifier}', '${escaped_checksum}')
ON CONFLICT (identifier) DO UPDATE
SET checksum = EXCLUDED.checksum,
    applied_at = now();
COMMIT;
SQL
}

apply_custom_sql_hooks() {
    local applied_any=false
    local sql_file
    local identifier

    while IFS= read -r sql_file; do
        identifier="dir:$(basename "$sql_file")"
        if run_custom_sql_file "$identifier" "$sql_file"; then
            applied_any=true
        fi
    done < <(optional_sql_files "$CUSTOM_MIGRATIONS_DIR")

    if [ -f "$CUSTOM_MIGRATION_FILE" ]; then
        if run_custom_sql_file "file:${CUSTOM_MIGRATION_FILE}" "$CUSTOM_MIGRATION_FILE"; then
            applied_any=true
        fi
    fi

    [ "$applied_any" = true ]
}

reset_stats() {
    psql -v ON_ERROR_STOP=1 -X -d "$TARGET_DB" <<'SQL' || true
SET ROLE supabase_admin;
SELECT extensions.pg_stat_statements_reset();
SELECT pg_stat_reset();
RESET ROLE;
SQL
}

if [ "$TARGET_DB" != "postgres" ]; then
    echo "ERROR: Supabase migrations are only supported against the postgres database" >&2
    exit 1
fi

PGVER=$(psql -v ON_ERROR_STOP=1 -X -d "$TARGET_DB" -tAc "SELECT current_setting('server_version_num')::int / 10000")
CURRENT_STAGE=environment-check
log_supabase "starting with postgres_major=${PGVER} custom_dir=${CUSTOM_MIGRATIONS_DIR} custom_file=${CUSTOM_MIGRATION_FILE}"
if [ "$MODE" != "custom-only" ] && [ "$PGVER" -lt 15 ]; then
    echo "ERROR: Supabase upstream migrations require PostgreSQL 15 or newer" >&2
    exit 1
fi

CURRENT_STAGE=ensure-custom-migrations-table
log_supabase "ensuring custom migration tracking table"
ensure_custom_migrations_table

bundle_applied=false
if [ "$MODE" != "custom-only" ]; then
    CURRENT_STAGE=validate-bundle-directories
    log_supabase "validating bundled Supabase migration directories"
    require_sql_dir "$INIT_SCRIPTS_DIR"
    require_sql_dir "$MIGRATIONS_DIR"

    CURRENT_STAGE=bootstrap-supabase-admin
    log_supabase "ensuring supabase_admin role exists"
    bootstrap_supabase_admin

    CURRENT_STAGE=ensure-schema-migrations-table
    log_supabase "ensuring schema_migrations table exists"
    ensure_schema_migrations_table

    CURRENT_STAGE=detect-latest-migration
    LATEST_MIGRATION_VERSION=$(latest_sql_version "$MIGRATIONS_DIR")
    log_supabase "latest bundled migration is ${LATEST_MIGRATION_VERSION}"
    if [ "$(is_migration_complete "$LATEST_MIGRATION_VERSION")" = "t" ]; then
        log_supabase "bundled Supabase migrations already applied"
    else
        CURRENT_STAGE=ensure-pgbouncer-auth-schema
        log_supabase "ensuring pgbouncer auth schema exists"
        ensure_pgbouncer_auth_schema

        CURRENT_STAGE=ensure-stat-extension-schema
        log_supabase "ensuring pg_stat_statements lives in extensions schema"
        ensure_stat_extension_schema

        CURRENT_STAGE=run-init-scripts
        log_supabase "running bundled init scripts as postgres"
        run_sql_dir_as_role postgres "$INIT_SCRIPTS_DIR"

        CURRENT_STAGE=run-migrations
        log_supabase "running bundled migrations as supabase_admin"
        run_sql_dir_as_role supabase_admin "$MIGRATIONS_DIR"
        bundle_applied=true
        log_supabase "bundled Supabase migrations finished"
    fi
fi

custom_applied=false
CURRENT_STAGE=apply-custom-sql-hooks
log_supabase "checking custom SQL hooks"
if apply_custom_sql_hooks; then
    custom_applied=true
    log_supabase "custom SQL hooks applied"
else
    log_supabase "no new custom SQL hooks applied"
fi

if [ "$bundle_applied" = true ] || [ "$custom_applied" = true ]; then
    CURRENT_STAGE=reset-stats
    log_supabase "resetting postgres stats after Supabase bootstrap changes"
    reset_stats
fi

CURRENT_STAGE=complete
if [ "$MODE" = "custom-only" ]; then
    if [ "$custom_applied" = true ]; then
        log_supabase "Supabase custom SQL applied successfully"
    else
        log_supabase "no new Supabase custom SQL to apply"
    fi
elif [ "$bundle_applied" = true ] && [ "$custom_applied" = true ]; then
    log_supabase "Supabase migration bundle and custom SQL applied successfully"
elif [ "$bundle_applied" = true ]; then
    log_supabase "Supabase migration bundle applied successfully"
elif [ "$custom_applied" = true ]; then
    log_supabase "Supabase custom SQL applied successfully"
else
    log_supabase "no new Supabase migrations to apply"
fi