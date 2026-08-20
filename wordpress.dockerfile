####################################################
# WordPress multisite image
# Installs WordPress multisite, PHP and PHP-FPM to serve
# files to NGINX
#
# Built on a Docker Hardened Image (DHI). Notes on what that changes:
#  - Debian 13, not Alpine. No package manager in the runtime stage, so
#    anything extra has to be built in the `builder` stage and COPYed in.
#  - Runs as UID 65532 out of the box. No user creation or chown needed.
#  - There is no root entry in /etc/passwd, so `USER root` fails. The runtime
#    stage therefore contains no RUN instructions at all - only COPY.
#  - DHI keeps upstream's docker-entrypoint.sh, the /usr/src/wordpress staging
#    copy and wp-config-docker.php, so the multisite bootstrap is unchanged.
# ##################################################

# ---------------------------------------------------------------------------
# Builder stage: compile PHPRedis and fetch wp-cli.
# The -dev variant is the same base as the runtime image, which guarantees the
# extension is built against the exact PHP ABI the runtime expects
# (PHP API 20240924, NTS, no-debug).
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 dhi.io/wordpress:7.0.4-php8.4-fpm-dev AS builder

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        php8.4-dev \
        php-pear \
        pkg-config \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Build PHPRedis and stage it alongside the .ini that enables it. Both are
# copied into the runtime stage, which cannot run docker-php-ext-enable itself.
RUN pecl install redis \
    && cp "$(php-config --extension-dir)/redis.so" /tmp/redis.so \
    && echo "extension=redis.so" > /tmp/docker-php-ext-redis.ini

# wp-cli. The runtime image has a PHP CLI but no curl, so the download happens
# here and the phar is copied across.
RUN curl -fsSL -o /tmp/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x /tmp/wp

# Staged empty directory - the runtime stage has no shell to mkdir with.
RUN mkdir -p /tmp/uploads

# ---------------------------------------------------------------------------
# Runtime stage. COPY only - no RUN, no package manager, no root.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 dhi.io/wordpress:7.0.4-php8.4-fpm

# PHPRedis, built above against this exact PHP build.
COPY --from=builder /tmp/redis.so /usr/lib/php/extensions/no-debug-non-zts-20240924/redis.so
COPY --from=builder /tmp/docker-php-ext-redis.ini /etc/php-8.4/conf.d/docker-php-ext-redis.ini

# wp-cli
COPY --from=builder --chmod=0755 /tmp/wp /usr/local/bin/wp

# Add PHP multsite supporting files
COPY opt/php/load.php /usr/src/wordpress/wp-content/mu-plugins/load.php
COPY opt/php/application.php /usr/src/wordpress/wp-content/mu-plugins/application.php
COPY opt/php/wpdr-document-upload-dir.php /usr/src/wordpress/wp-content/mu-plugins/wpdr-document-upload-dir.php
COPY opt/php/error-handling.php /usr/src/wordpress/error-handling.php
COPY opt/php/wp-cron-multisite.php /usr/src/wordpress/wp-cron-multisite.php

# PHP-FPM pool config. DHI uses the Debian layout (/etc/php-8.4), not the
# /usr/local/etc/php layout the official WordPress image uses.
# The image's own zz-wordpress.conf loads after this one and sets only
# user/group, so the pool tuning here is preserved.
COPY opt/php/www.conf /etc/php-8.4/php-fpm.d/www.conf

# Setup WordPress multisite and network
COPY --chmod=0755 opt/scripts/hale-entrypoint.sh /usr/local/bin/
COPY --chmod=0755 opt/scripts/config.sh /usr/local/bin/

# Generated Composer and NPM compiled artifacts (plugins, themes, CSS, JS)
# The WP offical Docker image expects files to be in /usr/src/wordpress
# but then will copy them over on launch of site to the /html directory.
COPY --chown=65532:65532 /wordpress/wp-content/plugins /usr/src/wordpress/wp-content/plugins
COPY --chown=65532:65532 /wordpress/wp-content/mu-plugins /usr/src/wordpress/wp-content/mu-plugins
COPY --chown=65532:65532 /wordpress/wp-content/themes /usr/src/wordpress/wp-content/themes
COPY --chown=65532:65532 /vendor /usr/src/wordpress/wp-content/vendor

# Create the uploads folder (staged in the builder - no shell here to mkdir)
COPY --from=builder --chown=65532:65532 /tmp/uploads /usr/src/wordpress/wp-content/uploads

# Overwrite offical WP image ENTRYPOINT (docker-entrypoint.sh)
# with custom entrypoint so we can launch WP multisite network
ENTRYPOINT ["/usr/local/bin/hale-entrypoint.sh"]

# Already the image default, but stated explicitly so a base image change
# cannot silently promote this container to root.
USER 65532
