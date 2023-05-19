#!/bin/bash
if ps aux | grep -q '[p]hp-fpm'; then
    echo "1"
else
    echo "0"
fi
