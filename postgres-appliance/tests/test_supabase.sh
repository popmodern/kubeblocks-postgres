#!/bin/bash

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# shellcheck disable=SC1091
source ./test_utils.sh

# Supabase tests also start the etcd service from docker-compose.yml, which
# uses SPILO_TEST_IMAGE. If only SPILO_SUPABASE_TEST_IMAGE is set, reuse it.
export SPILO_TEST_IMAGE=${SPILO_TEST_IMAGE:-${SPILO_SUPABASE_TEST_IMAGE:-spilo}}

readonly PREFIX="demo-"
readonly SUPABASE_TIMEOUT=300
readonly SUPABASE_PROGRESS_INTERVAL=10

resolve_supabase_modern_pgversion() {
    local image_ref=${SPILO_SUPABASE_TEST_IMAGE:-${SPILO_TEST_IMAGE:-spilo-supabase}}
    local max_pg_major

    max_pg_major=$(image_max_pg_major "$image_ref")
    if [[ -z "$max_pg_major" ]]; then
        log_error "Failed to determine supported PostgreSQL majors for ${image_ref}"
    fi
    if [[ "$max_pg_major" -lt 15 ]]; then
        log_error "Supabase tests require PostgreSQL 15 or newer, but image ${image_ref} supports up to ${max_pg_major}"
    fi

    printf '%s\n' "$max_pg_major"
}

