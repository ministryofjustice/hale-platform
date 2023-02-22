#!/bin/sh
# Basic tool to import WordPress database (.sql) file

RESTORE='\033[0m'
YELLOW='\033[00;33m'
GREEN='\033[00;32m'

function msg {
  echo "$1"$RESTORE
}

msg $GREEN"\nImport Bot [o_o]\n"

echo "You will need to enter 3 secrets, db user, db password and db name.
You will also need to be logged into the cluster and have port-fowarding on. 
You can get secrets using cloud-platform decode-secret tool\n"

while true; do
    read -p "Do you wish to continue?[y/n] " yn
    case $yn in
        [Yy]* )

            msg "Enter DB user:"

            read -s HALE_PLATFORM_DB_USER

            msg "Enter DB password:"

            read -s HALE_PLATFORM_DB_PASSWORD

            msg "Enter DB name:"

            read -s HALE_PALTFORM_DB_NAME

            mysqlimport -h 127.0.0.1 \
                -u ${HALE_PLATFORM_DB_USER} \
                -p${HALE_PLATFORM_DB_PASSWORD} \
                --port=5432 \
                --local \
                --compress \
                --verbose \
                ${HALE_PALTFORM_DB_NAME} hale-platform-db-export.sql

            msg $GREEN"Import complete"

            break;;

        [Nn]* )
            exit;;
        * ) msg $YELLOW"Please answer yes or no.";;
    esac
done
set -e
