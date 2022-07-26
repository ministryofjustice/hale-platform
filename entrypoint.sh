#!/bin/bash
set -e 
# set -o xtrace # Uncomment this line for debugging purpose

# Define the config anchor
#MOJ_WP_ANCHOR="/* That's all, stop editing! Happy publishing. */"

#wp config set MULTISITE true --raw --anchor="/* That's all, stop editing! Happy publishing. */" --placement='after' --config-file=/var/www/html
#wp core multisite-convert

echo " Test shell is working " > filename2.txt

exec "$@"
