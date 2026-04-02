#!/bin/bash

## -------------------------------------------
## Install PostgreSQL, extensions and contribs
## -------------------------------------------

export DEBIAN_FRONTEND=noninteractive
MAKEFLAGS="-j $(grep -c ^processor /proc/cpuinfo)"
export MAKEFLAGS
SYSTEM_CURL=/usr/bin/curl

set -ex
sed -i 's/^#\s*\(deb.*universe\)$/\1/g' /etc/apt/sources.list

apt-get update

lookup_github_release_asset_sha() {
    local repo="$1"
    local tag="$2"
    local asset_name="$3"

    python3 - "$repo" "$tag" "$asset_name" <<'PY'
import json
import re
import sys
import urllib.request

repo, tag, asset_name = sys.argv[1:]

release_url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
request = urllib.request.Request(
    release_url,
    headers={"Accept": "application/vnd.github+json"},
)

try:
    with urllib.request.urlopen(request) as response:
        release = json.load(response)
    for asset in release.get("assets", []):
        if asset.get("name") != asset_name:
            continue
        digest = asset.get("digest") or ""
        if digest.startswith("sha256:"):
            print(digest.split(":", 1)[1])
            raise SystemExit(0)
except Exception:
    pass

with urllib.request.urlopen(f"https://github.com/{repo}/releases/tag/{tag}") as response:
    html = response.read().decode("utf-8", errors="ignore")

pattern = re.escape(asset_name) + r'.{0,500}?sha256:([0-9a-f]{64})'
match = re.search(pattern, html, re.S)
if match:
    print(match.group(1))
PY
}

download_and_verify_sha256() {
    local url="$1"
    local output="$2"
    local expected_sha="$3"

    "$SYSTEM_CURL" -fsSL "$url" -o "$output"
    printf '%s  %s\n' "$expected_sha" "$output" | sha256sum -c -
}

install_modern_libcurl() {
    local curl_archive="curl-${CURL_VERSION}.tar.gz"
    local curl_source_dir="curl-${CURL_VERSION}"

    download_and_verify_sha256 \
        "https://curl.se/download/${curl_archive}" \
        "$curl_archive" \
        "$CURL_TARBALL_SHA256"
    tar xzf "$curl_archive"
    (
        cd "$curl_source_dir"
        ./configure --prefix=/usr/local --with-openssl --disable-static --enable-shared
        make
        make install
    )
    rm -f /usr/local/bin/curl /usr/local/bin/curl-config
    ldconfig
    rm -rf "$curl_archive" "$curl_source_dir"
}

extension_supports_version() {
    local ext_name="$1"
    local version="$2"

    case "$ext_name" in
        pgmq|pg_stat_monitor)
            [ "$version" -ge 14 ] && [ "$version" -le 17 ]
            ;;
        *)
            return 0
            ;;
    esac
}

extension_support_note() {
    local ext_name="$1"

    case "$ext_name" in
        pgmq)
            printf 'upstream v%s supports PostgreSQL 14-17' "$PGMQ_VERSION"
            ;;
        pg_stat_monitor)
            printf 'upstream %s is only documented and tested through PostgreSQL 17' "$PG_STAT_MONITOR_VERSION"
            ;;
        *)
            printf 'unsupported on this PostgreSQL major'
            ;;
    esac
}

build_pgxs_extension() {
    local version="$1"
    local ext_name="$2"
    local source_dir="$3"
    local install_target="${4:-install-strip}"

    if ! extension_supports_version "$ext_name" "$version"; then
        echo "Skipping ${ext_name} for pg${version}; $(extension_support_note "$ext_name")" >&2
        return 0
    fi

    PATH="/usr/lib/postgresql/$version/bin:$PATH" make -C "$source_dir" USE_PGXS=1 clean
    PATH="/usr/lib/postgresql/$version/bin:$PATH" make -C "$source_dir" USE_PGXS=1 "$install_target"
}

for version in $DEB_PG_SUPPORTED_VERSIONS; do
    if [ "$version" -lt 14 ] || [ "$version" -gt 17 ]; then
        echo "ERROR: PostgreSQL ${version} is not supported by this image. Supported majors are 14-17." >&2
        exit 1
    fi
