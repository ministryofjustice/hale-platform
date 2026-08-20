####################################################
# wp-tools - database tooling sidecar
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
#   kubectl exec <pod> -c wp-tools -- wp db query "SELECT ..."
#   docker compose exec wp-tools wp db query "SELECT ..."
# ##################################################

FROM alpine:3.24

# mariadb-client provides mysql/mysqldump/mysqlcheck, which is what `wp db`
# shells out to. The php84-* set covers what wp-cli needs to bootstrap
# WordPress far enough to read wp-config.php.
RUN apk add --no-cache \
        mariadb-client \
        php84 \
        php84-mysqli \
        php84-pdo \
        php84-pdo_mysql \
        php84-phar \
        php84-mbstring \
        php84-curl \
        php84-openssl \
        php84-simplexml \
        php84-xml \
        php84-dom \
        php84-tokenizer \
        php84-ctype \
        php84-iconv \
        php84-session \
        php84-fileinfo \
        php84-exif \
        php84-intl \
        php84-zip \
        php84-sodium \
        php84-posix \
        php84-opcache \
        php84-xmlreader \
        php84-xmlwriter \
        php84-sqlite3 \
        php84-pdo_sqlite \
        php84-bcmath \
        php84-gd \
        php84-pecl-imagick \
        php84-pecl-redis \
        curl \
    && ln -sf /usr/bin/php84 /usr/local/bin/php

# Newer mariadb-client installs the mariadb-* binary names. wp-cli invokes
# mysql/mysqldump/mysqlcheck by name, so make sure those resolve.
RUN for b in mysql mysqldump mysqlcheck; do \
        if [ ! -e "/usr/bin/$b" ]; then \
            src="mariadb$(echo "$b" | sed 's/^mysql//')"; \
            [ -e "/usr/bin/$src" ] && ln -sf "/usr/bin/$src" "/usr/bin/$b"; \
        fi; \
    done; true

RUN curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x /usr/local/bin/wp \
    && apk del curl

# Scratch space for exports. Writing dumps into /var/www/html would put them
# under the webroot where nginx could serve them.
RUN mkdir -p /scratch && chown 65532:65532 /scratch

WORKDIR /var/www/html

# Matches the WordPress container so files written here share ownership.
USER 65532

# Idle. The sidecar exists to be exec'd into, not to serve anything.
CMD ["tail", "-f", "/dev/null"]
