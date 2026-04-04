#!/bin/bash

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

export PGOPTIONS="-c synchronous_commit=local -c search_path=pg_catalog"

SUPABASE_EXTENSIONS_FLAG_FILE=/run/supabase-extensions-enabled
SUPABASE_INIT_FLAG_FILE=/run/supabase-init-enabled

flag_file_enabled() {
    [ -r "$1" ] && [ "$(tr -d '[:space:]' < "$1" 2> /dev/null)" = "true" ]
}

flag_file_status() {
    if flag_file_enabled "$1"; then
        echo present
    else
        echo absent
    fi
}

log_supabase_post_init() {
    echo "Supabase post-init: db=$2 pgver=$PGVER extensions=${SUPABASE_EXTENSIONS_ENABLED}(${SUPABASE_EXTENSIONS_SOURCE}) init=${SUPABASE_INIT_ENABLED}(${SUPABASE_INIT_SOURCE}) wal_level=${SUPABASE_WAL_LEVEL:-unknown} key_script=${SUPABASE_PGSODIUM_GETKEY_SCRIPT:-unset} - $1"
}

PGVER=$(psql -d "$2" -XtAc "SELECT pg_catalog.current_setting('server_version_num')::int/10000")
SUPABASE_EXTENSIONS_ENV=${ENABLE_SUPABASE_EXTENSIONS:-}
SUPABASE_INIT_ENV=${ENABLE_SUPABASE_INIT:-}
SUPABASE_PGSODIUM_GETKEY_SCRIPT=$(psql -d "$2" -XtAc "SELECT current_setting('pgsodium.getkey_script', true)")
SUPABASE_WAL_LEVEL=$(psql -d "$2" -XtAc "SHOW wal_level")

if [ -n "$SUPABASE_EXTENSIONS_ENV" ]; then
    SUPABASE_EXTENSIONS_ENABLED=$SUPABASE_EXTENSIONS_ENV
    SUPABASE_EXTENSIONS_SOURCE='env'
elif flag_file_enabled "$SUPABASE_EXTENSIONS_FLAG_FILE"; then
    SUPABASE_EXTENSIONS_ENABLED=true
    SUPABASE_EXTENSIONS_SOURCE='flag-file'
elif [ "$SUPABASE_PGSODIUM_GETKEY_SCRIPT" = "/scripts/pgsodium_getkey.sh" ]; then
    SUPABASE_EXTENSIONS_ENABLED=true
    SUPABASE_EXTENSIONS_SOURCE='inferred'
else
    SUPABASE_EXTENSIONS_ENABLED=false
    SUPABASE_EXTENSIONS_SOURCE='inferred'
fi

if [ -n "$SUPABASE_INIT_ENV" ]; then
    SUPABASE_INIT_ENABLED=$SUPABASE_INIT_ENV
    SUPABASE_INIT_SOURCE='env'
elif flag_file_enabled "$SUPABASE_INIT_FLAG_FILE"; then
    SUPABASE_INIT_ENABLED=true
    SUPABASE_INIT_SOURCE='flag-file'
elif [ "$SUPABASE_EXTENSIONS_ENABLED" = "true" ] && [ "$SUPABASE_WAL_LEVEL" = "logical" ]; then
    SUPABASE_INIT_ENABLED=true
    SUPABASE_INIT_SOURCE='inferred'
else
    SUPABASE_INIT_ENABLED=false
    SUPABASE_INIT_SOURCE=inferred
fi

if [ "$PGVER" -lt 17 ]; then
    RESET_ARGS="oid, oid, bigint"
else
    RESET_ARGS="oid, oid, bigint, bool"
fi

log_supabase_post_init "resolved bootstrap settings" "$2"
echo "Supabase post-init: db=$2 env_extensions=${SUPABASE_EXTENSIONS_ENV:-unset} env_init=${SUPABASE_INIT_ENV:-unset} flag_extensions=$(flag_file_status "$SUPABASE_EXTENSIONS_FLAG_FILE") flag_init=$(flag_file_status "$SUPABASE_INIT_FLAG_FILE") wal_level=${SUPABASE_WAL_LEVEL:-unknown} key_script=${SUPABASE_PGSODIUM_GETKEY_SCRIPT:-unset} - bootstrap inputs"

