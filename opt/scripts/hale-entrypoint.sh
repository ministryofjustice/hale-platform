#!/bin/bash
set -e
#set -o xtrace # Uncomment this line for debugging purposes

# Inject shell script into docker-entrypoint so that our own config script can run
sed "$ i /usr/local/bin/config.sh" /usr/local/bin/docker-entrypoint.sh > /tmp/docker-entrypoint.sh

# WordPress's default docker-entrypoint.sh copies source code from /usr/src/wordpress to
# /var/www/html using tar. On K8s, /var/www/html is an emptyDir volume owned by root, and
# the container runs as non-root (UID 1002). When tar extracts, it tries to chmod the mount
# point directory "." to rwxrwxrwx, which fails with:
#   tar: .: Cannot change mode to rwxrwxrwx: Operation not permitted
# This causes the WordPress pod to error and restart once every time a pod is created.
# The files themselves extract fine — only the chmod on "." fails — so it is safe to ignore.
# This modification suppresses that specific tar error while still failing on any unexpected
# tar errors, preventing the unnecessary pod restart.
#
# Step 1: Replace the tar pipeline with an error-capturing version
sed -i 's/tar "${sourceTarArgs\[@\]}" \. | tar "${targetTarArgs\[@\]}"/tar_err=$(tar "${sourceTarArgs[@]}" . | tar "${targetTarArgs[@]}" 2>\&1 || true)/' /tmp/docker-entrypoint.sh
# Step 2: Insert error checking lines after the tar_err assignment
sed -i '/tar_err=$(tar.*sourceTarArgs/a\
filtered=$(echo "$tar_err" | grep -v "Cannot change mode" | grep -v "Exiting with failure" || true)\
if [ -n "$filtered" ]; then echo "$filtered" >\&2; exit 1; fi' /tmp/docker-entrypoint.sh
# Step 3: Verify the tar patch was applied — if WordPress changes their entrypoint, we need to know
if ! grep -q 'tar_err=' /tmp/docker-entrypoint.sh; then
    echo >&2 "WARNING: tar permission patch was not applied to docker-entrypoint.sh — WordPress base image may have changed"
fi

# Write the contents of the temp. file back to the source entrypoint.
cat /tmp/docker-entrypoint.sh > /usr/local/bin/docker-entrypoint.sh

# Execute the modified docker-entrypoint.sh
/usr/local/bin/docker-entrypoint.sh "php-fpm"
