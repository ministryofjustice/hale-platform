#!/bin/bash
#
# Build the images the end-to-end test stack runs (docker-compose.test.yml).
#
# The stack images come from the same Dockerfiles as hale.docker, under their
# own hale-test/* tags so building them never replaces the images hale.docker
# runs. Plugins and themes are whatever composer last installed into
# ./wordpress, so run `composer install` (or `make build`) first.
# hale-test/playwright is the image the tests themselves run in, and
# hale-test/browserstack the one make test-e2e-browserstack runs them in.
#
# Usage: tests/e2e/stack/build.sh               every image but browserstack
#        tests/e2e/stack/build.sh playwright    hale-test/playwright only
#        tests/e2e/stack/build.sh browserstack  hale-test/browserstack only
#
# E2E_DEV=1 (make test-e2e) builds hale-test/wordpress with the dev/ clones
# that make symlink linked, in place of their composer.lock versions (see
# stage_dev_packages). Without it (make test-e2e-release, CI), every package
# is the composer.lock version.

set -euo pipefail

cd "$(dirname "$0")/../../.."

# Labelled with one hash of the lockfile and the Dockerfile it was built from
# (npm_image_current in stack.sh computes the same), so stack.sh can tell when
# the image is older than either and rebuild it. The build context is
# tests/e2e/ alone: nothing else in the repo reaches the npm install.
# Usage: build_npm_image <dockerfile target>, which is also the image name.
build_npm_image() {
    echo "Building hale-test/$1"
    docker build -f tests/e2e/docker/playwright.dockerfile --target "$1" \
        --label "hale-test.npm-inputs=$(cat tests/e2e/package-lock.json tests/e2e/docker/playwright.dockerfile |
            git hash-object --stdin)" \
        -t "hale-test/$1" tests/e2e
}

# Only make test-e2e-browserstack needs hale-test/browserstack, so a full
# build (and CI) leaves it out; stack.sh builds it when it is first needed.
case "${1:-}" in
    playwright | browserstack)
        build_npm_image "$1"
        exit 0
        ;;
esac

if [ ! -d wordpress/wp-content/plugins ] || [ ! -d vendor ]; then
    echo "wordpress/ or vendor/ is missing. Run 'composer install' first." >&2
    exit 1
fi

# Puts back the dev package links that restore_composer_packages removed. Runs
# once the images are built: they hold a copy of wp-content, so the links can
# return before the tests start. The links are made inside the hale.docker
# wordpress container, so they wait for `make run` when it is not running.
relink_dev_packages() {
    if docker exec wordpress true >/dev/null 2>&1; then
        echo "Restoring the dev package links"
        make --no-print-directory symlink ||
            echo "make symlink failed; run it again to restore the dev package links." >&2
    else
        echo "hale.docker is not running; 'make run' restores the dev package links." >&2
    fi
}

# The dev package links in wordpress/wp-content, one per line. The images COPY
# wordpress/wp-content/{plugins,themes,mu-plugins}, and COPY copies a symlink
# as a symlink. Links made by opt/scripts/link-dev-packages.sh point into
# /mnt/dev, which the test stack does not mount, so they would be dangling in
# the image. Only those three folders are checked: anything else in wp-content
# (such as Query Monitor's db.php link) never goes into the image.
package_links() {
    find wordpress/wp-content/plugins wordpress/wp-content/themes \
        wordpress/wp-content/mu-plugins -maxdepth 1 -type l
}

# Without E2E_DEV, the test stack runs the composer.lock versions, so the links are swapped for
# those for the build (composer reinstalls a package whose folder is missing)
# and put back after it. hale.docker serves the composer versions meanwhile.
# Asks first when run from a terminal; E2E_RESTORE_LINKS=1 answers yes.
restore_composer_packages() {
    local links reply
    links=$(package_links)
    [ -n "$links" ] || return 0

    echo "wordpress/wp-content holds dev package links, which the test images cannot use:"
    echo "$links" | sed 's/^/  /'
    if [ "${E2E_RESTORE_LINKS:-}" != "1" ]; then
        if [ ! -t 0 ] || [ -n "${CI:-}" ]; then
            echo "To remove the links, build, then put the links back, run again with" >&2
            echo "E2E_RESTORE_LINKS=1. Or run 'composer install' yourself first." >&2
            exit 1
        fi
        echo "The tests need the versions set in composer.lock, not your dev copies."
        echo "This will remove the links, build the test images, then put the links back."
        echo "Until the build is done, your local site uses the composer.lock versions."
        read -r -p "Continue? [Y/n] " reply || exit 1
        case "$reply" in
            "" | [Yy]*) ;;
            *) exit 1 ;;
        esac
    fi

    trap relink_dev_packages EXIT
    echo "$links" | while IFS= read -r link; do rm -- "$link"; done
    composer install --no-interaction
}

