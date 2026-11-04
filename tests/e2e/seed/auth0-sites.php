<?php

/**
 * The Auth0 test sites (see "Auth0 test sites" in seed.sh), in two steps that
 * each boot WordPress once:
 *
 *   wp --url=<network> eval-file /seed/auth0-sites.php create <path>...
 *   wp --url=<site url> eval-file /seed/auth0-sites.php finish <path>
 *
 * create makes e2esiteadmin and the sites, with their options, theme, roles
 * and page. finish runs on each site with its theme loaded: theme-setup.php,
 * the rewrite rules, then the Auth0 plugin, last so that it saves its default
 * settings with the site's https home URL already in place.
 *
 * @var array $args Positional arguments from `wp eval-file`.
 */

require_once ABSPATH . 'wp-admin/includes/plugin.php';

$step = array_shift($args);

function e2e_auth0_check($result, string $what)
{
    // false or a WP_Error. activate_plugin() returns null when it works.
    if (is_wp_error($result) || $result === false) {
        WP_CLI::error($what . (is_wp_error($result) ? ': ' . $result->get_error_message() : ''));
    }
    return $result;
}

function e2e_auth0_user_id(string $login): int
{
    $user = get_user_by('login', $login);
    if (!$user) {
        WP_CLI::error("No user {$login}");
    }
    return $user->ID;
}

if ($step === 'create') {
    $network = get_network();
    $admin_id = e2e_auth0_user_id('e2eadmin');

    $password = getenv('E2E_PASSWORD') ?: WP_CLI::error('E2E_PASSWORD is not set');
    $site_admin_id = e2e_auth0_check(
        wpmu_create_user('e2esiteadmin', $password, 'e2esiteadmin@example.test'),
        'Could not create e2esiteadmin',
    );
    e2e_auth0_check(
        wp_update_user(['ID' => $site_admin_id, 'display_name' => 'E2E site admin', 'role' => 'subscriber']),
        'Could not update e2esiteadmin',
    );

    foreach ($args as $path) {
        WP_CLI::log("Seeding Auth0 site '{$path}'");
        $blog_id = e2e_auth0_check(
            wpmu_create_blog($network->domain, "{$network->path}{$path}/", "Auth0 E2E ({$path})", $admin_id, ['public' => 1], $network->id),
            "Could not create /{$path}/",
        );
        switch_to_blog($blog_id);

        $home = 'https://' . $network->domain . $network->path . $path;
        update_option('home', $home);
        update_option('siteurl', $home);
        switch_theme('hale');
        update_option('revisionary_activation_done', 1);
        update_option('revisionary_activation', 0);
        foreach (['editor', 'author', 'contributor'] as $role) {
            add_user_to_blog($blog_id, e2e_auth0_user_id("e2e{$role}"), $role);
        }
        update_option('permalink_structure', '/%postname%/');
        update_option('blog_public', 0);
        e2e_auth0_check(wp_insert_post([
            'post_type' => 'page',
            'post_status' => 'publish',
            'post_title' => 'Members area',
            'post_name' => 'members-area',
            'post_content' => '<!-- wp:paragraph --><p>Only for signed-in users.</p><!-- /wp:paragraph -->',
        ], true), "Could not create the members-area page on /{$path}/");

        if ($path === 'auth0') {
            add_user_to_blog($blog_id, $site_admin_id, 'administrator');
        } elseif ($path === 'auth0-two') {
            update_option('moj_component_settings', ['user_switch_active' => 'yes']);
        }

        restore_current_blog();
    }
} elseif ($step === 'finish') {
    $path = $args[0] ?? '';

    require __DIR__ . '/theme-setup.php';
    flush_rewrite_rules(false);

    $plugin = 'auth0/' . array_key_first(get_plugins('/auth0'));
    if ($path === 'auth0-network') {
        // In the site's active plugins, as a network activation would make it
        // active there, but without activate_plugin(): no activation hook.
        update_option('active_plugins', array_merge((array) get_option('active_plugins', []), [$plugin]));
        WP_CLI::log("Plugin {$plugin} active without its activation hook.");
    } elseif ($path === 'auth0-legacy') {
        // The 4.x file name, whichever version is installed, and no activation
        // hook: what a site activated before the upgrade has stored.
        update_option('active_plugins', ['auth0/WP_Auth0.php']);
    } else {
        e2e_auth0_check(activate_plugin($plugin), "Could not activate {$plugin} on /{$path}/");
    }

    if ($path === 'auth0-private') {
        $force_login = 'wp-force-login/' . array_key_first(get_plugins('/wp-force-login'));
        e2e_auth0_check(activate_plugin($force_login), "Could not activate {$force_login}");
    }
} else {
    WP_CLI::error('Usage: auth0-sites.php create <path>... | finish <path>');
}
