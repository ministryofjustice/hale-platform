#!/bin/bash

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
            composer install

            echo -e '\n######################'
            echo -e '# Run NPM'
            echo -e '######################\n'
            npm install --prefix ./wordpress/wp-content/themes/wp-hale
            npm run build --prefix ./wordpress/wp-content/themes/wp-hale
            
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
