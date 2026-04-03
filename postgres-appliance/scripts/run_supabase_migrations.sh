#!/bin/bash

set -euo pipefail

MODE=full
ACTION=apply

while [ $# -gt 0 ]; do
    case "$1" in
        --custom-only)
            MODE=custom-only
            shift
            ;;
        --plan|--list)
            ACTION=plan
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "ERROR: unsupported option: $1" >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

TARGET_DB=${1:-postgres}
SUPABASE_ROOT=/usr/share/supabase/postgres
INIT_SCRIPTS_DIR=${SUPABASE_ROOT}/migrations/db/init-scripts
MIGRATIONS_DIR=${SUPABASE_ROOT}/migrations/db/migrations
INIT_SCRIPTS_BUNDLE=${INIT_SCRIPTS_DIR}.bundle.sql
MIGRATIONS_BUNDLE=${MIGRATIONS_DIR}.bundle.sql
CUSTOM_MIGRATIONS_DIR=${SUPABASE_CUSTOM_MIGRATIONS_DIR:-/etc/postgresql.schema.d}
CUSTOM_MIGRATION_FILE=${SUPABASE_CUSTOM_MIGRATION_FILE:-/etc/postgresql.schema.sql}
CURRENT_STAGE=initialization

log_supabase() {
    echo "Supabase migrations: mode=${MODE} target_db=${TARGET_DB} stage=${CURRENT_STAGE} - $*"
}

plan_log() {
    echo "Supabase migration plan: $*"
}

report_error() {
    local exit_code=$?

    echo "ERROR: Supabase migrations failed: mode=${MODE} target_db=${TARGET_DB} stage=${CURRENT_STAGE} exit=${exit_code}" >&2
    exit "$exit_code"
}

trap report_error ERR

psql_target_db() {
    psql -v ON_ERROR_STOP=1 -X -d "$TARGET_DB" "$@"
}

# shellcheck disable=SC2120
psql_bootstrap_superuser_db() {
    local role_name

    role_name=$(bootstrap_superuser_name)
    if [ -z "$role_name" ]; then
        echo "ERROR: failed to determine bootstrap superuser role name" >&2
        exit 1
    fi

    psql -v ON_ERROR_STOP=1 -X -U "$role_name" -d "$TARGET_DB" "$@"
}

psql_target_db_as() {
    local role_name=$1
    shift

    psql -v ON_ERROR_STOP=1 -X -U "$role_name" -d "$TARGET_DB" "$@"
}

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
    local manifest_path="${dir_path}.manifest"

    if [ -f "$manifest_path" ]; then
        cat "$manifest_path"
        return 0
    fi

    find "$dir_path" -maxdepth 1 -type f -name '*.sql' | LC_ALL=C sort
}

optional_sql_files() {
    local dir_path=$1

    if [ ! -d "$dir_path" ]; then
        return 0
    fi

    sql_files "$dir_path"
}

