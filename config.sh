#!/bin/bash

# Define settings in wp-config.php
wp config set MULTISITE true --raw
wp config set WP_ALLOW_MULTISITE true --raw
wp config set BLOG_ID_CURRENT_SITE 1 --raw
wp config set SITE_ID_CURRENT_SITE 1 --raw
wp config set SUBDOMAIN_INSTALL false --raw


# Check whether WordPress Multisite is installed or not.
# If not, then install via WP CLI
if ! wp core is-installed --network; then
    wp core multisite-convert --title="Hale Platform WP Multisite"
fi

# Run DB check and update
wp core update-db --network

# Check plugins are activated
wp plugin --all --network activate

# Convert database to support multisite if it is a fresh db install
exec "$@"
