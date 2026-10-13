#!/bin/sh
#
# Seed the end-to-end test multisite with dummy data.
#
# Runs once per test run, in the `seed` service of docker-compose.test.yml,
# against a network config.sh has just installed. WP-CLI sets up the network,
# sites, users, plugins and settings; import-content.php then loads each
# site's pages and posts from content/<site>/content.json. No database is
# copied from anywhere: everything a test can see is created here.
#
# The sites are listed in sites.json, which the Playwright config reads too.

set -eu

NETWORK="${SERVER_NAME:?SERVER_NAME is not set}"
PASSWORD="${E2E_PASSWORD:?E2E_PASSWORD is not set}"

cd /var/www/html

wp_network() { wp --url="$NETWORK" "$@"; }

# A fresh network has only the main site.
if [ "$(wp_network site list --format=count)" -gt 1 ]; then
    echo "The network is already seeded. Recreate the stack to seed it again." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Network settings
# ---------------------------------------------------------------------------

# config.sh installs over http, but the stack only serves https. New sites take
# their scheme from the network's siteurl, so switch that before creating any.
# Each site's own home and siteurl are set in the loop below.
wp_network site option update siteurl "https://$NETWORK/"

# No outbound HTTP from WordPress: no update checks, licence checks, Notify
# emails or other third-party calls. nginx stays reachable for anything that
# calls NGINX_INTERNAL_URL.
wp config set WP_HTTP_BLOCK_EXTERNAL true --raw
wp config set WP_ACCESSIBLE_HOSTS "nginx"

# ---------------------------------------------------------------------------
# Plugins
#
# The installed set is composer.json. Each plugin is either network-activated
# below or deliberately left off, with the reason.
#
# Left off:
#   auth0                  - replaces the WordPress login form
#   wp-force-login         - puts every page behind a login
#   microsoft-clarity      - sends visitor data to clarity.ms
#   ewww-image-optimizer   - sends uploads to its cloud service
#   wp-sentry-integration  - no DSN in the test stack
#   query-monitor          - debug output in every admin page
#   classic-editor         - the tests drive the block editor
# ---------------------------------------------------------------------------
wp_network eval-file /seed/activate-plugins.php \
    advanced-custom-fields-pro \
    breadcrumb-block \
    cms-tree-page-view \
    cookie-compliance \
    option-tree \
    relevanssi-premium \
    remove-category-url \
    revisionary \
    safe-svg \
    simple-301-redirects \
    simple-definition-list-blocks \
    unconfirmed \
    website-builder-block-restrictions \
    website-builder-blocks \
    wordpress-seo \
    wp-document-revisions \
    wp-moj-blocks \
    wps-hide-login

# Same login path as every deployed environment (wps-hide-login).
wp_network site option update whl_page hale-wpms-2020

# ---------------------------------------------------------------------------
# Users
#
# config.sh has already created the network admin (WORDPRESS_ADMIN_USER).
# These get the same role on every site. Test-only passwords.
# ---------------------------------------------------------------------------
for role in editor author contributor; do
    wp_network user create "e2e$role" "e2e$role@example.test" \
        --role=subscriber --user_pass="$PASSWORD" --display_name="E2E $role"
done

# ---------------------------------------------------------------------------
# Sites
# ---------------------------------------------------------------------------
# Fields are split on "|", not a tab: read collapses runs of whitespace
# separators, which would drop the main site's empty path.
php -r '
    foreach (json_decode(file_get_contents("/seed/sites.json"), true) as $site) {
        echo implode("|", [$site["key"], $site["path"], $site["theme"], $site["title"]]), "\n";
    }
' | while IFS="|" read -r key path theme title; do
    echo "Seeding site '$key' ($theme)"

    if [ -z "$path" ]; then
        url="$NETWORK/"
        wp --url="$url" option update blogname "$title"
    else
        url="$NETWORK/$path/"
        wp_network site create --slug="$path" --title="$title" \
            --email="e2eadmin@example.test"
    fi
    wp --url="$url" option update home "https://${url%/}"
    wp --url="$url" option update siteurl "https://${url%/}"

    wp --url="$url" theme enable "$theme"
    wp --url="$url" theme activate "$theme"

    # PublishPress Revisions redirects the first wp-admin page anyone opens on
    # a site to its Past Revisions screen. Mark that as already done, so a
    # test that opens the editor lands in the editor.
    wp --url="$url" option update revisionary_activation_done 1
    wp --url="$url" option update revisionary_activation 0

    for role in editor author contributor; do
        wp --url="$url" user set-role "e2e$role" "$role"
    done

    wp --url="$url" option update blogdescription "Dummy content for end-to-end tests"
    wp --url="$url" option update permalink_structure "/%postname%/"
    # Search engines must never index a test site, even by accident.
    wp --url="$url" option update blog_public 0

    wp --url="$url" eval-file /seed/import-content.php "$key"
    wp --url="$url" rewrite flush
done

echo "Seed complete"
