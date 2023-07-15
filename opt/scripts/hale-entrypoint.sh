#!/bin/bash
set -e
#set -o xtrace # Uncomment this line for debugging purposes

# Inject shell script into docker-entrypoint so that our own config script can run
sed "$ i /usr/local/bin/config.sh" /usr/local/bin/docker-entrypoint.sh > /tmp/docker-entrypoint.sh
cat /tmp/docker-entrypoint.sh > /usr/local/bin/docker-entrypoint.sh

# Execute the modified docker-entrypoint.sh
exec /usr/local/bin/docker-entrypoint.sh &

# Wait for the entrypoint script to complete
wait

# Create new user to run container as non-root
sudo adduser --disabled-password hale -u 1002

# Change the owner of the files in /var/www/html to hale
sudo chown -R hale:hale /var/www/html

# Run PHP-FPM ready for requests
exec php-fpm
