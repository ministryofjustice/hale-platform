<?php

/**
 * Auth0 configuration and login fixes
 *
 * Configures the Auth0 plugin (auth0/wordpress, 5.x and 6.x) for every site
 * from the AUTH0_ENV_* constants, which opt/scripts/config.sh sets from the
 * environment. The plugin itself reads only its own per-site options
 * (auth0_*), so each option it reads is answered here instead, with
 * pre_option_*: the same tenant and the same settings on every site, whatever
 * is stored, and nothing a site administrator can change.
 *
 * Without the constants (a local stack with no Auth0 credentials) nothing here
 * runs, the plugin stays unconfigured, and sites keep the WordPress login form.
 *
 * Also works around plugin behaviour the platform can't use:
 * - "remember me" logins: WordPress's login cookies are kept to the browser
 *   session, as they were with the 4.x plugin;
 * - no WordPress password login: staff can still reach it with a secret
 *   login bypass address;
 * - logout without WordPress's nonce, which the plugin allows;
 * - a redirect loop on wp-force-login sites for someone Auth0 signs in but who
 *   has no account here;
 * - the settings screens, which show the client secret in the page.
 *
 * Covered by tests/e2e/specs/auth0/.
 */

/**
 * Load the plugin's own classes (Auth0\WordPress\...). Composer's autoloader
 * maps them to wordpress/wp-content/plugins/auth0/src relative to the repo
 * root, but the image moves vendor/ to wp-content/vendor, so that map points
 * at a folder that doesn't exist and the plugin stops with a fatal error on
 * every request. The SDK and the plugin's other dependencies live inside
 * vendor/ and load as normal. Registered whether or not Auth0 is configured:
 * the plugin needs its classes wherever it is active. Registered ahead of
 * Composer's: CI builds with --optimize-autoloader, which lists each class's
 * file in a class map, and Composer includes a listed file without checking
 * it exists, so a PHP warning for every class would come before this.
 */
spl_autoload_register(function (string $class): void {
    $prefix = 'Auth0\\WordPress\\';
    if (strncmp($class, $prefix, strlen($prefix)) !== 0) {
        return;
    }
    $file = WP_PLUGIN_DIR . '/auth0/src/' . str_replace('\\', '/', substr($class, strlen($prefix))) . '.php';
    if (is_file($file)) {
        require $file;
    }
}, true, true);

/**
 * Keep the plugin active across the upgrade from 4.x. Its main file was
 * auth0/WP_Auth0.php and is now auth0/wpAuth0.php, but sites and the network
 * that activated 4.x still list the old file. WordPress skips a listed plugin
 * whose file is missing, without a word, so the plugin would be off everywhere
 * and every login page would be the WordPress password form. The old name is
 * read as the new one instead: nothing is written, so going back to 4.x needs
 * no change either. Only while the new file is there and the old one is not.
 * mu-plugins load before WordPress reads either list (wp-settings.php).
 */
const HC_AUTH0_PLUGIN_4X = 'auth0/WP_Auth0.php';
const HC_AUTH0_PLUGIN = 'auth0/wpAuth0.php';

function hc_auth0_renamed(): bool
{
    static $renamed = null;
    $renamed ??= is_file(WP_PLUGIN_DIR . '/' . HC_AUTH0_PLUGIN) && !is_file(WP_PLUGIN_DIR . '/' . HC_AUTH0_PLUGIN_4X);

    return $renamed;
}

// A site's plugins: a list of files.
add_filter('option_active_plugins', function ($plugins) {
    if (!is_array($plugins) || !hc_auth0_renamed() || !in_array(HC_AUTH0_PLUGIN_4X, $plugins, true)) {
        return $plugins;
    }

    return array_values(array_unique(array_map(
        fn ($plugin) => $plugin === HC_AUTH0_PLUGIN_4X ? HC_AUTH0_PLUGIN : $plugin,
        $plugins
    )));
});

// Network-activated plugins: file => activation time.
add_filter('site_option_active_sitewide_plugins', function ($plugins) {
    if (!is_array($plugins) || !hc_auth0_renamed() || !isset($plugins[HC_AUTH0_PLUGIN_4X])) {
        return $plugins;
    }

    $plugins[HC_AUTH0_PLUGIN] ??= $plugins[HC_AUTH0_PLUGIN_4X];
    unset($plugins[HC_AUTH0_PLUGIN_4X]);

    return $plugins;
});

