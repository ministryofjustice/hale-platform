#!/bin/bash
set -e
#set -o xtrace # Uncomment this line for debugging purposes

# Make a copy of docker-entrypoint and inject shell script into it so that our own config script can run
# The injection point is the line before the base image's final `exec "$@"`.
sed "$ i /usr/local/bin/config.sh" /usr/local/bin/docker-entrypoint.sh > /tmp/docker-entrypoint.sh

# Patch the copied entrypoint to suppress the known-harmless tar chmod failure on
# the /var/www/html mount point, which otherwise exits the container and costs an
# unnecessary restart on every fresh pod. fsGroup does not prevent it - the
# emptyDir stays root-owned and chmod needs ownership. See startup-patch.sh.
/usr/local/bin/startup-patch.sh /tmp/docker-entrypoint.sh

# Execute the modified entrypoint from /tmp — deliberately NOT writing back to
# /usr/local/bin/ so the original stays pristine across container stop/start cycles.
chmod +x /tmp/docker-entrypoint.sh
exec /tmp/docker-entrypoint.sh "php-fpm"
