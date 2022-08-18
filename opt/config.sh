#!/bin/bash

# Define settings in wp-config.php
wp config set MULTISITE true --raw
wp config set WP_ALLOW_MULTISITE true --raw
wp config set BLOG_ID_CURRENT_SITE 1 --raw
wp config set SITE_ID_CURRENT_SITE 1 --raw
wp config set SUBDOMAIN_INSTALL false --raw
wp config set DOMAIN_CURRENT_SITE "\$_SERVER['SERVER_NAME']" --raw
wp config set COOKIE_DOMAIN "\$_SERVER['HTTP_HOST']" --raw 
wp config set WP_ENVIRONMENT_TYPE "\$_SERVER['WP_ENVIRONMENT_TYPE']" --raw 
wp config set WP_DEBUG true --raw

#WP core install
wp core multisite-install --title="Hale Multisite Platform" \
    --admin_user="${WORDPRESS_ADMIN_USER}" \
    --admin_email="${WORDPRESS_ADMIN_EMAIL}" \
    --admin_password="${WORDPRESS_ADMIN_PASSWORD}" \
    --url="${SERVER_NAME}" \
    --skip-config \
    --skip-email \
    --quiet;

# Run DB check and update
wp core update-db --network

# Setup Hale theme
#wp theme enable wp-hale --network
#wp theme enable wp-hale --activate

wp theme enable twentytwentytwo --network
wp theme enable twentytwentytwo --activate

# Check plugins are activated
wp plugin --all --network activate

exec "$@"