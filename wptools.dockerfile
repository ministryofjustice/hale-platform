####################################################
# wptools - database tooling sidecar
#
# The hardened WordPress runtime image ships no MariaDB client, so `wp db`
# subcommands (query, export, import, cli, check, optimize, repair) cannot run
# there. Every other wp-cli command still works in the WordPress container,
# because that image does have a PHP CLI - only `wp db` shells out to the
# mysql binaries.
#
# This image runs as a sidecar in the same pod (and as a service in
# docker-compose locally), mounting the same /var/www/html volume so wp-cli can
# read wp-config.php for the database credentials.
#
# Why a sidecar rather than putting the client back in the WordPress image:
# containers in a pod share a network namespace but NOT a filesystem, and by
# default not a PID namespace either. A PHP RCE in the WordPress container
# therefore cannot execute this image's mysql binary. The client stays
# available to operators without being reachable from the code that executes
# untrusted input.
#
# Built from the same base image as the WordPress container, deliberately.
# It previously ran Alpine with its own hand-listed php8X-* packages, which
# meant maintaining a second PHP installation whose contents were decided by
# another distro: `php84-opcache` exists, `php85-opcache` does not, so a PHP
# bump re-rolled thirty package names against Alpine's packaging choices. Here
# the sidecar's PHP *is* the site's PHP, with the same extension set by
# construction, and a version bump follows the ARGs with nothing to maintain.
# The only thing added is the mysql client.
#
# Usage:
#   kubectl exec <pod> -c wptools -- wp db query "SELECT ..."
#   docker compose exec wptools wp db query "SELECT ..."
# ##################################################

ARG WORDPRESS_VERSION=7.1
ARG PHP_VERSION=8.5

# ---------------------------------------------------------------------------
# Extension stage: compile PHPRedis, exactly as wordpress.dockerfile does.
#
# The sidecar needs it because wp-cli bootstraps WordPress, which loads the
# mu-plugins - and hale-components' firewall controller and pagecache purge both
# talk to Redis. Without the extension every `wp` command fails at load time.
#
# No DHI variant ships phpize or php-config, so this is built in the official
# PHP image and only the .so is copied out. Same version as the site's, from the
# same ARG, so both load an extension built against the same ABI.
# ---------------------------------------------------------------------------
FROM php:${PHP_VERSION}-cli AS extbuilder

ARG PHPREDIS_VERSION=6.3.0
ARG PHPREDIS_SHA256=0d5141f634bd1db6c1ddcda053d25ecf2c4fc1c395430d534fd3f8d51dd7f0b5
RUN curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o /tmp/redis.tgz \
        "https://pecl.php.net/get/redis-${PHPREDIS_VERSION}.tgz" \
    && echo "${PHPREDIS_SHA256}  /tmp/redis.tgz" | sha256sum -c - \
    && pecl install /tmp/redis.tgz \
    && cp "$(php-config --extension-dir)/redis.so" /tmp/redis.so \
    && rm -rf /tmp/redis.tgz

# Colourscheme for the sidecar's neovim, vendored so the image needs no plugin
# manager and no network at runtime. Pinned to a commit sha: git verifies the sha
# on fetch, so unlike a tarball URL there is nothing to swap under us. Bump by
# changing ONEDARKPRO_COMMIT (matches lazy-lock.json in a local nvim setup).
FROM alpine:3.24 AS themes
ARG ONEDARKPRO_COMMIT=f5fddfd5122fe00421e199151ae4fe8571a02898
RUN apk add --no-cache git \
    && mkdir -p /themes/onedarkpro.nvim \
    && cd /themes/onedarkpro.nvim \
    && git init -q \
    && git remote add origin https://github.com/olimorris/onedarkpro.nvim.git \
    && git fetch -q --depth 1 origin "${ONEDARKPRO_COMMIT}" \
    && git checkout -q FETCH_HEAD \
    && rm -rf .git

# ---------------------------------------------------------------------------
# The sidecar itself. The -dev variant of the same image the site runs on: it
# carries a shell and a package manager, which is what "-dev" means for DHI.
# ---------------------------------------------------------------------------
FROM dhi.io/wordpress:${WORDPRESS_VERSION}-php${PHP_VERSION}-fpm-dev

USER root

