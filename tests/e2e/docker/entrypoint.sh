#!/bin/sh
#
# Entrypoint of the playwright and browserstack services in
# docker-compose.test.yml.
#
# The sites' stored domain is localhost:$HALE_TEST_PORT, so the browser (or the
# BrowserStack Local tunnel) has to ask for exactly that address. forward.js
# listens there and passes every connection on to nginx. Then the arguments
# run as a Playwright command, or as any other command when the first one is
# not a Playwright command.

set -eu

node /hale/tests/e2e/support/forward.js &

case "${1:-}" in
    node | sh) exec "$@" ;;
    # browserstack-node-sdk writes setup files into its working directory, and
    # /hale/tests/e2e is read-only. It runs from a copy in the
    # /hale/browserstack-run tmpfs instead, under /hale so the copy still finds
    # /hale/node_modules. The copy goes in a folder of its own: tar sets the
    # top folder's mode and times, which it cannot do to the root-owned mount
    # point. output/, log/ and .auth/ in the copy are links to the mounts, so
    # the report, the SDK's logs and the logins reach the host as before.
    # node_modules is a link to the image's packages, so the `npm ls` the SDK
    # runs beside package.json finds them.
    browserstack-node-sdk)
        run=/hale/browserstack-run/e2e
        mkdir "$run"
        tar -C /hale/tests/e2e --exclude=./output --exclude=./log \
            --exclude=./.auth --exclude=./.stack -cf - . | tar -C "$run" -xf -
        for dir in output log .auth; do
            ln -s "/hale/tests/e2e/$dir" "$run/$dir"
        done
        ln -s /hale/node_modules "$run/node_modules"
        cd "$run"
        exec "$@"
        ;;
    *) exec /hale/node_modules/.bin/playwright "$@" ;;
esac
