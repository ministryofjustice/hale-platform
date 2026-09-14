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
# Usage:
#   kubectl exec <pod> -c wptools -- wp db query "SELECT ..."
#   docker compose exec wptools wp db query "SELECT ..."
# ##################################################

# Colourscheme for the sidecar's neovim, vendored so the runtime image needs no
# plugin manager and no network. Pinned to a commit sha: git verifies the sha on
# fetch, so unlike a tarball URL there is nothing to swap under us. Bump by
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

FROM alpine:3.24

# mariadb-client provides mysql/mysqldump/mysqlcheck, which is what `wp db`
# shells out to. The php85-* set covers what wp-cli needs to bootstrap
# WordPress far enough to read wp-config.php.
#
# No opcache here, deliberately. Alpine has no php85-opcache package, and it
# would buy nothing if it did: this container runs wp-cli, one process per
# command, and opcache caches compiled bytecode for reuse across requests in a
# long-running process. PHP disables it for CLI by default for the same reason.
RUN apk add --no-cache \
        mariadb-client \
        php85 \
        php85-mysqli \
        php85-pdo \
        php85-pdo_mysql \
        php85-phar \
        php85-mbstring \
        php85-curl \
        php85-openssl \
        php85-simplexml \
        php85-xml \
        php85-dom \
        php85-tokenizer \
        php85-ctype \
        php85-iconv \
        php85-session \
        php85-fileinfo \
        php85-exif \
        php85-intl \
        php85-zip \
        php85-sodium \
        php85-posix \
        php85-xmlreader \
        php85-xmlwriter \
        php85-sqlite3 \
        php85-pdo_sqlite \
        php85-bcmath \
        php85-gd \
        php85-pecl-imagick \
        php85-pecl-redis \
        neovim \
        curl \
    && ln -sf /usr/bin/php85 /usr/local/bin/php

# Newer mariadb-client installs the mariadb-* binary names. wp-cli invokes
# mysql/mysqldump/mysqlcheck by name, so make sure those resolve.
RUN for b in mysql mysqldump mysqlcheck; do \
        if [ ! -e "/usr/bin/$b" ]; then \
            src="mariadb$(echo "$b" | sed 's/^mysql//')"; \
            [ -e "/usr/bin/$src" ] && ln -sf "/usr/bin/$src" "/usr/bin/$b"; \
        fi; \
    done; true

# wp-cli, pinned and checksum-verified. Fetching an unpinned phar from a raw
# git host and executing it is a supply-chain risk: this binary runs with full
# database access during multisite bootstrap, so a swapped or compromised build
# would be executing as us. Bump both values together - wp-cli publishes the
# checksum alongside each release as wp-cli-<version>.phar.sha512.
ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832
# --retry with --retry-all-errors covers transient 5xx and connection failures.
# curl -f fails hard on any HTTP error, so a single bad gateway from GitHub or
# pecl kills the whole build - which is a poor trade for a fetch that succeeds on
# the next attempt.
RUN curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors -o /usr/local/bin/wp \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" \
    && echo "${WP_CLI_SHA512}  /usr/local/bin/wp" | sha512sum -c - \
    && chmod +x /usr/local/bin/wp

RUN apk del curl

# Scratch space for exports. Writing dumps into /var/www/html would put them
# under the webroot where nginx could serve them.
RUN mkdir -p /scratch && chown 65532:65532 /scratch

# neovim writes state and cache under XDG paths below $HOME. uid 65532 has no
# passwd entry, so HOME is "/", which it cannot write to - hence pointing the
# writable XDG dirs at /scratch. HOME itself is left alone: wp-cli resolves
# ~/.wp-cli from it.
#
# XDG_CONFIG_HOME is the exception and must NOT be under /scratch. In Kubernetes
# an emptyDir is mounted at /scratch, which hides everything the image placed
# there - so an init.lua baked in at build time is invisible at runtime, nvim
# starts unconfigured, and the colourscheme below never gets selected even though
# its files are present. Config is read-only, so it lives outside the volume;
# only the dirs that genuinely need writing stay in it.
ENV XDG_CONFIG_HOME=/opt/nvim-config \
    XDG_DATA_HOME=/scratch/.local/share \
    XDG_STATE_HOME=/scratch/.local/state \
    XDG_CACHE_HOME=/scratch/.cache \
    EDITOR=nvim
RUN mkdir -p /scratch/.local/share /scratch/.local/state /scratch/.cache \
    && chown -R 65532:65532 /scratch
COPY --chown=65532:65532 opt/nvim/init.lua /opt/nvim-config/nvim/init.lua

# /usr/share/nvim/site is on the default packpath, so anything under
# pack/*/start loads at startup without a plugin manager.
COPY --from=themes /themes/onedarkpro.nvim /usr/share/nvim/site/pack/hale/start/onedarkpro.nvim

# `v` shorthand for nvim. ash only sources a startup file for interactive shells
# and only when $ENV names one, hence ENV=/etc/profile - Alpine's /etc/profile
# sources /etc/profile.d/*.sh. Applies to `docker compose exec wptools sh` and
# `kubectl exec -it <pod> -c wptools -- sh`; a non-interactive exec of a single
# command still needs the full `nvim`.
ENV ENV=/etc/profile
RUN printf 'alias v=nvim\n' > /etc/profile.d/nvim-alias.sh \
    && chmod 644 /etc/profile.d/nvim-alias.sh

WORKDIR /var/www/html

# Matches the WordPress container so files written here share ownership.
USER 65532

# Idle. The sidecar exists to be exec'd into, not to serve anything.
CMD ["tail", "-f", "/dev/null"]
