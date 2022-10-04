# WP package management
FROM composer:latest AS composer
COPY composer.json /tmp
WORKDIR /tmp
RUN composer install -vvv

# Build WordPress multisite image
FROM --platform=linux/amd64 wordpress:6.0.1-php7.4-fpm-alpine

# Adjust php.ini configuration settings
# COPY custom.ini $PHP_INI_DIR/conf.d/

# Adjust PHP-FPM configuration settings
COPY ./php/www.conf /usr/local/etc/php-fpm.d/www.conf 

# Set permissions for wp-cli
RUN addgroup -g 1001 wp && adduser -G wp -g wp -s /bin/sh -D wp
RUN chown wp:wp /var/www/html

# Install wp-cli
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
RUN chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp

# Add WP multisite network scripts
COPY opt/hale-entrypoint.sh /usr/local/bin/
COPY opt/config.sh /usr/local/bin/

# Make multisite scripts executable
RUN chmod +x /usr/local/bin/hale-entrypoint.sh && \
    chmod +x /usr/local/bin/config.sh

# neovim
RUN apk update && \
    apk add less && \
    apk add neovim --no-cache

# Install WP applications and repos
COPY --from=composer /tmp/wordpress/wp-content/plugins /usr/src/wordpress/wp-content/plugins
COPY --from=composer /tmp/wordpress/wp-content/themes /usr/src/wordpress/wp-content/themes

# Install NPM
RUN apk add --update npm

# Compile Hale Theme
WORKDIR /usr/src/wordpress/wp-content/themes/wp-hale

RUN npm install

RUN npm run production --if-present

RUN rm -rf node_modules

WORKDIR /var/www/html

# COPY Plugins and themes
# WARNING - Do not apply changes to plugins or themes in /var folder as it will not work

RUN cp -r /usr/src/wordpress/wp-content/plugins/* /var/www/html/wp-content/plugins
RUN cp -r /usr/src/wordpress/wp-content/themes/* /var/www/html/wp-content/themes

# Create new user to run container as non-root
RUN adduser --disabled-password hale -u 1002 && \
    chown -R hale:hale /var/www/html

RUN chown hale:hale /usr/local/bin/docker-entrypoint.sh

# Overwrite offical WP image ENTRYPOINT (docker-entrypoint.sh) 
# with custom entrypoint so we can launch WP multisite network 
ENTRYPOINT ["/usr/local/bin/hale-entrypoint.sh"]

# Set container user 'root' to 'hale'
USER 1002

CMD ["php-fpm"]