if (!defined('AUTH0_ENV_DOMAIN') || !defined('AUTH0_ENV_CLIENT_ID') || !defined('AUTH0_ENV_CLIENT_SECRET')
    || AUTH0_ENV_DOMAIN === '' || AUTH0_ENV_CLIENT_ID === '' || AUTH0_ENV_CLIENT_SECRET === ''
    || AUTH0_ENV_DOMAIN === null || AUTH0_ENV_CLIENT_ID === null || AUTH0_ENV_CLIENT_SECRET === null) {
    return;
}

/**
 * The plugin's options, by option name. Booleans are the strings 'true' and
 * 'false' and pair_sessions an integer: the plugin compares them strictly.
 */
$hc_auth0_options = [
    // On, wherever the plugin is active.
    'auth0_state' => ['enable' => 'true'],
    'auth0_client' => [
        'domain' => AUTH0_ENV_DOMAIN,
        'id' => AUTH0_ENV_CLIENT_ID,
        'secret' => AUTH0_ENV_CLIENT_SECRET,
    ],
    // No custom domain, API audiences or Organizations.
    'auth0_client_advanced' => [],
    // The key the plugin encrypts its session cookie with. The plugin makes a
    // random one on activation, but only on the site it was activated from, so
    // a network-activated plugin would be unconfigured everywhere else. Derived
    // from the WordPress salts instead: the same on every site and every pod,
    // and changed along with them.
    'auth0_cookies' => [
        'secret' => hash_hmac('sha256', 'auth0 session cookies', AUTH_KEY . AUTH_SALT),
        'secure' => 'true',
        'samesite' => 'lax',
    ],
    'auth0_authentication' => [
        // Off. Pairing logs people out on any request where the Auth0 user
        // is not linked to the WordPress user for that site: on another site
        // on the same domain, and when switching user (hale-components).
        'pair_sessions' => 2,
        // Not the plugin's own secret link to the WordPress login form: its
        // form sends the password straight back to Auth0. See the login
        // bypass below instead.
        'allow_fallback' => 'false',
        // Unused, but without one the plugin's back-channel logout check
        // compares an empty ?auth0_bcl= to an empty secret and accepts it.
        'backchannel_logout_secret' => hash_hmac('sha256', 'auth0 backchannel logout', AUTH_KEY . AUTH_SALT),
    ],
    'auth0_sessions' => [
        // Off. Rolling sessions start a new WordPress session on every page
        // view, which also invalidates nonces already on the page.
        'rolling_sessions' => 'false',
        'refresh_tokens' => 'false',
    ],
    // Match people to WordPress users by verified email address, and never
    // create an account for someone who has none.
    'auth0_accounts' => [
        'matching' => 'flexible',
        'missing' => 'reject',
    ],
    // No sync between WordPress users and the Auth0 tenant: it would create
    // and delete users in the tenant.
    'auth0_sync' => [],
    'auth0_sync_events' => [
        'user_creation' => 'false',
        'user_deletion' => 'false',
        'user_updates' => 'false',
    ],
    'auth0_backchannel_logout' => [],
    'auth0_tokens' => [],
];

foreach ($hc_auth0_options as $hc_auth0_option => $hc_auth0_value) {
    add_filter("pre_option_{$hc_auth0_option}", fn () => $hc_auth0_value);
}
unset($hc_auth0_options, $hc_auth0_option, $hc_auth0_value);

/**
 * Whether the Auth0 plugin is loaded and handling logins on this site.
 */
function hc_auth0_active(): bool
{
    return function_exists('wpAuth0') && wpAuth0()->isEnabled() && wpAuth0()->isReady();
}

/**
 * Logout needs WordPress's nonce. The plugin logs out on any request for
 * wp-login.php?action=logout, so a link or image on another site could log
 * people out. check_admin_referer() asks the person to confirm instead, as
 * WordPress does without the plugin. Runs before the plugin's own handler.
 */
add_action('login_form_logout', function () {
    if (hc_auth0_active()) {
        check_admin_referer('log-out');
    }
}, 9);

/**
 * Notes when the login page is handling the Auth0 callback, for the redirect
 * filter below. Runs before the plugin's own handler.
 */
add_action('login_form_login', function () {
    $GLOBALS['hc_auth0_callback'] = hc_auth0_active() && isset($_GET['code'], $_GET['state']);
}, 9);

/**
 * Keep WordPress's login cookies to the browser session. The plugin always
 * logs people in with "remember me" (wp_set_auth_cookie($user, true)): login
 * cookies that last 14 days and survive closing the browser. On the Auth0
 * callback, the persistent cookies WordPress is about to send are replaced by
 * session cookies for the same login session (the same token, so no second
 * session): gone when the browser closes, and expired by WordPress after 2
 * days (auth_cookie_expiration), as with the 4.x plugin.
 *
 * wp_clear_auth_cookie() also runs this filter, with no user and no expiry,
 * and is left alone.
 */