# mariadb-client provides mysql/mysqldump/mysqlcheck, which is what `wp db`
# shells out to. Everything PHP-side - mysqli, mbstring, intl, gd, zip, the
# XML extensions - is already in the base image, because it is the image that
# runs the site.
#
# No opcache: this container runs wp-cli, one process per command, and opcache
# caches compiled bytecode for reuse across requests in a long-running process.
# PHP disables it for CLI by default for the same reason.
RUN apt-get update && apt-get install -y --no-install-recommends \
        mariadb-client \
        neovim \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Newer mariadb-client installs the mariadb-* binary names. wp-cli invokes
# mysql/mysqldump/mysqlcheck by name, so make sure those resolve.
RUN for b in mysql mysqldump mysqlcheck; do \
        if [ ! -e "/usr/bin/$b" ]; then \
            src="mariadb$(echo "$b" | sed 's/^mysql//')"; \
            [ -e "/usr/bin/$src" ] && ln -sf "/usr/bin/$src" "/usr/bin/$b"; \
        fi; \
    done; true

# PHPRedis, built above against this exact PHP version. The path matches the one
# wordpress.dockerfile uses so both images resolve the extension identically.
COPY --from=extbuilder /tmp/redis.so /usr/local/lib/php-extensions/redis.so
RUN echo "extension=/usr/local/lib/php-extensions/redis.so" \
        > "${PHP_INI_DIR}/conf.d/docker-php-ext-redis.ini"

# wp-cli, pinned and checksum-verified. Fetching an unpinned phar from a raw
# git host and executing it is a supply-chain risk: this binary runs with full
# database access during multisite bootstrap, so a swapped or compromised build
# would be executing as us. Bump both values together - wp-cli publishes the
# checksum alongside each release as wp-cli-<version>.phar.sha512.
ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832
# --retry with --retry-all-errors covers transient 5xx and connection failures.
# curl -f fails hard on any HTTP error, so a single bad gateway from GitHub
# kills the whole build - a poor trade for a fetch that succeeds on the retry.
RUN curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o /usr/local/bin/wp \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" \
    && echo "${WP_CLI_SHA512}  /usr/local/bin/wp" | sha512sum -c - \
    && chmod +x /usr/local/bin/wp

# Scratch space for exports. Writing dumps into /var/www/html would put them
# under the webroot where nginx could serve them.
RUN mkdir -p /scratch && chown 65532:65532 /scratch

# neovim writes config/state/cache under XDG paths below $HOME. uid 65532 has no
# passwd entry, so HOME is "/", which it cannot write to. Point the XDG dirs at
# /scratch instead. HOME itself is left alone: wp-cli resolves ~/.wp-cli from it.
ENV XDG_CONFIG_HOME=/scratch/.config \
    XDG_DATA_HOME=/scratch/.local/share \
    XDG_STATE_HOME=/scratch/.local/state \
    XDG_CACHE_HOME=/scratch/.cache \
    EDITOR=nvim
RUN mkdir -p /scratch/.config /scratch/.local/share /scratch/.local/state /scratch/.cache \
    && chown -R 65532:65532 /scratch
COPY --chown=65532:65532 opt/nvim/init.lua /scratch/.config/nvim/init.lua

# /usr/share/nvim/site is on the default packpath, so anything under
# pack/*/start loads at startup without a plugin manager.
COPY --from=themes /themes/onedarkpro.nvim /usr/share/nvim/site/pack/hale/start/onedarkpro.nvim

# `v` shorthand for nvim. bash sources /etc/profile.d/*.sh for login shells;
# ENV=/etc/profile covers the non-login interactive case too. Applies to
# `docker compose exec wptools bash` and `kubectl exec -it <pod> -c wptools --
# bash`; a non-interactive exec of a single command still needs the full `nvim`.
ENV ENV=/etc/profile
RUN printf 'alias v=nvim\n' > /etc/profile.d/nvim-alias.sh \
    && chmod 644 /etc/profile.d/nvim-alias.sh

WORKDIR /var/www/html

# Matches the WordPress container so files written here share ownership.
# Already the image default, but stated so a base image change cannot silently
# promote this container to root.
USER 65532

# Idle. The sidecar exists to be exec'd into, not to serve anything.
CMD ["tail", "-f", "/dev/null"]
