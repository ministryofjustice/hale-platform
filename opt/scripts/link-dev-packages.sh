#!/usr/bin/env bash
set -euo pipefail

# Replace the composer-installed copy of each locally cloned MoJ package with a
# symlink into the dev mount, so the running site serves the working tree
# instead of the version composer.json pins.
#
# Runs through `make symlink`, and automatically from the `make run*` targets.
# Only packages actually cloned into dev/ are linked - anything not cloned keeps
# its composer copy, which is what makes a partial checkout work.
#
# The links are created inside the container and point at container paths
# (/mnt/dev/...), so they are deliberately dangling when read from the host.
# Edit in dev/, never through wordpress/wp-content.

# Only run in local dev
if [[ "${WP_ENVIRONMENT_TYPE:-}" != "local" ]]; then
  echo "[dev-links] Not local environment, skipping"
  exit 0
fi

DEV_ROOT="/mnt/dev"
WP_ROOT="/var/www/html/wp-content"

# Package types. The directory name is the same under both roots, which is why
# one list covers the dev clones and their destinations.
TYPES=(mu-plugins plugins themes)

# The clones reach the container through the ./dev bind mount. Without it every
# package below reports "not found" and the script exits 0, which reads as
# "nothing to link" rather than "the mount is missing" - so check once, up
# front, and fail loudly.
if [[ ! -d "$DEV_ROOT" ]]; then
  echo "[dev-links] ERROR: $DEV_ROOT is not present in this container." >&2
  echo "[dev-links] docker-compose.yml bind-mounts ./dev there - check the mount." >&2
  exit 1
fi

echo "[dev-links] Linking local development packages..."
echo "[dev-links] DEV_ROOT: $DEV_ROOT"
echo "[dev-links] WP_ROOT: $WP_ROOT"

# Counters for linked and skipped packages
LINKED_COUNT=0
SKIPPED_COUNT=0

# Does this directory hold a package WordPress could load? A clone that failed
# part way, or one whose contents were removed, still passes a plain -d test:
# linking to it deletes the composer copy and leaves an empty theme or plugin,
# with nothing to fall back on until the next `make build`.
has_package_files () {
  local src="$1"
  [[ -f "$src/style.css" ]] && return 0             # theme
  compgen -G "$src/*.php" > /dev/null && return 0   # plugin or mu-plugin
  return 1
}

link_package () {
  local src="$1"
  local dest="$2"

  if ! has_package_files "$src"; then
    echo "  Skipping (no package files, clone looks incomplete): $src"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    return
  fi

  echo "  ↳ $dest -> $src"

  # Create parent directory if it doesn't exist
  mkdir -p "$(dirname "$dest")"

  # Remove existing symlink or directory if it exists
  if [[ -L "$dest" ]]; then
    rm -f "$dest"
  elif [[ -d "$dest" ]]; then
    echo "     replacing the composer-installed copy"
    rm -rf "$dest"
  fi

  # Create the symlink
  ln -sfn "$src" "$dest"
  LINKED_COUNT=$((LINKED_COUNT + 1))
}

# Read the package list off the filesystem rather than hardcoding it. The same
# twelve repositories are already listed in bin/clone-repos.sh and required in
# composer.json; a third copy here meant a new repository had to be added in
# three places, and was silently not linked when it wasn't.
for type in "${TYPES[@]}"; do
  echo ""
  echo "[dev-links] === $type ==="

  if [[ ! -d "$DEV_ROOT/$type" ]]; then
    echo "  Nothing cloned"
    continue
  fi

  found=0
  for src in "$DEV_ROOT/$type"/*/; do
    src="${src%/}"
    [[ -d "$src" ]] || continue   # no matches - the glob stayed literal

    # Only link clones, so scratch directories, editor backups and unpacked
    # archives under dev/ never end up in wp-content.
    if [[ ! -d "$src/.git" ]]; then
      echo "  Skipping (not a git clone): $src"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi

    found=1
    link_package "$src" "$WP_ROOT/$type/$(basename "$src")"
  done

  if [[ "$found" -eq 0 ]]; then
    echo "  Nothing cloned"
  fi
done

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