add_filter('send_auth_cookies', function ($send, $expire, $expiration, $user_id, $scheme, $token) {
    static $reissuing = false;

    if (!$send || $reissuing || empty($GLOBALS['hc_auth0_callback']) || !$user_id || !$expire || $token === '') {
        return $send;
    }

    $reissuing = true;
    wp_set_auth_cookie($user_id, false, '', $token);
    $reissuing = false;

    return false;
}, 10, 6);

/**
 * Login bypass: the WordPress login form, for staff who sign in with a
 * WordPress password. The plugin sends every login to Auth0, so the form is
 * only shown when the login page's address has the bypass parameter set to
 * the secret: <login page>?<AUTH0_ENV_FALLBACK_PARAM>=<AUTH0_ENV_FALLBACK_SECRET>.
 * Both come from the environment, so neither is in the code. Without either
 * there is no bypass.
 */
function hc_auth0_login_bypass_param(): string
{
    return defined('AUTH0_ENV_FALLBACK_PARAM') ? (string) AUTH0_ENV_FALLBACK_PARAM : '';
}

function hc_auth0_login_bypass(): bool
{
    $param = hc_auth0_login_bypass_param();
    $secret = defined('AUTH0_ENV_FALLBACK_SECRET') ? (string) AUTH0_ENV_FALLBACK_SECRET : '';
    $given = $param !== '' && isset($_REQUEST[$param]) && is_string($_REQUEST[$param]) ? wp_unslash($_REQUEST[$param]) : '';

    return $param !== '' && $secret !== '' && $given !== '' && hash_equals($secret, $given);
}

/**
 * With the bypass secret, the plugin's login handler is taken off this
 * request, so WordPress shows its login form, and checks the password when the
 * form is sent. The form carries the secret in a hidden field, so the request
 * that sends the password is let through too.
 */
add_action('login_form_login', function () {
    if (hc_auth0_active() && hc_auth0_login_bypass()) {
        remove_action(
            'login_form_login',
            [wpAuth0()->getClassInstance(\Auth0\WordPress\Actions\Authentication::class), 'onLogin'],
            10
        );
    }
}, 9);

add_action('login_form', function () {
    if (hc_auth0_active() && hc_auth0_login_bypass()) {
        $param = hc_auth0_login_bypass_param();
        printf('<input type="hidden" name="%s" value="%s">', esc_attr($param), esc_attr(wp_unslash($_REQUEST[$param])));
    }
});

/**
 * Someone Auth0 signed in, but who has no WordPress account here. The plugin
 * sends them to the site with no message. On a wp-force-login site that sends
 * them straight back to the login page, then to Auth0, which signs them in
 * again: a loop until the browser stops it. Show an error instead, and clear
 * the plugin's Auth0 session so the next login starts again.
 */
add_filter('wp_redirect', function ($location) {
    if (empty($GLOBALS['hc_auth0_callback']) || is_user_logged_in()) {
        return $location;
    }

    wpAuth0()->getSdk()->clear();
    wp_die(
        esc_html__('There was a problem signing in. Your account does not have access to this site.'),
        esc_html__('Login error'),
        ['response' => 403]
    );
});

/**
 * The plugin's settings screens are for network admins only. They show the
 * client secret in the page, and the settings on them are fixed above anyway.
 * The screens are left out of everyone else's menu, refused if opened
 * directly, and their forms refused if posted.
 */
const HC_AUTH0_SETTINGS_SCREENS = ['auth0', 'auth0_sync', 'auth0_advanced', 'auth0_tools'];
const HC_AUTH0_SETTINGS_GROUPS = ['auth0_configuration', 'auth0_sync', 'auth0_advanced', 'auth0_tools'];

add_action('admin_menu', function () {
    if (!is_super_admin()) {
        remove_menu_page('auth0');
    }
}, 99);

add_action('admin_init', function () {
    $screen = isset($_GET['page']) ? sanitize_key(wp_unslash($_GET['page'])) : '';
    if (in_array($screen, HC_AUTH0_SETTINGS_SCREENS, true) && !is_super_admin()) {
        wp_die(esc_html__('Sorry, you are not allowed to access this page.'), 403);
    }
});

foreach (HC_AUTH0_SETTINGS_GROUPS as $hc_auth0_group) {
    add_filter("option_page_capability_{$hc_auth0_group}", fn () => 'manage_network_options');
}
unset($hc_auth0_group);
