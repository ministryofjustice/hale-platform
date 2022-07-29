#!/bin/bash
set -e 
# set -o xtrace # Uncomment this line for debugging purpose

#chmod +x /usr/local/bin/docker-entrypoint.sh
#./usr/local/bin/docker-entrypoint.sh

#wp core download

sed "$ i /usr/local/bin/config.sh" /usr/local/bin/docker-entrypoint.sh > /tmp/docker-entrypoint.sh && cat /tmp/docker-entrypoint.sh > /usr/local/bin/docker-entrypoint.sh

#sed -i '$ i /usr/local/bin/config.sh' /usr/local/bin/docker-entrypoint.sh


#wp core multisite-install --path="/var/www/html" --title="Welcome to the Hale Platform Multisite build"
#wp core multisite-convert --path="/var/www/html"
#wp db check
#echo "hello 2" >> pusheen.txt
#ls | grep * > filename.txt
#wp db check --path="/var/www/html" >> filename.txt

#export WORDPRESS_ENABLE_MULTISITE="${WORDPRESS_ENABLE_MULTISITE:-yes}" # only used during the first initialization

#wp config set MULTISITE true --raw
#wp config set WP_ALLOW_MULTISITE true --raw

echo "Running WP entrypoint"

exec /usr/local/bin/docker-entrypoint.sh $@
