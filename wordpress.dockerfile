####################################################
# WordPress multisite image
#
# Runs WordPress multisite under PHP-FPM. nginx (nginx.dockerfile) serves the
# site and passes PHP requests to this container on port 9000.
#
# Built on a Docker Hardened Image (DHI). It is based on Debian 13, runs as
# UID 65532 by default, and its runtime variant has no package manager and no
# root user. So the final stage only uses COPY: anything that has to be
# downloaded, compiled or created is done in an earlier stage and copied in.
#
# Stages, in order:
#   extbuilder    compiles the PHPRedis extension in the official php image
#   dictionaries  takes the hunspell dictionaries from Alpine
#   builder       the DHI -dev image (adds a shell and apt). Stages
#                 ghostscript, hunspell, the UTF-8 locale, wp-cli, the
#                 WordPress core patch, the translations, the uploads folder
#                 and the Query Monitor drop-in
#   (runtime)     the image that is deployed. Copies in everything above,
#                 plus the platform's plugins, themes, config and scripts
#
# DHI keeps the official WordPress image's start-up: when the webroot is
# empty, docker-entrypoint.sh copies /usr/src/wordpress into it, and it
# generates wp-config.php from wp-config-docker.php. hale-entrypoint.sh
# (below) adds this platform's setup to that.
# ##################################################

# Image versions. This is the only place in this file they are set.
#
# PHP_VERSION picks three images: the DHI builder and runtime images, and the
# official php image PHPRedis is compiled in. WORDPRESS_VERSION picks the two
# DHI images.
#
# The same versions are also declared in wordpress.local.dockerfile,
# wptools.dockerfile (its Alpine php8X packages) and the CI workflow's
# setup-php step. bin/check-versions.sh (make check-versions, also run in CI on
# pull requests) fails if any of them disagree.
ARG WORDPRESS_VERSION=7.0.4
ARG PHP_VERSION=8.4

# WordPress core patch. When PATCH_WORDPRESS_VERSION is set, the image runs that
# WordPress release instead of the one in the DHI image: the builder stage
# downloads it, the runtime stage copies its files over the DHI image's core,
# and the translations are downloaded for it. This is for a WordPress release
# DHI has not published an image for yet. Once DHI publishes it, set
# WORDPRESS_VERSION to it and empty both ARGs below. The build fails if
# PATCH_WORDPRESS_VERSION is not newer than WORDPRESS_VERSION, because the patch
# would then downgrade core.
#
# wordpress.org publishes a SHA-1 for each release
# (https://wordpress.org/wordpress-<version>.zip.sha1), not a SHA-256. To pin a
# release, download the .zip, check it against that SHA-1, then put its
# sha256sum here. Change the two ARGs together.
#
# bin/wp-core-cve-check.sh checks PATCH_WORDPRESS_VERSION for CVEs when it is
# set, as the version the site runs.
ARG PATCH_WORDPRESS_VERSION=7.0.6
ARG PATCH_WORDPRESS_SHA256=ceea51247a0a78428a3a12cbf02bb869a5a215899a5aabd8b7fb6c0dba3554aa

# ---------------------------------------------------------------------------
# Extension stage: build the PHPRedis extension (redis.so).
#
# This stage downloads a pinned PHPRedis release from pecl, checks its SHA-256
# and compiles it. It produces two files: redis.so, and a one-line .ini that
# tells PHP to load it. The runtime stage copies those two files and nothing
# else. hale-components needs the extension for its firewall controller and
# page cache purge, which both talk to Redis.
#
# Why the official php image and not a DHI one: compiling a PHP extension needs
# phpize and php-config, and no Docker Hardened Image variant includes them.
# The DHI "-dev" variants add a shell and a package manager, not PHP's build
# tools. The official php image has both tools plus pecl, and is published for
# every PHP release.
#
# This stage runs as root with a shell and a package manager. None of that
# reaches the final image, which only takes the two files above.
#
# Why a redis.so built here works in the DHI image: an extension loads in any
# PHP build that matches the one it was compiled with on three things - the PHP
# API number, thread safety and debug mode. Every build of the same PHP minor
# version (8.4.x, say) matches on all three, and PHP_VERSION sets the minor for
# both images. If they ever disagreed, php-fpm would log a warning and run
# without Redis, so the "Verify the images agree" CI step warns when the
# extension does not load.
#
# Why the version is pinned and checksummed: this is compiled C running inside
# every PHP-FPM process, and a plain "pecl install redis" would take whatever
# release is newest that day. pecl does not publish checksums, so
# PHPREDIS_SHA256 is the hash of the file downloaded when the version was
# pinned. Change PHPREDIS_VERSION and PHPREDIS_SHA256 together -
# https://pecl.php.net/package/redis
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 php:${PHP_VERSION}-cli AS extbuilder

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
# Dictionaries stage: the hunspell dictionaries.
#
# Taken from Alpine, not Debian, because the justice theme uses the
# en_GB-large dictionary and Debian's hunspell-en-gb package only has en_GB.
# PhpSpellcheck passes the name straight to `hunspell -d`, so a missing
# dictionary makes hunspell fail rather than fall back to a smaller one.
# Alpine's package has both.
#
# Mixing distributions is safe for these files: .aff and .dic files are plain
# text that hunspell reads at runtime, and they do not link against any system
# library. The hunspell program itself comes from Debian, in the builder stage.
# Uses the same Alpine version as wptools.dockerfile.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 alpine:3.24 AS dictionaries

