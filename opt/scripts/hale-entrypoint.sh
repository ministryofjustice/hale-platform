#!/bin/bash
set -e
#set -o xtrace # Uncomment this line for debugging purposes

echo "[hale-entrypoint] Starting WordPress multisite setup..."

# Inject shell script into docker-entrypoint so that our own config script can run
sed "$ i /usr/local/bin/config.sh" /usr/local/bin/docker-entrypoint.sh > /tmp/docker-entrypoint.sh
cat /tmp/docker-entrypoint.sh > /usr/local/bin/docker-entrypoint.sh

# Link dev packages BEFORE starting PHP-FPM
# This ensures symlinks are in place when WordPress initializes
echo "[hale-entrypoint] Linking development packages..."
if [ -f /opt/scripts/link-dev-packages.sh ]; then
  /bin/bash /opt/scripts/link-dev-packages.sh
else
  echo "[hale-entrypoint] WARNING: link-dev-packages.sh not found at /opt/scripts/"
fi

echo "[hale-entrypoint] Starting WordPress initialization and PHP-FPM..."
# Execute the modified docker-entrypoint.sh with php-fpm
# This will run in foreground and keep the container alive
exec /usr/local/bin/docker-entrypoint.sh "php-fpm"
