#!/bin/bash
set -e
#set -o xtrace # Uncomment this line for debugging purpose

# Inject shell script into docker-entrypoint so that our own config script can run
sed "$ i /usr/local/bin/config.sh" /usr/local/bin/docker-entrypoint.sh > /tmp/docker-entrypoint.sh
cat /tmp/docker-entrypoint.sh > /usr/local/bin/docker-entrypoint.sh

# Execute the modified docker-entrypoint.sh and run PHP-FPM ready for requests
exec /usr/local/bin/docker-entrypoint.sh "php-fpm"
