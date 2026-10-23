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
#   test-all [args]
#                  test, then the same tests on BrowserStack on the same stack
#                  when there are BrowserStack credentials (make test-e2e,
#                  make test-e2e-release). The BrowserStack account is checked
#                  first; when it does not work, an orange warning says the
#                  BrowserStack tests will be skipped
#   browserstack [args]
#                  the same, with the tests run on BrowserStack devices by
#                  browserstack-node-sdk (platforms in browserstack.yml)
#   up             start and seed a fresh stack and leave it running
#   down           remove the stack, its network and volumes
#   ui             Playwright UI mode on the running stack (starts one if none)
#   report         serve the last HTML report
#   urls           list the addresses the stack serves
#   lock           update package-lock.json from package.json, in a container
#   pw [args]      run any Playwright command in the container
#
# E2E_BUILD=1 rebuilds every image first. Otherwise images are rebuilt when
# missing, or when their build inputs (the Dockerfiles, opt/, composer.lock or
# tests/e2e/package-lock.json) have changed since they were built.
# hale-test/browserstack is left out of both: the browserstack command builds
# it when it is missing or stale.
#
# E2E_DEV=1 (every make target but test-e2e-release) builds the stack with
# the dev/ clones that make symlink linked, in place of their composer.lock
# versions; a run without it rebuilds them. REUSE_STACK=1 uses a running
# stack as it was built.

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

# Returns the command's status, so callers in an `if` or `||`, where set -e is
# off, still see a failure.
timed() {
    local label=$1 start=$SECONDS status=0
    shift
    "$@" || status=$?
    echo "[e2e] $label: $((SECONDS - start))s"
    return "$status"
}

label() {
    docker image inspect -f "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null
}

# True when hale-test/wordpress, nginx and wptools were all built from the
# current build inputs (stack/image-inputs.sh): the Dockerfiles, opt/ and
# composer.lock. An older image would test old code or old plugins.
stack_images_current() {
    local inputs image
    inputs=$("$E2E_DIR/stack/image-inputs.sh") || return 1
    for image in wordpress nginx wptools; do
        [ "$(label "hale-test/$image" hale-test.inputs)" = "$inputs" ] || return 1
    done
}

# True when hale-test/<name> was built from the current package-lock.json and
# docker/playwright.dockerfile (npm_inputs in build.sh).
npm_image_current() {
    [ "$(label "hale-test/$1" hale-test.npm-inputs)" = \
        "$(cat "$E2E_DIR/package-lock.json" "$E2E_DIR/docker/playwright.dockerfile" | git hash-object --stdin)" ]
}

# True for E2E_DEV=1 with dev package links in wordpress/wp-content. Such a
# build always runs: image-inputs.sh does not hash dev/, and Docker's cache
# keeps it short when the clones have not changed.
dev_build() {
    [ "${E2E_DEV:-}" = "1" ] && [ -n "$(find wordpress/wp-content/plugins \
        wordpress/wp-content/themes wordpress/wp-content/mu-plugins \
        -maxdepth 1 -type l 2>/dev/null)" ]
}

