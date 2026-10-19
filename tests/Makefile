####################################################
### Test commands
###
### Included by the root Makefile, so run these from the repo root:
###   make test-e2e
### `make help` lists them with the rest. They also work from here with
### `make -C tests <target>`: every recipe runs from the repo root.
####################################################

# The repo root, wherever make was started from.
TESTS_REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))..)

.PHONY: test-e2e test-e2e-build test-e2e-up test-e2e-run test-e2e-ui test-e2e-report test-e2e-urls test-e2e-lock test-e2e-down

# Playwright and its npm packages run only in the hale-test/playwright
# container; the host needs Docker, bash, git and openssl, not Node. Every
# target goes through tests/e2e/stack/stack.sh, which builds the images when
# they are stale. See tests/e2e/README.md.
TESTS_STACK := $(TESTS_REPO_ROOT)/tests/e2e/stack/stack.sh

# End-to-end tests: start the disposable test multisite (docker-compose.test.yml),
# seed it, run Playwright against it and remove it, pass or fail.
# ARGS passes Playwright arguments; KEEP_STACK=1 leaves the stack running.
#   make test-e2e
#   make test-e2e ARGS=--project=justice
test-e2e: ## Run the Playwright end-to-end tests on a throwaway test stack
	@$(TESTS_STACK) test $(ARGS)

# Rebuild every hale-test/* image, including the Playwright one, from the
# current ./wordpress, ./vendor and tests/e2e/package-lock.json. The other
# targets build them automatically when they are missing or older than
# composer.lock or the package lock.
#   make test-e2e-build
test-e2e-build: ## Rebuild the end-to-end test stack images
	@$(TESTS_REPO_ROOT)/tests/e2e/stack/build.sh

# Start and seed the test stack and leave it running, for the edit-and-rerun
# loop below. Runs only the login setup, no specs. A stack already running is
# replaced by a freshly seeded one.
#   make test-e2e-up
test-e2e-up: ## Start and seed the end-to-end test stack and leave it running
	@$(TESTS_STACK) up

# Run specs against the stack test-e2e-up started, skipping the ~45s setup.
# FILE picks a spec file or folder; without it every spec runs. Picks up spec
# changes straight away. Seed, theme or plugin changes need a new stack:
# make test-e2e-up (seed) or E2E_BUILD=1 make test-e2e-up (theme or plugin).
# With no stack running it starts one, and leaves it running.
#   make test-e2e-run FILE=specs/hale/editor-block.spec.js
#   make test-e2e-run FILE=specs/all-sites/
test-e2e-run: ## Run specs on the running test stack (FILE=specs/...)
	@REUSE_STACK=1 $(TESTS_STACK) test $(FILE)

# Playwright UI mode on the running test stack, at http://localhost:9323
# (E2E_UI_PORT). Turn on watch (the eye icon next to a test) to rerun it on
# every save of its spec file. With no stack running it starts one. The stack
# keeps running when the UI stops (Ctrl-C).
#   make test-e2e-ui
test-e2e-ui: ## Open Playwright UI mode on the running test stack
	@$(TESTS_STACK) ui

# Serve the last HTML report, with its screenshots, videos and traces, at
# http://localhost:9323 (E2E_UI_PORT). Ctrl-C stops it.
#   make test-e2e-report
test-e2e-report: ## Serve the last end-to-end HTML report
	@$(TESTS_STACK) report

# Print every address the test stack serves and what it is for: each site,
# the seeded pages, the login and admin screens and the HTML report. Follows
# sites.json and HALE_TEST_PORT, and says whether the stack is running.
#   make test-e2e-urls
#   HALE_TEST_PORT=9443 make test-e2e-urls
test-e2e-urls: ## List the test stack's localhost addresses and what they are for
	@$(TESTS_STACK) urls

# Update tests/e2e/package-lock.json after editing tests/e2e/package.json.
# npm runs in the Playwright image, not on the host, and runs no package code.
#   make test-e2e-lock
test-e2e-lock: ## Update the end-to-end package-lock.json in a container
	@$(TESTS_STACK) lock

# Remove a test stack left running by test-e2e-up, KEEP_STACK=1 or a crashed run.
#   make test-e2e-down
test-e2e-down: ## Remove the end-to-end test stack and its volumes
	@$(TESTS_STACK) down
