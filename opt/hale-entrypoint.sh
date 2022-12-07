#!/bin/bash
set -e 
# set -o xtrace # Uncomment this line for debugging purpose

VOLUME_VERSION="$(php -r 'require('"'"'/var/www/html/wp-includes/version.php'"'"'); echo $wp_version;')"

echo "Volume version : "$VOLUME_VERSION
echo "WordPress version : "$WORDPRESS_VERSION

if [ "$VOLUME_VERSION" != "$WORDPRESS_VERSION" ]; then
    echo "Forcing WordPress code update..."
    rm -f /var/www/html/index.php
    rm -f /var/www/html/wp-includes/version.php
fi

# Inject shell script into docker-entrypoint so that our own conifg script can run
sed "$ i /usr/local/bin/config.sh" /usr/local/bin/docker-entrypoint.sh > /tmp/docker-entrypoint.sh && cat /tmp/docker-entrypoint.sh > /usr/local/bin/docker-entrypoint.sh

exec /usr/local/bin/docker-entrypoint.sh $@