done

BUILD_PACKAGES=(devscripts equivs build-essential fakeroot debhelper git gcc libc6-dev make cmake libevent-dev libbrotli-dev libssl-dev libkrb5-dev libsodium-dev flex zlib1g-dev libcurl4-openssl-dev libpsl-dev systemtap-sdt-dev pkg-config)
if [ "$DEMO" = "true" ]; then
    export DEB_PG_SUPPORTED_VERSIONS="$PGVERSION"
    WITH_PERL=false
    rm -f ./*.deb
    apt-get install -y "${BUILD_PACKAGES[@]}" libcurl4
else
    BUILD_PACKAGES+=(libprotobuf-c-dev
                    libpam0g-dev
                    libicu-dev
                    libc-ares-dev
                    pandoc)
    apt-get install -y "${BUILD_PACKAGES[@]}" libcurl4

    install_modern_libcurl

    # install pam_oauth2.so
    git clone -b "$PAM_OAUTH2" --recurse-submodules https://github.com/zalando-pg/pam-oauth2.git
    make -C pam-oauth2 install

    # prepare 3rd sources
    git clone -b "$PLPROFILER" https://github.com/bigsql/plprofiler.git
    "$SYSTEM_CURL" -fsSL "https://github.com/zalando-pg/pg_mon/archive/$PG_MON_COMMIT.tar.gz" | tar xz

    for p in python3-keyring python3-docutils ieee-data; do
        version=$(apt-cache show $p | sed -n 's/^Version: //p' | sort -rV | head -n 1)
        printf "Section: misc\nPriority: optional\nStandards-Version: 3.9.8\nPackage: %s\nVersion: %s\nDescription: %s" "$p" "$version" "$p" > "$p"
        equivs-build "$p"
    done
fi

if [ "$DEMO" = "true" ]; then
    install_modern_libcurl
fi

if [ "$WITH_PERL" != "true" ]; then
    version=$(apt-cache show perl | sed -n 's/^Version: //p' | sort -rV | head -n 1)
    printf "Priority: standard\nStandards-Version: 3.9.8\nPackage: perl\nMulti-Arch: allowed\nReplaces: perl-base, perl-modules\nVersion: %s\nDescription: perl" "$version" > perl
    equivs-build perl
fi

"$SYSTEM_CURL" -fsSL "https://github.com/CyberDem0n/bg_mon/archive/$BG_MON_COMMIT.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/zalando-pg/pg_auth_mon/archive/$PG_ACCESS_MON_COMMIT.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/zubkov-andrei/pg_profile/archive/$PG_PROFILE.tar.gz" | tar xz

# Download source-built Supabase and additional extension sources
# GitHub does not publish an authoritative SHA256 for the pgsodium source archive,
# so fetch the exact git object we expect and verify HEAD matches the pinned commit.
git init "pgsodium-${PGSODIUM_COMMIT}"
git -C "pgsodium-${PGSODIUM_COMMIT}" remote add origin https://github.com/michelp/pgsodium.git
git -C "pgsodium-${PGSODIUM_COMMIT}" fetch --depth 1 origin "$PGSODIUM_COMMIT"
git -C "pgsodium-${PGSODIUM_COMMIT}" checkout --detach FETCH_HEAD
[ "$(git -C "pgsodium-${PGSODIUM_COMMIT}" rev-parse HEAD)" = "$PGSODIUM_COMMIT" ]
rm -rf "pgsodium-${PGSODIUM_COMMIT}/.git"
"$SYSTEM_CURL" -fsSL "https://github.com/supabase/vault/archive/v$VAULT_VERSION.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/supabase/pg_net/archive/v$PG_NET_VERSION.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/supabase/supautils/archive/v$SUPAUTILS_VERSION.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/pramsey/pgsql-http/archive/v$HTTP_VERSION.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/eradman/pg-safeupdate/archive/$PG_SAFEUPDATE_VERSION.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/iCyberon/pg_hashids/archive/$PG_HASHIDS_COMMIT.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/pgexperts/pg_plan_filter/archive/$PG_PLAN_FILTER_COMMIT.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/percona/pg_stat_monitor/archive/$PG_STAT_MONITOR_VERSION.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/aws/pg_tle/archive/v$PG_TLE_VERSION.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/postgrespro/rum/archive/$RUM_VERSION.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/michelp/pgjwt/archive/$PGJWT_COMMIT.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/tembo-io/pgmq/archive/v$PGMQ_VERSION.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/supabase/index_advisor/archive/v$INDEX_ADVISOR_VERSION.tar.gz" | tar xz
"$SYSTEM_CURL" -fsSL "https://github.com/theory/pgtap/archive/v$PGTAP_VERSION.tar.gz" | tar xz

# Add Groonga apt repository for pgroonga
if [ "$DEMO" != "true" ]; then
    distro_codename=$(sed -n 's/^DISTRIB_CODENAME=//p' /etc/lsb-release)
    if [ -z "$distro_codename" ]; then
        echo "ERROR: failed to determine Ubuntu codename from /etc/lsb-release" >&2
        exit 1
    fi
    groonga_source_pkg="groonga-apt-source-latest-${distro_codename}.deb"
    "$SYSTEM_CURL" -fsSL "https://packages.groonga.org/ubuntu/${groonga_source_pkg}" -o "$groonga_source_pkg"
    dpkg -i "$groonga_source_pkg"
    rm -f "$groonga_source_pkg"
    apt-get update
fi

apt-get install -y \
    postgresql-common \
    libevent-2.1 \
    libevent-pthreads-2.1 \
    brotli \
    libbrotli1 \
    libsodium23 \
    python3.10 \
    python3-psycopg2

# forbid creation of a main cluster when package is installed
sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf

for version in $DEB_PG_SUPPORTED_VERSIONS; do
    sed -i "s/ main.*$/ main $version/g" /etc/apt/sources.list.d/pgdg.list
    apt-get update

    if [ "$DEMO" != "true" ]; then
        EXTRAS=("postgresql-pltcl-${version}"
                "postgresql-${version}-dirtyread"
                "postgresql-${version}-extra-window-functions"
                "postgresql-${version}-first-last-agg"
                "postgresql-${version}-hll"
                "postgresql-${version}-hypopg"
                "postgresql-${version}-partman"
                "postgresql-${version}-plproxy"
                "postgresql-${version}-pgaudit"
                "postgresql-${version}-pldebugger"
                "postgresql-${version}-pglogical"
                "postgresql-${version}-plpgsql-check"
                "postgresql-${version}-pg-checksums"
                "postgresql-${version}-pgq-node"
                "postgresql-${version}-postgis-${POSTGIS_VERSION%.*}"
                "postgresql-${version}-postgis-${POSTGIS_VERSION%.*}-scripts"
                "postgresql-${version}-repack"
                "postgresql-${version}-wal2json"
                "postgresql-${version}-decoderbufs"
                "postgresql-${version}-pllua"
                "postgresql-${version}-pgvector"
                "postgresql-${version}-roaringbitmap"
                "postgresql-${version}-pgfaceting"
                "postgresql-${version}-pgrouting")

        # pgroonga from Groonga apt repository
        if apt-cache show "postgresql-${version}-pgdg-pgroonga" > /dev/null 2>&1; then
            EXTRAS+=("postgresql-${version}-pgdg-pgroonga")
        fi

        if [ "$version" != "18" ]; then
            EXTRAS+=("postgresql-${version}-pgl-ddl-deploy"
                    "postgresql-${version}-pglogical-ticker")
        fi

        if [ "$WITH_PERL" = "true" ]; then
            EXTRAS+=("postgresql-plperl-${version}")
        fi

    fi

    if [ "${TIMESCALEDB_APACHE_ONLY}" = "true" ]; then
        EXTRAS+=("timescaledb-2-oss-postgresql-${version}")
    else
        EXTRAS+=("timescaledb-2-postgresql-${version}")
    fi

    # Install PostgreSQL binaries, contrib, plproxy and multiple pl's
    apt-get install --allow-downgrades -y \
        "postgresql-${version}-cron" \
        "postgresql-contrib-${version}" \
        "postgresql-${version}-pgextwlist" \
        "postgresql-plpython3-${version}" \
        "postgresql-server-dev-${version}" \
        "postgresql-${version}-pgq3" \
        "postgresql-${version}-pg-stat-kcache" \
        "postgresql-${version}-pg-permissions" \
        "postgresql-${version}-set-user" \
        "${EXTRAS[@]}"

    # Clean up timescaledb versions - keep at least 5 minor versions, but ensure compatibility with the lowest/oldest PG version (where possible)

    exclude_patterns=()
    versions=$(find "/usr/lib/postgresql/$version/lib/" -name 'timescaledb-2.*.so' | sed -rn 's/.*timescaledb-([1-9]+\.[0-9]+\.[0-9]+)\.so$/\1/p' | sort -rV)
    
    # Calculate the number of versions dynamically based on the lowest PG version's latest minor
    num_versions=5
    if [ -n "$first_latest_minor" ]; then
        minor_versions=$(echo "$versions" | awk -F. '{print $1"."$2}' | uniq)
        position=0
        found=0
        while IFS= read -r minor; do
            position=$((position + 1))
            if [ "$minor" = "$first_latest_minor" ]; then
                found=1
                break
            fi
        done <<< "$minor_versions"
        
        # if found, keep max(5, position) versions (so all versions have at least 1 version in common with lowest PG version)
        if [ $found -eq 1 ] && [ $position -gt $num_versions ]; then
            num_versions=$position
        fi
    fi
    
    latest_minor_versions=$(echo "$versions" | awk -F. '{print $1"."$2}' | uniq | head -n "$num_versions")
    for minor in $latest_minor_versions; do
        for full_version in $(echo "$versions" | grep "^$minor"); do
            exclude_patterns+=(! -name timescaledb-"${full_version}".so)
            exclude_patterns+=(! -name timescaledb-tsl-"${full_version}".so)
        done
    done
    find "/usr/lib/postgresql/$version/lib/" \( -name 'timescaledb-2.*.so' -o -name 'timescaledb-tsl-2.*.so' \) "${exclude_patterns[@]}" -delete

    # Save the latest minor version from the first PG version
    if [ -z "$first_latest_minor" ]; then
        first_latest_minor=$(echo "$latest_minor_versions" | head -n 1)
    fi

    # Install 3rd party stuff

    if [ "${TIMESCALEDB_APACHE_ONLY}" != "true" ] && [ "${TIMESCALEDB_TOOLKIT}" = "true" ]; then
        apt-get update
        if [ "$(apt-cache search --names-only "^timescaledb-toolkit-postgresql-${version}$" | wc -l)" -eq 1 ]; then
            apt-get install "timescaledb-toolkit-postgresql-$version"
        else
            echo "Skipping timescaledb-toolkit-postgresql-$version as it's not found in the repository"
        fi
    fi

    EXTRA_EXTENSIONS=()
    if [ "$DEMO" != "true" ]; then
        EXTRA_EXTENSIONS+=("plprofiler" "pg_mon-${PG_MON_COMMIT}")
    fi

    for n in bg_mon-${BG_MON_COMMIT} \
            pg_auth_mon-${PG_ACCESS_MON_COMMIT} \
            pg_profile-${PG_PROFILE} \
            "${EXTRA_EXTENSIONS[@]}"; do
        PATH="/usr/lib/postgresql/$version/bin:$PATH" make -C "$n" USE_PGXS=1 clean
        PATH="/usr/lib/postgresql/$version/bin:$PATH" make -C "$n" USE_PGXS=1 install-strip
    done

    # Build Supabase and additional extensions from source.
    # pgsodium must be built before vault (vault depends on pgsodium).
    build_pgxs_extension "$version" pgsodium "pgsodium-${PGSODIUM_COMMIT}"
    build_pgxs_extension "$version" vault "vault-${VAULT_VERSION}"
    build_pgxs_extension "$version" pg_net "pg_net-${PG_NET_VERSION}"
    build_pgxs_extension "$version" http "pgsql-http-${HTTP_VERSION}"
    build_pgxs_extension "$version" safeupdate "pg-safeupdate-${PG_SAFEUPDATE_VERSION}"
    build_pgxs_extension "$version" pg_hashids "pg_hashids-${PG_HASHIDS_COMMIT}"
    build_pgxs_extension "$version" pg_plan_filter "pg_plan_filter-${PG_PLAN_FILTER_COMMIT}"
    build_pgxs_extension "$version" pg_stat_monitor "pg_stat_monitor-${PG_STAT_MONITOR_VERSION}"
    build_pgxs_extension "$version" pg_tle "pg_tle-${PG_TLE_VERSION}"
    build_pgxs_extension "$version" rum "rum-${RUM_VERSION}"
    build_pgxs_extension "$version" pgjwt "pgjwt-${PGJWT_COMMIT}"
    build_pgxs_extension "$version" index_advisor "index_advisor-${INDEX_ADVISOR_VERSION}"

    # pgmq has a subdirectory structure
    build_pgxs_extension "$version" pgmq "pgmq-${PGMQ_VERSION}/pgmq-extension"

    # pgtap uses make install (not install-strip)
    build_pgxs_extension "$version" pgtap "pgtap-${PGTAP_VERSION}" install

    # supautils is a preload library rather than a standard CREATE EXTENSION package.
    build_pgxs_extension "$version" supautils "supautils-${SUPAUTILS_VERSION}" install

    ARCH=$(dpkg --print-architecture)

    # Install pre-built release artifacts from GitHub Releases (.deb packages)
    for ext_name in pg_graphql pg_jsonschema wrappers; do
        case $ext_name in
            pg_graphql)    ext_ver=$PG_GRAPHQL_VERSION ;;
            pg_jsonschema) ext_ver=$PG_JSONSCHEMA_VERSION ;;
            wrappers)      ext_ver=$WRAPPERS_VERSION ;;
        esac
        asset_name="${ext_name}-v${ext_ver}-pg${version}-${ARCH}-linux-gnu.deb"
        deb_url="https://github.com/supabase/${ext_name}/releases/download/v${ext_ver}/${asset_name}"
        expected_sha=$(lookup_github_release_asset_sha "supabase/${ext_name}" "v${ext_ver}" "$asset_name")
        if [ -z "$expected_sha" ]; then
            if [ "$ext_name" = "wrappers" ]; then
                echo "Skipping wrappers for pg${version}-${ARCH}; upstream v${ext_ver} does not publish ${asset_name}" >&2
                continue
            fi
            echo "ERROR: unable to resolve SHA256 for ${asset_name} from the GitHub release page" >&2
            exit 1
        fi
        if download_and_verify_sha256 "$deb_url" "/tmp/${ext_name}-pg${version}.deb" "$expected_sha"; then
            dpkg -i "/tmp/${ext_name}-pg${version}.deb"
            rm -f "/tmp/${ext_name}-pg${version}.deb"
        else
            echo "Skipping ${ext_name} for pg${version}-${ARCH} (no .deb available)"
        fi
    done
done

apt-get install -y skytools3-ticker pgbouncer

sed -i "s/ main.*$/ main/g" /etc/apt/sources.list.d/pgdg.list
apt-get update
apt-get install -y postgresql postgresql-server-dev-all postgresql-all libpq-dev
for version in $DEB_PG_SUPPORTED_VERSIONS; do
    apt-get install -y "postgresql-server-dev-${version}"
done

if [ "$DEMO" != "true" ]; then
    for version in $DEB_PG_SUPPORTED_VERSIONS; do
        # create postgis symlinks to make it possible to perform update
        ln -s "postgis-${POSTGIS_VERSION%.*}.so" "/usr/lib/postgresql/${version}/lib/postgis-2.5.so"
    done
fi

# make it possible for cron to work without root
gcc -s -shared -fPIC -o /usr/local/lib/cron_unprivileged.so cron_unprivileged.c

apt-get purge -y "${BUILD_PACKAGES[@]}"
apt-get autoremove -y

if [ "$WITH_PERL" != "true" ] || [ "$DEMO" != "true" ]; then
    dpkg -i ./*.deb || apt-get -y -f install
fi

# Remove unnecessary packages
apt-get purge -y \
                libdpkg-perl \
                libperl5.* \
                perl-modules-5.* \
                postgresql \
                postgresql-all \
                postgresql-server-dev-* \
                libpq-dev=* \
                libmagic1 \
                bsdmainutils
apt-get autoremove -y
apt-get clean
dpkg -l | grep '^rc' | awk '{print $2}' | xargs apt-get purge -y

# Try to minimize size by creating symlinks instead of duplicate files
if [ "$DEMO" != "true" ]; then
    cd "/usr/lib/postgresql/$PGVERSION/bin"
    for u in clusterdb \
            pg_archivecleanup \
            pg_basebackup \
            pg_isready \
            pg_recvlogical \
            pg_test_fsync \
            pg_test_timing \
            pgbench \
            reindexdb \
            vacuumlo *.py; do
        for v in /usr/lib/postgresql/*; do
            if [ "$v" != "/usr/lib/postgresql/$PGVERSION" ] && [ -f "$v/bin/$u" ]; then
                rm "$v/bin/$u"
                ln -s "../../$PGVERSION/bin/$u" "$v/bin/$u"
            fi
        done
    done

    set +x

    for v1 in $(find /usr/share/postgresql -type d -mindepth 1 -maxdepth 1 | sort -Vr); do
        # relink files with the same content
        cd "$v1/extension"
        while IFS= read -r -d '' orig
        do
            for f in "${orig%.sql}"--*.sql; do
                if [ ! -L "$f" ] && diff "$orig" "$f" > /dev/null; then
                    echo "creating symlink $f -> $orig"
                    rm "$f" && ln -s "$orig" "$f"
                fi
            done
        done <  <(find . -type f -maxdepth 1 -name '*.sql' -not -name '*--*')

        for e in pgq pgq_node plproxy address_standardizer address_standardizer_data_us; do
            orig=$(basename "$(find . -maxdepth 1 -type f -name "$e--*--*.sql" | head -n1)")
            if [ "x$orig" != "x" ]; then
                for f in "$e"--*--*.sql; do
                    if [ "$f" != "$orig" ] && [ ! -L "$f" ] && diff "$f" "$orig" > /dev/null; then
                        echo "creating symlink $f -> $orig"
                        rm "$f" && ln -s "$orig" "$f"
                    fi
                done
            fi
        done

        # relink files with the same name and content across different major versions
        started=0
        for v2 in $(find /usr/share/postgresql -type d -mindepth 1 -maxdepth 1 | sort -Vr); do
            if [ "$v1" = "$v2" ]; then
                started=1
            elif [ $started = 1 ]; then
                for d1 in extension contrib contrib/postgis-$POSTGIS_VERSION; do
                    cd "$v1/$d1"
                    d2="$d1"
                    d1="../../${v1##*/}/$d1"
                    if [ "${d2%-*}" = "contrib/postgis" ]; then
                        d1="../$d1"
                    fi
                    d2="$v2/$d2"
                    for f in *.html *.sql *.control *.pl; do
                        if [ -f "$d2/$f" ] && [ ! -L "$d2/$f" ] && diff "$d2/$f" "$f" > /dev/null; then
                            echo "creating symlink $d2/$f -> $d1/$f"
                            rm "$d2/$f" && ln -s "$d1/$f" "$d2/$f"
                        fi
                    done
                done
            fi
        done
    done
    set -x
fi

# Clean up
rm -rf /var/lib/apt/lists/* \
        /var/cache/debconf/* \
        /builddeps \
        /usr/share/doc \
        /usr/share/man \
        /usr/share/info \
        /usr/share/locale/?? \
        /usr/share/locale/??_?? \
        /usr/share/postgresql/*/man \
        /etc/pgbouncer/* \
        /usr/lib/postgresql/*/bin/createdb \
        /usr/lib/postgresql/*/bin/createlang \
        /usr/lib/postgresql/*/bin/createuser \
        /usr/lib/postgresql/*/bin/dropdb \
        /usr/lib/postgresql/*/bin/droplang \
        /usr/lib/postgresql/*/bin/dropuser \
        /usr/lib/postgresql/*/bin/pg_standby \
        /usr/lib/postgresql/*/bin/pltcl_*
find /var/log -type f -exec truncate --size 0 {} \;
