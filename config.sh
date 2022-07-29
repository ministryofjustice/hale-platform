#!/bin/bash

wp config set MULTISITE true --raw
wp config set WP_ALLOW_MULTISITE true --raw

wp core multisite-convert
wp core update-db --network

exec "$@"
