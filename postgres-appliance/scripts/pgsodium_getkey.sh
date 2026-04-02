#!/bin/bash
# pgsodium key provider script
# Returns the server key used by pgsodium for encryption.
# Supply the key via PGSODIUM_KEY or mount it in a file referenced by
# PGSODIUM_KEY_FILE. The key must be a 64 character hex string.

set -euo pipefail

if [ -n "${PGSODIUM_KEY_FILE:-}" ]; then
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
