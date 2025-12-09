#!/bin/bash
set -e
#set -o xtrace # Uncomment this line for debugging purposes

# Inject shell script into docker-entrypoint so that our own config script can run
sed "$ i /usr/local/bin/config.sh" /usr/local/bin/docker-entrypoint.sh > /tmp/docker-entrypoint.sh

# Modify `targetTarArgs` to add `--no-same-owner --no-same-permissions` flags
# This means that tar will not attempt to modify permissions from 0755 to 0777, 
# which fails on Cloud Platform, because /var/www/html is owned by root.
sed -i 's/--no-overwrite-dir/--no-overwrite-dir --no-same-owner --no-same-permissions/g' /tmp/docker-entrypoint.sh

cat /tmp/docker-entrypoint.sh > /usr/local/bin/docker-entrypoint.sh

# Execute the modified docker-entrypoint.sh
/usr/local/bin/docker-entrypoint.sh "php-fpm"