function cleanup() {
    stop_containers
    local -a containers
    local container_id

    containers=()
    while IFS= read -r container_id; do
        containers+=("$container_id")
    done < <(docker ps -aq --filter="name=${PREFIX}")
    if (( ${#containers[@]} > 0 )); then
        docker rm -f "${containers[@]}"
    fi
}

function find_leader() {
    local container=$1
    local silent=$2
    declare -r timeout=${3:-$SUPABASE_TIMEOUT}
    local attempts=0
    local leader_name

    while true; do
        leader_name=$(docker_exec "$container" 'patronictl list -f tsv' 2> /dev/null | awk '($4 == "Leader"){print $2}')
        if [[ -n "$leader_name" ]]; then
            [ -z "$silent" ] && echo "$leader_name"
            return
        fi
        ((attempts++))
        if [[ $attempts -ge $timeout ]]; then
            docker logs "$container"
            log_error "Leader is not running after $timeout seconds"
        fi
        sleep 1
    done
}

function wait_query() {
    local container=$1
    local query=$2
    local result=$3
    declare -r timeout=${4:-$SUPABASE_TIMEOUT}

    local attempts=0
    local ret

    while true; do
        ret=$(docker_exec "$container" "psql -U postgres -d postgres -tAc \"$query\"" 2> /dev/null || true)
        if [[ "$ret" = "$result" ]]; then
            return 0
        fi
        ((attempts++))
        if [[ $attempts -ge $timeout ]]; then
            docker logs "$container"
            log_error "Query \"$query\" didn't return expected result $result after $timeout seconds"
        fi
        sleep 1
    done
}

function query_true() {
    local container=$1
    local query=$2
    local ret

    ret=$(docker_exec "$container" "psql -U postgres -d postgres -tAc \"$query\"" 2> /dev/null || true)
    [ "$ret" = "t" ]
}

function supabase_bundle_latest_version() {
    docker_exec "$1" "latest=\$(find /usr/share/supabase/postgres/migrations/db/migrations -maxdepth 1 -type f -name '*.sql' | LC_ALL=C sort | tail -n 1); if [ -n \"\$latest\" ]; then basename \"\$latest\" .sql; fi" 2> /dev/null || true
}

function supabase_bundle_marker_applied() {
    local container=$1
    local latest_version

    latest_version=$(supabase_bundle_latest_version "$container")
    [ -n "$latest_version" ] || return 1

    query_true "$container" "SELECT EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = '${latest_version}')"
}

function wait_for_condition() {
    local container=$1
    local description=$2
    local check_function=$3
    declare -r timeout=${4:-$SUPABASE_TIMEOUT}
    local attempts=0

    while true; do
        if "$check_function" "$container"; then
            return 0
        fi
        ((attempts++))
        if (( attempts % SUPABASE_PROGRESS_INTERVAL == 0 )); then
            report_supabase_progress "$container" "$description" "$attempts"
        fi
        if [[ $attempts -ge $timeout ]]; then
            report_supabase_progress "$container" "$description" "$attempts"
            docker logs "$container"
            log_error "Condition '$description' did not become true after $timeout seconds"
        fi
        sleep 1
    done
}

function report_supabase_progress() {
    local container=$1
    local description=$2
    local elapsed=$3
    local role_ready
    local schema_table_ready
    local bundle_marker_ready
    local publication_ready
    local custom_table_ready
    local custom_rows
    local event_trigger_count
    local wal_level
    local key_script
    local latest_bundle_version
    local latest_applied_version
    local recent_stage_logs

    role_ready=$(query_true "$container" "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_admin')" && echo yes || echo no)
    schema_table_ready=$(query_true "$container" "SELECT to_regclass('public.schema_migrations') IS NOT NULL" && echo yes || echo no)
    bundle_marker_ready=$(supabase_bundle_marker_applied "$container" && echo yes || echo no)
    publication_ready=$(query_true "$container" "SELECT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')" && echo yes || echo no)
    custom_table_ready=$(query_true "$container" "SELECT to_regclass('public.spilo_supabase_custom_migrations') IS NOT NULL" && echo yes || echo no)
    custom_rows=$(docker_exec "$container" "psql -U postgres -d postgres -tAc \"SELECT CASE WHEN to_regclass('public.spilo_supabase_custom_migrations') IS NULL THEN -1 ELSE (SELECT COUNT(*) FROM public.spilo_supabase_custom_migrations) END\"" 2> /dev/null || true)
    event_trigger_count=$(docker_exec "$container" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM pg_event_trigger WHERE evtname IN ('issue_pg_graphql_access','issue_pg_net_access','issue_pg_cron_access')\"" 2> /dev/null || true)
    wal_level=$(docker_exec "$container" "psql -U postgres -d postgres -tAc \"SHOW wal_level\"" 2> /dev/null || true)
    key_script=$(docker_exec "$container" "psql -U postgres -d postgres -tAc \"SELECT current_setting('pgsodium.getkey_script', true)\"" 2> /dev/null || true)
    latest_bundle_version=$(supabase_bundle_latest_version "$container")
    latest_applied_version=$(docker_exec "$container" "psql -U postgres -d postgres -tAc \"SELECT CASE WHEN to_regclass('public.schema_migrations') IS NULL THEN '' ELSE COALESCE((SELECT MAX(version) FROM public.schema_migrations), '') END\"" 2> /dev/null || true)
    recent_stage_logs=$(docker logs --tail 80 "$container" 2>&1 | grep -E 'Supabase post-init:|Supabase migrations:' | tail -n 6 || true)

    log_info "[progress] ${container} waiting for ${description} (${elapsed}s elapsed)"
    log_info "[progress] role=${role_ready} schema_migrations=${schema_table_ready} bundle_marker=${bundle_marker_ready} publication=${publication_ready} wal_level=${wal_level:-unknown} key_script=${key_script:-unset} bundle_latest=${latest_bundle_version:-unknown} applied_latest=${latest_applied_version:-none} custom_table=${custom_table_ready} custom_rows=${custom_rows:-unknown} event_triggers=${event_trigger_count:-unknown}"
    if [[ -n "$recent_stage_logs" ]]; then
        printf '%s\n' "$recent_stage_logs"
    else
        log_info "[progress] no Supabase stage logs from the container yet"
    fi
}

function supabase_bundle_ready() {
    local container=$1

    query_true "$container" "SELECT to_regclass('public.schema_migrations') IS NOT NULL" &&
    supabase_bundle_marker_applied "$container" &&
    query_true "$container" "SELECT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')"
}

function wait_supabase_bundle_ready() {
    wait_for_condition "$1" "supabase bundle ready" supabase_bundle_ready
}

function supabase_custom_ready() {
    local container=$1

    supabase_bundle_ready "$container" &&
    query_true "$container" "SELECT to_regclass('public.spilo_supabase_custom_migrations') IS NOT NULL" &&
    [ "$(docker_exec "$container" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM public.spilo_supabase_custom_migrations WHERE identifier IN ('dir:001-directory-create.sql','dir:002-directory-extra.sql','file:/etc/postgresql.schema.sql')\"" 2> /dev/null || true)" = "3" ]
}

function wait_supabase_custom_ready() {
    wait_for_condition "$1" "supabase custom SQL ready" supabase_custom_ready
}

function supabase_legacy_ready() {
    local container=$1

    query_true "$container" "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_admin')" &&
    [ "$(docker_exec "$container" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE (e.extname = 'uuid-ossp' AND n.nspname = 'extensions') OR (e.extname = 'pgcrypto' AND n.nspname = 'extensions') OR (e.extname = 'pgjwt' AND n.nspname = 'extensions')\"" 2> /dev/null || true)" = "3" ] &&
    [ "$(docker_exec "$container" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM pg_event_trigger WHERE evtname IN ('issue_pg_graphql_access','issue_pg_net_access','issue_pg_cron_access')\"" 2> /dev/null || true)" = "3" ]
}

function wait_supabase_legacy_ready() {
    wait_for_condition "$1" "supabase legacy ready" supabase_legacy_ready
}

function supabase_legacy_custom_ready() {
    local container=$1

    supabase_legacy_ready "$container" &&
    query_true "$container" "SELECT to_regclass('public.spilo_supabase_custom_migrations') IS NOT NULL" &&
    [ "$(docker_exec "$container" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM public.spilo_supabase_custom_migrations WHERE identifier IN ('dir:001-directory-create.sql','dir:002-directory-extra.sql','file:/etc/postgresql.schema.sql')\"" 2> /dev/null || true)" = "3" ]
}

function wait_supabase_legacy_custom_ready() {
    wait_for_condition "$1" "supabase legacy custom SQL ready" supabase_legacy_custom_ready
}

function csv_has_extension() {
    local csv=$1
    local extension_name=$2

    printf '%s\n' "$csv" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -qx "$extension_name"
}

function missing_available_whitelist_extensions() {
    local container=$1
    shift
    local sql_extensions=''
    local extension_name

    for extension_name in "$@"; do
        if [[ -n "$sql_extensions" ]]; then
            sql_extensions+="," 
        fi
        sql_extensions+="'${extension_name}'"
    done

    docker_exec "$container" "psql -U postgres -d postgres -tAc \"
        WITH expected(name) AS (
            SELECT unnest(ARRAY[${sql_extensions}])
        ), allowed(name) AS (
            SELECT btrim(value)
            FROM unnest(string_to_array(current_setting('extwlist.extensions'), ',')) AS value
        )
        SELECT COALESCE(string_agg(expected.name, ',' ORDER BY expected.name), '')
        FROM expected
        WHERE EXISTS (
            SELECT 1
            FROM pg_available_extensions
            WHERE name = expected.name
        )
        AND NOT EXISTS (
            SELECT 1
            FROM allowed
            WHERE allowed.name = expected.name
        )\""
}

function verify_supabase_wal_level() {
    local wal_level
    wal_level=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SHOW wal_level\"")
    [ "$wal_level" = "logical" ]
}

function verify_supabase_roles() {
    local count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM pg_roles WHERE rolname IN ('anon','authenticated','authenticator','dashboard_user','pgbouncer','service_role','supabase_admin','supabase_auth_admin','supabase_etl_admin','supabase_read_only_user','supabase_replication_admin','supabase_storage_admin')\"")
    [ "$count" = "12" ]
}

function verify_supabase_schemas() {
    local count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name IN ('auth','extensions','graphql','graphql_public','pgbouncer','realtime','storage','vault')\"")
    [ "$count" = "8" ]
}

