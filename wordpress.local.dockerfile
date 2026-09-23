####################################################
# WordPress multisite image - local development
#
# The local version of wordpress.dockerfile, built by docker compose. It uses
# the same stages and the same hardened base image, so path and permission
# problems show up locally before they reach a cluster. wordpress.dockerfile
# explains each stage in full; the comments here are shorter.
#
# How it differs from wordpress.dockerfile:
#   - No --platform on the FROM lines. docker-compose.yml picks the
#     architecture (arm64 locally); the deployed image is amd64.
#   - php-fpm uses www.local.conf, which listens on port 9000 on every
#     address. nginx runs in its own container here, so it can't reach
#     127.0.0.1 inside this one.
#   - An empty /opt/scripts folder, which docker compose mounts ./opt/scripts
#     over.
#   - No translations, Query Monitor drop-in or wpdr-document-upload-dir.php.
#     ./wordpress/wp-content is mounted over wp-content locally, and
#     bin/local-build.sh downloads the translations into that folder instead.
#
# Database tools (the mysql client, wp db) are in the wptools service in
# docker-compose.yml, as they are in the wptools sidecar in Kubernetes.
# ##################################################

# Image versions. Keep them the same as wordpress.dockerfile -
# bin/check-versions.sh (make check-versions) fails if they differ.
ARG WORDPRESS_VERSION=7.0.4
ARG PHP_VERSION=8.4

# WordPress core patch. Same purpose and same two values as
# wordpress.dockerfile, which explains them in full: the builder stage
# downloads this release and the runtime stage copies its files over the DHI
# image's core, so local runs the version the cluster runs. Empty both when
# WORDPRESS_VERSION catches up. Change the two together - the SHA-256 is the
# sha256sum of the .zip, checked against wordpress.org's published SHA-1.
ARG PATCH_WORDPRESS_VERSION=7.0.6
ARG PATCH_WORDPRESS_SHA256=ceea51247a0a78428a3a12cbf02bb869a5a215899a5aabd8b7fb6c0dba3554aa

# ---------------------------------------------------------------------------
# Extension stage: build the PHPRedis extension (redis.so).
#
# Downloads a pinned PHPRedis release from pecl, checks its SHA-256 and
# compiles it. This uses the official php image because it has phpize and
# php-config, which no DHI image includes. The runtime stage copies only
# redis.so and its one-line .ini.
#
# A redis.so built here loads in the DHI image because both are builds of the
# same PHP minor version - see wordpress.dockerfile. Change PHPREDIS_VERSION and
# PHPREDIS_SHA256 together, here and in wordpress.dockerfile -
# https://pecl.php.net/package/redis
# ---------------------------------------------------------------------------
FROM php:${PHP_VERSION}-cli AS extbuilder

ARG PHPREDIS_VERSION=6.3.0
ARG PHPREDIS_SHA256=0d5141f634bd1db6c1ddcda053d25ecf2c4fc1c395430d534fd3f8d51dd7f0b5
# Retries up to 3 times on any error, including a dropped connection or a
# temporary 5xx from pecl. -f makes curl fail on an HTTP error instead of
# saving the error page, so without retries one bad response fails the build.
RUN curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o /tmp/redis.tgz \
        "https://pecl.php.net/get/redis-${PHPREDIS_VERSION}.tgz" \
    && echo "${PHPREDIS_SHA256}  /tmp/redis.tgz" | sha256sum -c - \
    && pecl install /tmp/redis.tgz \
    && cp "$(php-config --extension-dir)/redis.so" /tmp/redis.so \
    && echo "extension=/usr/local/lib/php-extensions/redis.so" > /tmp/docker-php-ext-redis.ini \
    && rm -rf /tmp/redis.tgz

# ---------------------------------------------------------------------------
# Dictionaries stage: the hunspell dictionaries (en_GB and en_GB-large).
#
# Taken from Alpine because the justice theme uses en_GB-large and Debian's
# hunspell-en-gb package only has en_GB. The files are plain text, so mixing
# distributions is safe - see wordpress.dockerfile.
# ---------------------------------------------------------------------------
FROM alpine:3.24 AS dictionaries

