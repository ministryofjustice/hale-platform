####################################################
# WordPress multisite image - local development
# Mirrors wordpress.dockerfile so local reproduces the k8s runtime exactly.
# The only differences are the PHP-FPM pool config (listen on all interfaces
# rather than 127.0.0.1, since nginx is a separate container here rather than
# a sidecar sharing a network namespace) and the /opt/scripts mount point.
#
# Dev tooling (mysql client, wp-cli against the database) lives in the
# `wptools` service in docker-compose.yml, matching the wptools sidecar in
# k8s. Keeping this image identical to production is the point - it is what
# catches path and permission problems before they reach a cluster.
#
# No platform pin here: let docker-compose.yml control the target architecture
# for local builds. Production (wordpress.dockerfile) stays amd64.
# ##################################################

ARG WORDPRESS_VERSION=7.1
ARG PHP_VERSION=8.5

# ---------------------------------------------------------------------------
# Extension stage: compile PHPRedis.
#
# Built in the official PHP image rather than the DHI one, because no DHI
# variant ships phpize or php-config - "-dev" there means the image has a shell
# and a package manager, not that it carries development headers. Debian's
# php<version>-dev was filling that gap, which capped PHP at whatever Debian
# packages; the official image tracks upstream releases and bundles pecl, so
# that ceiling is gone.
#
# Only redis.so leaves this stage. The shell, the package manager and the root
# user it needs never reach the runtime image, which is still COPY-only.
#
# The .so is loaded by a PHP that did not build it. That is sound: extension
# compatibility is defined by the ABI triple - PHP API number, thread safety and
# debug build - which matches for any build of the same PHP minor version. It is
# the same guarantee the previous approach relied on, against a different
# provider.
#
# Pinned and checksum-verified: this is compiled C loaded into every PHP-FPM
# process, and a bare "pecl install redis" takes whatever is latest on the day.
# pecl publishes no per-release hash, so this attests to the bytes fetched when
# the pin was set. Bump both together - https://pecl.php.net/package/redis
# ---------------------------------------------------------------------------
FROM php:${PHP_VERSION}-cli AS extbuilder

ARG PHPREDIS_VERSION=6.3.0
ARG PHPREDIS_SHA256=0d5141f634bd1db6c1ddcda053d25ecf2c4fc1c395430d534fd3f8d51dd7f0b5
# --retry with --retry-all-errors covers transient 5xx and connection failures.
# curl -f fails hard on any HTTP error, so a single bad gateway from GitHub or
# pecl kills the whole build - which is a poor trade for a fetch that succeeds on
# the next attempt.
RUN curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o /tmp/redis.tgz \
        "https://pecl.php.net/get/redis-${PHPREDIS_VERSION}.tgz" \
    && echo "${PHPREDIS_SHA256}  /tmp/redis.tgz" | sha256sum -c - \
    && pecl install /tmp/redis.tgz \
    && cp "$(php-config --extension-dir)/redis.so" /tmp/redis.so \
    && echo "extension=/usr/local/lib/php-extensions/redis.so" > /tmp/docker-php-ext-redis.ini \
    && rm -rf /tmp/redis.tgz

# ---------------------------------------------------------------------------
# Builder stage - see wordpress.dockerfile for the rationale.
# ---------------------------------------------------------------------------
# Image versions - the only place either is written. Both are consumed solely by
# the FROM tags below, so bumping either is a one-line edit here.
#
# PHP_VERSION drives three tags: the two DHI stages and the official php image
# the extension is compiled in. It is no longer bounded by what Debian packages.
# That mattered: no DHI variant ships phpize or php-config - verified in CI,
# /usr/bin holds only `php` and `php-8.4`, and "-dev" there means the image has
# a shell and a package manager, not development headers - so the only source of
# build tooling was Debian's php<version>-dev, which stops at 8.4 on trixie.
#
# Core and PHP still bump independently: wptools installs its own Alpine php8X-*
# packages and CI resolves composer under setup-php, so a PHP bump is four files.
# bin/check-versions.sh asserts they agree.
#
# Hunspell dictionaries. From Alpine because Debian's hunspell-en-gb ships
# en_GB alone and the justice theme asks for en_GB-large, which PhpSpellcheck
# passes straight to `hunspell -d`. Safe to mix: .aff and .dic are plain text
# with no linkage to a C library. Full reasoning in wordpress.dockerfile.
FROM alpine:3.24 AS dictionaries

RUN apk add --no-cache hunspell-en-gb

FROM dhi.io/wordpress:${WORDPRESS_VERSION}-php${PHP_VERSION}-fpm-dev AS builder

# PHP_VERSION is consumed by the FROM tags above and nothing else.
USER root

