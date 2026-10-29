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

.PHONY: test-e2e-cmds test-e2e test-e2e-release test-e2e-build test-e2e-up test-e2e-run test-e2e-browserstack test-e2e-ui test-e2e-report test-e2e-urls test-e2e-lock test-e2e-down

# Playwright and its npm packages run only in the hale-test/playwright
# container; the host needs Docker, bash, git and openssl, not Node. Every
# target goes through tests/e2e/stack/stack.sh, which builds the images when
# they are stale. See tests/e2e/README.md.
TESTS_STACK := $(TESTS_REPO_ROOT)/tests/e2e/stack/stack.sh

# The targets that build or start a stack run the dev/ clones that make
# symlink linked, in place of their composer.lock versions (E2E_DEV=1); with
# none linked, every package is its composer.lock version. E2E_DEV=0 runs the
# composer.lock versions instead, which test-e2e-release always does. See
# "dev/ clones and composer.lock" in tests/e2e/README.md.
TESTS_DEV := E2E_DEV=$${E2E_DEV:-1}

# List the test-e2e commands with their ## descriptions, read from this file,
# and the options they take.
#   make test-e2e-cmds
test-e2e-cmds: ## List the end-to-end test commands and what they do
	@echo "End-to-end test commands (tests/e2e/README.md has the details):"
	@echo ""
	@grep -E '^test-e2e[a-zA-Z0-9_-]*:.*## ' $(TESTS_REPO_ROOT)/tests/Makefile | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  make %-22s %s\n", $$1, $$2}'
	@echo ""
	@echo "Options, before or after the command:"
	@echo "  ARGS=...        Playwright arguments, e.g. ARGS=--project=justice"
	@echo "  FILE=...        the spec file or folder for test-e2e-run"
	@echo "  KEEP_STACK=1    leave the stack running after the tests"
	@echo "  E2E_DEV=0       use the composer.lock versions, not your dev/ clones"
	@echo "  E2E_BUILD=1     rebuild the images first"
	@echo "  E2E_VERBOSE=1   show all of the BrowserStack SDK's logging"

# End-to-end tests: start the disposable test multisite (docker-compose.test.yml),
# seed it, run Playwright against it and remove it, pass or fail. The stack
# runs your linked dev/ clones (TESTS_DEV above), so it tests what your local
# site serves. With BrowserStack credentials (see test-e2e-browserstack) the
# same tests then run on BrowserStack against the same stack; without them
# that step is skipped. ARGS passes Playwright arguments; KEEP_STACK=1 leaves
# the stack running.
#   make test-e2e
#   make test-e2e ARGS=--project=justice
test-e2e: ## Run the end-to-end tests against your linked dev/ clones
	@$(TESTS_DEV) $(TESTS_STACK) test-all $(ARGS)

# The same run with every package at its composer.lock version, as it would
# be deployed. What CI runs (.github/workflows/e2e.yaml).
#   make test-e2e-release
#   make test-e2e-release ARGS=--project=justice
test-e2e-release: ## Run the end-to-end tests against the composer.lock versions, as CI does
	@E2E_DEV=0 $(TESTS_STACK) test-all $(ARGS)

# Rebuild every hale-test/* image, including the Playwright one, from the
# current ./wordpress, ./vendor, linked dev/ clones and
# tests/e2e/package-lock.json. The other targets build them automatically
# when they are missing or out of date.
#   make test-e2e-build
test-e2e-build: ## Rebuild the end-to-end test stack images
	@$(TESTS_DEV) $(TESTS_REPO_ROOT)/tests/e2e/stack/build.sh

# Start and seed the test stack and leave it running, for the edit-and-rerun
# loop below. Runs only the login setup, no specs. A stack already running is
# replaced by a freshly seeded one.
#   make test-e2e-up
test-e2e-up: ## Start and seed the end-to-end test stack and leave it running
	@$(TESTS_DEV) $(TESTS_STACK) up

# Run specs against the stack test-e2e-up started, skipping the ~45s setup.
# FILE picks a spec file or folder; without it every spec runs. Picks up spec
# changes straight away. Seed changes and changes in a linked dev/ clone need
# a new stack: make test-e2e-up. With no stack running it starts one, and
# leaves it running.
#   make test-e2e-run FILE=specs/hale/editor-block.spec.js
#   make test-e2e-run FILE=specs/all-sites/
test-e2e-run: ## Run specs on the running test stack (FILE=specs/...)
	@$(TESTS_DEV) REUSE_STACK=1 $(TESTS_STACK) test $(FILE)

# The same tests on BrowserStack devices: a fresh stack, seeded, then
# browserstack-node-sdk in the hale-test/browserstack container runs them
# through a BrowserStack Local tunnel. Platforms are in
# tests/e2e/browserstack.yml. Needs BROWSERSTACK_USERNAME and
# BROWSERSTACK_ACCESS_KEY in the environment or in .env at the repo root.
# ARGS, KEEP_STACK and REUSE_STACK work as for test-e2e. The projects here
# are the platforms, desktop and mobile; on them every spec runs against its
# own site, and all-sites/ against the main site only.
#   make test-e2e-browserstack
#   make test-e2e-browserstack ARGS=--project=mobile
#   make test-e2e-browserstack ARGS=specs/justice/
test-e2e-browserstack: ## Run the end-to-end tests on BrowserStack devices
	@$(TESTS_DEV) $(TESTS_STACK) browserstack $(ARGS)

# Playwright UI mode on the running test stack, at http://localhost:9323
# (E2E_UI_PORT). Turn on watch (the eye icon next to a test) to rerun it on
# every save of its spec file. With no stack running it starts one. The stack
# keeps running when the UI stops (Ctrl-C).
#   make test-e2e-ui
test-e2e-ui: ## Open Playwright UI mode on the running test stack
	@$(TESTS_DEV) $(TESTS_STACK) ui

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
