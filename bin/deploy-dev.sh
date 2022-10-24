#!/bin/bash

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
    --values helm_deploy/wordpress/values-dev.yaml \
    --namespace hale-platform-dev \
    --timeout 5m \
    --atomic

set -e
