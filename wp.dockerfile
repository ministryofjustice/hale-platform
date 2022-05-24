# WP package management
FROM composer:latest AS composer
COPY composer.json /tmp
WORKDIR /tmp
RUN composer install -vvv

# PHP system env and WordPress setup
FROM wordpress:5.9.3-php7.4-fpm-alpine

# Adjust php.ini configuration settings
# COPY custom.ini $PHP_INI_DIR/conf.d/

# Support for wp-cli
RUN addgroup -g 1001 wp && adduser -G wp -g wp -s /bin/sh -D wp
RUN chown wp:wp /var/www/html

# Persistent dependencies
# wp-cli
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
RUN chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp
# neovim
RUN apk add neovim

# Install WP application and repos
COPY --from=composer /tmp/wordpress/wp-content/plugins /usr/src/wordpress/wp-content/plugins
COPY --from=composer /tmp/wordpress/wp-content/themes /usr/src/wordpress/wp-content/themes
RUN cp -r /usr/src/wordpress/wp-content/plugins/* /var/www/html/wp-content/plugins
RUN cp -r /usr/src/wordpress/wp-content/themes/* /var/www/html/wp-content/themes

USER 1001
