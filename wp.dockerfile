# Build app - WordPress Multisite
FROM --platform=linux/amd64 wordpress:6.2.2-php8.2-fpm-alpine

# Add load.php into mu-plugins
COPY opt/php/load.php /usr/src/wordpress/wp-content/mu-plugins/load.php

# Add conifg & error handling
COPY opt/php/application.php /usr/src/wordpress/wp-content/mu-plugins/application.php
COPY opt/php/error-handling.php /usr/src/wordpress/error-handling.php

# Set PHP-FPM settings
COPY opt/php/www.conf /usr/local/etc/php-fpm.d/www.conf
COPY opt/php/wp-cron-multisite.php /usr/src/wordpress/wp-cron-multisite.php

# Add WP multisite network scripts
COPY opt/scripts/hale-entrypoint.sh /usr/local/bin/
COPY opt/scripts/config.sh /usr/local/bin/

# Generated Composer and NPM compiled artifacts (plugins, themes, CSS, JS)
# are copied into place at this stage of build.
# The WP offical Docker image expects files to be in /usr/src/wordpress
# but then will copy them over on launch of site to the /html directory.
COPY /wordpress/wp-content/plugins /usr/src/wordpress/wp-content/plugins
COPY /wordpress/wp-content/mu-plugins /usr/src/wordpress/wp-content/mu-plugins
COPY /wordpress/wp-content/themes /usr/src/wordpress/wp-content/themes
COPY /vendor /usr/src/wordpress/wp-content/vendor

# Load default production php.ini file in
# Custom php.ini additions for dev, staging & prod are done via k8s manifest
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# Set permissions for wp-cli
RUN addgroup -g 1001 wp && adduser -G wp -g wp -s /bin/sh -D wp && \
    chown wp:wp /var/www/html

# Install wp-cli
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
    chmod +x wp-cli.phar && \
    mv wp-cli.phar /usr/local/bin/wp

# Make multisite scripts executable
RUN chmod +x /usr/local/bin/hale-entrypoint.sh && \
    chmod +x /usr/local/bin/config.sh

# Install additional Alpine packages
RUN apk update && \
    apk add less && \
    apk add vim --no-cache && \
    apk add mysql mysql-client

# Create the uploads folder
RUN mkdir -p /usr/src/wordpress/wp-content/uploads

# Overwrite offical WP image ENTRYPOINT (docker-entrypoint.sh)
# with custom entrypoint so we can launch WP multisite network
ENTRYPOINT ["/usr/local/bin/hale-entrypoint.sh"]

# Create new user to run container as non-root
RUN adduser --disabled-password hale -u 1002 && \
    chown -R hale:hale /var/www/html

RUN chown hale:hale /usr/local/bin/docker-entrypoint.sh

# Set container user 'root' to 'hale'
USER 1002