if [ "$SUPABASE_INIT_ENABLED" = "true" ] && [ -z "$SUPABASE_PGSODIUM_GETKEY_SCRIPT" ]; then
    echo "WARNING: Supabase bootstrap requested but no pgsodium root key source is configured. Skipping bootstrap; provide PGSODIUM_KEY, PGSODIUM_KEY_FILE, or pgsodium.getkey_script and rerun /scripts/run_supabase_migrations.sh $2 once the key is available." >&2
    SUPABASE_INIT_ENABLED=false
    SUPABASE_INIT_SOURCE='disabled-missing-pgsodium-key'
fi

if [ "$SUPABASE_INIT_ENABLED" = "true" ] && [ "$SUPABASE_WAL_LEVEL" != "logical" ]; then
    echo "ERROR: Supabase bootstrap requires wal_level=logical, got ${SUPABASE_WAL_LEVEL}" >&2
    exit 1
fi

log_supabase_post_init "starting base post-init SQL" "$2"

(echo "\set ON_ERROR_STOP on"
echo "DO \$\$
BEGIN
    PERFORM * FROM pg_catalog.pg_authid WHERE rolname = 'admin';
    IF FOUND THEN
        ALTER ROLE admin WITH CREATEDB NOLOGIN NOCREATEROLE NOSUPERUSER NOREPLICATION INHERIT;
    ELSE
        CREATE ROLE admin CREATEDB;
    END IF;

    PERFORM * FROM pg_catalog.pg_authid WHERE rolname = 'cron_admin';
    IF FOUND THEN
        ALTER ROLE cron_admin WITH NOCREATEDB NOLOGIN NOCREATEROLE NOSUPERUSER NOREPLICATION INHERIT;
    ELSE
        CREATE ROLE cron_admin;
    END IF;
END;\$\$;

GRANT cron_admin TO admin;

DO \$\$
BEGIN
    PERFORM * FROM pg_catalog.pg_authid WHERE rolname = '$1';
    IF FOUND THEN
        ALTER ROLE $1 WITH NOCREATEDB NOLOGIN NOCREATEROLE NOSUPERUSER NOREPLICATION INHERIT;
    ELSE
        CREATE ROLE $1;
    END IF;
END;\$\$;

DO \$\$
BEGIN
    PERFORM * FROM pg_catalog.pg_authid WHERE rolname = 'robot_zmon';
    IF FOUND THEN
        ALTER ROLE robot_zmon WITH NOCREATEDB NOLOGIN NOCREATEROLE NOSUPERUSER NOREPLICATION INHERIT;
    ELSE
        CREATE ROLE robot_zmon;
    END IF;
END;\$\$;

CREATE EXTENSION IF NOT EXISTS pg_auth_mon SCHEMA public;
ALTER EXTENSION pg_auth_mon UPDATE;
GRANT SELECT ON TABLE public.pg_auth_mon TO robot_zmon;

CREATE EXTENSION IF NOT EXISTS pg_cron SCHEMA pg_catalog;
DO \$\$
BEGIN
    PERFORM 1 FROM pg_catalog.pg_proc WHERE pronamespace = 'cron'::pg_catalog.regnamespace AND proname = 'schedule' AND proargnames = '{p_schedule,p_database,p_command}';
    IF FOUND THEN
        ALTER FUNCTION cron.schedule(text, text, text) RENAME TO schedule_in_database;
    END IF;
END;\$\$;
ALTER EXTENSION pg_cron UPDATE;

ALTER POLICY cron_job_policy ON cron.job USING (username = current_user OR
    (pg_has_role(current_user, 'cron_admin', 'MEMBER')
    AND pg_has_role(username, 'cron_admin', 'MEMBER')
    AND NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = username AND rolsuper)
    ));
REVOKE SELECT ON cron.job FROM admin, public;
GRANT SELECT ON cron.job TO cron_admin;
REVOKE UPDATE (database, nodename) ON cron.job FROM admin;
GRANT UPDATE (database, nodename) ON cron.job TO cron_admin;

ALTER POLICY cron_job_run_details_policy ON cron.job_run_details USING (username = current_user OR
    (pg_has_role(current_user, 'cron_admin', 'MEMBER')
    AND pg_has_role(username, 'cron_admin', 'MEMBER')
    AND NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = username AND rolsuper)
    ));
REVOKE SELECT ON cron.job_run_details FROM admin, public;
GRANT SELECT ON cron.job_run_details TO cron_admin;

CREATE OR REPLACE FUNCTION cron.schedule_in_database(p_schedule text, p_database text, p_command text)
RETURNS bigint
LANGUAGE plpgsql
AS \$function\$
DECLARE
    l_jobid bigint;
