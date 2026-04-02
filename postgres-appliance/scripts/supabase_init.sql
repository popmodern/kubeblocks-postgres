-- Supabase bootstrap SQL for KubeBlocks Spilo PG14 compatibility mode.
-- Upstream supabase/postgres no longer ships a PG14 bootstrap artifact we can vendor directly.
-- Run once per database when ENABLE_SUPABASE_INIT=true.

-- ============================================================================
-- Roles
-- ============================================================================

DO $$
BEGIN
    -- anon: unauthenticated API access
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN NOINHERIT;
    END IF;

    -- authenticated: logged-in API access
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN NOINHERIT;
    END IF;

    -- service_role: elevated API access (bypasses RLS)
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') THEN
        CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
    END IF;

    -- authenticator: PostgREST connection role
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
        CREATE ROLE authenticator NOLOGIN NOINHERIT;
    END IF;

    -- supabase_auth_admin: auth microservice
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
        CREATE ROLE supabase_auth_admin NOLOGIN NOINHERIT CREATEROLE;
    END IF;

    -- supabase_storage_admin: storage microservice
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN
        CREATE ROLE supabase_storage_admin NOLOGIN NOINHERIT;
    END IF;

    -- supabase_functions_admin: edge functions
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_functions_admin') THEN
        CREATE ROLE supabase_functions_admin NOLOGIN NOINHERIT;
    END IF;

    -- dashboard_user: Studio UI access
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dashboard_user') THEN
        CREATE ROLE dashboard_user NOLOGIN NOINHERIT CREATEDB CREATEROLE;
    END IF;

    -- supabase_admin: compatibility admin role aligned with upstream custom-hook execution
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_admin') THEN
        CREATE ROLE supabase_admin LOGIN SUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS;
    ELSE
        ALTER ROLE supabase_admin WITH LOGIN SUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS;
    END IF;
END
$$;

-- Role memberships
GRANT anon TO authenticator;
GRANT authenticated TO authenticator;
GRANT service_role TO authenticator;
GRANT supabase_auth_admin TO authenticator;
GRANT supabase_storage_admin TO authenticator;
GRANT supabase_functions_admin TO authenticator;

-- ============================================================================
-- Schemas
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE SCHEMA IF NOT EXISTS graphql_public;
CREATE SCHEMA IF NOT EXISTS graphql;
CREATE SCHEMA IF NOT EXISTS supabase_functions;
CREATE SCHEMA IF NOT EXISTS supabase_migrations;

-- Grant schema usage
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA graphql_public TO anon, authenticated, service_role;

-- Default privileges for future objects in public schema
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;

-- ============================================================================
-- Base extensions (installed in extensions schema)
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgjwt SCHEMA extensions;

-- ============================================================================
-- Search path: include extensions so callers don't need schema prefix
-- ============================================================================

DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET search_path TO public, extensions', current_database());
END
$$;

-- ============================================================================
-- Supabase-specific function grants
-- ============================================================================

-- Allow API roles to use extension functions
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA extensions
    GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;

-- ============================================================================
-- Event triggers: auto-grant access when key extensions are created
-- ============================================================================

-- pg_graphql: set up graphql_public.graphql() shim on CREATE EXTENSION pg_graphql
CREATE OR REPLACE FUNCTION extensions.grant_pg_graphql_access()
RETURNS event_trigger
LANGUAGE plpgsql
AS $func$
DECLARE
    func_is_graphql_resolve bool;
BEGIN
    func_is_graphql_resolve = (
        SELECT n.proname = 'resolve'
        FROM pg_event_trigger_ddl_commands() AS ev
        JOIN pg_catalog.pg_proc AS n ON ev.objid = n.oid
    );

    IF func_is_graphql_resolve THEN
        -- Expose graphql.resolve via graphql_public schema
        GRANT USAGE ON SCHEMA graphql_public TO anon, authenticated, service_role;

        CREATE OR REPLACE FUNCTION graphql_public.graphql(
            "operationName" text DEFAULT NULL,
            query text DEFAULT NULL,
            variables jsonb DEFAULT NULL,
            extensions jsonb DEFAULT NULL
        )
        RETURNS jsonb
        LANGUAGE sql
        AS $$
            SELECT graphql.resolve(
                query := query,
                variables := coalesce(variables, '{}'),
                "operationName" := "operationName",
                extensions := extensions
            );
        $$;

        GRANT EXECUTE ON FUNCTION graphql_public.graphql TO anon, authenticated, service_role;
    END IF;
