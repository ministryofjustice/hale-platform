####################################################
# WordPress image for the end-to-end test stack
#
# wordpress.local.dockerfile's image plus compiled theme assets. The deployed
# image gets its CSS and JS from the `npm run production` step in
# .github/workflows/rw-build-image.yaml; `make build` has no such step,
# because locally the themes come from the dev/ clones. Without this layer
# the test sites would render unstyled and without their JavaScript, which is
# not what we deploy.
#
# Built by tests/e2e/stack/build.sh with BASE_IMAGE set to the image
# wordpress.local.dockerfile produces, and a `dev` build context holding
# plugins/, mu-plugins/ and themes/. With E2E_DEV=1 those hold the dev/ clones
# to run in place of the composer.lock versions, and the base image is built
# without them; otherwise they are empty.
# ##################################################

ARG BASE_IMAGE=hale-test/wordpress-base

# ---------------------------------------------------------------------------
# Theme build stage: the same loop as rw-build-image.yaml.
# ---------------------------------------------------------------------------
FROM node:22-bookworm AS themes

COPY wordpress/wp-content/themes /themes

# Dev theme clones over the composer versions. With E2E_DEV=1 the folders
# above hold dev package links in their place, which point nowhere here.
RUN find /themes -mindepth 1 -maxdepth 1 -type l -delete
COPY --from=dev /themes /themes

# The npm cache mount keeps downloaded packages between builds, so a rebuild
# after a theme change does not download every theme's dependencies again.
RUN --mount=type=cache,target=/root/.npm \
    set -e; \
    for theme in hale hale-dash hale-showcase ppo govwind justice; do \
        echo "Building theme $theme"; \
        cd "/themes/$theme"; \
        if [ -f package-lock.json ]; then \
            npm ci --no-audit --no-fund; \
        else \
            npm install --no-audit --no-fund; \
        fi; \
        npm run production --if-present; \
        rm -rf node_modules; \
    done

# ---------------------------------------------------------------------------
# Runtime: the local image with the dev plugin clones and the built themes
# over its own.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}

COPY --from=dev --chown=65532:65532 /plugins /usr/src/wordpress/wp-content/plugins
COPY --from=dev --chown=65532:65532 /mu-plugins /usr/src/wordpress/wp-content/mu-plugins
COPY --from=themes --chown=65532:65532 /themes /usr/src/wordpress/wp-content/themes
