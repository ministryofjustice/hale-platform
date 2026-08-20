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
FROM dhi.io/wordpress:7.0.4-php8.4-fpm-dev AS builder

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        php8.4-dev \
        php-pear \
        pkg-config \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

RUN pecl install redis \
    && cp "$(php-config --extension-dir)/redis.so" /tmp/redis.so \
    && echo "extension=redis.so" > /tmp/docker-php-ext-redis.ini

RUN curl -fsSL -o /tmp/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x /tmp/wp

# /opt/scripts is a volume mount point locally; the directory has to exist and
# the uploads folder is staged here because the runtime stage has no shell.
RUN mkdir -p /tmp/uploads /tmp/optscripts

# ---------------------------------------------------------------------------
# Runtime stage. COPY only - no RUN, no package manager, no root.
# ---------------------------------------------------------------------------
FROM dhi.io/wordpress:7.0.4-php8.4-fpm

COPY --from=builder /tmp/redis.so /usr/lib/php/extensions/no-debug-non-zts-20240924/redis.so
COPY --from=builder /tmp/docker-php-ext-redis.ini /etc/php-8.4/conf.d/docker-php-ext-redis.ini

COPY --from=builder --chmod=0755 /tmp/wp /usr/local/bin/wp

# Add PHP multsite supporting files
COPY opt/php/load.php /usr/src/wordpress/wp-content/mu-plugins/load.php
COPY opt/php/application.php /usr/src/wordpress/wp-content/mu-plugins/application.php
COPY opt/php/error-handling.php /usr/src/wordpress/error-handling.php
COPY opt/php/wp-cron-multisite.php /usr/src/wordpress/wp-cron-multisite.php

COPY opt/php/www.local.conf /etc/php-8.4/php-fpm.d/www.conf

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
