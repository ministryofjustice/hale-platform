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
FROM --platform=linux/amd64 php:${PHP_VERSION}-cli AS extbuilder

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
# Builder stage: compile PHPRedis and fetch wp-cli.
# The -dev variant is the same base as the runtime image, which guarantees the
# extension is built against the exact PHP ABI the runtime expects
# (PHP API 20240924, NTS, no-debug).
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
FROM --platform=linux/amd64 dhi.io/wordpress:${WORDPRESS_VERSION}-php${PHP_VERSION}-fpm-dev AS builder

# Only WORDPRESS_VERSION is needed inside the stage (the translation packs).
# PHP_VERSION is consumed by the FROM tags above and nothing else.
ARG WORDPRESS_VERSION
USER root

# Nothing is compiled in this stage any more - the extension is built in
# extbuilder above - so this is just what is needed to fetch and unpack: wp-cli
# and the translation packs.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Ghostscript, staged for the runtime stage.
#
# ImageMagick has no PDF decoder of its own - it shells out to `gs`. Without it
# every PDF upload 500s: WordPress asks an image editor for thumbnail sizes
# (wp-admin/includes/image.php), Imagick::readImage() reports
# "FailedToExecuteCommand `gs'", and nothing catches it.
#
# The Alpine image this replaced carried ghostscript by accident - the official
# WordPress image resolves imagick's runtime dependencies with scanelf, and apk
# pulled ghostscript in behind libMagickCore. DHI installs no such thing, so it
# has to be asked for deliberately.
#
# Staged rather than installed, because the runtime stage has no package
# manager. The find/comm pair records the filesystem either side of the install
# and stages only what apt added, so nothing from the base image is shadowed by
# the COPY - including /etc/ld.so.cache, which is rewritten in place by apt's
# ldconfig trigger and would be wrong in the runtime. That the loader has no
# cache entry for these libraries is fine: glibc falls back to its built-in
# default directories, which is where they land.
#
# fonts-urw-base35 is named explicitly. It is what gs substitutes with when a
# PDF does not embed its own fonts, and a thumbnail of unrenderable text is
# worse than no thumbnail.
#
# The runtime image is verified to actually run this - see the "Verify the
# images agree" step in .github/workflows/rw-build-image.yaml. The -dev variant
# carries libraries the runtime does not, so a dependency satisfied here is not
# proof of one satisfied there.
# ---------------------------------------------------------------------------
RUN find /usr /etc -xdev | sort > /tmp/fs-before \
    && apt-get update && apt-get install -y --no-install-recommends \
        ghostscript \
        fonts-urw-base35 \
    && rm -rf /var/lib/apt/lists/* \
    && find /usr /etc -xdev | sort > /tmp/fs-after \
    && mkdir -p /tmp/gs \
    && comm -13 /tmp/fs-before /tmp/fs-after \
        | grep -Ev '^/usr/share/(doc|man|info|lintian|bug)(/|$)' \
        | tar -cf - --no-recursion -T - \
        | tar -xf - -C /tmp/gs \
    && rm -f /tmp/fs-before /tmp/fs-after \
    && test -x /tmp/gs/usr/bin/gs \
    && echo "gs libraries not staged, so expected in the runtime base:" \
    && ldd /usr/bin/gs | awk '$3 ~ /^\// {print $3}' | sed 's|^/lib/|/usr/lib/|' \
        | sort -u | while read -r l; do [ -e "/tmp/gs$l" ] || echo "  $l"; done


# The runtime image has a PHP CLI but no curl, so the download happens here and
# the phar is copied across.
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
    && curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o /tmp/lang.zip \
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
COPY --from=extbuilder /tmp/redis.so /usr/local/lib/php-extensions/redis.so
COPY --from=extbuilder /tmp/docker-php-ext-redis.ini ${PHP_INI_DIR}/conf.d/docker-php-ext-redis.ini

# wp-cli
COPY --from=builder --chmod=0755 /tmp/wp /usr/local/bin/wp

# Ghostscript (staged in the builder above). The tree holds /usr/bin/gs, the
# shared libraries apt pulled in with it and the PostScript resources under
# /usr/share/ghostscript, each already at the path it was installed to. Only
# files absent from the base image are in it, so this COPY adds and never
# replaces. Needed by ImageMagick to rasterise the first page of a PDF upload
# into the media library thumbnail.
COPY --from=builder /tmp/gs/ /

# Add PHP multsite supporting files
COPY opt/php/load.php /usr/src/wordpress/wp-content/mu-plugins/load.php
COPY opt/php/application.php /usr/src/wordpress/wp-content/mu-plugins/application.php
COPY opt/php/wpdr-document-upload-dir.php /usr/src/wordpress/wp-content/mu-plugins/wpdr-document-upload-dir.php
COPY opt/php/error-handling.php /usr/src/wordpress/error-handling.php
COPY opt/php/wp-cron-multisite.php /usr/src/wordpress/wp-cron-multisite.php
# Health endpoint. Reachable only through the internal 8090 listener; the
# public server block denies /healthz.php by path.
COPY opt/php/healthz.php /usr/src/wordpress/healthz.php

# PHP-FPM pool config. PHP_INI_DIR is set by the base image and is version
# stamped (/etc/php-<version>, DHI's own layout rather than the
# /usr/local/etc/php of the official WordPress image), so referencing the
# variable tracks a PHP bump automatically instead of hardcoding the path.
# The image's own zz-wordpress.conf loads after this one and sets only
# user/group, so the pool tuning here is preserved.
COPY opt/php/www.conf ${PHP_INI_DIR}/php-fpm.d/www.conf

# Setup WordPress multisite and network
COPY --chmod=0755 opt/scripts/hale-entrypoint.sh /usr/local/bin/
COPY --chmod=0755 opt/scripts/config.sh /usr/local/bin/
COPY --chmod=0755 opt/scripts/startup-patch.sh /usr/local/bin/

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
