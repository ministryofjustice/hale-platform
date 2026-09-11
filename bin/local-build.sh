#!/bin/bash

##################
# Image Builder
##################

# Installs all the dependancies the multisite image needs and
# then builds the image.

# Required programs that need to be present:
# - Composer - Download and install WP plugins & themes
# - NPM - Compile frontend assets
# - Docker - Build the Docker image

# If /wordpress directory exists and rebuild = yes, remove directory
# so that Docker has a fresh WP directory to install into, resolving
# issues with Docker not overwriting older files.

while true; do
    read -p "Rebuilding will delete all local WP files? Continue? [y/n] " yn
    case $yn in
        [Yy]* )
            DIR=wordpress
            # Check if dir exist, if so delete
            if [[ -d "$DIR" ]]; then
                rm -rf $DIR
            fi

            # Remove the shared WP core volume so the entrypoint of the new
            # image repopulates core files on next start. Containers must be
            # stopped first or the volume is in use. DB volume is untouched.
            docker compose --profile firewall down --remove-orphans 2>/dev/null
            docker volume rm -f hale-platform_wpcore 2>/dev/null || true

            # Determine the path for the .env file and create file. Do not overwrite if .env exists.
            ENV_FILE_PATH="$(pwd)/.env"

            # Check if .env file already exists
            if [ ! -f "$ENV_FILE_PATH" ]; then
                # Create .env only if it doesn't exist
                echo "# Add in custom variables you want to run in the Docker container locally" > "$ENV_FILE_PATH"
                echo "Generated .env file at $ENV_FILE_PATH"
            else
                # .env file already exists
                echo ".env file already exists at $ENV_FILE_PATH. Skipping creation."
            fi

            # Install build dependancies
            # Cache flag not added here because Composer caches already automatically.
            # Script deletes lock so Composer is forced to re-reslove dependancies anyway.
            echo -e '\n######################'
            echo -e '# Run Composer'
            echo -e '######################\n'
            rm composer.lock
            composer install -vvv

            # Translations for the locales the platform offers.
            #
            # wordpress.dockerfile bakes these into the deployed image, but that
            # cannot work locally: ./wordpress/wp-content is bind-mounted over
            # /var/www/html/wp-content, so anything the image ships under
            # wp-content is hidden. Without this the Site Language dropdown
            # offers only English (United States), and DISALLOW_FILE_MODS stops
            # WordPress fetching the packs itself.
            #
            # Version comes from the image this build produces; the locale list
            # comes from wordpress.dockerfile, so local offers exactly what
            # deploys. tr -d strips the CR - both dockerfiles are stored with
            # CRLF endings. A failure here is a warning, not a build failure:
            # local translations are not worth stopping a build for, unlike the
            # deployed image where the strings must match core.
            WP_VERSION=$(sed -nE 's/^ARG WORDPRESS_VERSION=([0-9.]+).*/\1/p' \
                wordpress.local.dockerfile | head -1 | tr -d '\r')
            WP_LOCALES=$(sed -nE 's/^ARG WP_LOCALES="?([^"]*)"?.*/\1/p' \
                wordpress.dockerfile | head -1 | tr -d '\r')
            WP_LOCALES=${WP_LOCALES:-"en_GB cy"}
            LANG_DIR=wordpress/wp-content/languages
            echo -e "\nFetching translations for WordPress $WP_VERSION: $WP_LOCALES"
            mkdir -p "$LANG_DIR"
            for locale in $WP_LOCALES; do
                if curl -fsSL -o /tmp/hale-lang.zip \
                    "https://downloads.wordpress.org/translation/core/$WP_VERSION/$locale.zip"; then
                    unzip -o -q /tmp/hale-lang.zip -d "$LANG_DIR"
                    echo "  $locale installed into $LANG_DIR"
                else
                    echo "  WARNING: could not fetch $locale for $WP_VERSION -"
                    echo "  WARNING: it will be missing from the Site Language dropdown."
                fi
            done
            rm -f /tmp/hale-lang.zip "$LANG_DIR"/*.po

            # Test NPM is installed locally
            if ! command -v npm > /dev/null 2>&1; then
              echo "Oops, NPM does not appear to be installed locally."
              exit 1
            fi

			# Test Docker is running locally
            if ! docker info > /dev/null 2>&1; then
            echo -e "Oops, where is Docker? Start Docker and try again.\n"
            exit 1
            fi

            # wordpress.local.dockerfile COPYs wordpress/wp-content into the
            # image, and COPY copies a symlink as a symlink. Building while the
            # dev links from opt/scripts/link-dev-packages.sh are in place
            # therefore bakes dangling links to /mnt/dev into the image, which
            # the bind mount hides locally and nothing reports. The rm -rf of
            # wordpress/ above clears them, so this cannot fire on a normal run
            # - it is here for anyone who reorders or reuses this script. A bare
            # `docker compose build` skips this check entirely: use make build.
            if find wordpress/wp-content -maxdepth 2 -type l 2>/dev/null | grep -q .; then
                echo -e "\nDev symlinks are still present under wordpress/wp-content."
                echo -e "Building now would copy them into the image as dangling links."
                echo -e "Run 'make build', which clears wordpress/ first.\n"
                exit 1
            fi

            # Build Docker images
            echo -e '\n######################'
            echo -e '# Run Docker Build'
            echo -e '######################\n'
            docker compose build

            break;;
        [Nn]* )
            exit;;
        * ) echo "Please answer yes or no.";;
    esac
done

