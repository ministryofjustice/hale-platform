#!/usr/bin/env bash
set -euo pipefail

# Only run in local dev
if [[ "${WP_ENVIRONMENT_TYPE:-}" != "local" ]]; then
  echo "[dev-links] Not local environment, skipping"
  exit 0
fi

DEV_ROOT="/mnt/dev"
WP_ROOT="/var/www/html/wp-content"

echo "[dev-links] Linking local development packages..."
echo "[dev-links] DEV_ROOT: $DEV_ROOT"
echo "[dev-links] WP_ROOT: $WP_ROOT"

# Counter for linked packages
LINKED_COUNT=0
SKIPPED_COUNT=0

link_if_exists () {
  local src="$1"
  local dest="$2"

  if [[ -d "$src" ]]; then
    echo "  ↳ $dest -> $src"
    
    # Create parent directory if it doesn't exist
    mkdir -p "$(dirname "$dest")"
    
    # Remove existing symlink or directory if it exists
    if [[ -L "$dest" ]]; then
      rm -f "$dest"
    elif [[ -d "$dest" ]]; then
      echo "Warning: $dest exists as a directory, removing..."
      rm -rf "$dest"
    fi
    
    # Create the symlink
    ln -sfn "$src" "$dest"
    ((++LINKED_COUNT))
  else
    echo "Skipping (not found): $src"
    ((++SKIPPED_COUNT))
  fi
}

####################
# MU PLUGINS
####################
echo ""
echo "[dev-links] === MU Plugins ==="
link_if_exists "$DEV_ROOT/mu-plugins/hale-components" \
  "$WP_ROOT/mu-plugins/hale-components"

link_if_exists "$DEV_ROOT/mu-plugins/wp-gov-uk-notify" \
  "$WP_ROOT/mu-plugins/wp-gov-uk-notify"

link_if_exists "$DEV_ROOT/mu-plugins/wp-s3-uploads" \
  "$WP_ROOT/mu-plugins/wp-s3-uploads"

####################
# PLUGINS
####################
echo ""
echo "[dev-links] === Plugins ==="
link_if_exists "$DEV_ROOT/plugins/cookie-compliance" \
  "$WP_ROOT/plugins/cookie-compliance"

link_if_exists "$DEV_ROOT/plugins/govwind" \
  "$WP_ROOT/plugins/govwind"

link_if_exists "$DEV_ROOT/plugins/hale-dash" \
  "$WP_ROOT/plugins/hale-dash"

link_if_exists "$DEV_ROOT/plugins/hale-showcase" \
  "$WP_ROOT/plugins/hale-showcase"

link_if_exists "$DEV_ROOT/plugins/ppo" \
  "$WP_ROOT/plugins/ppo"

link_if_exists "$DEV_ROOT/plugins/website-builder-blocks" \
  "$WP_ROOT/plugins/website-builder-blocks"

link_if_exists "$DEV_ROOT/plugins/wp-moj-blocks" \
  "$WP_ROOT/plugins/wp-moj-blocks"

####################
# THEMES
####################
echo ""
echo "[dev-links] === Themes ==="
link_if_exists "$DEV_ROOT/themes/hale" \
  "$WP_ROOT/themes/hale"

####################
# SUMMARY
####################
echo ""
echo "[dev-links] ================================"
echo "[dev-links] Summary:"
echo "[dev-links]   ✓ Linked: $LINKED_COUNT packages"
echo "[dev-links]   ⊘ Skipped: $SKIPPED_COUNT packages"
echo "[dev-links] ================================"
echo "[dev-links] Done"

# Exit successfully
exit 0
