#!/bin/bash

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# shellcheck disable=SC1091
source ./test_utils.sh

readonly PREFIX="demo-"
readonly UPGRADE_SCRIPT="python3 /scripts/inplace_upgrade.py"
readonly TIMEOUT=120
readonly SUPABASE_TIMEOUT=300


function cleanup() {
    stop_containers
    local -a containers
    mapfile -t containers < <(docker ps -q --filter="ancestor=${SPILO_TEST_IMAGE:-spilo}" --filter="name=${PREFIX}")
    if (( ${#containers[@]} > 0 )); then
        docker rm -f "${containers[@]}"
    fi
}

function get_non_leader() {
    declare -r container=$1

    if [[ "$container" == "${PREFIX}spilo1" ]]; then
        echo "${PREFIX}spilo2"
    else
        echo "${PREFIX}spilo1"
    fi
}

function find_leader() {
    local container=$1
    local silent=$2
    declare -r timeout=${3:-$TIMEOUT}
    local attempts=0

    while true; do
        leader=$(docker_exec "$container" 'patronictl list -f tsv' 2> /dev/null | awk '($4 == "Leader"){print $2}')
        if [[ -n "$leader" ]]; then
            [ -z "$silent" ] && echo "$leader"
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

function wait_backup() {
    local container=$1

    declare -r timeout=$TIMEOUT
    local attempts=0

    # speed up backup creation
    local backup_starter_pid
    backup_starter_pid=$(docker exec "$container" pgrep -f '/bin/bash /scripts/patroni_wait.sh -t 3600 -- envdir /run/etc/wal-e.d/env /scripts/postgres_backup.sh')
    if [ -n "$backup_starter_pid" ]; then
        docker exec "$container" pkill -P "$backup_starter_pid" -f 'sleep 60'
    fi

    log_info "Waiting for backup on S3..,"

    sleep 1

    docker_exec -i "$1" "psql -U postgres -c CHECKPOINT" > /dev/null 2>&1

    while true; do
        count=$(docker_exec "$container" "envdir /run/etc/wal-e.d/env wal-g backup-list" | grep -c ^base)
        if [[ "$count" -gt 0 ]]; then
            return
        fi
        ((attempts++))
        if [[ $attempts -ge $timeout ]]; then
            log_error "No backup produced after $timeout seconds"
        fi
        sleep 1
    done
}

function wait_query() {
    local container=$1
    local query=$2
    local result=$3
    declare -r timeout=${4:-$TIMEOUT}

    local attempts=0

    while true; do
        ret=$(docker_exec "$container" "psql -U postgres -tAc \"$query\"")
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

function wait_all_streaming() {
    local repl_count=${2:-2}
    log_info "Waiting for all replicas to start streaming from the leader ($1)..."
    wait_query "$1" "SELECT COUNT(*) FROM pg_stat_replication WHERE application_name LIKE 'spilo_'" "$repl_count"
}

function wait_zero_lag() {
    local repl_count=${2:-2}
    log_info "Waiting for all replicas to catch up with WAL replay..."
    wait_query "$1" "SELECT COUNT(*) FROM pg_stat_replication WHERE application_name LIKE 'spilo_' AND pg_catalog.pg_wal_lsn_diff(pg_catalog.pg_current_wal_lsn(), COALESCE(replay_lsn, '0/0')) < 16*1024*1024" "$repl_count"
}

function create_schema() {
    docker_exec -i "$1" "psql -U postgres" < schema.sql
}

function create_timescaledb() {
    docker_exec -i "$1" "psql -U postgres" < timescaledb.sql
}

function drop_timescaledb() {
    docker_exec "$1" "psql -U postgres -d test_db -c 'DROP EXTENSION timescaledb CASCADE'"
}

function test_inplace_upgrade_wrong_version() {
    docker_exec "$1" "PGVERSION=14 $UPGRADE_SCRIPT 3" 2>&1 | grep 'Upgrade is not required'
}

function test_inplace_upgrade_wrong_capacity() {
    docker_exec "$1" "PGVERSION=15 $UPGRADE_SCRIPT 4" 2>&1 | grep 'number of replicas does not match'
}

function test_successful_inplace_upgrade_to_15() {
    docker_exec "$1" "PGVERSION=15 $UPGRADE_SCRIPT 3"
}

function test_envdir_suffix() {
    docker_exec "$1" "cat /run/etc/wal-e.d/env/WALG_S3_PREFIX" | grep -q "$2$"
}

function test_envdir_updated_to_x() {
    for c in {1..3}; do
        test_envdir_suffix "${PREFIX}spilo$c" "$1" || return 1
    done
}

function test_failed_inplace_upgrade_big_replication_lag() {
    ! test_successful_inplace_upgrade_to_15 "$1"
}

function test_successful_inplace_upgrade_to_16() {
    docker_exec "$1" "PGVERSION=16 $UPGRADE_SCRIPT 3"
}

function test_successful_inplace_upgrade_to_17() {
    docker_exec "$1" "PGVERSION=17 $UPGRADE_SCRIPT 3"
}

function start_clone_with_walg_upgrade_container() {
    local ID=${1:-1}

    docker-compose run \
        -e SCOPE=upgrade \
        -e PGVERSION=15 \
        -e CLONE_SCOPE=demo \
        -e CLONE_METHOD=CLONE_WITH_WALG \
        -e CLONE_TARGET_TIME="$(next_minute)" \
        -e WALG_BACKUP_THRESHOLD_PERCENTAGE=80 \
        --name "${PREFIX}upgrade$ID" \
        -d "spilo$ID"
}

function start_clone_with_walg_upgrade_replica_container() {
    start_clone_with_walg_upgrade_container 2
}

function start_clone_with_walg_upgrade_to_17_container() {
    docker-compose run \
        -e SCOPE=upgrade3 \
        -e PGVERSION=17 \
        -e CLONE_SCOPE=demo \
        -e CLONE_PGVERSION=14 \
        -e CLONE_METHOD=CLONE_WITH_WALG \
        -e CLONE_TARGET_TIME="$(next_minute)" \
        --name "${PREFIX}upgrade4" \
        -d "spilo3"
}

function start_clone_with_walg_17_container() {
    docker-compose run \
        -e SCOPE=clone17 \
        -e PGVERSION=17 \
        -e CLONE_SCOPE=upgrade3 \
        -e CLONE_PGVERSION=17 \
        -e CLONE_METHOD=CLONE_WITH_WALG \
        -e CLONE_TARGET_TIME="$(next_hour)" \
        --name "${PREFIX}clone17" \
        -d "spilo3"
}

function start_clone_with_basebackup_upgrade_container() {
    local container=$1
    docker-compose run \
        -e SCOPE=upgrade2 \
        -e PGVERSION=16 \
        -e CLONE_SCOPE=upgrade \
        -e CLONE_METHOD=CLONE_WITH_BASEBACKUP \
        -e CLONE_HOST="$(docker_exec "$container" "hostname --ip-address")" \
        -e CLONE_PORT=5432 \
        -e CLONE_USER=standby \
        -e CLONE_PASSWORD=standby \
        --name "${PREFIX}upgrade3" \
        -d spilo3
}

function start_clone_with_hourly_log_rotation() {
    docker-compose run \
        -e SCOPE=hourlylogs \
        -e PGVERSION=17 \
        -e LOG_SHIP_HOURLY="true" \
        -e CLONE_SCOPE=upgrade2 \
        -e CLONE_PGVERSION=16 \
        -e CLONE_METHOD=CLONE_WITH_WALG \
        -e CLONE_TARGET_TIME="$(next_minute)" \
        --name "${PREFIX}hourlylogs" \
        -d "spilo3"
}

function verify_clone_upgrade() {
    local type=$2
    local from_version=$3
    local to_version=$4
    log_info "Waiting for clone with $type and upgrade $from_version->$to_version to complete..."
    find_leader "$1" 1
    wait_query "$1" "SELECT current_setting('server_version_num')::int/10000" "$to_version" 2> /dev/null
}

function verify_archive_mode_is_on() {
    archive_mode=$(docker_exec "$1" "psql -U postgres -tAc \"SHOW archive_mode\"")
    [ "$archive_mode" = "on" ]
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

function verify_general_extension_whitelist() {
    local missing
    missing=$(missing_available_whitelist_extensions "$1" \
        hypopg vector pg_repack pgaudit pgtap pg_hashids safeupdate http \
        rum index_advisor pgrouting postgis plpgsql_check)
    if [[ -n "$missing" ]]; then
        echo "Missing installed whitelist extensions: $missing"
        return 1
    fi
}

function verify_supabase_extension_whitelist_is_opt_in() {
    local whitelist
    whitelist=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SHOW extwlist.extensions\"")

    ! csv_has_extension "$whitelist" pg_graphql &&
    ! csv_has_extension "$whitelist" pg_jsonschema &&
    ! csv_has_extension "$whitelist" pgjwt &&
    ! csv_has_extension "$whitelist" pgmq &&
    ! csv_has_extension "$whitelist" supabase_vault &&
    ! csv_has_extension "$whitelist" wrappers
}

function verify_extwlist_custom_path() {
    local custom_path
    custom_path=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SHOW extwlist.custom_path\"")
    [ "$custom_path" = "/scripts" ]
}

function verify_default_preload_libraries() {
    local preload
    preload=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SHOW shared_preload_libraries\"")
    csv_has_extension "$preload" bg_mon &&
    csv_has_extension "$preload" pg_stat_statements &&
    csv_has_extension "$preload" pgextwlist &&
    csv_has_extension "$preload" pg_auth_mon &&
    csv_has_extension "$preload" set_user &&
    csv_has_extension "$preload" timescaledb &&
    csv_has_extension "$preload" pg_cron &&
    csv_has_extension "$preload" pg_stat_kcache &&
    csv_has_extension "$preload" pg_mon &&
    ! csv_has_extension "$preload" pgsodium &&
    ! csv_has_extension "$preload" pg_net &&
    ! csv_has_extension "$preload" pg_tle &&
    ! csv_has_extension "$preload" pg_stat_monitor &&
    ! csv_has_extension "$preload" pg_plan_filter &&
    ! csv_has_extension "$preload" supautils
}

function verify_supabase_extension_whitelist() {
    local whitelist
    whitelist=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SHOW extwlist.extensions\"")

    csv_has_extension "$whitelist" pg_graphql &&
    csv_has_extension "$whitelist" pg_jsonschema &&
    csv_has_extension "$whitelist" pgjwt &&
    csv_has_extension "$whitelist" pgmq &&
    csv_has_extension "$whitelist" supabase_vault &&
    csv_has_extension "$whitelist" wrappers
}

function verify_default_created_extensions() {
    local count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM pg_extension WHERE extname IN ('pg_auth_mon','pg_cron','file_fdw','pg_stat_statements','pg_stat_kcache','set_user','pg_mon')\"")
    [ "$count" = "7" ]
}

function verify_hourly_log_rotation() {
    log_rotation_age=$(docker_exec "$1" "psql -U postgres -tAc \"SHOW log_rotation_age\"")
    log_filename=$(docker_exec "$1" "psql -U postgres -tAc \"SHOW log_filename\"")
    # we expect 8x24 foreign tables and views + 8 views for daily logs and failed authentications
    postgres_log_ftables=$(docker_exec "$1" "psql -U postgres -tAc \"SELECT count(*) FROM pg_foreign_table WHERE ftrelid::regclass::text LIKE 'postgres_log_%'\"")
    postgres_log_views=$(docker_exec "$1" "psql -U postgres -tAc \"SELECT count(*) FROM pg_views WHERE viewname LIKE 'postgres_log_%'\"")
    postgres_failed_auth_views=$(docker_exec "$1" "psql -U postgres -tAc \"SELECT count(*) FROM pg_views WHERE viewname LIKE 'failed_authentication_%'\"")

    [ "$log_rotation_age" = "1h" ] && [ "$log_filename" = "postgresql-%u-%H.log" ] && [ "$postgres_log_ftables" -eq 192 ] && [ "$postgres_log_views" -eq 8 ] && [ "$postgres_failed_auth_views" -eq 200 ]
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

function verify_supabase_pgbouncer_auth() {
    local count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'pgbouncer' AND p.proname = 'get_auth'\"")
    [ "$count" = "1" ]
}

function verify_supabase_migration_marker() {
    local applied
    applied=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = '20260211120934_supabase_privileged_role')\"")
    [ "$applied" = "t" ]
}

