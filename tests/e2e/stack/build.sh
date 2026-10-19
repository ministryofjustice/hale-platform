#!/bin/bash
#
# Build the images the end-to-end test stack runs (docker-compose.test.yml).
#
# The stack images come from the same Dockerfiles as hale.docker, under their
# own hale-test/* tags so building them never replaces the images hale.docker
# runs. Plugins and themes are whatever composer last installed into
# ./wordpress, so run `composer install` (or `make build`) first.
# hale-test/playwright is the image the tests themselves run in, and
# hale-test/browserstack the one make test-e2e-browserstack runs them in.
#
# Usage: tests/e2e/stack/build.sh               every image but browserstack
#        tests/e2e/stack/build.sh playwright    hale-test/playwright only
#        tests/e2e/stack/build.sh browserstack  hale-test/browserstack only

set -euo pipefail

cd "$(dirname "$0")/../../.."

# Labelled with the lockfile it was built from, so stack.sh can tell when the
# image is older than the lockfile and rebuild it. The build context is
# tests/e2e/ alone: nothing else in the repo reaches the npm install.
# Usage: build_npm_image <dockerfile target>, which is also the image name.
build_npm_image() {
    echo "Building hale-test/$1"
    docker build -f tests/e2e/docker/playwright.dockerfile --target "$1" \
        --label "hale-test.package-lock=$(git hash-object tests/e2e/package-lock.json)" \
        -t "hale-test/$1" tests/e2e
}

# Only make test-e2e-browserstack needs hale-test/browserstack, so a full
# build (and CI) leaves it out; stack.sh builds it when it is first needed.
case "${1:-}" in
    playwright | browserstack)
        build_npm_image "$1"
        exit 0
        ;;
esac

if [ ! -d wordpress/wp-content/plugins ] || [ ! -d vendor ]; then
    echo "wordpress/ or vendor/ is missing. Run 'composer install' first." >&2
    exit 1
fi

# The images COPY wordpress/wp-content/{plugins,themes,mu-plugins}, and COPY
# copies a symlink as a symlink. Links made by opt/scripts/link-dev-packages.sh
# point into /mnt/dev, which the test stack does not mount, so they would be
# dangling in the image. Only those three folders are checked: anything else in
# wp-content (such as Query Monitor's db.php link) never goes into the image.
links=$(find wordpress/wp-content/plugins wordpress/wp-content/themes \
    wordpress/wp-content/mu-plugins -maxdepth 1 -type l)
if [ -n "$links" ]; then
    echo "wordpress/wp-content holds symlinks (dev package links?):" >&2
    echo "$links" | sed 's/^/  /' >&2
    echo "Run 'composer install' to restore real folders, then build again." >&2
    exit 1
fi

echo "Building hale-test/wordpress-base"
docker build -f wordpress.local.dockerfile -t hale-test/wordpress-base .

# Labelled with the composer.lock it was built from, so stack.sh can
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

build_npm_image playwright
