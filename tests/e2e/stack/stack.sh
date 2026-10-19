#!/bin/bash
#
# Start, seed, test and remove the end-to-end test stack
# (docker-compose.test.yml). Runs on the host and is the only part of the e2e
# tests that talks to Docker; Playwright itself runs in the playwright service,
# which has no Docker socket. The make test-e2e* targets in tests/Makefile call
# this.
#
# Usage: tests/e2e/stack/stack.sh <command> [playwright arguments]
#
#   test [args]    start and seed a fresh stack, run `playwright test [args]`
#                  in the container, remove the stack. KEEP_STACK=1 leaves it
#                  running; REUSE_STACK=1 uses (and keeps) one already running.
#   up             start and seed a fresh stack and leave it running
#   down           remove the stack, its network and volumes
#   ui             Playwright UI mode on the running stack (starts one if none)
#   report         serve the last HTML report
#   urls           list the addresses the stack serves
#   lock           update package-lock.json from package.json, in a container
#   pw [args]      run any Playwright command in the container
#
# E2E_BUILD=1 rebuilds every image first. Otherwise images are rebuilt when
# missing, or when composer.lock or tests/e2e/package-lock.json has changed
# since they were built.

set -euo pipefail

cd "$(dirname "$0")/../../.."

export HALE_TEST_PROJECT=${HALE_TEST_PROJECT:-hale-test}
export HALE_TEST_PORT=${HALE_TEST_PORT:-8443}
E2E_UI_PORT=${E2E_UI_PORT:-9323}
E2E_DIR=tests/e2e

# On Linux the container writes its output as the host user, so the report and
# traces belong to whoever ran the tests. Docker Desktop maps ownership itself.
if [ "$(uname -s)" = "Linux" ]; then
    export E2E_USER="$(id -u):$(id -g)"
fi

compose() {
    docker compose -p "$HALE_TEST_PROJECT" -f docker-compose.test.yml "$@"
}

timed() {
    local label=$1 start=$SECONDS
    shift
    "$@"
    echo "[e2e] $label: $((SECONDS - start))s"
}

label() {
    docker image inspect -f "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null
}

# True when hale-test/wordpress, nginx and wptools exist and hale-test/wordpress
# was built from the current composer.lock. An image from an older lock would
# test old plugins.
stack_images_current() {
    docker image inspect hale-test/wordpress hale-test/nginx hale-test/wptools >/dev/null 2>&1 &&
        [ "$(label hale-test/wordpress hale-test.composer-lock)" = "$(git hash-object composer.lock)" ]
}

playwright_image_current() {
    [ "$(label hale-test/playwright hale-test.package-lock)" = "$(git hash-object "$E2E_DIR/package-lock.json")" ]
}

build_if_stale() {
    if [ "${E2E_BUILD:-}" = "1" ] || ! stack_images_current; then
        timed "build images" "$E2E_DIR/stack/build.sh"
    elif ! playwright_image_current; then
        timed "build playwright image" "$E2E_DIR/stack/build.sh" playwright
    fi
}

# Self-signed certificate for localhost, under the file names
# opt/nginx/localwordpress.conf expects. The key is test-only and world
# readable, because nginx runs as a different user from whoever made it.
ensure_certificate() {
    local dir=$E2E_DIR/.stack/certs
    [ -f "$dir/hale.docker.pem" ] && [ -f "$dir/hale.docker-key.pem" ] && return
    mkdir -p "$dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj /CN=localhost \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        -keyout "$dir/hale.docker-key.pem" -out "$dir/hale.docker.pem" 2>/dev/null
    chmod 644 "$dir/hale.docker-key.pem"
}

is_running() {
    [ -n "$(compose ps --status running -q nginx 2>/dev/null)" ]
}

# `compose down` leaves one-off `compose run` containers (seed, playwright)
# behind if one outlived its run, and they hold the networks open. Remove any
# first.
down() {
    local oneoff
    oneoff=$(docker ps -aq --filter "label=com.docker.compose.project=$HALE_TEST_PROJECT" \
        --filter "label=com.docker.compose.oneoff=True")
    if [ -n "$oneoff" ]; then
        # shellcheck disable=SC2086
        docker rm -f $oneoff >/dev/null
    fi
    compose --profile seed --profile playwright --profile playwright-ui down -v --remove-orphans
}