BEGIN
    IF NOT (SELECT rolcanlogin FROM pg_roles WHERE rolname = current_user)
    THEN RAISE 'You cannot create a job using a role that cannot log in';
    END IF;

    SELECT schedule INTO l_jobid FROM cron.schedule(p_schedule, p_command);
    UPDATE cron.job SET database = p_database, nodename = '' WHERE jobid = l_jobid;
    RETURN l_jobid;
END;
\$function\$;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA cron FROM admin, public;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA cron TO cron_admin;

REVOKE USAGE ON SCHEMA cron FROM admin;
GRANT USAGE ON SCHEMA cron TO cron_admin;

CREATE EXTENSION IF NOT EXISTS file_fdw SCHEMA public;
DO \$\$
BEGIN
    PERFORM * FROM pg_catalog.pg_foreign_server WHERE srvname = 'pglog';
    IF NOT FOUND THEN
        CREATE SERVER pglog FOREIGN DATA WRAPPER file_fdw;
    END IF;
END;\$\$;

CREATE TABLE IF NOT EXISTS public.postgres_log (
    log_time timestamp(3) with time zone,
    user_name text,
    database_name text,
    process_id integer,
    connection_from text,
    session_id text NOT NULL,
    session_line_num bigint NOT NULL,
    command_tag text,
    session_start_time timestamp with time zone,
    virtual_transaction_id text,
    transaction_id bigint,
    error_severity text,
    sql_state_code text,
    message text,
    detail text,
    hint text,
    internal_query text,
    internal_query_pos integer,
    context text,
    query text,
    query_pos integer,
    location text,
    application_name text,
    backend_type text,
    leader_pid integer,
    query_id bigint,
    CONSTRAINT postgres_log_check CHECK (false) NO INHERIT
);
GRANT SELECT ON public.postgres_log TO admin;"

# Sunday could be 0 or 7 depending on the format, we just create both
LOG_SHIP_HOURLY=$(echo "SELECT text(current_setting('log_rotation_age') = '1h')" | psql -tAX -d postgres 2> /dev/null | tail -n 1)
if [ "$LOG_SHIP_HOURLY" != "true" ]; then
    tbl_regex='postgres_log_\d_\d{2}$'
else
    tbl_regex='postgres_log_\d$'
fi
echo "DO \$\$DECLARE tbl_name TEXT;
    BEGIN
    FOR tbl_name IN SELECT 'public' || '.' || quote_ident(relname) FROM pg_class
                    WHERE relname ~ '${tbl_regex}' AND relnamespace = 'public'::pg_catalog.regnamespace AND relkind = 'f'
    LOOP
        IF tbl_name IS NOT NULL THEN
            EXECUTE format('DROP FOREIGN TABLE IF EXISTS %s CASCADE', tbl_name);
        END IF;
    END LOOP;
END;\$\$;"

for i in $(seq 0 7); do
    if [ "$LOG_SHIP_HOURLY" != "true" ]; then
        echo "CREATE FOREIGN TABLE IF NOT EXISTS public.postgres_log_${i} () INHERITS (public.postgres_log) SERVER pglog
        OPTIONS (filename '../pg_log/postgresql-${i}.csv', format 'csv', header 'false');
        GRANT SELECT ON public.postgres_log_${i} TO admin;

        CREATE OR REPLACE VIEW public.failed_authentication_${i} WITH (security_barrier) AS
        SELECT *
          FROM public.postgres_log_${i}
         WHERE command_tag = 'authentication'
           AND error_severity = 'FATAL';
        ALTER VIEW public.failed_authentication_${i} OWNER TO postgres;
        GRANT SELECT ON TABLE public.failed_authentication_${i} TO robot_zmon;"
    else
        daily_log="CREATE OR REPLACE VIEW public.postgres_log_${i} AS\n"
        daily_auth="CREATE OR REPLACE VIEW public.failed_authentication_${i} WITH (security_barrier) AS\n"
        daily_union=""

        for h in $(seq -w 0 23); do
            filter_logs="SELECT * FROM public.postgres_log_${i}_${h} WHERE command_tag = 'authentication' AND error_severity = 'FATAL'"

            echo "CREATE FOREIGN TABLE IF NOT EXISTS public.postgres_log_${i}_${h} () INHERITS (public.postgres_log) SERVER pglog
            OPTIONS (filename '../pg_log/postgresql-${i}-${h}.csv', format 'csv', header 'false');
            GRANT SELECT ON public.postgres_log_${i}_${h} TO admin;

            CREATE OR REPLACE VIEW public.failed_authentication_${i}_${h} WITH (security_barrier) AS
            ${filter_logs};
            ALTER VIEW public.failed_authentication_${i}_${h} OWNER TO postgres;
            GRANT SELECT ON TABLE public.failed_authentication_${i}_${h} TO robot_zmon;"

            daily_log="${daily_log}${daily_union}SELECT * FROM public.postgres_log_${i}_${h}\n"
            daily_auth="${daily_auth}${daily_union}${filter_logs}\n"
            daily_union="UNION ALL\n"
        done

        echo -e "${daily_log};"
        echo -e "${daily_auth};"
    fi
