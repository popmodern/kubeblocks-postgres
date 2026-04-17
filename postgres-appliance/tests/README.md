# Run tests

After building the image, you can test your image by:

1. Setting up the environment variable `SPILO_TEST_IMAGE` to test the specific image. If unset, the default will be `spilo`.
    ```
    export SPILO_TEST_IMAGE=<your_spilo_image>
    ```
2. Run the core Spilo regression suite:
    ```
    bash test_spilo.sh
    ```
    To enable debugging for an entire script when it runs:
    ```
    bash -x test_spilo.sh
    ```
3. Run the dedicated Supabase bootstrap suite when validating Supabase init behavior:
    ```
    export SPILO_SUPABASE_TEST_IMAGE=<your_supabase_default_image>
    bash test_supabase.sh
    ```
    To enable debugging for the Supabase suite:
    ```
    bash -x test_supabase.sh
    ```

The suites now have different jobs:

- `test_spilo.sh` covers the main upgrade, clone, replica, whitelist, and hourly log rotation matrix.
- `test_supabase.sh` covers PG15+ Supabase bootstrap with explicit and generated pgsodium keys, PG15+ custom SQL hooks, PG14 legacy bootstrap, and PG14 legacy custom SQL hooks.

For the Supabase path, image build prepares the static artifacts that upstream Supabase startup expects: binaries, extensions, runtime scripts, the vendored upstream migration bundle under `/usr/share/supabase/postgres/migrations`, and a working pgsodium getkey script path. The actual SQL bootstrap still happens on first cluster initialization through Patroni's `post_init` hook in `post_init.sh`.

The `supabase bundle ready` wait in `test_supabase.sh` is intentionally stricter than container health. It waits for the live database to contain the bundled migration state and the `supabase_realtime` publication, so bootstrap regressions fail fast as configuration problems rather than looking like generic startup timeouts. The keyless Supabase scenario now verifies that Spilo generates and reuses a persistent cluster-local pgsodium root key when no explicit external key source is provided.

The test will create multiple containers. They will be cleaned up by the last line before running `main` in `test_spilo.sh`. To keep and debug the containers after running the test, this part can be commented.
```
trap cleanup QUIT TERM EXIT
```

The same cleanup advice applies to `test_supabase.sh`.
