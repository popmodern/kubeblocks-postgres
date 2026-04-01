ARG BASE_IMAGE=ubuntu:22.04
ARG PGVERSION=18
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
ARG PGOLDVERSIONS="14 15 16 17"
ARG WITH_PERL=false

ARG DEB_PG_SUPPORTED_VERSIONS="$PGOLDVERSIONS $PGVERSION"

# Install PostgreSQL, extensions and contribs
ENV POSTGIS_VERSION=3.6 \
    BG_MON_COMMIT=a73c6bcd10dfdf9feaf5eabab7eb6b12d167680d \
    PG_AUTH_MON_COMMIT=fe099eef7662cbc85b0b79191f47f52f1e96b779 \
    PG_MON_COMMIT=88ac7b58348aa061c814982defc170644f368f39 \
    PLPROFILER=REL4_2_5 \
    PG_PROFILE=4.11 \
    PAM_OAUTH2=v1.0.1 \
    CURL_VERSION=8.10.1 \
    CURL_TARBALL_SHA256=d15ebab765d793e2e96db090f0e172d127859d78ca6f6391d7eafecfd894bbc0 \
    PGSODIUM_VERSION=3.1.8 \
    VAULT_VERSION=0.3.1 \
    PG_NET_VERSION=0.20.0 \
    SUPAUTILS_VERSION=2.8.0 \
    HTTP_VERSION=1.6.1 \
    PG_SAFEUPDATE_VERSION=1.4 \
    PG_HASHIDS_COMMIT=cd0e1b31d52b394a0df64079406a14a4f7387cd6 \
    PG_PLAN_FILTER_COMMIT=5081a7b5cb890876e67d8e7486b6a64c38c9a492 \
    PG_STAT_MONITOR_VERSION=2.1.0 \
    PG_TLE_VERSION=1.4.0 \
    RUM_VERSION=1.3.14 \
    PGJWT_COMMIT=f3d82fd30151e754e19ce5d6a06c71c20689ce3d \
    PGMQ_VERSION=1.5.1 \
    INDEX_ADVISOR_VERSION=0.2.0 \
    PGTAP_VERSION=1.3.3 \
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
COPY build_scripts/post_build.sh /builddeps/

RUN sh /builddeps/post_build.sh && rm -rf /builddeps/

COPY scripts bootstrap major_upgrade /scripts/
COPY launch.sh /

CMD ["/bin/sh", "/launch.sh", "init"]
