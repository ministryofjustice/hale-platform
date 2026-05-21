#!/bin/bash
set -euo pipefail

# Run Lua firewall unit + integration tests locally.
# Starts Redis if not already running, and stops it again afterwards.
# In CI, use the workflow directly (tests.yaml) — this script is for local dev only.

cd "$(dirname "$0")/.."

REDIS_WAS_RUNNING=no
if docker compose ps --status running redis 2>/dev/null | grep -q redis; then
    REDIS_WAS_RUNNING=yes
fi

if [ "$REDIS_WAS_RUNNING" = "no" ]; then
    echo "Starting Redis..."
    docker compose up -d --wait redis
    trap 'echo "Stopping Redis..."; docker compose stop redis' EXIT
fi

echo "Building test image..."
IMAGE=$(docker build -f nginx.local.dockerfile --target test --quiet .)

echo "Running Lua firewall tests..."
docker run --rm \
    --network hale-platform_default \
    -e REDIS_DB=1 \
    -e REDIS_HOST=redis \
    "$IMAGE"
