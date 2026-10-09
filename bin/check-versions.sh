#!/usr/bin/env bash
set -euo pipefail

# Assert that the versions expressed in more than one place still agree.
#
# Two numbers - the WordPress core version and the PHP version - are declared
# independently in four files, because they describe four separate builds that
# nothing links together at build time:
#
#   wordpress.dockerfile        the deployed image
#   wordpress.local.dockerfile  the local image
#   wptools.dockerfile          Alpine php8X-* packages for the sidecar's wp-cli
#   .github/workflows/...       setup-php, which resolves composer dependencies
#
# Nothing enforces agreement, and a mismatch is quiet: local tests a different
# PHP than production runs, or the sidecar's wp-cli bootstraps WordPress on an
# older interpreter than the site does. This check makes that loud.
#
# Run locally with `make check-versions`, and in CI on every pull request.
#
# tr -d '\r' throughout: both dockerfiles are stored with CRLF endings, so a
# captured value carries a trailing CR that breaks every comparison.

cd "$(dirname "$0")/.."

fail=0
note() { printf '  %-46s %s\n' "$1" "$2"; }
bad()  { printf '  %-46s %s\n' "$1" "$2"; fail=1; }

arg_of() {  # arg_of <file> <ARG name>
    sed -nE "s/^ARG $2=\"?([^\"[:space:]]+)\"?.*/\1/p" "$1" | head -1 | tr -d '\r'
}

WP_DEPLOYED=$(arg_of wordpress.dockerfile WORDPRESS_VERSION)
WP_LOCAL=$(arg_of wordpress.local.dockerfile WORDPRESS_VERSION)
PHP_DEPLOYED=$(arg_of wordpress.dockerfile PHP_VERSION)
PHP_LOCAL=$(arg_of wordpress.local.dockerfile PHP_VERSION)

# wptools pins Alpine packages as php84-*, i.e. the version without the dot.
PHP_WPTOOLS_RAW=$(sed -nE 's/^[[:space:]]*php([0-9]{2})[[:space:]\\]*$/\1/p' wptools.dockerfile | head -1 | tr -d '\r')
PHP_WPTOOLS="${PHP_WPTOOLS_RAW:0:1}.${PHP_WPTOOLS_RAW:1:1}"

PHP_CI=$(sed -nE 's/^[[:space:]]*php-version:[[:space:]]*"?([0-9]+\.[0-9]+)"?.*/\1/p' \
    .github/workflows/rw-build-image.yaml | head -1 | tr -d '\r')

echo "WordPress core"
note "wordpress.dockerfile" "$WP_DEPLOYED"
if [ "$WP_LOCAL" = "$WP_DEPLOYED" ]; then
    note "wordpress.local.dockerfile" "$WP_LOCAL"
else
    bad "wordpress.local.dockerfile" "$WP_LOCAL   <-- does not match $WP_DEPLOYED"
fi

echo
echo "PHP"
note "wordpress.dockerfile" "$PHP_DEPLOYED"
for pair in "wordpress.local.dockerfile:$PHP_LOCAL" \
            "wptools.dockerfile (php${PHP_WPTOOLS_RAW}-*):$PHP_WPTOOLS" \
            "rw-build-image.yaml (setup-php):$PHP_CI"; do
    label="${pair%:*}"; value="${pair##*:}"
    if [ "$value" = "$PHP_DEPLOYED" ]; then
        note "$label" "$value"
    else
        bad "$label" "$value   <-- does not match $PHP_DEPLOYED"
    fi
done

# Pins duplicated across images, which drift the same way.
echo
echo "wp-cli (duplicated in three images)"
WP_CLI_REF=$(arg_of wordpress.dockerfile WP_CLI_VERSION)
for f in wordpress.dockerfile wordpress.local.dockerfile wptools.dockerfile; do
    v=$(arg_of "$f" WP_CLI_VERSION)
    if [ "$v" = "$WP_CLI_REF" ]; then note "$f" "$v"; else bad "$f" "$v   <-- does not match $WP_CLI_REF"; fi
done

echo
echo "phpredis (duplicated in two images)"
PR_REF=$(arg_of wordpress.dockerfile PHPREDIS_VERSION)
for f in wordpress.dockerfile wordpress.local.dockerfile; do
    v=$(arg_of "$f" PHPREDIS_VERSION)
    if [ "$v" = "$PR_REF" ]; then note "$f" "$v"; else bad "$f" "$v   <-- does not match $PR_REF"; fi
done

echo
if [ "$fail" -ne 0 ]; then
    echo "Versions disagree. Bump them together, or decide deliberately that one should lag." >&2
    exit 1
fi
echo "All version references agree."
