#!/bin/bash
set -e
#set -o xtrace # Uncomment this line for debugging purposes

# Inject shell script into docker-entrypoint so that our own config script can run
sed "$ i /usr/local/bin/config.sh" /usr/local/bin/docker-entrypoint.sh > /tmp/docker-entrypoint.sh

# Tolerate "Cannot change mode" tar error when extracting WordPress to a K8s emptyDir volume.
# Running as non-root (UID 1002), tar cannot chmod the mount point directory itself. The files
# extract fine — only the chmod on "." fails — so we suppress that specific error while still
# failing on any unexpected tar errors.
#
# Step 1: Replace the tar pipeline with an error-capturing version
sed -i 's/tar "${sourceTarArgs\[@\]}" \. | tar "${targetTarArgs\[@\]}"/tar_err=$(tar "${sourceTarArgs[@]}" . | tar "${targetTarArgs[@]}" 2>\&1 || true)/' /tmp/docker-entrypoint.sh
# Step 2: Insert error checking lines after the tar_err assignment
sed -i '/tar_err=$(tar.*sourceTarArgs/a\
filtered=$(echo "$tar_err" | grep -v "Cannot change mode" | grep -v "Exiting with failure" || true)\
if [ -n "$filtered" ]; then echo "$filtered" >\&2; exit 1; fi' /tmp/docker-entrypoint.sh

cat /tmp/docker-entrypoint.sh > /usr/local/bin/docker-entrypoint.sh

# Execute the modified docker-entrypoint.sh
/usr/local/bin/docker-entrypoint.sh "php-fpm"