# Every run starts from an empty database: anything a previous run left behind
# is removed first.
up() {
    local start=$SECONDS
    build_if_stale
    ensure_certificate
    timed "remove previous stack" down
    if ! timed "start stack" compose up -d --wait --wait-timeout 300 nginx ||
        ! timed "seed" compose --profile seed run --rm seed; then
        [ "${KEEP_STACK:-}" = "1" ] || down
        return 1
    fi
    echo "[e2e] stack ready in $((SECONDS - start))s at https://localhost:$HALE_TEST_PORT/"
}

# The directories the container may write to. Made here so they belong to the
# host user rather than being created by Docker as root.
output_dirs() {
    mkdir -p "$E2E_DIR/.auth" "$E2E_DIR/output"
}

# No TTY (-T): with one, the HTML reporter suggests `npx playwright
# show-report`, which would install and run Playwright on the host. Colour is
# forced on instead when there is a terminal to show it.
pw() {
    output_dirs
    if [ -t 1 ]; then export FORCE_COLOR=1; fi
    compose run --rm -T playwright "$@"
}

pw_ui() {
    output_dirs
    echo "[e2e] Open http://localhost:$E2E_UI_PORT/"
    compose run --rm --service-ports playwright-ui "$@"
}

# npm resolves the lockfile in the playwright image, on a copy of the two
# manifests, so no npm runs on the host and the container sees nothing else.
# --package-lock-only downloads metadata only and runs no package code.
update_lock() {
    local work
    work=$(mktemp -d)
    cp "$E2E_DIR/package.json" "$E2E_DIR/package-lock.json" "$work/"
    docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$work:/work" -w /work \
        --entrypoint npm hale-test/playwright \
        install --package-lock-only --ignore-scripts --no-audit --no-fund
    cp "$work/package-lock.json" "$E2E_DIR/package-lock.json"
    rm -rf "$work"
    echo "[e2e] Updated $E2E_DIR/package-lock.json. make test-e2e-build rebuilds the image from it."
}

# Printed last, after teardown, so the link is the end of the output.
print_report_links() {
    [ -f "$E2E_DIR/output/playwright-report/index.html" ] || return 0
    echo ""
    if [ "$1" -ne 0 ]; then
        echo "[e2e] Tests failed."
    fi
    echo "[e2e] Report: make test-e2e-report, then http://localhost:$E2E_UI_PORT/"
}

leave_running() {
    echo "[e2e] Leaving the $HALE_TEST_PROJECT stack running at https://localhost:$HALE_TEST_PORT/"
    echo "[e2e] Remove it with: make test-e2e-down"
}

run_tests() {
    if [ "${REUSE_STACK:-}" = "1" ] && is_running; then
        echo "[e2e] Reusing the running $HALE_TEST_PROJECT stack"
        playwright_image_current || timed "build playwright image" "$E2E_DIR/stack/build.sh" playwright
    else
        up
    fi

    local status=0
    pw test "$@" || status=$?

    if [ "${KEEP_STACK:-}" = "1" ] || [ "${REUSE_STACK:-}" = "1" ]; then
        leave_running
    else
        down
    fi
    print_report_links "$status"
    return "$status"
}

command=${1:-}
shift || true

case "$command" in
    test) run_tests "$@" ;;
    up) up && pw test --project=setup && leave_running ;;
    down) down ;;
    ui)
        is_running || up
        pw_ui test --ui --ui-host=0.0.0.0 --ui-port=9323
        ;;
    report) pw_ui show-report output/playwright-report --host=0.0.0.0 --port=9323 ;;
    urls)
        playwright_image_current || "$E2E_DIR/stack/build.sh" playwright
        export E2E_STACK_RUNNING=0
        is_running && E2E_STACK_RUNNING=1
        pw node /hale/tests/e2e/stack/endpoints.js
        ;;
    lock)
        docker image inspect hale-test/playwright >/dev/null 2>&1 || "$E2E_DIR/stack/build.sh" playwright
        update_lock
        ;;
    pw) pw "$@" ;;
    *)
        sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