plan_tags() {
    local file_name=$1
    local -a tags

    tags=()

    case "$file_name" in
        *postgres*|*role*|*grant*|*revoke*|*search_path*|*lock_timeout*)
            tags+=(role-privileges)
            ;;
    esac

    case "$file_name" in
        *auth*|*storage*|*realtime*)
            tags+=(schema-data-model)
            ;;
    esac

    case "$file_name" in
        *pg_graphql*|*pg_net*|*pgsodium*|*vault*|*orioledb*|*pgmq*|*pgrst*|*pgbouncer*|*safeupdate*)
            tags+=(extension-runtime)
            ;;
    esac

    case "$file_name" in
        *trigger*|*post-setup*)
            tags+=(event-triggers)
            ;;
    esac

    case "$file_name" in
        *subscription*|*predefined_role*|*with_admin*|*privileged_role*)
            tags+=(pg-version-sensitive)
            ;;
    esac

    if [ ${#tags[@]} -eq 0 ]; then
        tags+=(general)
    fi

    local tag
    local joined_tags=''
    for tag in "${tags[@]}"; do
        if [ -n "$joined_tags" ]; then
            joined_tags+=','
        fi
        joined_tags+="$tag"
    done

    printf '%s' "$joined_tags"
}

print_plan_section() {
    local title=$1
    local role_name=$2
    local file_list_command=$3
    local sql_file
    local file_name
    local tags
    local count=0

    plan_log "$title (run as ${role_name})"
    while IFS= read -r sql_file; do
        [ -n "$sql_file" ] || continue
        file_name=$(basename "$sql_file")
        tags=$(plan_tags "$file_name")
        printf '  - %s [%s]\n' "$file_name" "$tags"
        count=$((count + 1))
    done < <(eval "$file_list_command")

    if [ "$count" -eq 0 ]; then
        printf '  - none\n'
    fi
}

print_migration_plan() {
    require_sql_dir "$INIT_SCRIPTS_DIR"
    require_sql_dir "$MIGRATIONS_DIR"

    plan_log "source bundle root ${SUPABASE_ROOT}"
    plan_log "execution order follows upstream supabase/postgres migrate.sh: init-scripts as postgres, bootstrap helper SQL as postgres, migrations as supabase_admin, then custom hooks"
    print_plan_section "bundled init-scripts" postgres "sql_files \"$INIT_SCRIPTS_DIR\""
    plan_log "bootstrap helper SQL (run as postgres)"
    printf '  - pgbouncer auth schema [extension-runtime,role-privileges]\n'
    printf '  - pg_stat_statements schema normalization [extension-runtime]\n'
    print_plan_section "bundled migrations" supabase_admin "sql_files \"$MIGRATIONS_DIR\""
    print_plan_section "custom SQL hooks from directory" supabase_admin "optional_sql_files \"$CUSTOM_MIGRATIONS_DIR\""

    plan_log "custom SQL hook file (run as supabase_admin)"
    if [ -f "$CUSTOM_MIGRATION_FILE" ]; then
        printf '  - %s [%s]\n' "$(basename "$CUSTOM_MIGRATION_FILE")" "$(plan_tags "$(basename "$CUSTOM_MIGRATION_FILE")")"
    else
        printf '  - none\n'
    fi

    plan_log "high-risk categories to inspect first: role-privileges, extension-runtime, pg-version-sensitive"
}

latest_sql_version() {
    local dir_path=$1
    local last_file

    last_file=$(sql_files "$dir_path" | tail -n 1)
    basename "$last_file" .sql
}

is_migration_complete() {
    local latest_version=$1

    psql_target_db -tAc "SELECT to_regclass('public.schema_migrations') IS NOT NULL AND EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = '${latest_version}')"
}

bootstrap_supabase_admin() {
    # shellcheck disable=SC2119
    psql_bootstrap_superuser_db <<'SQL'
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

bootstrap_superuser_name() {
    psql_target_db -tAc "SELECT rolname FROM pg_roles WHERE oid = 10"
}

ensure_upstream_supabase_role_layout() {
    local bootstrap_role
    local swap_role=spilo_supabase_role_swapper

    bootstrap_role=$(bootstrap_superuser_name)
    case "$bootstrap_role" in
        supabase_admin)
            return 0
            ;;
        postgres)
            ;;
        '')
            echo "ERROR: failed to determine bootstrap superuser role name" >&2
            exit 1
            ;;
        *)
            echo "ERROR: unsupported bootstrap superuser role name: ${bootstrap_role}" >&2
            exit 1
            ;;
    esac

    # shellcheck disable=SC2119
    psql_bootstrap_superuser_db <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${swap_role}') THEN
        EXECUTE 'CREATE ROLE ${swap_role} WITH LOGIN SUPERUSER';
    ELSE
        EXECUTE 'ALTER ROLE ${swap_role} WITH LOGIN SUPERUSER';
    END IF;
END
\$\$;
SQL

    # shellcheck disable=SC2119
    psql_bootstrap_superuser_db <<SQL
SET SESSION AUTHORIZATION ${swap_role};
ALTER ROLE postgres RENAME TO supabase_admin__bootstrap_tmp;
ALTER ROLE supabase_admin RENAME TO postgres;
ALTER ROLE supabase_admin__bootstrap_tmp RENAME TO supabase_admin;
ALTER DATABASE postgres OWNER TO postgres;
RESET SESSION AUTHORIZATION;
DROP ROLE IF EXISTS ${swap_role};
SQL
}

ensure_schema_migrations_table() {
    psql_target_db_as postgres <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
    version character varying(255) PRIMARY KEY
);
SQL
}

ensure_custom_migrations_table() {
    # shellcheck disable=SC2119
    psql_bootstrap_superuser_db <<'SQL'
CREATE TABLE IF NOT EXISTS public.spilo_supabase_custom_migrations (
    identifier text PRIMARY KEY,
    checksum text NOT NULL,
    applied_at timestamp with time zone NOT NULL DEFAULT now()
);
SQL
}