RUN apk add --no-cache hunspell-en-gb

# ---------------------------------------------------------------------------
# Builder stage: prepares the files the runtime stage copies in.
#
# The -dev variant of the same DHI WordPress image, which adds a shell and apt.
# Nothing from this stage reaches the runtime image except what it leaves in
# /tmp: sysdeps (ghostscript, hunspell, the locale), wp (wp-cli), core (the
# WordPress core patch), languages, uploads and dropins.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 dhi.io/wordpress:${WORDPRESS_VERSION}-php${PHP_VERSION}-fpm-dev AS builder

# An ARG set before the first FROM has to be declared again to be used inside a
# stage. The WordPress versions are needed here, for the core patch and the
# translations.
ARG WORDPRESS_VERSION
ARG PATCH_WORDPRESS_VERSION
ARG PATCH_WORDPRESS_SHA256
USER root

# Tools for the downloads below: curl and ca-certificates for HTTPS, and unzip
# for the WordPress release and the translation packs.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# System programs the application runs: ghostscript and hunspell.
#
# This step downloads the Debian packages for ghostscript, fonts-urw-base35 and
# hunspell, plus any of their dependencies this stage does not already have,
# and unpacks them into /tmp/sysdeps. It also takes the C.UTF-8 locale out of
# libc-bin (see ENV LANG in the runtime stage). The runtime stage copies
# /tmp/sysdeps onto its own filesystem.
#
# What needs them:
#   - ghostscript (gs): ImageMagick cannot read PDFs itself, it runs gs. Without
#     gs, making thumbnails for a PDF upload fails with
#     "FailedToExecuteCommand `gs'", nothing catches it, and the upload
#     returns a 500.
#   - fonts-urw-base35: the fonts gs uses when a PDF does not embed its own.
#     Without them, the text in those thumbnails cannot be drawn.
#   - hunspell: the justice theme spellchecks page content from a cron hook,
#     using PhpSpellcheck, which runs hunspell as a separate process. If
#     hunspell is missing, PhpSpellcheck throws and the whole cron run stops.
#
# Why unpack instead of apt-get install: a normal install fails in this image,
# because dpkg cannot configure the packages. The runtime needs none of that
# configuration anyway - it has no package manager and runs no install
# scripts - so only the packages' files are taken. Unpacking also leaves
# /etc/ld.so.cache unchanged. The runtime has no cache entries for these
# libraries, which is fine: glibc then searches its default library
# directories, and that is where they are placed.
#
# Why ldconfig -n: unpacking a library package gives only the fully versioned
# file (libgs.so.10.05), not the shorter name programs link against
# (libgs.so.10). A normal install would create that link. `ldconfig -n`
# creates it inside the staging directory without touching any cache.
#
# Why the COPY only adds files: this stage is the runtime image plus a shell
# and a package manager, and apt only downloads packages that are not already
# installed here. So nothing in /tmp/sysdeps replaces a file the runtime
# already has.
#
# What this step cannot prove: this stage has packages the runtime does not
# (its shell and package manager, plus curl, ca-certificates and unzip), so a
# library one of those brought in counts as present here but may be missing at
# runtime. The RUN fails if gs or hunspell has an unresolved library here, and
# prints the libraries it expects the runtime to provide. The "Verify the
# images agree" CI step then runs gs and hunspell in the real runtime image and
# warns if either fails.
# ---------------------------------------------------------------------------
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
# /tmp/core for the runtime stage to copy over /usr/src/wordpress (see the ARGs
# at the top of this file). With PATCH_WORDPRESS_VERSION empty, /tmp/core stays
# empty and that COPY changes nothing.
#
# Only wp-admin, wp-includes and the release's top-level files are staged. The
# release's wp-content (default themes, Akismet, Hello Dolly) is left out, so
# wp-content is the same with or without the patch.
#
# The RUN fails if:
#   - PATCH_WORDPRESS_VERSION is not newer than WORDPRESS_VERSION, so the patch
#     would downgrade core.
#   - the download does not match PATCH_WORDPRESS_SHA256.
#   - a file in the DHI image's wp-admin or wp-includes is not in the release.
#     COPY adds and replaces files but cannot delete them, so a file the
#     release removed would stay in the image and in every webroot. This stage
#     is the -dev variant of the same DHI image, so its /usr/src/wordpress is
#     the core the runtime stage starts with.
#   - the release's version.php does not report PATCH_WORDPRESS_VERSION.
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

