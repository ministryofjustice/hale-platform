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
# Hunspell dictionaries.
#
# From Alpine rather than Debian, because Debian's hunspell-en-gb ships en_GB
# alone and the justice theme asks for en_GB-large. PhpSpellcheck passes that
# name straight to `hunspell -d`, so a variant that does not exist is a failed
# process rather than a fallback to a smaller wordlist. Alpine's package
# carries both, and is the one the pre-hardening image installed, so this keeps
# the platform spellchecking against the wordlist it always has.
#
# Mixing distributions is safe for these particular files. A .aff and a .dic
# are plain text read at runtime, with no linkage to a C library or to whoever
# packaged them. The binary itself still comes from Debian with everything
# else. Pinned to the same Alpine the wptools image uses.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 alpine:3.24 AS dictionaries

RUN apk add --no-cache hunspell-en-gb

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
# External binaries the application shells out to, staged for the runtime.
#
# ImageMagick has no PDF decoder of its own - it forks `gs`. Without it every
# PDF upload 500s: WordPress asks an image editor for thumbnail sizes
# (wp-admin/includes/image.php), Imagick::readImage() reports
# "FailedToExecuteCommand `gs'", and nothing catches it.
#
# The Alpine image this replaced carried ghostscript by accident - the official
# WordPress image resolves imagick's runtime dependencies with scanelf, and apk
# pulled ghostscript in behind libMagickCore. DHI installs no such thing, so it
# has to be asked for deliberately.
#
# dpkg-deb unpacks files and nothing else, so the SONAME symlinks that ldconfig
# would normally create are missing - Debian library packages ship only the
# fully versioned file, libgs.so.10.05 and not libgs.so.10, which is what gs
# actually links against. `ldconfig -n` on the staged directory creates them
# without touching any cache, which is exactly the half of ldconfig wanted here.
#
# Downloaded and unpacked, not installed. A plain apt-get install fails in this
# image: dpkg cannot configure the packages and exits 1 with every one of them
# listed - the libraries as well as ghostscript itself, which is the signature
# of trigger processing failing rather than of anything specific to gs. None of
# that configuration is wanted anyway. The runtime has no package manager, runs
# no maintainer script and cannot run ldconfig, so the only thing needed out of
# these packages is their files.
#
# Working package-wise also makes the COPY additive by construction. apt
# downloads only what is not already installed in this stage, and this stage is
# the runtime image plus a shell and a package manager - so anything downloaded
# here is absent from the runtime too. /etc/ld.so.cache in particular is never
# touched, where an install would have had apt's ldconfig trigger rewrite it in
# place and the runtime would have inherited a cache describing a filesystem it
# does not have. That the loader then has no cache entry for these libraries is
# fine: glibc falls back to its built-in default directories, which is where
# they land.
#
# fonts-urw-base35 is named explicitly. It is what gs substitutes with when a
# PDF does not embed its own fonts, and a thumbnail of unrenderable text is
# worse than no thumbnail.
#
# hunspell is the other one. The justice theme spellchecks page content on a
# cron hook, through PhpSpellcheck, which runs the binary as a subprocess - so
# a missing hunspell is an uncaught ProcessFailedException that kills the cron
# run, not a skipped check. It was an explicit apk package before the base
# image swap and was dropped with the rest of that block.
#
# The runtime image is verified to actually run this - see the "Verify the
# images agree" step in .github/workflows/rw-build-image.yaml. This stage
# carries packages the runtime does not, so a dependency treated as satisfied
# here is not proof of one satisfied there.
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
# shared libraries it was downloaded with and the PostScript resources under
# /usr/share/ghostscript, each at the path dpkg would have installed it to.
# It contains only packages this image does not already have, so the COPY
# adds and never replaces. Needed by ImageMagick to rasterise the first page
# of a PDF upload into the media library thumbnail.
COPY --from=builder /tmp/sysdeps/ /

# Hunspell dictionaries (Alpine stage above), kept separate from the Debian
# tree because the two distributions disagree about which variants exist.
COPY --from=dictionaries /usr/share/hunspell /usr/share/hunspell

# glibc resolves a locale name against /usr/lib/locale, and DHI ships no locale
# data at all - so every locale but C is unavailable and nl_langinfo(CODESET)
# answers ANSI_X3.4-1968. hunspell asks glibc for the terminal encoding and
# converts its personal dictionary into it, so a wordlist with accented entries
# produces one failed conversion per entry on stderr, and PhpSpellcheck treats
# any stderr at all as a failed process - an uncaught exception out of
# wp-cron.php. musl has no such failure mode: it answers UTF-8 whatever the
# locale, which is why this only appeared after the base image changed.
#
# C.utf8 is 404K and ships prebuilt in libc-bin, so the builder takes the
# locale out of that package and nothing else - the rest is already here.
ENV LANG=C.UTF-8

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