function verify_supabase_extensions() {
    local count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE (e.extname = 'pg_stat_statements' AND n.nspname = 'extensions') OR (e.extname = 'pg_graphql' AND n.nspname = 'graphql') OR (e.extname = 'pgcrypto' AND n.nspname = 'extensions') OR (e.extname = 'supabase_vault' AND n.nspname = 'vault') OR (e.extname = 'uuid-ossp' AND n.nspname = 'extensions')\"")
    [ "$count" = "5" ]
}

function verify_supabase_extension_whitelist() {
    local whitelist
    local missing
    local wrappers_available

    whitelist=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SHOW extwlist.extensions\"")
    missing=$(missing_available_whitelist_extensions "$1" pg_graphql pg_jsonschema pgjwt pgmq supabase_vault wrappers)
    wrappers_available=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'wrappers')\"")

    csv_has_extension "$whitelist" pg_graphql &&
    csv_has_extension "$whitelist" pg_jsonschema &&
    csv_has_extension "$whitelist" pgjwt &&
    csv_has_extension "$whitelist" pgmq &&
    csv_has_extension "$whitelist" supabase_vault &&
    { [ "$wrappers_available" != "t" ] || csv_has_extension "$whitelist" wrappers; } &&
    [ -z "$missing" ]
}

function verify_supabase_pgbouncer_auth() {
    local count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'pgbouncer' AND p.proname = 'get_auth'\"")
    [ "$count" = "1" ]
}