ensure_pgbouncer_auth_schema() {
    psql_target_db_as postgres <<'SQL'
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
    psql_target_db_as postgres <<'SQL'
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

ensure_postgres_demoted() {
    psql_target_db_as supabase_admin <<'SQL'
ALTER ROLE postgres WITH NOSUPERUSER;
SQL
}

run_tracked_sql_file() {
    local role_name=$1
    local sql_file=$2
    local version_name
    local already_applied

    version_name=$(basename "$sql_file" .sql)
    already_applied=$(psql_target_db -tAc "SELECT EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = '${version_name}')")
    if [ "$already_applied" = "t" ]; then
        return 0
    fi

    echo "Running Supabase migration ${version_name} as ${role_name}"
    psql_target_db_as "$role_name" <<SQL
BEGIN;
\i ${sql_file}
INSERT INTO public.schema_migrations(version) VALUES ('${version_name}');
COMMIT;
SQL
}

bundle_script_for_dir() {
    local dir_path=$1

    case "$dir_path" in
        "$INIT_SCRIPTS_DIR")
            printf '%s' "$INIT_SCRIPTS_BUNDLE"
            ;;
        "$MIGRATIONS_DIR")
            printf '%s' "$MIGRATIONS_BUNDLE"
            ;;
        *)
            return 1
            ;;
    esac
}

run_tracked_bundle_script() {
    local role_name=$1
    local dir_path=$2
    local bundle_script

    bundle_script=$(bundle_script_for_dir "$dir_path") || return 1
    [ -f "$bundle_script" ] || return 1

    psql_target_db_as "$role_name" -f "$bundle_script"
}

run_sql_dir_as_role() {
    local role_name=$1
    local dir_path=$2
    local sql_file

    if run_tracked_bundle_script "$role_name" "$dir_path"; then
        return 0
    fi

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
    already_applied=$(psql_target_db -tAc "SELECT EXISTS (SELECT 1 FROM public.spilo_supabase_custom_migrations WHERE identifier = '${escaped_identifier}' AND checksum = '${escaped_checksum}')")
    if [ "$already_applied" = "t" ]; then
        return 1
    fi

    echo "Running Supabase custom SQL ${identifier} on ${TARGET_DB}"
    psql_target_db_as supabase_admin <<SQL
BEGIN;
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
    psql_target_db_as supabase_admin <<'SQL' || true
SELECT extensions.pg_stat_statements_reset();
SELECT pg_stat_reset();
SQL
}

if [ "$ACTION" = "plan" ]; then
    print_migration_plan
    exit 0
fi

if [ "$TARGET_DB" != "postgres" ]; then
    echo "ERROR: Supabase migrations are only supported against the postgres database" >&2
    exit 1
fi

PGVER=$(psql_target_db -tAc "SELECT current_setting('server_version_num')::int / 10000")
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

    CURRENT_STAGE=normalize-upstream-role-layout
    log_supabase "aligning bootstrap role names with upstream Supabase expectations"
    ensure_upstream_supabase_role_layout

    CURRENT_STAGE=ensure-schema-migrations-table
    log_supabase "ensuring schema_migrations table exists"
    ensure_schema_migrations_table

    CURRENT_STAGE=detect-latest-migration
    LATEST_MIGRATION_VERSION=$(latest_sql_version "$MIGRATIONS_DIR")
    log_supabase "latest bundled migration is ${LATEST_MIGRATION_VERSION}"
    if [ "$(is_migration_complete "$LATEST_MIGRATION_VERSION")" = "t" ]; then
        log_supabase "bundled Supabase migrations already applied"
    else
        CURRENT_STAGE=run-init-scripts
        log_supabase "running bundled init scripts as postgres"
        run_sql_dir_as_role postgres "$INIT_SCRIPTS_DIR"

        CURRENT_STAGE=ensure-pgbouncer-auth-schema
        log_supabase "ensuring pgbouncer auth schema exists"
        ensure_pgbouncer_auth_schema

        CURRENT_STAGE=ensure-stat-extension-schema
        log_supabase "ensuring pg_stat_statements lives in extensions schema"
        ensure_stat_extension_schema

        CURRENT_STAGE=run-migrations
        log_supabase "running bundled migrations as supabase_admin"
        run_sql_dir_as_role supabase_admin "$MIGRATIONS_DIR"
        bundle_applied=true
        log_supabase "bundled Supabase migrations finished"
    fi

    CURRENT_STAGE=demote-postgres-role
    log_supabase "ensuring postgres role is no longer a superuser"
    ensure_postgres_demoted
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