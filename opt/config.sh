#!/bin/bash

# Define settings in wp-config.php
wp config set MULTISITE true --raw
wp config set WP_ALLOW_MULTISITE true --raw
wp config set BLOG_ID_CURRENT_SITE 1 --raw
wp config set SITE_ID_CURRENT_SITE 1 --raw
wp config set SUBDOMAIN_INSTALL false --raw
wp config set COOKIE_DOMAIN "\$_SERVER['HTTP_HOST']" --raw 
wp config set DOMAIN_CURRENT_SITE "\$_SERVER['SERVER_NAME']" --raw
wp config set WP_ENVIRONMENT_TYPE "\$_SERVER['WP_ENVIRONMENT_TYPE']" --raw 
wp config set WP_DEBUG true --raw

# Check whether WordPress Multisite is installed or not.
# If not, then install via WP CLI
if ! wp core is-installed --network; then
    wp core multisite-convert --title="Hale Platform WP Multisite"
fi

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
