#!/bin/bash


echo "DB downloader. 
You will need to enter 3 secrets, db user, db password and db name.
You will also need to be logged into the cluster and have port-fowarding on."

echo "You can get these using cloud-platform decode-secret tool"

while true; do
    read -p "Do you wish to continue?[y/n] " yn
    case $yn in
        [Yy]* )

            echo "Enter DB user:"

            read -s HALE_PLATFORM_DEV_DB_USER

            echo "Enter DB password:"

            read -s HALE_PLATFORM_DEV_DB_PASSWORD

            echo "Enter DB name:"

            read -s HALE_PALTFORM_DEV_DB_NAME

            mysqldump -h 127.0.0.1 \
                -u ${HALE_PLATFORM_DEV_DB_USER} \
                -p${HALE_PLATFORM_DEV_DB_PASSWORD} \
                --port=5432 \
                --single-transaction \
                --routines \
                --triggers \
                --column-statistics=0 \
                --verbose \
                --databases ${HALE_PALTFORM_DEV_DB_NAME} > hale-platform-dev-db-export.sql

            echo "Download complete"

            break;;

        [Nn]* )
            exit;;
        * ) echo "Please answer yes or no.";;
    esac
done
set -e
