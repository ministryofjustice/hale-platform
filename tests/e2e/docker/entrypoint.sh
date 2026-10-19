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
    node | sh | browserstack-node-sdk) exec "$@" ;;
    *) exec /hale/node_modules/.bin/playwright "$@" ;;
esac
