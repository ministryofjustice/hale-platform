#!/bin/bash

if ps aux | grep -q '[p]hp-fpm'; then
    # Readiness check pass
    exit 0
else
    # Readiness check fail
    exit 1
fi