RUN apk add --no-cache hunspell-en-gb

# ---------------------------------------------------------------------------
# Builder stage: prepares the files the runtime stage copies in.
#
# The -dev variant of the same DHI WordPress image, which adds a shell and apt.
# Nothing from this stage reaches the runtime image except what it leaves in
# /tmp: sysdeps (ghostscript, hunspell, the locale), wp (wp-cli), core (the
# WordPress core patch), uploads and optscripts.
# ---------------------------------------------------------------------------
FROM dhi.io/wordpress:${WORDPRESS_VERSION}-php${PHP_VERSION}-fpm-dev AS builder

# An ARG set before the first FROM has to be declared again to be used inside
# a stage. These are for the core patch below.
ARG WORDPRESS_VERSION
ARG PATCH_WORDPRESS_VERSION
ARG PATCH_WORDPRESS_SHA256

# Root, for apt. The runtime stage runs as 65532.
USER root

# Tools for the downloads below.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# ghostscript, hunspell and the C.UTF-8 locale. PDF thumbnails run gs, and the
# justice theme's spellcheck runs hunspell. The packages are downloaded and
# unpacked into /tmp/sysdeps rather than installed, because dpkg can't
# configure them in this image and the runtime only needs their files.
# `ldconfig -n` adds the short library links (libgs.so.10) that unpacking
# leaves out. The multiarch library directory is discovered rather than named:
# this image has no --platform pin, so it builds for the host architecture and
# the directory is aarch64-linux-gnu on an Apple Silicon machine where
# wordpress.dockerfile, pinned to amd64, always gets x86_64-linux-gnu.
# wordpress.dockerfile explains each step.
RUN mkdir -p /tmp/debs/partial /tmp/sysdeps \
    && apt-get update \
    && apt-get install -y --no-install-recommends --download-only \
        -o Dir::Cache::archives=/tmp/debs \
        -o APT::Keep-Downloaded-Packages=true \
        ghostscript \
        fonts-urw-base35 \
        hunspell \
    && for deb in /tmp/debs/*.deb; do dpkg-deb -x "$deb" /tmp/sysdeps; done \
    && mkdir -p /tmp/libcdeb /tmp/sysdeps/usr/lib/locale \
    && ( cd /tmp/libcdeb && apt-get download libc-bin ) \
    && dpkg-deb -x /tmp/libcdeb/libc-bin_*.deb /tmp/libc \
    && cp -a /tmp/libc/usr/lib/locale/C.utf8 /tmp/sysdeps/usr/lib/locale/ \
    && test -f /tmp/sysdeps/usr/lib/locale/C.utf8/LC_CTYPE \
    && rm -rf /tmp/libcdeb /tmp/libc /tmp/debs /var/lib/apt/lists/* \
    && rm -rf /tmp/sysdeps/usr/share/doc /tmp/sysdeps/usr/share/man /tmp/sysdeps/usr/share/lintian \
    && libdir="$(ls -d /tmp/sysdeps/usr/lib/*-linux-gnu 2>/dev/null | head -n1)" \
    && if [ -z "$libdir" ]; then \
        echo "no multiarch library directory under /tmp/sysdeps/usr/lib"; exit 1; \
    fi \
    && ldconfig -n "$libdir" \
    && for bin in gs hunspell; do \
        test -x "/tmp/sysdeps/usr/bin/$bin" || exit 1; \
        if LD_LIBRARY_PATH="$libdir" \
            ldd "/tmp/sysdeps/usr/bin/$bin" | grep -q "not found"; then \
            echo "unresolved libraries for $bin"; exit 1; \
        fi; \
    done \
    && echo "libraries not staged, so expected in the runtime base:" \
    && { for bin in gs hunspell; do \
            LD_LIBRARY_PATH="$libdir" \
                ldd "/tmp/sysdeps/usr/bin/$bin"; \
        done; } \
        | awk '$3 ~ /^\// {print $3}' | grep -v '^/tmp/sysdeps' | sort -u | sed 's/^/  /'


# wp-cli, downloaded here because the runtime image has no curl.
#
# Pinned and checked against its SHA-512. wp-cli runs with full database access
# every time a container starts (config.sh), so a tampered download would too.
# wp-cli publishes the checksum next to each release as
# wp-cli-<version>.phar.sha512 - change WP_CLI_VERSION and WP_CLI_SHA512
# together.
ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832
RUN curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o /tmp/wp \
    "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" \
    && echo "${WP_CLI_SHA512}  /tmp/wp" | sha512sum -c - \
    && chmod +x /tmp/wp

# WordPress core patch: PATCH_WORDPRESS_VERSION's core files, staged in
# /tmp/core for the runtime stage to copy over /usr/src/wordpress. The
# release's own wp-content is left out, so wp-content is the same with or
# without the patch. With PATCH_WORDPRESS_VERSION empty, /tmp/core stays empty
# and that COPY changes nothing. wordpress.dockerfile explains each check.
RUN set -e; \
    mkdir -p /tmp/core; \
    if [ -n "${PATCH_WORDPRESS_VERSION}" ]; then \
        newest=$(printf '%s\n%s\n' "${WORDPRESS_VERSION}" "${PATCH_WORDPRESS_VERSION}" | sort -V | tail -n1); \
        if [ "${PATCH_WORDPRESS_VERSION}" = "${WORDPRESS_VERSION}" ] || [ "${newest}" != "${PATCH_WORDPRESS_VERSION}" ]; then \
            echo "PATCH_WORDPRESS_VERSION (${PATCH_WORDPRESS_VERSION}) is not newer than WORDPRESS_VERSION (${WORDPRESS_VERSION}). Empty it."; \
            exit 1; \
        fi; \
        echo "Patching WordPress core from ${WORDPRESS_VERSION} to ${PATCH_WORDPRESS_VERSION}"; \
        curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o /tmp/wordpress.zip \
            "https://wordpress.org/wordpress-${PATCH_WORDPRESS_VERSION}.zip"; \
        echo "${PATCH_WORDPRESS_SHA256}  /tmp/wordpress.zip" | sha256sum -c -; \
        unzip -q /tmp/wordpress.zip -d /tmp/release; \
        (cd /usr/src/wordpress && find wp-admin wp-includes -type f) > /tmp/base-files; \
        missing=$(while read -r f; do [ -e "/tmp/release/wordpress/$f" ] || echo "  $f"; done < /tmp/base-files); \
        if [ -n "${missing}" ]; then \
            echo "Files in the ${WORDPRESS_VERSION} core that ${PATCH_WORDPRESS_VERSION} does not have:"; \
            echo "${missing}"; \
            exit 1; \
        fi; \
        grep -qF "\$wp_version = '${PATCH_WORDPRESS_VERSION}';" /tmp/release/wordpress/wp-includes/version.php \
            || { echo "version.php in the download is not ${PATCH_WORDPRESS_VERSION}"; exit 1; }; \
        rm -rf /tmp/release/wordpress/wp-content; \
        cp -a /tmp/release/wordpress/. /tmp/core/; \
        rm -rf /tmp/wordpress.zip /tmp/release /tmp/base-files; \
    fi

# Two empty folders for the runtime stage, which only uses COPY: the uploads
# folder, and /opt/scripts, which docker compose mounts ./opt/scripts over.
RUN mkdir -p /tmp/uploads /tmp/optscripts

# ---------------------------------------------------------------------------
# Runtime stage: the image docker compose runs.
#
# No RUN instructions - only COPY, ENV, ENTRYPOINT and USER, as in
# wordpress.dockerfile.
# ---------------------------------------------------------------------------
FROM dhi.io/wordpress:${WORDPRESS_VERSION}-php${PHP_VERSION}-fpm

# PHPRedis, from the extbuilder stage. The .ini loads redis.so by its full
# path, so these paths do not depend on the PHP version or on PHP's own
# extension folder. PHP_INI_DIR is set by the base image and follows
# PHP_VERSION.
COPY --from=extbuilder /tmp/redis.so /usr/local/lib/php-extensions/redis.so
COPY --from=extbuilder /tmp/docker-php-ext-redis.ini ${PHP_INI_DIR}/conf.d/docker-php-ext-redis.ini

# wp-cli, from the builder stage.
COPY --from=builder --chmod=0755 /tmp/wp /usr/local/bin/wp

# ghostscript with its fonts and libraries, hunspell, and the C.UTF-8 locale,
# from the builder stage. The folder only holds packages this image does not
# already have, so this COPY adds files and never replaces one.
COPY --from=builder /tmp/sysdeps/ /

# Hunspell dictionaries (en_GB and en_GB-large) from the dictionaries stage.
COPY --from=dictionaries /usr/share/hunspell /usr/share/hunspell

# Use the C.UTF-8 locale, from the builder stage. The DHI image has no locale
# data of its own, so without it glibc reports ASCII and hunspell fails on every
# accented word. See wordpress.dockerfile.
ENV LANG=C.UTF-8

# WordPress core patch from the builder stage, over the DHI image's core. The
# folder is empty when PATCH_WORDPRESS_VERSION is empty, and this COPY then
# changes nothing.
COPY --from=builder --chown=65532:65532 /tmp/core/ /usr/src/wordpress/

# Platform PHP files: the must-use plugin loader and Composer autoloader,
# PHP error logging, and the script that runs cron for every site.
COPY opt/php/load.php /usr/src/wordpress/wp-content/mu-plugins/load.php
COPY opt/php/application.php /usr/src/wordpress/wp-content/mu-plugins/application.php
COPY opt/php/error-handling.php /usr/src/wordpress/error-handling.php
COPY opt/php/wp-cron-multisite.php /usr/src/wordpress/wp-cron-multisite.php
# Health check script for /healthz. Only reachable through nginx's internal
# port 8090 listener - the public site blocks /healthz.php.
COPY opt/php/healthz.php /usr/src/wordpress/healthz.php

# PHP-FPM pool settings for local: listens on port 9000 on every address,
# because nginx runs in its own container.
COPY opt/php/www.local.conf ${PHP_INI_DIR}/php-fpm.d/www.conf

# Readiness-probe pool on port 9001. See wordpress.dockerfile.
COPY opt/php/healthz.local.conf ${PHP_INI_DIR}/php-fpm.d/healthz.conf

# Start-up scripts. hale-entrypoint.sh runs the image's docker-entrypoint.sh
# with config.sh added before php-fpm starts; config.sh sets up wp-config.php
# and the multisite network; startup-patch.sh stops a harmless tar permissions
# error on the webroot from failing start-up.
COPY --chmod=0755 opt/scripts/hale-entrypoint.sh /usr/local/bin/
COPY --chmod=0755 opt/scripts/config.sh /usr/local/bin/
COPY --chmod=0755 opt/scripts/startup-patch.sh /usr/local/bin/

# Plugins, themes and Composer packages. COPY copies a symlink as a symlink, so
# building while opt/scripts/link-dev-packages.sh's dev links are in place puts
# broken links to /mnt/dev into the image - and the wp-content bind mount hides
# them locally, so nothing reports it. `make build` deletes wordpress/ before
# composer runs, which turns the links back into real folders. Build with make,
# not a bare `docker compose build`.
COPY --chown=65532:65532 /wordpress/wp-content/plugins /usr/src/wordpress/wp-content/plugins
COPY --chown=65532:65532 /wordpress/wp-content/mu-plugins /usr/src/wordpress/wp-content/mu-plugins
COPY --chown=65532:65532 /wordpress/wp-content/themes /usr/src/wordpress/wp-content/themes
COPY --chown=65532:65532 /vendor /usr/src/wordpress/wp-content/vendor

# Empty uploads folder, from the builder stage.
COPY --from=builder --chown=65532:65532 /tmp/uploads /usr/src/wordpress/wp-content/uploads

# Mount point for ./opt/scripts. The folder has to exist before docker compose
# can mount over it.
COPY --from=builder --chown=65532:65532 /tmp/optscripts /opt/scripts

# Start through hale-entrypoint.sh instead of the image's docker-entrypoint.sh.
ENTRYPOINT ["/usr/local/bin/hale-entrypoint.sh"]

# 65532 is already the base image's default user. Set here anyway so a change
# to the base image can never make this container run as root.
USER 65532
