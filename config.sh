#!/bin/bash

# Define settings in wp-config.php
wp config set MULTISITE true --raw
wp config set WP_ALLOW_MULTISITE true --raw
wp config set BLOG_ID_CURRENT_SITE 1 --raw
wp config set SITE_ID_CURRENT_SITE 1 --raw
wp config set SUBDOMAIN_INSTALL false --raw

# Convert database to support multisite if it is a fresh db install
wp core multisite-convert --title="Hale Platform"
wp core update-db --network

wp plugin --network activate

exec "$@"
