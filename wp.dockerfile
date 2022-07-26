# WP package management
FROM composer:latest AS composer
COPY composer.json /tmp
WORKDIR /tmp
RUN composer install -vvv

# PHP system env and WordPress setup
FROM --platform=linux/amd64 wordpress:6.0.0-php7.4-fpm-alpine

# Adjust php.ini configuration settings
# COPY custom.ini $PHP_INI_DIR/conf.d/

# Adjust PHP-FPM configuration settings
COPY ./php/www.conf /usr/local/etc/php-fpm.d/www.conf 

# Set permissions for wp-cli
RUN addgroup -g 1001 wp && adduser -G wp -g wp -s /bin/sh -D wp
RUN chown wp:wp /var/www/html

# wp-cli
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
RUN chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp

# neovim
RUN apk update && \
    apk add less && \
    apk add neovim --no-cache

# Install WP application and repos
COPY --from=composer /tmp/wordpress/wp-content/plugins /usr/src/wordpress/wp-content/plugins
COPY --from=composer /tmp/wordpress/wp-content/themes /usr/src/wordpress/wp-content/themes
RUN cp -r /usr/src/wordpress/wp-content/plugins/* /var/www/html/wp-content/plugins
RUN cp -r /usr/src/wordpress/wp-content/themes/* /var/www/html/wp-content/themes

RUN adduser --disabled-password hale -u 1002 && \
    chown -R hale:hale /var/www/html

# Add WP multisite network script
COPY entrypoint.sh /usr/local/bin/

# Make multisite script executable
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

USER 1002

CMD ["/usr/local/bin/docker-entrypoint.sh", "php-fpm"]
