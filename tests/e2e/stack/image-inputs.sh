#!/bin/bash
#
# Print one hash of everything the hale-test/wordpress, nginx and wptools
# images are built from: their Dockerfiles, opt/ and composer.lock, which fixes
# what composer put in ./wordpress and ./vendor. Uncommitted and untracked
# files count. build.sh labels the images with it; stack.sh rebuilds them when
# it no longer matches.
#
# ./wordpress itself is not hashed: it is thousands of files, and composer.lock
# already decides its contents. After editing a file in it by hand, rebuild
# with E2E_BUILD=1.

set -euo pipefail

cd "$(dirname "$0")/../../.."

# -c lists tracked files, including any deleted from the working tree, which
# the -f test drops; -o adds untracked files that .gitignore does not cover.
files=()
while IFS= read -r file; do
    [ -f "$file" ] && files+=("$file")
done < <(git ls-files -co --exclude-standard -- \
    composer.lock opt \
    wordpress.local.dockerfile nginx.local.dockerfile wptools.dockerfile \
    tests/e2e/stack/wordpress.dockerfile | sort -u)

# Each path next to the hash of its contents, then one hash of that list. One
# git process hashes every file.
paste -d ' ' \
    <(printf '%s\n' "${files[@]}" | git hash-object --stdin-paths) \
    <(printf '%s\n' "${files[@]}") |
    git hash-object --stdin