done

cat _zmon_schema.dump

while IFS= read -r db_name; do
    echo "\c ${db_name}"
    # In case if timescaledb binary is missing the first query fails with the error
    # ERROR:  could not access file "$libdir/timescaledb-$OLD_VERSION": No such file or directory
    UPGRADE_TIMESCALEDB=$(echo -e "SELECT NULL;\nSELECT default_version != installed_version FROM pg_catalog.pg_available_extensions WHERE name = 'timescaledb'" | psql -tAX -d "${db_name}" 2> /dev/null | tail -n 1)
    if [ "$UPGRADE_TIMESCALEDB" = "t" ]; then
        echo "ALTER EXTENSION timescaledb UPDATE;"
        IS_VERSION_BELOW_215=$(echo -e "SELECT (installed_version < '2.15')::bool FROM pg_catalog.pg_available_extensions WHERE name = 'timescaledb'" | psql -tAX -d "${db_name}" 2> /dev/null | tail -n 1)
        if [ "$IS_VERSION_BELOW_215" = "t" ]; then
            echo """
                    -- Fix compressed hypertables with FOREIGN KEY constraints that were created with TimescaleDB versions before 2.15.0
                    CREATE OR REPLACE FUNCTION pg_temp.constraint_columns(regclass, int2[]) RETURNS text[] AS
                    $$
                    SELECT array_agg(attname) FROM unnest($2) un(attnum) LEFT JOIN pg_attribute att ON att.attrelid=$1 AND att.attnum = un.attnum;
                    $$ LANGUAGE SQL SET search_path TO pg_catalog, pg_temp;
                    DO $$
                        DECLARE
                        ht_id int;
                        ht regclass;
                        chunk regclass;
                        con_oid oid;
                        con_frelid regclass;
                        con_name text;
                        con_columns text[];
                        chunk_id int;

                        BEGIN

                        -- iterate over all hypertables that have foreign key constraints
                        FOR ht_id, ht in
                            SELECT
                            ht.id,
                            format('%I.%I',ht.schema_name,ht.table_name)::regclass
                            FROM _timescaledb_catalog.hypertable ht
                            WHERE
                            EXISTS (
                                SELECT FROM pg_constraint con
                                WHERE
                                con.contype='f' AND
                                con.conrelid=format('%I.%I',ht.schema_name,ht.table_name)::regclass
                            )
                        LOOP
                            RAISE NOTICE 'Hypertable % has foreign key constraint', ht;

                            -- iterate over all foreign key constraints on the hypertable
                            -- and check that they are present on every chunk
                            FOR con_oid, con_frelid, con_name, con_columns IN
                            SELECT con.oid, con.confrelid, con.conname, pg_temp.constraint_columns(con.conrelid,con.conkey)
                            FROM pg_constraint con
                            WHERE
                                con.contype='f' AND
                                con.conrelid=ht
                            LOOP
                                RAISE NOTICE 'Checking constraint % %', con_name, con_columns;
                                -- check that the foreign key constraint is present on the chunk

                                FOR chunk_id, chunk IN
                                    SELECT
                                    ch.id,
                                    format('%I.%I',ch.schema_name,ch.table_name)::regclass
                                    FROM _timescaledb_catalog.chunk ch
                                    WHERE
                                    ch.hypertable_id=ht_id
                                LOOP
                                    RAISE NOTICE 'Checking chunk %', chunk;
                                    IF NOT EXISTS (
                                    SELECT FROM pg_constraint con
                                    WHERE
                                        con.contype='f' AND
                                        con.conrelid=chunk AND
                                        con.confrelid=con_frelid  AND
                                        pg_temp.constraint_columns(con.conrelid,con.conkey) = con_columns
                                    ) THEN
                                    RAISE WARNING 'Restoring constraint % on chunk %', con_name, chunk;
                                    PERFORM _timescaledb_functions.constraint_clone(con_oid, chunk);
                                    INSERT INTO _timescaledb_catalog.chunk_constraint(chunk_id, dimension_slice_id, constraint_name, hypertable_constraint_name) VALUES (chunk_id, NULL, con_name, con_name);
                                    END IF;

                                END LOOP;
                            END LOOP;

                        END LOOP;

                    END
                    $$;

                    DROP FUNCTION pg_temp.constraint_columns(regclass, int2[]);
                """
        fi
    fi
    UPGRADE_TIMESCALEDB_TOOLKIT=$(echo -e "SELECT NULL;\nSELECT default_version != installed_version FROM pg_catalog.pg_available_extensions WHERE name = 'timescaledb_toolkit'" | psql -tAX -d "${db_name}" 2> /dev/null | tail -n 1)
    if [ "$UPGRADE_TIMESCALEDB_TOOLKIT" = "t" ]; then
        echo "ALTER EXTENSION timescaledb_toolkit UPDATE;"
    fi
    UPGRADE_POSTGIS=$(echo "SELECT COUNT(*) FROM pg_catalog.pg_extension WHERE extname = 'postgis'" | psql -tAX -d "${db_name}" 2> /dev/null | tail -n 1)
    if [ "$UPGRADE_POSTGIS" = "1" ]; then
        # public.postgis_lib_version() is available only if postgis extension is created
        UPGRADE_POSTGIS=$(echo "SELECT extversion != public.postgis_lib_version() FROM pg_catalog.pg_extension WHERE extname = 'postgis'" | psql -tAX -d "${db_name}" 2> /dev/null | tail -n 1)
        if [ "$UPGRADE_POSTGIS" = "t" ]; then
            echo "ALTER EXTENSION postgis UPDATE;"
            echo "SELECT public.postgis_extensions_upgrade();"
        fi
    fi
    sed "s/:HUMAN_ROLE/$1/" create_user_functions.sql
    echo "CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_stat_kcache SCHEMA public;