# The dev/ clones to build in place of the composer.lock versions: the `dev`
# build context of tests/e2e/stack/wordpress.dockerfile, one folder per type.
# Empty unless E2E_DEV=1.
dev_stage=tests/e2e/.stack/dev-packages
rm -rf "$dev_stage"
mkdir -p "$dev_stage/plugins" "$dev_stage/mu-plugins" "$dev_stage/themes"

# Usage: copy_git_files <clone> <destination>. Copies the files git sees in
# the clone: tracked ones, as they are on disk, and untracked ones .gitignore
# does not cover. That is what the package holds once the change is committed,
# without .git, node_modules, built assets or ignored leftovers such as a
# stale package-lock.json, which would make the theme build's npm ci fail.
copy_git_files() {
    mkdir -p "$2"
    (
        cd "$1"
        # -c also lists tracked files deleted from the working tree.
        git ls-files -z -co --exclude-standard | while IFS= read -r -d '' file; do
            if [ -e "$file" ] || [ -L "$file" ]; then
                printf '%s\0' "$file"
            fi
        done | tar --null -T - -cf -
    ) | tar -C "$2" -xf -
}

# Usage: check_clone <clone> <type> <name>. Adds to dev_warnings, with the
# commands that fix it, when the clone does not include the commit
# composer.lock pins for it (so the run tests older code than
# make test-e2e-release), and when a theme clone has an untracked
# package-lock.json, which the theme build's npm ci would use.
check_clone() {
    local src=$1 type=$2 name=$3 pin version branch default fixes=""
    if [ "$type" = themes ] &&
        [ -n "$(git -C "$src" ls-files -o --exclude-standard package-lock.json)" ]; then
        fixes="$fixes
    # untracked package-lock.json, used by the theme build; remove it unless you mean to commit it
    rm $src/package-lock.json"
    fi

    read -r pin version < <(awk -v n="$name" '$1 == n { print $2, $3 }' <<<"$composer_pins") || true
    if [ -n "${pin:-}" ] && ! git -C "$src" merge-base --is-ancestor "$pin" HEAD 2>/dev/null; then
        branch=$(git -C "$src" rev-parse --abbrev-ref HEAD)
        default=$(git -C "$src" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
        if [ "$branch" = "${default#origin/}" ]; then
            fixes="$fixes
    git -C $src pull --ff-only"
        else
            fixes="$fixes
    git -C $src fetch origin
    git -C $src rebase $default"
        fi
        fixes="  $type/$name is on $branch, without ${pin:0:7}, the $version that composer.lock pins:$fixes"
    elif [ -n "$fixes" ]; then
        fixes="  $type/$name:$fixes"
    fi

    if [ -n "$fixes" ]; then
        dev_warnings="${dev_warnings:+$dev_warnings

}$fixes"
    fi
}

# Prints dev_warnings before anything is built and, from a terminal, asks
# whether to go on with the clones as they are. Without a terminal it goes on.
# Blue on a terminal, unless NO_COLOR is set.
confirm_dev_warnings() {
    local reply blue="" reset=""
    [ -n "$dev_warnings" ] || return 0
    if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
        blue=$'\033[34m'
        reset=$'\033[0m'
    fi
    {
        echo ""
        printf '%s' "$blue"
        echo "Warning: some dev/ clones need updating. They differ from the versions"
        echo "make test-e2e-release tests, so this run may test older code or fail to build."
        echo "To fix them, run these from the repo root:"
        echo ""
        echo "$dev_warnings"
        echo ""
        echo "Or run E2E_DEV=0 make test-e2e to test the composer.lock versions instead."
        printf '%s' "$reset"
        echo ""
    } >&2
    [ -t 0 ] || return 0
    read -r -p "Continue with the clones as they are? [Y/n] " reply || exit 1
    case "$reply" in
        "" | [Yy]*) ;;
        *)
            echo "Stopped. Update the clones above, then run again." >&2
            exit 1
            ;;
    esac
}

