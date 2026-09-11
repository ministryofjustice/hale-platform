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
# Image version, declared once. PHP_VERSION must match the version in the tag:
# it selects the Debian -dev headers the Redis extension is compiled against.
ARG WORDPRESS_VERSION=7.0.4
ARG PHP_VERSION=8.4

FROM --platform=linux/amd64 dhi.io/wordpress:${WORDPRESS_VERSION}-php${PHP_VERSION}-fpm-dev AS builder

ARG PHP_VERSION
ARG WORDPRESS_VERSION
USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    php${PHP_VERSION}-dev \
    php-pear \
    pkg-config \
    ca-certificates \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Build PHPRedis and stage it alongside the .ini that enables it. Both are
# copied into the runtime stage, which cannot run docker-php-ext-enable itself.
#
# Pinned and checksum-verified, for the same reason wp-cli is below: bare
# "pecl install redis" takes whatever release is latest on the day, and the
# result is compiled C loaded into every PHP-FPM process. The tarball is
# fetched here and handed to pecl as a local file, so the hash is checked
# before anything is unpacked or built.
#
# What the sha256 buys: the exact bytes are pinned, so a rebuild that fetches
# different ones fails loudly instead of quietly shipping different code. What
# it does not buy: pecl publishes no per-release hash to check against, so this
# attests to what was fetched when the pin was set, not to authenticity at the
# source. It was cross-checked against the file size in pecl's release
# metadata (399284 bytes) at the time of pinning.
#
# Bump both values together - releases are at https://pecl.php.net/package/redis
ARG PHPREDIS_VERSION=6.3.0
ARG PHPREDIS_SHA256=0d5141f634bd1db6c1ddcda053d25ecf2c4fc1c395430d534fd3f8d51dd7f0b5
RUN curl -fsSL -o /tmp/redis.tgz \
    "https://pecl.php.net/get/redis-${PHPREDIS_VERSION}.tgz" \
    && echo "${PHPREDIS_SHA256}  /tmp/redis.tgz" | sha256sum -c - \
    && pecl install /tmp/redis.tgz \
    && rm /tmp/redis.tgz \
    && cp "$(php-config --extension-dir)/redis.so" /tmp/redis.so \
    && echo "extension=/usr/local/lib/php-extensions/redis.so" > /tmp/docker-php-ext-redis.ini

# The runtime image has a PHP CLI but no curl, so the download happens here and
# the phar is copied across.
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