# Nothing is compiled in this stage any more - the extension is built in
# extbuilder above - so this is just what is needed to fetch and unpack: wp-cli
# and the translation packs.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# External binaries the application shells out to. ImageMagick forks `gs` to
# rasterise a PDF, so without it every PDF upload fails in
# wp_generate_attachment_metadata; the justice theme forks `hunspell` to
# spellcheck content on a cron hook, and without it that cron run dies on an
# uncaught ProcessFailedException. Downloaded and unpacked rather than
# installed, because dpkg cannot configure these packages in this image - and
# the runtime needs their files, not their maintainer scripts. apt downloads
# only what this stage lacks, so the COPY below shadows nothing. `ldconfig -n`
# creates the SONAME symlinks dpkg-deb does not unpack.
# Full reasoning in wordpress.dockerfile.
RUN mkdir -p /tmp/debs/partial /tmp/sysdeps \
    && apt-get update \
    && apt-get install -y --no-install-recommends --download-only \
        -o Dir::Cache::archives=/tmp/debs \
        -o APT::Keep-Downloaded-Packages=true \
        ghostscript \
        fonts-urw-base35 \
        hunspell \
    && for deb in /tmp/debs/*.deb; do dpkg-deb -x "$deb" /tmp/sysdeps; done \
    && rm -rf /tmp/debs /var/lib/apt/lists/* \
    && rm -rf /tmp/sysdeps/usr/share/doc /tmp/sysdeps/usr/share/man /tmp/sysdeps/usr/share/lintian \
    && ldconfig -n /tmp/sysdeps/usr/lib/x86_64-linux-gnu \
    && for bin in gs hunspell; do \
        test -x "/tmp/sysdeps/usr/bin/$bin" || exit 1; \
        if LD_LIBRARY_PATH=/tmp/sysdeps/usr/lib/x86_64-linux-gnu \
            ldd "/tmp/sysdeps/usr/bin/$bin" | grep -q "not found"; then \
            echo "unresolved libraries for $bin"; exit 1; \
        fi; \
    done \
    && echo "libraries not staged, so expected in the runtime base:" \
    && { for bin in gs hunspell; do \
            LD_LIBRARY_PATH=/tmp/sysdeps/usr/lib/x86_64-linux-gnu \
                ldd "/tmp/sysdeps/usr/bin/$bin"; \
        done; } \
        | awk '$3 ~ /^\// {print $3}' | grep -v '^/tmp/sysdeps' | sort -u | sed 's/^/  /'


# wp-cli, pinned and checksum-verified. Fetching an unpinned phar from a raw
# git host and executing it is a supply-chain risk: this binary runs with full
# database access during multisite bootstrap, so a swapped or compromised build
# would be executing as us. Bump both values together - wp-cli publishes the
# checksum alongside each release as wp-cli-<version>.phar.sha512.
ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832
RUN curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o /tmp/wp \
    "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" \
    && echo "${WP_CLI_SHA512}  /tmp/wp" | sha512sum -c - \
    && chmod +x /tmp/wp

# /opt/scripts is a volume mount point locally; the directory has to exist and
# the uploads folder is staged here because the runtime stage has no shell.
RUN mkdir -p /tmp/uploads /tmp/optscripts

# ---------------------------------------------------------------------------
# Runtime stage. COPY only - no RUN, no package manager, no root.
# ---------------------------------------------------------------------------
FROM dhi.io/wordpress:${WORDPRESS_VERSION}-php${PHP_VERSION}-fpm

# Version-independent paths: the .so is referenced by absolute path from the
# .ini, so neither the PHP version nor the ABI number appears here. PHP_INI_DIR
# comes from the base image, so a PHP bump follows the FROM tag automatically.
COPY --from=extbuilder /tmp/redis.so /usr/local/lib/php-extensions/redis.so
COPY --from=extbuilder /tmp/docker-php-ext-redis.ini ${PHP_INI_DIR}/conf.d/docker-php-ext-redis.ini

COPY --from=builder --chmod=0755 /tmp/wp /usr/local/bin/wp

# Ghostscript (staged in the builder above), at its installed paths. Only files
# absent from the base image are in the tree, so this adds and never replaces.
COPY --from=builder /tmp/sysdeps/ /

# Hunspell dictionaries (Alpine stage above).
COPY --from=dictionaries /usr/share/hunspell /usr/share/hunspell

# Add PHP multsite supporting files
COPY opt/php/load.php /usr/src/wordpress/wp-content/mu-plugins/load.php
COPY opt/php/application.php /usr/src/wordpress/wp-content/mu-plugins/application.php
COPY opt/php/error-handling.php /usr/src/wordpress/error-handling.php
COPY opt/php/wp-cron-multisite.php /usr/src/wordpress/wp-cron-multisite.php
# Health endpoint. Reachable only through the internal 8090 listener; the
# public server block denies /healthz.php by path.
COPY opt/php/healthz.php /usr/src/wordpress/healthz.php

COPY opt/php/www.local.conf ${PHP_INI_DIR}/php-fpm.d/www.conf

# Setup WordPress multisite and network
COPY --chmod=0755 opt/scripts/hale-entrypoint.sh /usr/local/bin/
COPY --chmod=0755 opt/scripts/config.sh /usr/local/bin/
COPY --chmod=0755 opt/scripts/startup-patch.sh /usr/local/bin/

# Composer and NPM artifacts. COPY copies a symlink as a symlink, so building
# while the dev links created by opt/scripts/link-dev-packages.sh are in place
# bakes dangling links to /mnt/dev into the image. The wp-content bind mount
# hides that locally, so nothing reports it. `make build` deletes wordpress/
# before composer runs, which is what keeps these directories real - build
# through make, not with a bare `docker compose build`.
COPY --chown=65532:65532 /wordpress/wp-content/plugins /usr/src/wordpress/wp-content/plugins
COPY --chown=65532:65532 /wordpress/wp-content/mu-plugins /usr/src/wordpress/wp-content/mu-plugins
COPY --chown=65532:65532 /wordpress/wp-content/themes /usr/src/wordpress/wp-content/themes
COPY --chown=65532:65532 /vendor /usr/src/wordpress/wp-content/vendor

COPY --from=builder --chown=65532:65532 /tmp/uploads /usr/src/wordpress/wp-content/uploads

# Volume mount point for ./opt/scripts - must exist before the bind mount
COPY --from=builder --chown=65532:65532 /tmp/optscripts /opt/scripts

ENTRYPOINT ["/usr/local/bin/hale-entrypoint.sh"]

USER 65532
