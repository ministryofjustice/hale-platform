#!/bin/bash
#set -e
#set -o xtrace # Uncomment this line for debugging purpose

# Inject shell script into docker-entrypoint so that our own config script can run
sed "$ i /usr/local/bin/config.sh" /usr/local/bin/docker-entrypoint.sh > /tmp/docker-entrypoint.sh
cat /tmp/docker-entrypoint.sh > /usr/local/bin/docker-entrypoint.sh || true

# Execute the modified docker-entrypoint.sh script with command-line arguments
(exec /usr/local/bin/docker-entrypoint.sh "php-fpm") || true

# Ensure the script exits with code 0 (success)
exit 0
