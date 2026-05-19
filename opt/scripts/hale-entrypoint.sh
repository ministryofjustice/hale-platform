#!/bin/bash
set -e
#set -o xtrace # Uncomment this line for debugging purposes

# Make a copy of docker-entrypoint and inject shell script into it so that our own config script can run
sed "$ i /usr/local/bin/config.sh" /usr/local/bin/docker-entrypoint.sh > /tmp/docker-entrypoint.sh

# Patch the copied entrypoint to suppress a known-harmless tar chmod failure
# on the /var/www/html mount point that otherwise causes an unnecessary pod
# restart on every fresh start. See startup-patch.sh for full details.
/usr/local/bin/startup-patch.sh /tmp/docker-entrypoint.sh

# Execute the modified entrypoint from /tmp — deliberately NOT writing back to
# /usr/local/bin/ so the original stays pristine across container stop/start cycles.
chmod +x /tmp/docker-entrypoint.sh
exec /tmp/docker-entrypoint.sh "php-fpm"