function verify_supabase_publication() {
    local count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM pg_publication WHERE pubname = 'supabase_realtime'\"")
    [ "$count" = "1" ]
}

function verify_supabase_custom_hook_rows() {
    local count
    local applied_as_count
    count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM public.supabase_custom_hook_log WHERE hook_name IN ('001-directory-create','002-directory-extra','999-post-migration-file')\"")
    applied_as_count=$(docker_exec "$1" "psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM public.supabase_custom_hook_log WHERE hook_name IN ('001-directory-create','002-directory-extra','999-post-migration-file') AND applied_as = 'supabase_admin'\"")
    [ "$count" = "3" ] && [ "$applied_as_count" = "3" ]
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

function test_supabase_bootstrap() {
    local container=$1

    log_info "[TS8] Waiting for Supabase bootstrap on $container..."
    find_leader "$container" 1 "$SUPABASE_TIMEOUT"
    wait_query "$container" "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'supabase_admin'" "1" "$SUPABASE_TIMEOUT"

    run_test verify_supabase_wal_level "$container"
    run_test verify_supabase_roles "$container"
    run_test verify_supabase_schemas "$container"
    run_test verify_supabase_extensions "$container"
    run_test verify_supabase_extension_whitelist "$container"
    run_test verify_supabase_pgbouncer_auth "$container"
    run_test verify_supabase_migration_marker "$container"
    run_test verify_supabase_publication "$container"
}

