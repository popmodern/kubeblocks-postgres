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

for command_name in bash sh python3 openssl crontab envdir sv runsvdir psql vacuumdb patroni chpst chrt timeout; do
    require_command "$command_name"
done

require_executable /usr/bin/dumb-init
require_executable /usr/sbin/cron
require_executable /usr/sbin/pgbouncer
require_executable /usr/bin/pgqd
require_executable /usr/local/bin/wal-g
require_file /usr/local/lib/cron_unprivileged.so

if [ "${DEMO:-false}" != "true" ]; then
    require_executable /bin/etcd
    require_executable /bin/etcdctl
fi
