#!/bin/bash
# pgsodium key provider script
# Returns the server key used by pgsodium for encryption.
# Supply the key via PGSODIUM_KEY or mount it in a file referenced by
# PGSODIUM_KEY_FILE. When Spilo enables Supabase support without an explicit
# external key source, launch.sh points PGSODIUM_KEY_FILE at a persistent
# cluster-local fallback path inside PGDATA and sets
# SPILO_AUTO_GENERATE_PGSODIUM_KEY=true so this script can generate the key on
# first boot. The key must always be a 64 character hex string.

set -euo pipefail

generate_key_file() {
    local key_file=$1
    local old_umask

    mkdir -p "$(dirname "$key_file")"

    old_umask=$(umask)
    umask 077
    head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n' > "$key_file"
    umask "$old_umask"
}

if [ -n "${PGSODIUM_KEY_FILE:-}" ]; then
    if [ ! -e "$PGSODIUM_KEY_FILE" ] && [ "${SPILO_AUTO_GENERATE_PGSODIUM_KEY:-}" = "true" ]; then
        generate_key_file "$PGSODIUM_KEY_FILE"
    fi

    if [ ! -r "$PGSODIUM_KEY_FILE" ]; then
        echo "ERROR: PGSODIUM_KEY_FILE is set but not readable: $PGSODIUM_KEY_FILE" >&2
        exit 1
    fi
    key_material=$(tr -d '[:space:]' < "$PGSODIUM_KEY_FILE")
elif [ -n "${PGSODIUM_KEY:-}" ]; then
    key_material=$(printf '%s' "$PGSODIUM_KEY" | tr -d '[:space:]')
else
    echo "ERROR: PGSODIUM_KEY or PGSODIUM_KEY_FILE must be provided via a secret-backed source" >&2
    exit 1
fi

if [ "${#key_material}" -ne 64 ]; then
    echo "ERROR: pgsodium root key must be exactly 64 hex characters" >&2
    exit 1
fi

if ! printf '%s' "$key_material" | grep -Eq '^[0-9a-fA-F]{64}$'; then
    echo "ERROR: pgsodium root key must be a 64 character hex string" >&2
    exit 1
fi

echo "$key_material"
