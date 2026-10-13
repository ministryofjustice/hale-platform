#!/bin/bash
#
# Build the images the end-to-end test stack runs (docker-compose.test.yml).
#
# They come from the same Dockerfiles as hale.docker, under their own
# hale-test/* tags so building them never replaces the images hale.docker
# runs. Plugins and themes are whatever composer last installed into
# ./wordpress, so run `composer install` (or `make build`) first.
#
# Usage: tests/e2e/stack/build.sh

set -euo pipefail

cd "$(dirname "$0")/../../.."

if [ ! -d wordpress/wp-content/plugins ] || [ ! -d vendor ]; then
    echo "wordpress/ or vendor/ is missing. Run 'composer install' first." >&2
    exit 1
fi

# The images COPY wordpress/wp-content, and COPY copies a symlink as a symlink.
# Links made by opt/scripts/link-dev-packages.sh point into /mnt/dev, which the
# test stack does not mount, so they would be dangling in the image.
links=$(find wordpress/wp-content -maxdepth 2 -type l)
if [ -n "$links" ]; then
    echo "wordpress/wp-content holds symlinks (dev package links?):" >&2
    echo "$links" | sed 's/^/  /' >&2
    echo "Run 'composer install' to restore real folders, then build again." >&2
    exit 1
fi

echo "Building hale-test/wordpress-base"
docker build -f wordpress.local.dockerfile -t hale-test/wordpress-base .

# Labelled with the composer.lock it was built from, so the global setup can
# tell when the image is older than the lock and rebuild it.
echo "Building hale-test/wordpress (compiled theme assets)"
docker build -f tests/e2e/stack/wordpress.dockerfile \
    --build-arg BASE_IMAGE=hale-test/wordpress-base \
    --label "hale-test.composer-lock=$(git hash-object composer.lock)" \
    -t hale-test/wordpress .

echo "Building hale-test/nginx"
docker build -f nginx.local.dockerfile --target nginx -t hale-test/nginx .

echo "Building hale-test/wptools"
docker build -f wptools.dockerfile -t hale-test/wptools .