# Translations: British English (en_GB) and Welsh (cy).
#
# They have to be in the image. The webroot is an emptyDir, so a language pack
# downloaded at runtime is gone when the next pod starts, and
# DISALLOW_FILE_MODS (config.sh) stops WordPress downloading one anyway. Being
# in the image also makes both languages show as installed in the Site
# Language dropdown. Which language a site uses is still a per-site setting in
# the database.
#
# The packs match the core version the image runs: PATCH_WORDPRESS_VERSION when
# it is set, otherwise WORDPRESS_VERSION. If no pack is published for a
# language at that version, the build fails here - better than shipping another
# version's strings or leaving a language out.
#
# Not checksummed, unlike wp-cli and PHPRedis: a translation pack is rebuilt
# every time a translator changes a string, so a pinned hash would break the
# build at random.
#
# To add a language, add its code to WP_LOCALES (space-separated). .po files
# are deleted because WordPress only reads the .mo and .json files. The
# `|| exit 1` is needed: a failed command inside a for loop does not fail the
# RUN by itself, so a language could silently go missing.
ARG WP_LOCALES="en_GB cy"
RUN mkdir -p /tmp/languages \
    && core_version="${PATCH_WORDPRESS_VERSION:-${WORDPRESS_VERSION}}" \
    && for locale in ${WP_LOCALES}; do \
    echo "Fetching ${locale} translations for ${core_version}" \
    && curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o /tmp/lang.zip \
    "https://downloads.wordpress.org/translation/core/${core_version}/${locale}.zip" \
    && unzip -q -o /tmp/lang.zip -d /tmp/languages \
    || exit 1; \
    done \
    && rm -f /tmp/lang.zip /tmp/languages/*.po

# An empty uploads folder, created here because the runtime stage only uses
# COPY.
RUN mkdir -p /tmp/uploads

# Query Monitor's database drop-in: wp-content/db.php, a symlink to the file
# inside the plugin. Query Monitor creates this link itself when it is
# activated, but DISALLOW_FILE_MODS (config.sh) blocks that, and the webroot is
# rebuilt on every pod start, so the image ships the link instead.
#
# It must be a symlink, not a copy. The drop-in finds the plugin using
# dirname(dirname(__FILE__)), and PHP resolves symlinks in __FILE__, so a copy
# would look for the plugin in the wrong place, fail its is_readable() check
# and do nothing. The link is relative, so it works both in
# /usr/src/wordpress/wp-content and in /var/www/html/wp-content.
#
# It is created inside a folder, not as /tmp/db.php on its own. The link points
# at a file that only exists in the runtime stage, and BuildKit follows the
# source of a single-file COPY, which fails with "/tmp/db.php: not found".
# Copying a folder keeps the symlinks inside it as they are.
RUN mkdir -p /tmp/dropins \
    && ln -s plugins/query-monitor/wp-content/db.php /tmp/dropins/db.php

# ---------------------------------------------------------------------------
# Runtime stage: the image that is deployed.
#
# No RUN instructions - only COPY, ENV, ENTRYPOINT and USER. Everything that
# needed a package manager or root was prepared in the stages above.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 dhi.io/wordpress:${WORDPRESS_VERSION}-php${PHP_VERSION}-fpm

# PHPRedis, from the extbuilder stage. The .ini loads redis.so by its full
# path, so these paths do not depend on the PHP version or on PHP's own
# extension folder. PHP_INI_DIR is set by the base image and follows
# PHP_VERSION.
COPY --from=extbuilder /tmp/redis.so /usr/local/lib/php-extensions/redis.so
COPY --from=extbuilder /tmp/docker-php-ext-redis.ini ${PHP_INI_DIR}/conf.d/docker-php-ext-redis.ini

# wp-cli, from the builder stage.
COPY --from=builder --chmod=0755 /tmp/wp /usr/local/bin/wp

# ghostscript with its fonts and libraries, hunspell, and the C.UTF-8 locale,
# from the builder stage. Each file is at the path a normal install would put
# it. The folder only holds packages this image does not already have, so this
# COPY adds files and never replaces one.
COPY --from=builder /tmp/sysdeps/ /

# Hunspell dictionaries (en_GB and en_GB-large) from the dictionaries stage.
COPY --from=dictionaries /usr/share/hunspell /usr/share/hunspell

# Use the C.UTF-8 locale, so glibc reports UTF-8 as the text encoding. The DHI
# image has no locale data of its own. Without the locale files the builder
# stage copied in, only the plain C locale exists, and glibc reports ASCII
# (ANSI_X3.4-1968).
#
# hunspell needs this. It converts its personal dictionary into that encoding,
# so under ASCII every accented word fails to convert and prints an error.
# PhpSpellcheck treats any error output as a failure and throws, which stops
# the wp-cron.php run.
ENV LANG=C.UTF-8

# WordPress core patch from the builder stage: PATCH_WORDPRESS_VERSION's
# wp-admin, wp-includes and top-level files, over the DHI image's core. The
# folder is empty when PATCH_WORDPRESS_VERSION is empty, and this COPY then
# changes nothing.
COPY --from=builder --chown=65532:65532 /tmp/core/ /usr/src/wordpress/

# Platform PHP files. load.php and application.php load the platform's
# must-use plugins, the Composer autoloader and error-handling.php, which sets
# PHP error logging per environment. wpdr-document-upload-dir.php makes
# wp-document-revisions store documents through S3. wp-cron-multisite.php runs
# cron for every site, and is called by the cron-wp-multisite CronJob.
COPY opt/php/load.php /usr/src/wordpress/wp-content/mu-plugins/load.php
COPY opt/php/application.php /usr/src/wordpress/wp-content/mu-plugins/application.php
COPY opt/php/wpdr-document-upload-dir.php /usr/src/wordpress/wp-content/mu-plugins/wpdr-document-upload-dir.php
COPY opt/php/error-handling.php /usr/src/wordpress/error-handling.php
COPY opt/php/wp-cron-multisite.php /usr/src/wordpress/wp-cron-multisite.php
# Health check script for /healthz. Only reachable through nginx's internal
# port 8090 listener - the public site blocks /healthz.php.
COPY opt/php/healthz.php /usr/src/wordpress/healthz.php

# PHP-FPM pool settings. PHP_INI_DIR comes from the base image and includes the
# PHP version (/etc/php-<version>), so using the variable keeps this path right
# when PHP_VERSION changes. The image's own zz-wordpress.conf loads after this
# file but only sets user and group, so the settings here still apply.
COPY opt/php/www.conf ${PHP_INI_DIR}/php-fpm.d/www.conf

# Readiness-probe pool on 127.0.0.1:9001, so /healthz keeps answering while
# every [www] worker is busy. Named to sort before www.conf, so the pool
# zz-wordpress.conf follows is still [www], as it was before this file existed.
COPY opt/php/healthz.conf ${PHP_INI_DIR}/php-fpm.d/healthz.conf

# Start-up scripts. hale-entrypoint.sh (the ENTRYPOINT below) copies the
# image's docker-entrypoint.sh, adds a call to config.sh just before php-fpm
# starts, applies startup-patch.sh and runs the result. config.sh sets up
# wp-config.php and the multisite network. startup-patch.sh stops a harmless
# tar permissions error on the webroot from failing start-up.
COPY --chmod=0755 opt/scripts/hale-entrypoint.sh /usr/local/bin/
COPY --chmod=0755 opt/scripts/config.sh /usr/local/bin/
COPY --chmod=0755 opt/scripts/startup-patch.sh /usr/local/bin/

# Plugins, themes and Composer packages, built by composer install and the npm
# build before this image is built. Like everything under /usr/src/wordpress,
# they are copied into the webroot (/var/www/html) when a new pod starts.
COPY --chown=65532:65532 /wordpress/wp-content/plugins /usr/src/wordpress/wp-content/plugins
COPY --chown=65532:65532 /wordpress/wp-content/mu-plugins /usr/src/wordpress/wp-content/mu-plugins
COPY --chown=65532:65532 /wordpress/wp-content/themes /usr/src/wordpress/wp-content/themes
COPY --chown=65532:65532 /vendor /usr/src/wordpress/wp-content/vendor

# Empty uploads folder, from the builder stage.
COPY --from=builder --chown=65532:65532 /tmp/uploads /usr/src/wordpress/wp-content/uploads

# Query Monitor database drop-in symlink, from the builder stage.
COPY --from=builder --chown=65532:65532 /tmp/dropins/ /usr/src/wordpress/wp-content/

# en_GB and cy translations, from the builder stage.
COPY --from=builder --chown=65532:65532 /tmp/languages /usr/src/wordpress/wp-content/languages

# Start through hale-entrypoint.sh instead of the image's docker-entrypoint.sh.
# See the start-up scripts above.
ENTRYPOINT ["/usr/local/bin/hale-entrypoint.sh"]

# 65532 is already the base image's default user. Set here anyway so a change
# to the base image can never make this container run as root.
USER 65532
