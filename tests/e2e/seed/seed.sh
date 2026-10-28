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

# Plugin files that end in "?>" and a newline print blank lines on every
# WP-CLI command. Drop blank lines from each command's output, keeping its exit
# status (sh has no pipefail). Errors and warnings go to stderr, untouched.
wp() {
    if out="$(command wp "$@")"; then status=0; else status=$?; fi
    printf '%s\n' "$out" | grep -v '^[[:space:]]*$' || true
    return "$status"
}
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
# calls NGINX_INTERNAL_URL, and so does the mock Auth0 tenant, which the Auth0
# test sites (below) call for tokens and keys.
wp config set WP_HTTP_BLOCK_EXTERNAL true --raw
wp config set WP_ACCESSIBLE_HOSTS "nginx,${AUTH0_ENV_DOMAIN:?AUTH0_ENV_DOMAIN is not set}"

# ---------------------------------------------------------------------------
# Plugins
#
# The installed set is composer.json. Each plugin is either network-activated
# below or deliberately left off, with the reason.
#
# Left off:
#   auth0                  - replaces the WordPress login form. Activated
#                            on the Auth0 test sites only (end of this file)
#   wp-force-login         - puts every page behind a login
#   microsoft-clarity      - sends visitor data to clarity.ms
#   ewww-image-optimizer   - sends uploads to its cloud service
#   wp-sentry-integration  - no DSN in the test stack
#   query-monitor          - debug output in every admin page
#   classic-editor         - the tests drive the block editor
#   wordpress-seo          - not active on the live sites (they have no Yoast
#                            tags). Its og:description runs the_content on an
#                            excerpt with lists and custom blocks removed, and
#                            the justice theme caches that as the page body.
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
    wp-document-revisions \
    wp-moj-blocks \
    wps-hide-login

# A test-only login path (wps-hide-login), so the deployed one stays out of
# the repo. support/stack.js has the same slug.
wp_network site option update whl_page e2e-test-login

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
# separators, which would drop the main site's empty path. Read into a variable
# first: sh has no pipefail, so a php failure inside the pipe would be lost
# and the seed would finish with no sites.
sites="$(php -r '
    $sites = json_decode(file_get_contents("/seed/sites.json"), true, 512, JSON_THROW_ON_ERROR);
    foreach ($sites as $i => $site) {
        foreach (["key", "path", "theme", "title"] as $field) {
            if (!isset($site[$field])) {
                fwrite(STDERR, "sites.json: site $i has no $field\n");
                exit(1);
            }
        }
        echo implode("|", [$site["key"], $site["path"], $site["theme"], $site["title"], $site["blogId"] ?? ""]), "\n";
    }
')"
printf '%s\n' "$sites" | while IFS="|" read -r key path theme title blog_id; do
    echo "Seeding site '$key' ($theme)"

    if [ -z "$path" ]; then
        url="$NETWORK/"
        wp --url="$url" option update blogname "$title"
    else
        url="$NETWORK/$path/"
        # A theme that styles one site by its ID (govwind keys its IPA colours
        # on .website-61) needs that site to have the same ID here.
        if [ -n "$blog_id" ]; then
            wp_network eval "global \$wpdb; \$wpdb->query('ALTER TABLE ' . \$wpdb->blogs . ' AUTO_INCREMENT = $blog_id');"
        fi
        created_id="$(wp_network site create --slug="$path" --title="$title" \
            --email="e2eadmin@example.test" --porcelain)"
        if [ -n "$blog_id" ] && [ "$created_id" != "$blog_id" ]; then
            echo "Site '$key' was given ID $created_id, not $blog_id" >&2
            exit 1
        fi
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
    # After the content: it builds the colour stylesheet from the theme mods
    # the content sets.
    wp --url="$url" eval-file /seed/theme-setup.php
    wp --url="$url" rewrite flush
done

