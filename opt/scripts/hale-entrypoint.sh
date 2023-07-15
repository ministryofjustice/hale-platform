#!/bin/bash
set -e
#set -o xtrace # Uncomment this line for debugging purposes

# Set a default value for $1 if it is not provided
if [ -z "$1" ]; then
  set -- default_argument
fi

# Inject shell script into docker-entrypoint so that our own config script can run
sed "$ i /usr/local/bin/config.sh" /usr/local/bin/docker-entrypoint.sh > /tmp/docker-entrypoint.sh
cat /tmp/docker-entrypoint.sh > /usr/local/bin/docker-entrypoint.sh

# Execute the modified docker-entrypoint.sh
exec /usr/local/bin/docker-entrypoint.sh "$@" &

# Wait for the entrypoint script to complete
wait

# Create new user to run container as non-root
adduser --disabled-password hale -u 1002

# Change the owner of the files in /var/www/html to hale
chown -R hale:hale /var/www/html

# Run PHP-FPM ready for requests
exec php-fpm
