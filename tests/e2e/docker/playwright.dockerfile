# Images the Playwright tests run in (docker-compose.test.yml). Hold Node,
# Chromium and the npm packages from tests/e2e/package-lock.json; the specs
# themselves are mounted read-only at /hale/tests/e2e at run time, so the
# images only change when the lockfile does. node_modules sits at
# /hale/node_modules, above that mount, where Node finds it from the specs and
# the mount cannot hide it.
#
# Two targets, both built by tests/e2e/stack/build.sh with tests/e2e/ as the
# build context:
#   playwright    hale-test/playwright, service playwright: package.json's
#                 dependencies only
#   browserstack  hale-test/browserstack, service browserstack: adds the
#                 devDependencies (browserstack-node-sdk), which the offline
#                 playwright image never holds
#
# The browsers ship in this base image, so its tag must match the
# @playwright/test version in package.json. Bump both together.
FROM mcr.microsoft.com/playwright:v1.62.1-noble@sha256:dcc5531e97840b9b5e794f2814476b21571c5124a3fca2267d73041f56e7580e AS playwright

WORKDIR /hale

# npm ci installs exactly what the lockfile names and checks every package
# against its integrity hash. --ignore-scripts: no package code runs at
# install time; Playwright needs no install scripts here because the
# browsers are already in the base image.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
    && npm cache clean --force

FROM playwright AS browserstack

# The full lockfile, so browserstack-node-sdk runs against the same
# @playwright/test as the playwright image.
RUN npm ci --ignore-scripts --no-audit --no-fund \
    && npm cache clean --force

# The installed playwright and browserstack-node-sdk binaries on PATH, so a
# command or npx call from the SDK finds them rather than downloading another
# copy.
ENV PATH=/hale/node_modules/.bin:$PATH