function verify_supabase_migration_marker() {
    local applied

    applied=$(supabase_bundle_marker_applied "$1" && echo t || echo f)
    [ "$applied" = "t" ]
}

function verify_supabase_publication() {
    local count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM pg_publication WHERE pubname = 'supabase_realtime'\"")
    [ "$count" = "1" ]
}

function verify_supabase_bootstrap_role_name() {
    local bootstrap_role

    bootstrap_role=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT rolname FROM pg_roles WHERE oid = 10\"")
    [ "$bootstrap_role" = "supabase_admin" ]
}

function verify_supabase_postgres_demoted() {
    local postgres_superuser

    postgres_superuser=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT rolsuper FROM pg_roles WHERE rolname = 'postgres'\"")
    [ "$postgres_superuser" = "f" ]
}

function verify_supabase_custom_hook_rows() {
    local count
    local applied_as_count
    local session_user_count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM public.supabase_custom_hook_log WHERE hook_name IN ('001-directory-create','002-directory-extra','999-post-migration-file')\"")
    applied_as_count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM public.supabase_custom_hook_log WHERE hook_name IN ('001-directory-create','002-directory-extra','999-post-migration-file') AND applied_as = 'supabase_admin'\"")
    session_user_count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM public.supabase_custom_hook_log WHERE hook_name IN ('001-directory-create','002-directory-extra','999-post-migration-file') AND applied_session_user = 'supabase_admin'\"")
    [ "$count" = "3" ] && [ "$applied_as_count" = "3" ] && [ "$session_user_count" = "3" ]
}

function verify_supabase_custom_tracking() {
    local count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM public.spilo_supabase_custom_migrations WHERE identifier IN ('dir:001-directory-create.sql','dir:002-directory-extra.sql','file:/etc/postgresql.schema.sql')\"")
    [ "$count" = "3" ]
}

function verify_supabase_custom_idempotence() {
    local before_count
    local after_count

    before_count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM public.spilo_supabase_custom_migrations\"")
    docker_exec "$1" "/scripts/run_supabase_migrations.sh postgres"
    after_count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM public.spilo_supabase_custom_migrations\"")

    [ "$before_count" = "$after_count" ] && [ "$after_count" = "3" ]
}

function verify_supabase_legacy_roles() {
    local count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM pg_roles WHERE rolname IN ('anon','authenticated','authenticator','dashboard_user','service_role','supabase_admin','supabase_auth_admin','supabase_functions_admin','supabase_storage_admin')\"")
    [ "$count" = "9" ]
}

function verify_supabase_legacy_schemas() {
    local count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name IN ('extensions','graphql','graphql_public','supabase_functions','supabase_migrations')\"")
    [ "$count" = "5" ]
}

function verify_supabase_legacy_extensions() {
    local count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE (e.extname = 'uuid-ossp' AND n.nspname = 'extensions') OR (e.extname = 'pgcrypto' AND n.nspname = 'extensions') OR (e.extname = 'pgjwt' AND n.nspname = 'extensions')\"")
    [ "$count" = "3" ]
}

