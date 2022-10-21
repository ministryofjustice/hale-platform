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

            # Install build dependancies
            echo -e '\n######################'
            echo -e '# Run Composer'
            echo -e '######################\n'
            echo -e "Make sure you're connected to MoJ Digital VPN.\n"
            composer install --no-cache
          
            # Test NPM is installed locally            
            if npm > /dev/null 2>&1; then
            echo -e "Oops, NPM does not appear to be installed locally.\nMake sure NPM is installed and try again.\n"
            exit 1
            fi

            echo -e '\n######################'
            echo -e '# Run NPM'
            echo -e '######################\n'
            npm install --prefix ./wordpress/wp-content/themes/wp-hale
            npm run build --prefix ./wordpress/wp-content/themes/wp-hale
           
            # Test Docker is running locally            
            if ! docker info > /dev/null 2>&1; then
            echo -e "Oops, where is Docker? Start Docker and try again.\n"
            exit 1
            fi

            # Build Docker images
            echo -e '\n######################'
            echo -e '# Run Docker Build'
            echo -e '######################\n'
            docker-compose build --no-cache
            break;;
        [Nn]* ) 
            exit;;
        * ) echo "Please answer yes or no.";;
    esac
done
