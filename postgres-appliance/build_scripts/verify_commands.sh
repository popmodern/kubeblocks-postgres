#!/bin/sh

set -eu

require_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        echo "ERROR: required command '$1' is not available in the image" >&2
        exit 1
    fi
}

require_executable() {
    if [ ! -x "$1" ]; then
        echo "ERROR: required executable '$1' is missing or not executable" >&2
        exit 1
    fi
}

require_file() {
    if [ ! -f "$1" ]; then
        echo "ERROR: required file '$1' is missing" >&2
        exit 1
    fi
}

require_libcurl_from_usr_local() {
    local extension_lib="$1"

    if ! ldd "$extension_lib" | grep -Eq 'libcurl\.so\.4 => /usr/local/lib/'; then
        echo "ERROR: $extension_lib does not resolve libcurl.so.4 from /usr/local/lib" >&2
        ldd "$extension_lib" >&2
        exit 1
    fi
}

require_preferred_libcurl() {
    local first_libcurl

    first_libcurl=$(ldconfig -p | awk '/libcurl\.so\.4 \(/ {print $NF; exit}')
    if [ "$first_libcurl" != "/usr/local/lib/libcurl.so.4" ]; then
        echo "ERROR: ldconfig does not prefer /usr/local/lib/libcurl.so.4 (got ${first_libcurl:-<none>})" >&2
        ldconfig -p | grep 'libcurl\.so\.4' >&2 || true
        exit 1
    fi
}

for command_name in bash sh python3 openssl crontab envdir sv runsvdir psql vacuumdb patroni chpst chrt timeout ldd ldconfig; do
    require_command "$command_name"
done

require_executable /usr/bin/dumb-init
require_executable /usr/sbin/cron
require_executable /usr/sbin/pgbouncer
require_executable /usr/bin/pgqd
require_executable /usr/local/bin/wal-g
require_file /usr/local/lib/cron_unprivileged.so
require_file /usr/local/lib/libcurl.so.4
require_preferred_libcurl

for extension_lib in $(find /usr/lib/postgresql -path '*/lib/pg_net.so' -o -path '*/lib/http.so'); do
    require_file "$extension_lib"
    require_libcurl_from_usr_local "$extension_lib"
done

if [ "${DEMO:-false}" != "true" ]; then
    require_executable /bin/etcd
    require_executable /bin/etcdctl
fi
