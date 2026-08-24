####################################################
# WordPress multisite image - local development
# Mirrors wordpress.dockerfile so local reproduces the k8s runtime exactly.
# The only differences are the PHP-FPM pool config (listen on all interfaces
# rather than 127.0.0.1, since nginx is a separate container here rather than
# a sidecar sharing a network namespace) and the /opt/scripts mount point.
#
# Dev tooling (mysql client, wp-cli against the database) lives in the
# `wp-tools` service in docker-compose.yml, matching the wp-tools sidecar in
# k8s. Keeping this image identical to production is the point - it is what
# catches path and permission problems before they reach a cluster.
#
# No platform pin here: let docker-compose.yml control the target architecture
# for local builds. Production (wordpress.dockerfile) stays amd64.
# ##################################################

# ---------------------------------------------------------------------------
# Builder stage - see wordpress.dockerfile for the rationale.
# ---------------------------------------------------------------------------
# Image version, declared once. PHP_VERSION must match the version in the tag:
# it selects the Debian -dev headers the Redis extension is compiled against.
ARG WORDPRESS_VERSION=7.0.4
ARG PHP_VERSION=8.4

FROM dhi.io/wordpress:${WORDPRESS_VERSION}-php${PHP_VERSION}-fpm-dev AS builder

ARG PHP_VERSION
USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        php${PHP_VERSION}-dev \
        php-pear \
        pkg-config \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

RUN pecl install redis \
    && cp "$(php-config --extension-dir)/redis.so" /tmp/redis.so \
    && echo "extension=/usr/local/lib/php-extensions/redis.so" > /tmp/docker-php-ext-redis.ini

# wp-cli, pinned and checksum-verified. Fetching an unpinned phar from a raw
# git host and executing it is a supply-chain risk: this binary runs with full
# database access during multisite bootstrap, so a swapped or compromised build
# would be executing as us. Bump both values together - wp-cli publishes the
# checksum alongside each release as wp-cli-<version>.phar.sha512.
ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832
RUN curl -fsSL -o /tmp/wp \
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
COPY --from=builder /tmp/redis.so /usr/local/lib/php-extensions/redis.so
COPY --from=builder /tmp/docker-php-ext-redis.ini ${PHP_INI_DIR}/conf.d/docker-php-ext-redis.ini

COPY --from=builder --chmod=0755 /tmp/wp /usr/local/bin/wp

# Add PHP multsite supporting files
COPY opt/php/load.php /usr/src/wordpress/wp-content/mu-plugins/load.php
COPY opt/php/application.php /usr/src/wordpress/wp-content/mu-plugins/application.php
COPY opt/php/error-handling.php /usr/src/wordpress/error-handling.php
COPY opt/php/wp-cron-multisite.php /usr/src/wordpress/wp-cron-multisite.php

COPY opt/php/www.local.conf ${PHP_INI_DIR}/php-fpm.d/www.conf

# Setup WordPress multisite and network
COPY --chmod=0755 opt/scripts/hale-entrypoint.sh /usr/local/bin/
COPY --chmod=0755 opt/scripts/config.sh /usr/local/bin/

COPY --chown=65532:65532 /wordpress/wp-content/plugins /usr/src/wordpress/wp-content/plugins
COPY --chown=65532:65532 /wordpress/wp-content/mu-plugins /usr/src/wordpress/wp-content/mu-plugins
COPY --chown=65532:65532 /wordpress/wp-content/themes /usr/src/wordpress/wp-content/themes
COPY --chown=65532:65532 /vendor /usr/src/wordpress/wp-content/vendor

COPY --from=builder --chown=65532:65532 /tmp/uploads /usr/src/wordpress/wp-content/uploads

# Volume mount point for ./opt/scripts - must exist before the bind mount
COPY --from=builder --chown=65532:65532 /tmp/optscripts /opt/scripts

ENTRYPOINT ["/usr/local/bin/hale-entrypoint.sh"]

USER 65532