# ---------------------------------------------------------------------------
# Auth0 test sites
#
# Sites with the Auth0 plugin active on them alone, for specs/auth0/. They
# sign in through the mock tenant (auth0-mock in docker-compose.test.yml),
# whose Allowed Callback and Logout URLs list these paths. support/auth0.js
# has them too. Not in sites.json: they have no seeded content, and the
# all-sites specs log in with the WordPress form, which Auth0 replaces.
#
#   auth0          the plugin's default settings. e2esiteadmin is its
#                  administrator: a site admin, not a network admin
#   auth0-two      the same, for moving between two Auth0 sites on one domain.
#                  hale-components' switch user (impersonation) is on
#   auth0-private  also wp-force-login, as a site that is not public yet
#   auth0-network  the plugin active without its activation hook having run
#                  on the site, as on every site but one when the plugin is
#                  network-activated
#   auth0-legacy   the plugin listed as active by the 4.x plugin's file name,
#                  auth0/WP_Auth0.php, as on every site activated before the
#                  upgrade from 4.x. 5.x and later's file is auth0/wpAuth0.php
#
# Each has a members-area page. The plugin is activated last: it saves its
# default settings on activation, and the default address to send users to
# after login is the site's home URL, so home must already be https.
# ---------------------------------------------------------------------------

# Trust the mock tenant's certificate (see the file).
cp /seed/mu-plugins/e2e-auth0-mock.php wp-content/mu-plugins/

wp_network user create e2esiteadmin e2esiteadmin@example.test \
    --role=subscriber --user_pass="$PASSWORD" --display_name="E2E site admin"

for path in auth0 auth0-two auth0-private auth0-network auth0-legacy; do
    echo "Seeding Auth0 site '$path'"
    url="$NETWORK/$path/"
    wp_network site create --slug="$path" --title="Auth0 E2E ($path)" \
        --email="e2eadmin@example.test" --porcelain >/dev/null
    wp --url="$url" option update home "https://${url%/}"
    wp --url="$url" option update siteurl "https://${url%/}"
    wp --url="$url" theme activate hale
    wp --url="$url" option update revisionary_activation_done 1
    wp --url="$url" option update revisionary_activation 0
    for role in editor author contributor; do
        wp --url="$url" user set-role "e2e$role" "$role"
    done
    wp --url="$url" option update permalink_structure "/%postname%/"
    wp --url="$url" option update blog_public 0
    wp --url="$url" post create --post_type=page --post_status=publish \
        --post_title="Members area" --post_name=members-area \
        --post_content="<!-- wp:paragraph --><p>Only for signed-in users.</p><!-- /wp:paragraph -->" \
        >/dev/null
    wp --url="$url" eval-file /seed/theme-setup.php
    wp --url="$url" rewrite flush
    if [ "$path" = auth0-network ]; then
        # In the site's active plugins, as a network activation would make it
        # active there, but without activate_plugin(): no activation hook.
        wp --url="$url" eval '
            require_once ABSPATH . "wp-admin/includes/plugin.php";
            $plugin = "auth0/" . array_key_first(get_plugins("/auth0"));
            update_option("active_plugins", array_merge((array) get_option("active_plugins", []), [$plugin]));
            echo "Plugin $plugin active without its activation hook.\n";'
    elif [ "$path" = auth0-legacy ]; then
        # The 4.x file name, whichever version is installed, and no activation
        # hook: what a site activated before the upgrade has stored.
        wp --url="$url" option update active_plugins '["auth0/WP_Auth0.php"]' --format=json
    else
        wp --url="$url" plugin activate auth0
    fi
done
# activate_plugin() reports success even when the plugin stops with a fatal
# error as it loads, so check that every site really runs it: is-active fails
# when the plugin is inactive, and when loading it stops WordPress.
for path in auth0 auth0-two auth0-private auth0-network auth0-legacy; do
    wp --url="$NETWORK/$path/" plugin is-active auth0 ||
        { echo "The Auth0 plugin is not running on /$path/" >&2; exit 1; }
done
wp --url="$NETWORK/auth0/" user set-role e2esiteadmin administrator
wp --url="$NETWORK/auth0-two/" option update moj_component_settings '{"user_switch_active":"yes"}' --format=json
wp --url="$NETWORK/auth0-private/" plugin activate wp-force-login

echo "Seed complete"