function test_supabase_custom_sql() {
    local container=$1

    log_info "[TS9] Waiting for Supabase custom SQL bootstrap on $container..."
    find_leader "$container" 1 "$SUPABASE_TIMEOUT"
    wait_query "$container" "SELECT CASE WHEN to_regclass('public.supabase_custom_hook_log') IS NULL THEN 0 ELSE (SELECT COUNT(*) FROM public.supabase_custom_hook_log) END" "3" "$SUPABASE_TIMEOUT"

    run_test verify_supabase_custom_hook_rows "$container"
    run_test verify_supabase_custom_tracking "$container"
    run_test verify_supabase_custom_idempotence "$container"
}

function test_supabase_legacy_custom_sql() {
    local container=$1

    log_info "[TS10] Waiting for legacy Supabase custom SQL bootstrap on $container..."
    find_leader "$container" 1 "$SUPABASE_TIMEOUT"
    wait_query "$container" "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'supabase_admin'" "1" "$SUPABASE_TIMEOUT"
    wait_query "$container" "SELECT CASE WHEN to_regclass('public.supabase_custom_hook_log') IS NULL THEN 0 ELSE (SELECT COUNT(*) FROM public.supabase_custom_hook_log) END" "3" "$SUPABASE_TIMEOUT"

    run_test verify_supabase_custom_hook_rows "$container"
    run_test verify_supabase_custom_tracking "$container"
}