# Translations, baked into the image. en_GB (British English) and cy (Welsh).
#
# wp-content/languages is not otherwise shipped and the webroot is an emptyDir,
# so a pack downloaded at runtime is lost on the next pod start - and with
# DISALLOW_FILE_MODS set (config.sh) WordPress cannot re-fetch it at all.
# Baking it in is what makes en_GB survive a restart, and it puts the locale in
# the Site Language dropdown as already installed, so selecting it needs no
# download. The locale itself stays a per-site database option - this only
# makes the choice work.
#
# Tracks WORDPRESS_VERSION, so a core bump pulls the matching translations. If
# a core version has no pack published for one of these locales the build fails
# here, which is the right way round - better than silently shipping strings
# from another release, or an image missing a locale the sites offer.
#
# Deliberately not checksummed, unlike wp-cli and phpredis above: translation
# packages are regenerated whenever a translator updates a string, so a pinned
# hash would break the build at random. Those two are immutable releases, this
# is not.
#
# .po files are translator sources - only .mo and .json are read at runtime.
# Space-separated, so adding a locale is a one-word change. The `|| exit 1`
# matters: a failing command inside a for loop does not fail the RUN on its own,
# which would leave a locale silently missing from the image.
ARG WP_LOCALES="en_GB cy"
RUN mkdir -p /tmp/languages \
    && for locale in ${WP_LOCALES}; do \
    echo "Fetching ${locale} translations for ${WORDPRESS_VERSION}" \
    && curl -fsSL -o /tmp/lang.zip \
    "https://downloads.wordpress.org/translation/core/${WORDPRESS_VERSION}/${locale}.zip" \
    && unzip -q -o /tmp/lang.zip -d /tmp/languages \
    || exit 1; \
    done \
    && rm -f /tmp/lang.zip /tmp/languages/*.po

# Staged empty directory - the runtime stage has no shell to mkdir with.
RUN mkdir -p /tmp/uploads

# Query Monitor's database drop-in. QM normally symlinks this itself on
# activation, but DISALLOW_FILE_MODS (config.sh) stops that, and activation
# only fires once anyway while the webroot is an emptyDir rebuilt on every
# pod start - so the panel has been absent in deployed environments either
# way. Shipping it in the image is what makes it work.
#
# It has to be a symlink, not a copy: the drop-in locates the plugin with
# dirname(dirname(__FILE__)), and PHP resolves __FILE__ through symlinks, so
# a plain copy at wp-content/db.php would point at the webroot and QM would
# bail out of its own is_readable() guard. Relative, so it resolves the same
# under /usr/src/wordpress/wp-content and /var/www/html/wp-content.
#
# Staged inside a directory rather than as /tmp/db.php on its own. The link is
# deliberately dangling here - its target only exists in the runtime stage - and
# BuildKit dereferences the source of a single-file COPY to compute its cache
# key, which fails with "/tmp/db.php: not found". Copying a directory preserves
# the symlinks inside it without resolving them.
RUN mkdir -p /tmp/dropins \
    && ln -s plugins/query-monitor/wp-content/db.php /tmp/dropins/db.php

# ---------------------------------------------------------------------------
# Runtime stage. COPY only - no RUN, no package manager, no root.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 dhi.io/wordpress:${WORDPRESS_VERSION}-php${PHP_VERSION}-fpm

# PHPRedis, built above against this exact PHP build.
# Version-independent paths: the .so is referenced by absolute path from the
# .ini, so neither the PHP version nor the ABI number appears here. PHP_INI_DIR
# comes from the base image, so a PHP bump follows the FROM tag automatically.
COPY --from=builder /tmp/redis.so /usr/local/lib/php-extensions/redis.so
COPY --from=builder /tmp/docker-php-ext-redis.ini ${PHP_INI_DIR}/conf.d/docker-php-ext-redis.ini

# wp-cli
COPY --from=builder --chmod=0755 /tmp/wp /usr/local/bin/wp

# Add PHP multsite supporting files
COPY opt/php/load.php /usr/src/wordpress/wp-content/mu-plugins/load.php
COPY opt/php/application.php /usr/src/wordpress/wp-content/mu-plugins/application.php
COPY opt/php/wpdr-document-upload-dir.php /usr/src/wordpress/wp-content/mu-plugins/wpdr-document-upload-dir.php
COPY opt/php/error-handling.php /usr/src/wordpress/error-handling.php
COPY opt/php/wp-cron-multisite.php /usr/src/wordpress/wp-cron-multisite.php
# Health endpoint. Reachable only through the internal 8090 listener; the
# public server block denies /healthz.php by path.
COPY opt/php/healthz.php /usr/src/wordpress/healthz.php

# PHP-FPM pool config. PHP_INI_DIR is set by the base image (currently
# /etc/php-8.4 - the Debian layout, not the /usr/local/etc/php layout of the
# official WordPress image), so this tracks a PHP version bump automatically.
# The image's own zz-wordpress.conf loads after this one and sets only
# user/group, so the pool tuning here is preserved.
COPY opt/php/www.conf ${PHP_INI_DIR}/php-fpm.d/www.conf

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

# Query Monitor database drop-in (symlink staged in the builder above).
COPY --from=builder --chown=65532:65532 /tmp/dropins/ /usr/src/wordpress/wp-content/

# British English translations (staged in the builder above).
COPY --from=builder --chown=65532:65532 /tmp/languages /usr/src/wordpress/wp-content/languages

# Overwrite offical WP image ENTRYPOINT (docker-entrypoint.sh)
# with custom entrypoint so we can launch WP multisite network
ENTRYPOINT ["/usr/local/bin/hale-entrypoint.sh"]

# Already the image default, but stated explicitly so a base image change
# cannot silently promote this container to root.
USER 65532