CREATE EXTENSION IF NOT EXISTS set_user SCHEMA public;
ALTER EXTENSION set_user UPDATE;
GRANT EXECUTE ON FUNCTION public.set_user(text) TO admin;
GRANT EXECUTE ON FUNCTION public.pg_stat_statements_reset($RESET_ARGS) TO admin;"
    echo "GRANT EXECUTE ON FUNCTION pg_catalog.pg_switch_wal() TO admin;"
    if [ "$ENABLE_PG_MON" = "true" ]; then echo "CREATE EXTENSION IF NOT EXISTS pg_mon SCHEMA public;"; fi
    cat metric_helpers.sql
done < <(psql -d "$2" -tAc 'select pg_catalog.quote_ident(datname) from pg_catalog.pg_database where datallowconn')
) | psql -Xd "$2"

log_supabase_post_init "base post-init SQL completed" "$2"

# Optional: Supabase bootstrap (roles, schemas, event triggers, permissions)
if [ "$SUPABASE_INIT_ENABLED" = "true" ]; then
    log_supabase_post_init "bootstrap requested" "$2"
    if [ "$SUPABASE_EXTENSIONS_ENABLED" != "true" ]; then
        echo "ERROR: ENABLE_SUPABASE_INIT=true requires ENABLE_SUPABASE_EXTENSIONS=true" >&2
        exit 1
    fi
    if [ "$PGVER" -lt 15 ]; then
        log_supabase_post_init "running legacy bootstrap SQL" "$2"
        while read -r db_name; do
            log_supabase_post_init "applying legacy compatibility SQL on ${db_name}" "$2"
            psql -Xd "$db_name" -f /scripts/supabase_init.sql
            log_supabase_post_init "applying legacy custom SQL hooks on ${db_name}" "$2"
            if ! /scripts/run_supabase_migrations.sh --custom-only "$db_name"; then
                log_supabase_post_init "legacy custom SQL hooks failed on ${db_name}" "$2"
                exit 1
            fi
        done < <(psql -d "$2" -tAc "SELECT pg_catalog.quote_ident(datname) FROM pg_catalog.pg_database WHERE datallowconn AND datname NOT IN ('template0','template1')")
        log_supabase_post_init "legacy bootstrap completed" "$2"
    else
        log_supabase_post_init "running upstream migration bundle on postgres" "$2"
        if ! /scripts/run_supabase_migrations.sh postgres; then
            log_supabase_post_init "upstream migration bundle failed on postgres" "$2"
            exit 1
        fi
        log_supabase_post_init "upstream migration bundle completed on postgres" "$2"
    fi
else
    log_supabase_post_init "bootstrap skipped" "$2"
fi