END;
$func$;

DROP EVENT TRIGGER IF EXISTS issue_pg_graphql_access;
CREATE EVENT TRIGGER issue_pg_graphql_access
    ON ddl_command_end
    WHEN TAG IN ('CREATE FUNCTION')
    EXECUTE PROCEDURE extensions.grant_pg_graphql_access();

-- pg_net: grant access when pg_net extension is created
CREATE OR REPLACE FUNCTION extensions.grant_pg_net_access()
RETURNS event_trigger
LANGUAGE plpgsql
AS $func$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_event_trigger_ddl_commands() AS ev
        JOIN pg_extension AS ext ON (ev.classid = 'pg_extension'::regclass AND ev.objid = ext.oid)
        WHERE ext.extname = 'pg_net'
    ) THEN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_functions_admin') THEN
            CREATE ROLE supabase_functions_admin NOLOGIN NOINHERIT;
        END IF;

        GRANT USAGE ON SCHEMA net TO supabase_functions_admin, authenticated, service_role, anon;
        GRANT ALL ON ALL TABLES IN SCHEMA net TO supabase_functions_admin;
        GRANT ALL ON ALL ROUTINES IN SCHEMA net TO supabase_functions_admin;
        GRANT ALL ON ALL SEQUENCES IN SCHEMA net TO supabase_functions_admin;

        ALTER FUNCTION net.http_get SET search_path = net, public, extensions;
        ALTER FUNCTION net.http_post SET search_path = net, public, extensions;
    END IF;
END;
$func$;

DROP EVENT TRIGGER IF EXISTS issue_pg_net_access;
CREATE EVENT TRIGGER issue_pg_net_access
    ON ddl_command_end
    WHEN TAG IN ('CREATE EXTENSION')
    EXECUTE PROCEDURE extensions.grant_pg_net_access();

-- pg_cron: grant cron access when extension is created
CREATE OR REPLACE FUNCTION extensions.grant_pg_cron_access()
RETURNS event_trigger
LANGUAGE plpgsql
AS $func$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_event_trigger_ddl_commands() AS ev
        JOIN pg_extension AS ext ON (ev.classid = 'pg_extension'::regclass AND ev.objid = ext.oid)
        WHERE ext.extname = 'pg_cron'
    ) THEN
        GRANT USAGE ON SCHEMA cron TO anon, authenticated, service_role;
        GRANT ALL ON ALL TABLES IN SCHEMA cron TO anon, authenticated, service_role;
        ALTER FUNCTION cron.schedule(text, text) SET search_path = cron, public, extensions;
        ALTER FUNCTION cron.schedule(text, text, text) SET search_path = cron, public, extensions;
    END IF;
END;
$func$;

DROP EVENT TRIGGER IF EXISTS issue_pg_cron_access;
CREATE EVENT TRIGGER issue_pg_cron_access
    ON ddl_command_end
    WHEN TAG IN ('CREATE EXTENSION')
    EXECUTE PROCEDURE extensions.grant_pg_cron_access();

-- ============================================================================
-- graphql_public.graphql() placeholder (before pg_graphql is installed)
-- ============================================================================

CREATE OR REPLACE FUNCTION graphql_public.graphql(
    "operationName" text DEFAULT NULL,
    query text DEFAULT NULL,
    variables jsonb DEFAULT NULL,
    extensions jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
    DECLARE
        server_version numeric;
    BEGIN
        server_version = current_setting('server_version_num')::numeric;
        IF server_version >= 140000 AND NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pg_graphql'
        ) THEN
            RAISE EXCEPTION 'pg_graphql extension is not installed. Run: CREATE EXTENSION pg_graphql;';
        END IF;
        RETURN graphql.resolve(
            query := query,
            variables := coalesce(variables, '{}'),
            "operationName" := "operationName",
            extensions := extensions
        );
    END;
$$;

GRANT EXECUTE ON FUNCTION graphql_public.graphql TO anon, authenticated, service_role;

-- ============================================================================
-- Record Supabase init completion
-- ============================================================================
DO $$
BEGIN
    RAISE NOTICE 'Supabase bootstrap SQL completed successfully';
END
$$;