function verify_supabase_legacy_event_triggers() {
    local count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM pg_event_trigger WHERE evtname IN ('issue_pg_graphql_access','issue_pg_net_access','issue_pg_cron_access')\"")
    [ "$count" = "3" ]
}

function verify_supabase_legacy_search_path() {
    local search_path
    search_path=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SHOW search_path\"")
    [ "$search_path" = "public, extensions" ]
}

function run_supabase_bundle_assertions() {
    local container=$1

    run_test verify_supabase_wal_level "$container"
    run_test verify_supabase_roles "$container"
    run_test verify_supabase_schemas "$container"
    run_test verify_supabase_extensions "$container"
    run_test verify_supabase_extension_whitelist "$container"
    run_test verify_supabase_pgbouncer_auth "$container"
    run_test verify_supabase_migration_marker "$container"
    run_test verify_supabase_publication "$container"
    run_test verify_supabase_bootstrap_role_name "$container"
    run_test verify_supabase_postgres_demoted "$container"
}

function run_supabase_legacy_assertions() {
    local container=$1

    run_test verify_supabase_wal_level "$container"
    run_test verify_supabase_legacy_roles "$container"
    run_test verify_supabase_legacy_schemas "$container"
    run_test verify_supabase_legacy_extensions "$container"
    run_test verify_supabase_legacy_event_triggers "$container"
    run_test verify_supabase_legacy_search_path "$container"
}

function test_supabase_bootstrap() {
    local container=$1

    log_info "[TS8] Waiting for Patroni leader on $container..."
    find_leader "$container" 1 "$SUPABASE_TIMEOUT"
    log_info "[TS8] Waiting for full Supabase bootstrap on $container..."
    wait_supabase_bundle_ready "$container"

    run_supabase_bundle_assertions "$container"
}

function test_supabase_custom_sql() {
    local container=$1

    log_info "[TS9] Waiting for Patroni leader on $container..."
    find_leader "$container" 1 "$SUPABASE_TIMEOUT"
    log_info "[TS9] Waiting for Supabase bundle and custom SQL on $container..."
    wait_supabase_custom_ready "$container"

    run_supabase_bundle_assertions "$container"
    run_test verify_supabase_custom_hook_rows "$container"
    run_test verify_supabase_custom_tracking "$container"
    run_test verify_supabase_custom_idempotence "$container"
}

function test_supabase_legacy_bootstrap() {
    local container=$1

    log_info "[TS10] Waiting for Patroni leader on $container..."
    find_leader "$container" 1 "$SUPABASE_TIMEOUT"
    log_info "[TS10] Waiting for PG14 legacy Supabase bootstrap on $container..."
    wait_supabase_legacy_ready "$container"

    run_supabase_legacy_assertions "$container"
}

function test_supabase_legacy_custom_sql() {
    local container=$1

    log_info "[TS11] Waiting for Patroni leader on $container..."
    find_leader "$container" 1 "$SUPABASE_TIMEOUT"
    log_info "[TS11] Waiting for PG14 legacy Supabase custom SQL on $container..."
    wait_supabase_legacy_custom_ready "$container"

    run_supabase_legacy_assertions "$container"
    run_test verify_supabase_custom_hook_rows "$container"
    run_test verify_supabase_custom_tracking "$container"
}

function main() {
    cleanup
    export SUPABASE_MODERN_PGVERSION
    SUPABASE_MODERN_PGVERSION=$(resolve_supabase_modern_pgversion)
    log_info "Using PostgreSQL ${SUPABASE_MODERN_PGVERSION} for modern Supabase test containers"
    start_containers etcd supabase supabase-custom supabase-legacy supabase-legacy-custom

    test_supabase_bootstrap "${PREFIX}supabase"
    test_supabase_custom_sql "${PREFIX}supabase-custom"
    test_supabase_legacy_bootstrap "${PREFIX}supabase-legacy"
    test_supabase_legacy_custom_sql "${PREFIX}supabase-legacy-custom"
}

trap cleanup QUIT TERM EXIT

main