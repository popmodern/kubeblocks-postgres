#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

echo -e 'APT::Install-Recommends "0";\nAPT::Install-Suggests "0";' > /etc/apt/apt.conf.d/01norecommend

apt-get update
apt-get -y upgrade
apt-get install -y curl ca-certificates less locales jq vim-tiny gnupg1 cron runit dumb-init libcap2-bin rsync sysstat gpg openssl

normalize_fingerprint() {
    printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
}

key_file_contains_fingerprint() {
    local key_file="$1"
    local expected
    local actual

    expected=$(normalize_fingerprint "$2")

    while IFS= read -r actual; do
        case "${#expected}" in
            40)
                [ "$actual" = "$expected" ] && return 0
                ;;
            *)
                case "$actual" in
                    *"$expected") return 0 ;;
                esac
                ;;
        esac
    done < <(gpg --show-keys --with-colons "$key_file" | awk -F: '/^fpr:/ {print toupper($10)}')

    return 1
}

install_verified_apt_keyring() {
    local key_url="$1"
    local keyring_path="$2"
    local expected_fingerprint="$3"
    local key_file

    key_file=$(mktemp)
    curl -fsSL "$key_url" -o "$key_file"

    if ! key_file_contains_fingerprint "$key_file" "$expected_fingerprint"; then
        echo "ERROR: fingerprint mismatch for repository key from ${key_url}" >&2
        rm -f "$key_file"
        exit 1
    fi

    mkdir -p "$(dirname "$keyring_path")"
    gpg --dearmor < "$key_file" > "$keyring_path"
    rm -f "$key_file"
}

ln -s chpst /usr/bin/envdir

# Make it possible to use the following utilities without root (if container runs without "no-new-privileges:true")
setcap 'cap_sys_nice+ep' /usr/bin/chrt
setcap 'cap_sys_nice+ep' /usr/bin/renice

# Disable unwanted cron jobs
rm -fr /etc/cron.??*
truncate --size 0 /etc/crontab

if [ "$DEMO" != "true" ]; then
    # install etcdctl
    ETCDVERSION=3.3.27
    curl -L https://github.com/coreos/etcd/releases/download/v${ETCDVERSION}/etcd-v${ETCDVERSION}-linux-"$(dpkg --print-architecture)".tar.gz \
                | tar xz -C /bin --strip=1 --wildcards --no-anchored --no-same-owner etcdctl etcd
fi

# Dirty hack for smooth migration of existing dbs
bash /builddeps/locales.sh
mv /usr/lib/locale/locale-archive /usr/lib/locale/locale-archive.22
ln -s /run/locale-archive /usr/lib/locale/locale-archive
ln -s /usr/lib/locale/locale-archive.22 /run/locale-archive

# Add PGDG repositories
DISTRIB_CODENAME=$(sed -n 's/DISTRIB_CODENAME=//p' /etc/lsb-release)
for t in deb deb-src; do
    echo "$t [signed-by=/etc/apt/keyrings/apt.postgresql.org.gpg] https://apt.postgresql.org/pub/repos/apt/ ${DISTRIB_CODENAME}-pgdg main" >> /etc/apt/sources.list.d/pgdg.list
done
install_verified_apt_keyring \
    "https://www.postgresql.org/media/keys/ACCC4CF8.asc" \
    /etc/apt/keyrings/apt.postgresql.org.gpg \
    "B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8"

# add TimescaleDB repository
echo "deb [signed-by=/etc/apt/keyrings/timescale_timescaledb-archive-keyring.gpg] https://packagecloud.io/timescale/timescaledb/ubuntu/ ${DISTRIB_CODENAME} main" | tee /etc/apt/sources.list.d/timescaledb.list
install_verified_apt_keyring \
    "https://packagecloud.io/timescale/timescaledb/gpgkey" \
    /etc/apt/keyrings/timescale_timescaledb-archive-keyring.gpg \
    "E7391C94080429FF"

# Clean up
apt-get purge -y libcap2-bin
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/* \
            /var/cache/debconf/* \
            /usr/share/doc \
            /usr/share/man \
            /usr/share/locale/?? \
            /usr/share/locale/??_??
find /var/log -type f -exec truncate --size 0 {} \;
