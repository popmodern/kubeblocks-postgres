ARG BASE_IMAGE=ubuntu:22.04
ARG PGVERSION=17
ARG DEMO=false
ARG COMPRESS=false
ARG ADDITIONAL_LOCALES=


FROM ubuntu:18.04 AS ubuntu-18

ARG ADDITIONAL_LOCALES

COPY build_scripts/locales.sh /builddeps/

RUN bash /builddeps/locales.sh


FROM $BASE_IMAGE AS dependencies-builder

ARG DEMO

ENV WALG_VERSION=v3.0.8

COPY build_scripts/dependencies.sh /builddeps/

COPY dependencies/debs /builddeps/

RUN bash /builddeps/dependencies.sh


FROM $BASE_IMAGE AS builder-false

ARG DEMO
ARG ADDITIONAL_LOCALES

COPY build_scripts/prepare.sh build_scripts/locales.sh /builddeps/

RUN bash /builddeps/prepare.sh

COPY --from=ubuntu-18 /usr/lib/locale/locale-archive /usr/lib/locale/locale-archive.18

COPY cron_unprivileged.c /builddeps/
COPY build_scripts/base.sh /builddeps/
COPY --from=dependencies-builder /builddeps/*.deb /builddeps/

ARG PGVERSION
ARG TIMESCALEDB_APACHE_ONLY=true
ARG TIMESCALEDB_TOOLKIT=true
ARG COMPRESS
ARG PGOLDVERSIONS="14 15 16"
ARG WITH_PERL=false

ARG DEB_PG_SUPPORTED_VERSIONS="$PGOLDVERSIONS $PGVERSION"

# Install PostgreSQL, extensions and contribs
ENV POSTGIS_VERSION=3.6 \
    BG_MON_COMMIT=a73c6bcd10dfdf9feaf5eabab7eb6b12d167680d \
    PG_ACCESS_MON_COMMIT=fe099eef7662cbc85b0b79191f47f52f1e96b779 \
    PG_MON_COMMIT=88ac7b58348aa061c814982defc170644f368f39 \
    PLPROFILER=REL4_2_5 \
    PLPROFILER_COMMIT=92c4d4af1823b4e56740dd2c07d68f53c4188de4 \
    PG_PROFILE=4.11 \
    PG_PROFILE_COMMIT=306f0fed2663cf8aaa9a88373de4394e75e31f19 \
    PAM_OAUTH2=v1.0.1 \
    PAM_OAUTH2_COMMIT=3dd86d6759be51ff0b5eb829a0c542d580ff97fc \
    CURL_VERSION=8.10.1 \
    CURL_TARBALL_SHA256=d15ebab765d793e2e96db090f0e172d127859d78ca6f6391d7eafecfd894bbc0 \
    PGSODIUM_VERSION=3.1.9 \
    PGSODIUM_COMMIT=7222ebc5ed87084a68d526aef977be0f4eb319a2 \
    VAULT_VERSION=0.3.1 \
    VAULT_COMMIT=6e0cd916242d922a646e4d611cc215e09dd429f4 \
    PG_NET_VERSION=0.20.2 \
    PG_NET_COMMIT=8203cb72c87479d39c9e3e47ce3e493242110f83 \
    SUPAUTILS_VERSION=3.2.0 \
    SUPAUTILS_COMMIT=6d20b577253f57689ce590602286b5bf4f19556e \
    HTTP_VERSION=1.7.0 \
    HTTP_COMMIT=fbea6fe46c9e1db5a18103606ec00a9809e91d11 \
    PG_SAFEUPDATE_VERSION=1.4 \
    PG_SAFEUPDATE_COMMIT=104f78d27b607076b49f22927ba33828fd0a98a0 \
    PG_HASHIDS_COMMIT=cd0e1b31d52b394a0df64079406a14a4f7387cd6 \
    PG_PLAN_FILTER_COMMIT=5081a7b5cb890876e67d8e7486b6a64c38c9a492 \
    PG_STAT_MONITOR_VERSION=2.3.1 \
    PG_STAT_MONITOR_COMMIT=bcd345a8738c412bb0626e34cd6c34857d5a1924 \
    PG_TLE_VERSION=1.5.2 \
    PG_TLE_COMMIT=5b953dd51161a02e4c4e22860ecaaef137649777 \
    RUM_VERSION=1.3.15 \
    RUM_COMMIT=d66640112d88572d21dc93ff873cafe3b11c9521 \
    PGJWT_COMMIT=f3d82fd30151e754e19ce5d6a06c71c20689ce3d \
    PGMQ_VERSION=1.5.1 \
    PGMQ_COMMIT=7fd411d8ffd53b5313039f59167124c861d46430 \
    INDEX_ADVISOR_VERSION=0.2.0 \
    INDEX_ADVISOR_COMMIT=d37723555e6425f18e6a45cb0956ced2250a3fe7 \
    PGTAP_VERSION=1.3.4 \
    PGTAP_COMMIT=968eb53a33114e83042b3bdb0c664b5b80cf8bdf \
    PG_GRAPHQL_VERSION=1.5.12 \
    PG_JSONSCHEMA_VERSION=0.3.4 \
    WRAPPERS_VERSION=0.6.0

WORKDIR /builddeps
RUN bash base.sh

# Install wal-g
COPY --from=dependencies-builder /builddeps/wal-g /usr/local/bin/

COPY build_scripts/patroni.sh build_scripts/compress_build.sh /builddeps/

# Install patroni
ENV PATRONIVERSION=4.1.0

WORKDIR /

RUN bash /builddeps/patroni.sh

RUN if [ "$COMPRESS" = "true" ]; then bash /builddeps/compress_build.sh; fi


FROM scratch AS builder-true
COPY --from=builder-false / /


FROM builder-${COMPRESS}

LABEL maintainer="Team ACID @ Zalando <team-acid@zalando.de>"

ARG PGVERSION
ARG DEMO
ARG COMPRESS

EXPOSE 5432 8008 8080

ENV LC_ALL=en_US.utf-8 \
    PATH=$PATH:/usr/lib/postgresql/$PGVERSION/bin \
    PGHOME=/home/postgres \
    RW_DIR=/run \
    DEMO=$DEMO

ENV WALG_ENV_DIR=$RW_DIR/etc/wal-e.d/env \
    LOG_ENV_DIR=$RW_DIR/etc/log.d/env \
    PGROOT=$PGHOME/pgdata/pgroot

ENV PGDATA=$PGROOT/data \
    PGLOG=$PGROOT/pg_log

ENV USE_OLD_LOCALES=false

WORKDIR $PGHOME

COPY motd /etc/
COPY runit /etc/service/
COPY pgq_ticker.ini $PGHOME/
COPY build_scripts/post_build.sh build_scripts/verify_commands.sh /builddeps/

RUN sh /builddeps/post_build.sh

COPY scripts bootstrap major_upgrade /scripts/
RUN chmod +x /scripts/pgsodium_getkey.sh && sh /builddeps/verify_commands.sh && rm -rf /builddeps/
COPY launch.sh /

CMD ["/bin/sh", "/launch.sh", "init"]
