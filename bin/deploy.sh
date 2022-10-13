#!/bin/bash


# check for the .env file and generate a configmap out of it 
if [[ -a ".env" ]]; then
    kubectl create configmap wpconfig --from-env-file=.env
else
    echo ".env file is missing, please add, so a configmap can be generated."
    exit
fi

# https://helm.sh/docs/helm/helm_upgrade
#
# This script does the following:
# - installs the chart if it doesn't exist
# - applies the correct environment values
# - creates the namespace if it doesn't exist
# - will timeout if there is any issue after 60 seconds
# - uses atomic flag which rolls back changes in the case of a failed upgrade
#
helm upgrade wordpress helm_deploy/wordpress \
    --install \
    --values helm_deploy/wordpress/values.yaml \
    --namespace hale-platform-local \
    --create-namespace \
    --timeout 1m \
    --atomic

set -e