# TEST SUITE 1 - In-place major upgrade 14->15->16->17
# TEST SUITE 2 - Major upgrade 14->17 after wal-g clone (with CLONE_PGVERSION set)
# TEST SUITE 3 - PITR (clone with wal-g) with unreachable target (15+)
# TEST SUITE 4 - Major upgrade 14->15 after wal-g clone (no CLONE_PGVERSION)
# TEST SUITE 5 - Replica bootstrap with wal-g
# TEST SUITE 6 - Major upgrade 15->16 after clone with basebackup
# TEST SUITE 7 - Hourly log rotation
function test_spilo() {
    # TEST SUITE 1
    local container=$1

    run_test test_envdir_suffix "$container" 14
    run_test verify_default_preload_libraries "$container"
    run_test verify_general_extension_whitelist "$container"
    run_test verify_supabase_extension_whitelist_is_opt_in "$container"
    run_test verify_extwlist_custom_path "$container"
    run_test verify_default_created_extensions "$container"

    log_info "[TS1] Testing wrong upgrade setups"
    run_test test_inplace_upgrade_wrong_version "$container"
    run_test test_inplace_upgrade_wrong_capacity "$container"

    wait_all_streaming "$container"
    create_schema "$container" || exit 1 # incompatible upgrade exts, custom tbl with statistics and data
    # run_test test_failed_inplace_upgrade_big_replication_lag "$container"

    wait_zero_lag "$container"
    run_test verify_archive_mode_is_on "$container"
    wait_backup "$container"


    # TEST SUITE 2
    local upgrade3_container
    upgrade3_container=$(start_clone_with_walg_upgrade_to_17_container) # SCOPE=upgrade3 PGVERSION=17 CLONE: _SCOPE=demo _PGVERSION=14 _TARGET_TIME=<next_min>
    log_info "[TS2] Started $upgrade3_container for testing major upgrade 14->17 after clone with wal-g"


    # TEST SUITE 4
    local upgrade_container
    upgrade_container=$(start_clone_with_walg_upgrade_container) # SCOPE=upgrade PGVERSION=15 CLONE: _SCOPE=demo _TARGET_TIME=<next_min>
    log_info "[TS4] Started $upgrade_container for testing major upgrade 14->15 after clone with wal-g"


    # TEST SUITE 1
    # wait clone to finish and prevent timescale installation gets cloned
    find_leader "$upgrade3_container"
    find_leader "$upgrade_container"
    create_timescaledb "$container" # we don't install it at the beginning, as we do 14->17 in a clone

    log_info "[TS1] Testing in-place major upgrade 14->15"
    wait_zero_lag "$container"
    run_test test_successful_inplace_upgrade_to_15 "$container"
    wait_all_streaming "$container"
    run_test test_envdir_updated_to_x 15

    # TEST SUITE 2
    log_info "[TS2] Testing in-place major upgrade 14->17 after wal-g clone"
    run_test verify_clone_upgrade "$upgrade3_container" "wal-g" 14 17

    run_test verify_archive_mode_is_on "$upgrade3_container"
    wait_backup "$upgrade3_container"


    # TEST SUITE 3
    local clone17_container
    clone17_container=$(start_clone_with_walg_17_container) # SCOPE=clone17 CLONE: _SCOPE=upgrade3 _PGVERSION=17 _TARGET_TIME=<next_hour>
    log_info "[TS3] Started $clone17_container for testing point-in-time recovery (clone with wal-g) with unreachable target on 15+"


    # TEST SUITE 1
    log_info "[TS1] Testing in-place major upgrade 15->16"
    run_test test_successful_inplace_upgrade_to_16 "$container"
    wait_all_streaming "$container"
    run_test test_envdir_updated_to_x 16


    # TEST SUITE 3
    find_leader "$clone17_container"
    run_test verify_archive_mode_is_on "$clone17_container"


    # TEST SUITE 1
    wait_backup "$container"

    log_info "[TS1] Testing in-place major upgrade to 16->17"
    run_test test_successful_inplace_upgrade_to_17 "$container"
    wait_all_streaming "$container"
    run_test test_envdir_updated_to_x 17


    # TEST SUITE 4
    log_info "[TS4] Testing in-place major upgrade 14->15 after clone with wal-g"
    run_test verify_clone_upgrade "$upgrade_container" "wal-g" 14 15

    run_test verify_archive_mode_is_on "$upgrade_container"
    wait_backup "$upgrade_container"


    # TEST SUITE 5
    local upgrade_replica_container
    upgrade_replica_container=$(start_clone_with_walg_upgrade_replica_container)  # SCOPE=upgrade
    log_info "[TS5] Started $upgrade_replica_container for testing replica bootstrap with wal-g"


    # TEST SUITE 6
    local basebackup_container
    basebackup_container=$(start_clone_with_basebackup_upgrade_container "$upgrade_container")  # SCOPE=upgrade2 PGVERSION=16 CLONE: _SCOPE=upgrade
    log_info "[TS6] Started $basebackup_container for testing major upgrade 15->16 after clone with basebackup"
    wait_backup "$basebackup_container"

    # TEST SUITE 1
    # TEST SUITE 5
    log_info "[TS5] Waiting for postgres to start in the $upgrade_replica_container and stream from primary..."
    wait_all_streaming "$upgrade_container" 1

    # TEST SUITE 7
    local hourlylogs_container
    hourlylogs_container=$(start_clone_with_hourly_log_rotation "$upgrade_container")
    log_info "[TS7] Started $hourlylogs_container for testing hourly log rotation"

    # TEST SUITE 6
    log_info "[TS6] Testing in-place major upgrade 15->16 after clone with basebackup"
    run_test verify_clone_upgrade "$basebackup_container" "basebackup" 15 16
    run_test verify_archive_mode_is_on "$basebackup_container"

    # TEST SUITE 7
    find_leader "$hourlylogs_container"
    log_info "[TS7] Testing correct setup with hourly log rotation"
    run_test verify_hourly_log_rotation "$hourlylogs_container"
}

function main() {
    cleanup
    start_containers etcd spilo1 spilo2 spilo3

    log_info "Waiting for leader..."
    local leader
    leader="$PREFIX$(find_leader "${PREFIX}spilo1")"
    test_spilo "$leader"

    start_containers supabase supabase-custom supabase-legacy
    test_supabase_bootstrap "${PREFIX}supabase"
    test_supabase_custom_sql "${PREFIX}supabase-custom"
    test_supabase_legacy_custom_sql "${PREFIX}supabase-legacy"
}

trap cleanup QUIT TERM EXIT

main
