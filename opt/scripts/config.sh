#!/bin/bash

# Define settings in wp-config.php
wp config set MULTISITE true --raw
wp config set WP_ALLOW_MULTISITE true --raw
wp config set BLOG_ID_CURRENT_SITE 1 --raw
wp config set SITE_ID_CURRENT_SITE 1 --raw
wp config set SUBDOMAIN_INSTALL false --raw
wp config set DOMAIN_CURRENT_SITE "\$_SERVER['SERVER_NAME']" --raw
wp config set COOKIE_DOMAIN false --raw
wp config set ADMIN_COOKIE_PATH "/"
wp config set COOKIEPATH "/"
wp config set SITECOOKIEPATH "/"
wp config set WP_ENVIRONMENT_TYPE "\$_SERVER['WP_ENVIRONMENT_TYPE']" --raw
wp config set AUTOMATIC_UPDATER_DISABLED true --raw
wp config set FORCE_SSL_ADMIN true --raw
wp config set S3_UPLOADS_BUCKET "\$_SERVER['S3_UPLOADS_BUCKET']" --raw
wp config set S3_UPLOADS_REGION "\$_SERVER['S3_UPLOADS_REGION']" --raw
wp config set S3_UPLOADS_USE_INSTANCE_PROFILE "\$_SERVER['S3_UPLOADS_USE_INSTANCE_PROFILE']" --raw

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
wp core update-db --network --url="${SERVER_NAME}"

# Setup Hale theme
wp theme enable hale --network --url="${SERVER_NAME}"
wp theme enable hale --activate --url="$SERVER_NAME"

# Check plugins are activated
#wp plugin --network activate advanced-custom-fields-pro --url="${SERVER_NAME}"
#wp plugin --network activate wp-user-roles --url="${SERVER_NAME}"
#wp plugin --network activate wp-moj-blocks --url="${SERVER_NAME}"

exec "$@"