build_if_stale() {
    if [ "${E2E_BUILD:-}" = "1" ] || dev_build || ! stack_images_current; then
        timed "build images" "$E2E_DIR/stack/build.sh" || return 1
    elif ! npm_image_current playwright; then
        timed "build playwright image" "$E2E_DIR/stack/build.sh" playwright || return 1
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

project_containers() {
    docker ps -aq --filter "label=com.docker.compose.project=$HALE_TEST_PROJECT"
}

project_networks() {
    docker network ls -q --filter "label=com.docker.compose.project=$HALE_TEST_PROJECT"
}

# True while a container is still attached to one of the stack's networks.
networks_in_use() {
    local nets
    nets=$(project_networks)
    [ -n "$nets" ] || return 1
    # shellcheck disable=SC2086
    docker network inspect -f '{{len .Containers}}' $nets 2>/dev/null | grep -qv '^0$'
}

# Removes every container of the stack first, the one-off `compose run`
# containers (seed, playwright, browserstack) among them, which `compose down`
# leaves behind. Then waits until the networks have nothing attached before
# `compose down` removes them: Docker removes a `run --rm` container in the
# background once it exits, and lets go of a removed container's network a
# moment after it is gone, so removing the networks straight away fails with
# "Resource is still in use". Names whatever still holds a network after that.
down() {
    local containers nets tries=0
    containers=$(project_containers)
    if [ -n "$containers" ]; then
        # Fails for a container Docker is already removing; the wait covers it.
        # shellcheck disable=SC2086
        docker rm -fv $containers >/dev/null 2>&1 || true
    fi
    while { [ -n "$(project_containers)" ] || networks_in_use; } && [ "$tries" -lt 30 ]; do
        sleep 1
        tries=$((tries + 1))
    done
    compose --profile seed --profile playwright --profile playwright-ui --profile browserstack down -v --remove-orphans

    nets=$(project_networks)
    if [ -n "$nets" ]; then
        echo "[e2e] Test networks still in use by:" >&2
        # shellcheck disable=SC2086
        docker network inspect -f '  {{.Name}}: {{range .Containers}}{{.Name}} {{end}}' $nets >&2 || true
    fi
}

# Every run starts from an empty database: anything a previous run left behind
# is removed first. Each step returns on failure itself, because up is also
# called from `||` and `&&` lists, where set -e does not apply.
up() {
    local start=$SECONDS
    build_if_stale || return 1
    ensure_certificate || return 1
    timed "remove previous stack" down || return 1
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

# browserstack-node-sdk runs Playwright in the browserstack service and sends
# the browsers to BrowserStack, which reaches the stack through BrowserStack
# Local. Its logs go to tests/e2e/log/, its report and results to
# tests/e2e/output/browserstack/, beside the local run's. bs_ready first.
bs() {
    if [ -t 1 ]; then export FORCE_COLOR=1; fi
    if [ "${E2E_VERBOSE:-}" = 1 ]; then
        compose run --rm -T browserstack \
            browserstack-node-sdk playwright test --browserstack.config browserstack.yml "$@"
    else
        compose run --rm -T browserstack \
            browserstack-node-sdk playwright test --browserstack.config browserstack.yml "$@" 2>&1 |
            bs_quiet
    fi
}

# browserstack-node-sdk logs every step of every test to the terminal, as
# well as to tests/e2e/log/usage.log. This keeps Playwright's own output and
# drops the SDK's lines: its info lines (and the objects some of them dump)
# go, each distinct warning or error is shown once without its stack trace,
# and the build report link stays. Stack traces in Playwright's own output,
# under a failed test, are kept.
bs_quiet() {
    awk '
        { line = $0; gsub(/\033\[[0-9;]*m/, "", line) }
        skip { if (line ~ /^[]}]$/) skip = 0; next }
        trace && line ~ /^( +at |for call at$)/ { next }
        { trace = 0 }
        line ~ /^=+$/ { banner = !banner; next }
        banner { trace = 1 }
        line ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9:]+ - [a-z]+: / {
            trace = 1
            if (line ~ /[[{]$/) skip = 1
            msg = substr(line, index(line, " - ") + 3)
            if (line ~ /browserstack\.com\/builds\// ||
                (msg ~ /^(warn|error): / && !(msg in seen))) {
                seen[msg] = 1
                print
                fflush()
            }
            next
        }
        { print; fflush() }
    '
    echo "[e2e] BrowserStack SDK log: tests/e2e/log/usage.log (E2E_VERBOSE=1 shows it all here)"
}

# Everything a BrowserStack run needs before it starts: its folders, the
# hale-test/browserstack image, and an account BrowserStack accepts, with an
# Automate plan (support/browserstack-account.js, in the browserstack
# container, which has the credentials). Needs no stack, so it runs before one
# is started. Prints the account line when it works; otherwise returns 1 with
# the reason in bs_problem, for the caller to show.
bs_problem=""
bs_ready() {
    local out status=0
    output_dirs
    mkdir -p "$E2E_DIR/log" "$E2E_DIR/.stack/browserstack"
    # The SDK's helper writes the access key, unredacted, into its debug log
    # (log/sdk-cli-debug.log), so only the user can read the folder.
    chmod 700 "$E2E_DIR/log"
    if ! { npm_image_current browserstack ||
        timed "build browserstack image" "$E2E_DIR/stack/build.sh" browserstack; }; then
        bs_problem="[e2e] The hale-test/browserstack image did not build."
        return 1
    fi
    out=$(compose run --rm -T browserstack node /hale/tests/e2e/support/browserstack-account.js 2>&1) ||
        status=$?
    # Only the check's own lines: compose's container progress is noise here,
    # unless compose failed before the check ran.
    if [ "$status" = 0 ]; then
        grep '^\[e2e\]' <<<"$out" || true
        return 0
    fi
    bs_problem=$(grep '^\[e2e\]' <<<"$out") ||
        bs_problem="[e2e] The BrowserStack account check did not run:"$'\n'"$out"
    return 1
}

# Lines in orange on a terminal, unless NO_COLOR is set, so a skipped
# BrowserStack run is noticed.
warn() {
    local orange="" reset=""
    if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
        orange=$'\033[38;5;208m'
        reset=$'\033[0m'
    fi
    {
        printf '%s' "$orange"
        printf '%s\n' "$@"
        printf '%s' "$reset"
    } >&2
}

# At the start of a run with the BrowserStack tests (make test-e2e): decides
# whether they will run, and says so before anything is built, rather than
# after the local tests.
bs_run=0
plan_browserstack() {
    if ! has_browserstack_credentials; then
        echo "[e2e] No credentials available, skipping BrowserStack tests"
        return 0
    fi
    if bs_ready; then
        bs_run=1
    else
        warn "$bs_problem" "[e2e] The BrowserStack tests will be skipped. The local tests still run."
    fi
}

# True when BROWSERSTACK_USERNAME and BROWSERSTACK_ACCESS_KEY are set in the
# environment or in the repo root .env, which compose reads.
has_browserstack_credentials() {
    local name
    for name in BROWSERSTACK_USERNAME BROWSERSTACK_ACCESS_KEY; do
        [ -n "${!name:-}" ] || grep -q "^$name=." .env 2>/dev/null || return 1
    done
}

# The BrowserStack tests listed as skipped, with the reason, so the report
# shows them (playwright.browserstack-skipped.config.js). Offline, in the
# playwright container; nothing is opened in a browser.
bs_listed_skipped=0
bs_skipped() {
    compose run --rm -T -e E2E_OUTPUT_DIR=./output/browserstack -e "E2E_SKIP_REASON=$1" \
        playwright test --config playwright.browserstack-skipped.config.js >/dev/null 2>&1 || {
        echo "[e2e] Could not list the skipped BrowserStack tests in the report." >&2
        return 1
    }
}

# One HTML report, in output/playwright-report (the one make test-e2e-report
# serves), from the blob reports in the folders given, relative to tests/e2e.
merge_reports() {
    compose run --rm -T \
        -e PLAYWRIGHT_HTML_OUTPUT_DIR=output/playwright-report -e PLAYWRIGHT_HTML_OPEN=never \
        playwright sh -c '
            mkdir /tmp/blobs
            for dir in "$@"; do cp "$dir"/*.zip /tmp/blobs/ 2>/dev/null || true; done
            exec /hale/node_modules/.bin/playwright merge-reports --reporter html /tmp/blobs
        ' sh "$@" >/dev/null 2>&1 ||
        echo "[e2e] Could not merge the reports; the BrowserStack one is in tests/e2e/output/browserstack/playwright-report/." >&2
}

# The arguments without --project, for the BrowserStack run after the local
# one: its projects are the platforms in browserstack.yml (desktop, mobile),
# so a local project name would match nothing there. Prints the rest, one per
# line, NUL-free arguments assumed.
bs_args_from() {
    local skip=0 arg
    for arg in "$@"; do
        if [ "$skip" = 1 ]; then
            skip=0
            continue
        fi
        case "$arg" in
            --project=*) ;;
            --project) skip=1 ;;
            *) printf '%s\n' "$arg" ;;
        esac
    done
}

# The local tests, then the same tests on BrowserStack when plan_browserstack
# found credentials and a working account, or listed as skipped when it did
# not; then one report of both. Fails when either run fails; a skipped
# BrowserStack run is not a failure, but is mentioned again here.
pw_and_bs() {
    local status=0 reason arg
    local bs_args=()
    rm -rf "$E2E_DIR/output/blob" "$E2E_DIR/output/browserstack/blob"
    pw test "$@" || status=$?
    if [ "$bs_run" = 1 ]; then
        while IFS= read -r arg; do bs_args+=("$arg"); done < <(bs_args_from "$@")
        if [ "${#bs_args[@]}" -ne "$#" ]; then
            echo "[e2e] BrowserStack run without --project: its projects are desktop and mobile."
        fi
        # ${a[@]+...}: bash 3.2, the macOS one, treats an empty array as unset.
        bs ${bs_args[@]+"${bs_args[@]}"} || status=$?
    elif [ -n "$bs_problem" ]; then
        warn "[e2e] Skipped the BrowserStack tests: the account check at the start failed. The report lists them as skipped."
        reason=${bs_problem%%$'\n'*}
        bs_skipped "${reason#"[e2e] "}" && bs_listed_skipped=1
    else
        return "$status"
    fi
    merge_reports output/blob output/browserstack/blob
    return "$status"
}

# make test-e2e-browserstack: the BrowserStack tests, in the report page.
# The BrowserStack projects do not depend on the login setup as the local ones
# do, so it runs first: the sessions in .auth/ belong to whichever stack saved
# them, and this one is new.
bs_only() {
    local status=0
    rm -rf "$E2E_DIR/output/browserstack/blob"
    pw test --project=setup || return 1
    bs "$@" || status=$?
    merge_reports output/browserstack/blob
    return "$status"
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

# An E2E_DEV=1 build labels hale-test/wordpress with the dev/ clones it holds,
# so a run on it says it did not test the composer.lock versions. The build
# listed the clones.
print_dev_packages() {
    [ -n "$(label hale-test/wordpress hale-test.dev-packages)" ] || return 0
    echo "[e2e] Ran dev/ clones, not the composer.lock versions."
}

# Printed last, after teardown, so the link is the end of the output.
print_report_links() {
    [ -f "$E2E_DIR/output/playwright-report/index.html" ] || return 0
    echo ""
    if [ "$1" -ne 0 ]; then
        echo "[e2e] Tests failed."
    fi
    echo "[e2e] Report: make test-e2e-report, then http://localhost:$E2E_UI_PORT/"
    # The report leaves skipped tests out of its default list.
    if [ "$bs_listed_skipped" = 1 ]; then
        echo "[e2e] Skipped BrowserStack tests: http://localhost:$E2E_UI_PORT/#?q=s:skipped"
    fi
}

leave_running() {
    echo "[e2e] Leaving the $HALE_TEST_PROJECT stack running at https://localhost:$HALE_TEST_PORT/"
    echo "[e2e] Remove it with: make test-e2e-down"
}

# Usage: run_tests <runner> [args], where the runner is pw test or bs.
run_tests() {
    if [ "${REUSE_STACK:-}" = "1" ] && is_running; then
        echo "[e2e] Reusing the running $HALE_TEST_PROJECT stack"
        npm_image_current playwright || timed "build playwright image" "$E2E_DIR/stack/build.sh" playwright
    else
        up
    fi

    local status=0
    "$@" || status=$?

    if [ "${KEEP_STACK:-}" = "1" ] || [ "${REUSE_STACK:-}" = "1" ]; then
        leave_running
    else
        down
    fi
    print_dev_packages
    print_report_links "$status"
    return "$status"
}

command=${1:-}
shift || true

case "$command" in
    test) run_tests pw test "$@" ;;
    test-all)
        plan_browserstack
        run_tests pw_and_bs "$@"
        ;;
    browserstack)
        # Checked before a stack is started for nothing.
        if ! has_browserstack_credentials; then
            echo "[e2e] Set BROWSERSTACK_USERNAME and BROWSERSTACK_ACCESS_KEY in the environment or in .env at the repo root." >&2
            exit 1
        fi
        if ! bs_ready; then
            warn "$bs_problem" "[e2e] The BrowserStack tests cannot run."
            exit 1
        fi
        run_tests bs_only "$@"
        ;;
    up) up && pw test --project=setup && print_dev_packages && leave_running ;;
    down) down ;;
    ui)
        is_running || up
        pw_ui test --ui --ui-host=0.0.0.0 --ui-port=9323
        ;;
    report) pw_ui show-report output/playwright-report --host=0.0.0.0 --port=9323 ;;
    urls)
        npm_image_current playwright || "$E2E_DIR/stack/build.sh" playwright
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
        sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
