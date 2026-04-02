#!/bin/bash

set -euo pipefail

TARGET_DB=${1:-postgres}
SUPABASE_ROOT=/usr/share/supabase/postgres
INIT_SCRIPTS_DIR=${SUPABASE_ROOT}/migrations/db/init-scripts
MIGRATIONS_DIR=${SUPABASE_ROOT}/migrations/db/migrations

require_sql_dir() {
    local dir_path=$1

    if [ ! -d "$dir_path" ]; then
        echo "ERROR: missing Supabase migration directory: ${dir_path}" >&2
        exit 1
    fi
}

sql_files() {
    local dir_path=$1

    find "$dir_path" -maxdepth 1 -type f -name '*.sql' | LC_ALL=C sort
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

require_sql_dir "$INIT_SCRIPTS_DIR"
require_sql_dir "$MIGRATIONS_DIR"

PGVER=$(psql -v ON_ERROR_STOP=1 -X -d "$TARGET_DB" -tAc "SELECT current_setting('server_version_num')::int / 10000")
if [ "$PGVER" -lt 15 ]; then
    echo "ERROR: Supabase upstream migrations require PostgreSQL 15 or newer" >&2
    exit 1
fi

LATEST_MIGRATION_VERSION=$(latest_sql_version "$MIGRATIONS_DIR")
if [ "$(is_migration_complete "$LATEST_MIGRATION_VERSION")" = "t" ]; then
    echo "Supabase migration bundle already applied to ${TARGET_DB}"
    exit 0
fi

bootstrap_supabase_admin
ensure_schema_migrations_table
ensure_pgbouncer_auth_schema
ensure_stat_extension_schema
run_sql_dir_as_role postgres "$INIT_SCRIPTS_DIR"
run_sql_dir_as_role supabase_admin "$MIGRATIONS_DIR"
reset_stats

echo "Supabase migration bundle applied successfully to ${TARGET_DB}"