# E2E_DEV=1: build the clones that hale.docker's dev package links point to,
# so the tests run the code the local site serves. Each link reaches its clone
# as /mnt/dev/<type>/<name>, which is dev/<type>/<name> here. The clone's git
# files are copied into $dev_stage (copy_git_files), and the base image is
# built without the link: a per-Dockerfile ignore file (a copy of
# .dockerignore plus the links) leaves it out of the build context.
# Usage: stage_dev_packages <links>. Sets base_dockerfile and dev_packages,
# the summary stack.sh prints.
stage_dev_packages() {
    local link target type name src commit ignore entry
    local staged=()
    base_dockerfile=tests/e2e/.stack/wordpress-base.dockerfile
    ignore=$base_dockerfile.dockerignore
    cp wordpress.local.dockerfile "$base_dockerfile"
    cp .dockerignore "$ignore"
    dev_packages=""
    dev_warnings=""

    # One "<name> <commit> <version>" line per MoJ package in composer.lock;
    # the name is the folder composer installs it to.
    composer_pins=$(php -r '
        foreach (json_decode(file_get_contents("composer.lock"), true)["packages"] as $p) {
            $ref = $p["source"]["reference"] ?? $p["dist"]["reference"] ?? "";
            if ($ref !== "") echo basename($p["name"]), " ", $ref, " ", $p["version"], "\n";
        }')

    echo "Building these dev/ clones in place of their composer.lock versions:"
    while IFS= read -r link; do
        target=$(readlink "$link")
        case "$target" in
            /mnt/dev/*) src=dev/${target#/mnt/dev/} ;;
            *)
                echo "$link points to $target, not into /mnt/dev." >&2
                exit 1
                ;;
        esac
        if [ ! -d "$src" ]; then
            echo "$link points to $src, which does not exist." >&2
            exit 1
        fi
        name=${link##*/}
        type=${link%/*}
        type=${type##*/}

        staged+=("$src $type/$name")
        printf '/%s\n' "$link" >>"$ignore"

        commit="$(git -C "$src" rev-parse --abbrev-ref HEAD)@$(git -C "$src" rev-parse --short HEAD)"
        if [ -n "$(git -C "$src" status --porcelain)" ]; then
            commit="$commit, uncommitted changes"
        fi
        echo "  $type/$name ($commit)"
        check_clone "$src" "$type" "$name"
        dev_packages="${dev_packages:+$dev_packages; }$type/$name ($commit)"
    done <<<"$1"

    confirm_dev_warnings

    # Copied only once the run is going ahead.
    for entry in "${staged[@]}"; do
        copy_git_files "${entry% *}" "$dev_stage/${entry##* }"
    done
}

# Labelled on hale-test/wordpress, nginx and wptools, so stack.sh can tell
# when any of them is older than its build inputs and rebuild them.
inputs=$(tests/e2e/stack/image-inputs.sh)
wordpress_inputs=$inputs
base_dockerfile=wordpress.local.dockerfile
dev_packages=""

# With no links (no dev/ clones, or make symlink not run), E2E_DEV=1 builds
# the composer.lock versions like any other build.
dev_links=""
if [ "${E2E_DEV:-}" = "1" ]; then
    dev_links=$(package_links)
    if [ -z "$dev_links" ]; then
        echo "No dev package links (make symlink), so the stack runs the composer.lock versions."
    fi
fi

if [ -n "$dev_links" ]; then
    stage_dev_packages "$dev_links"
    # Never matches image-inputs.sh, so the next run without E2E_DEV rebuilds
    # hale-test/wordpress from the composer.lock versions.
    wordpress_inputs=dev
else
    restore_composer_packages
fi

echo "Building hale-test/wordpress-base"
docker build -f "$base_dockerfile" -t hale-test/wordpress-base .

echo "Building hale-test/wordpress (compiled theme assets)"
docker build -f tests/e2e/stack/wordpress.dockerfile \
    --build-arg BASE_IMAGE=hale-test/wordpress-base \
    --build-context dev="$dev_stage" \
    --label "hale-test.inputs=$wordpress_inputs" \
    --label "hale-test.dev-packages=$dev_packages" \
    -t hale-test/wordpress .

echo "Building hale-test/nginx"
docker build -f nginx.local.dockerfile --target nginx \
    --label "hale-test.inputs=$inputs" -t hale-test/nginx .

echo "Building hale-test/wptools"
docker build -f wptools.dockerfile \
    --label "hale-test.inputs=$inputs" -t hale-test/wptools .

build_npm_image playwright
