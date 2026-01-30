#!/bin/bash
set -euo pipefail

echo "[config.sh] Environment: ${WP_ENVIRONMENT_TYPE:-unknown}"
echo "[config.sh] Starting WordPress configuration..."

WP_CONFIG="/var/www/html/wp-config.php"

# Wait for wp-config.php to exist (created by WordPress entrypoint)
for i in {1..30}; do
    if [ -f "$WP_CONFIG" ]; then
        echo "[config.sh] Found wp-config.php"
        break
    fi
    echo "[config.sh] Waiting for wp-config.php to be created... ($i/30)"
    sleep 1
done

if [ ! -f "$WP_CONFIG" ]; then
    echo "[config.sh] ERROR: wp-config.php not found after 30 seconds"
    exit 1
fi

# Check if WordPress is already installed in the database
WP_INSTALLED=false
if wp core is-installed --network --quiet 2>/dev/null; then
    WP_INSTALLED=true
    echo "[config.sh] WordPress database already initialized"
else
    echo "[config.sh] Fresh database detected - will run full installation"
fi

# Set all configuration constants
# These need to be in wp-config.php for WordPress multisite to work
# We only do this once by checking if MULTISITE constant already exists
echo "[config.sh] Configuring wp-config.php constants..."

if ! grep -q "define.*MULTISITE" "$WP_CONFIG" 2>/dev/null; then
    echo "[config.sh] Adding multisite constants to wp-config.php..."
    
    # Use wp config set for each constant
    # This is the official, supported way and handles all edge cases
    wp config set MULTISITE true --raw --type=constant --quiet
    wp config set WP_ALLOW_MULTISITE true --raw --type=constant --quiet
    wp config set BLOG_ID_CURRENT_SITE 1 --raw --type=constant --quiet
    wp config set SITE_ID_CURRENT_SITE 1 --raw --type=constant --quiet
    wp config set SUBDOMAIN_INSTALL false --raw --type=constant --quiet
    wp config set DOMAIN_CURRENT_SITE "\$_SERVER['SERVER_NAME']" --raw --type=constant --quiet
    wp config set COOKIE_DOMAIN false --raw --type=constant --quiet
    wp config set ADMIN_COOKIE_PATH "/" --type=constant --quiet
    wp config set COOKIEPATH "/" --type=constant --quiet
    wp config set SITECOOKIEPATH "/" --type=constant --quiet
    wp config set WP_ENVIRONMENT_TYPE "\$_SERVER['WP_ENVIRONMENT_TYPE']" --raw --type=constant --quiet
    wp config set AUTOMATIC_UPDATER_DISABLED true --raw --type=constant --quiet
    wp config set FORCE_SSL_ADMIN true --raw --type=constant --quiet
    wp config set S3_UPLOADS_BUCKET "\$_SERVER['S3_UPLOADS_BUCKET']" --raw --type=constant --quiet
    wp config set S3_UPLOADS_REGION "\$_SERVER['S3_UPLOADS_REGION']" --raw --type=constant --quiet
    wp config set S3_UPLOADS_BUCKET_URL "\$_SERVER['S3_UPLOADS_BUCKET_URL']" --raw --type=constant --quiet
    wp config set S3_UPLOADS_USE_INSTANCE_PROFILE "\$_SERVER['S3_UPLOADS_USE_INSTANCE_PROFILE']" --raw --type=constant --quiet
    wp config set QM_ENABLE_CAPS_PANEL true --raw --type=constant --quiet
    wp config set WP_CACHE true --raw --type=constant --quiet
    wp config set ACF_PRO_LICENSE "\$_SERVER['ACF_PRO_LICENSE']" --raw --type=constant --quiet
    wp config set WP_SENTRY_PHP_DSN "\$_SERVER['PHP_DSN']" --raw --type=constant --quiet
    wp config set WP_SENTRY_BROWSER_DSN "\$_SERVER['PHP_DSN']" --raw --type=constant --quiet
    wp config set WP_SENTRY_ENV "\$_SERVER['WP_ENVIRONMENT_TYPE']" --raw --type=constant --quiet
    wp config set WP_SENTRY_BROWSER_ADMIN_ENABLED true --raw --type=constant --quiet
    wp config set WP_SENTRY_BROWSER_LOGIN_ENABLED true --raw --type=constant --quiet
    wp config set WP_SENTRY_BROWSER_FRONTEND_ENABLED true --raw --type=constant --quiet
    wp config set WP_SENTRY_BROWSER_TRACES_SAMPLE_RATE "0.2" --raw --type=constant --quiet
    wp config set WP_SENTRY_BROWSER_REPLAYS_ON_ERROR_SAMPLE_RATE "1.0" --raw --type=constant --quiet
    
    echo "[config.sh] Constants added to wp-config.php"
else
    echo "[config.sh] Constants already exist in wp-config.php, skipping"
fi

# Now handle WordPress installation
if [ "$WP_INSTALLED" = false ]; then
    # First-time installation: run full WordPress setup
    echo "[config.sh] Installing WordPress multisite..."
    
    wp core multisite-install \
        --title="Hale Multisite Platform" \
        --admin_user="${WORDPRESS_ADMIN_USER}" \
        --admin_email="${WORDPRESS_ADMIN_EMAIL}" \
        --admin_password="${WORDPRESS_ADMIN_PASSWORD}" \
        --url="${SERVER_NAME}" \
        --skip-config \
        --skip-email \
        --quiet
    
    echo "[config.sh] Running initial database setup..."
    
    # Update database schema if needed
    wp core update-db --network --url="${SERVER_NAME}"
    
    # Enable Hale theme across the network
    wp theme enable hale --network --url="${SERVER_NAME}"
    
    # Activate Query Monitor extended capabilities
    wp qm enable
    
    # Clean up default WordPress themes and plugins
    echo "[config.sh] Removing default WordPress content..."
    wp theme delete twentytwentyone twentytwentytwo 2>/dev/null || true
    wp plugin delete akismet hello 2>/dev/null || true
    
    echo "[config.sh] Initial WordPress installation complete"
else
    # WordPress already installed - just do quick maintenance
    echo "[config.sh] Running maintenance tasks..."
    wp core update-db --network --url="${SERVER_NAME}" --quiet 2>/dev/null || true
fi

# Link development packages (LOCAL ENVIRONMENT ONLY)
if [ "${WP_ENVIRONMENT_TYPE:-}" = "local" ] && [ -f /opt/scripts/link-dev-packages.sh ]; then
    echo "[config.sh] Linking local development packages..."
    /bin/bash /opt/scripts/link-dev-packages.sh
else
    echo "[config.sh] Skipping dev package linking (not in local environment)"
fi

echo "[config.sh] Startup complete - ready to serve requests"
exec "$@"
