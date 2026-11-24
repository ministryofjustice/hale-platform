<?php
/**
 * Pod health endpoint.
 *
 * Served only on the internal listener (port 8090), which the ingress never
 * routes, and denied by path on the public listener. Two depths, selected by
 * the HALE_HEALTH_DEEP fastcgi_param rather than a query string, so a client
 * cannot ask for the expensive one:
 *
 *   /healthz        Shallow, and what the readiness probe reads. Proves
 *                   php-fpm dispatched to a worker and that this pod's webroot
 *                   holds a readable WordPress.
 *
 *                   Deliberately does NOT touch the database. Every pod shares
 *                   one database, so a database check here would mark the whole
 *                   Deployment unready in the same second and empty the
 *                   Service - and Kubernetes has no fail-open for an endpoint
 *                   list, unlike an ALB. nginx can still serve page cache hits
 *                   with no PHP and no database involved, which is worth
 *                   keeping during exactly that outage.
 *
 *   /healthz/deep   Shallow plus a real query, for monitoring and the uptime
 *                   pod. Never for a probe: a database outage should raise an
 *                   alarm, not remove capacity.
 *
 * Note the asymmetry this creates, and why it is not an accident: shallow never
 * loads WordPress, because wpdb connects in its constructor - booting core at
 * all would make the shallow check fail whenever the database is down, which is
 * the one thing it exists to avoid.
 */

header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: no-store');

$root = __DIR__;
$deep = ($_SERVER['HALE_HEALTH_DEEP'] ?? '') === '1';

// The entrypoint copies core out of /usr/src/wordpress into the emptyDir on
// every pod start. A pod that has not finished that copy, or whose volume is
// broken, fails here - which is the realistic instance-scoped failure.
foreach (['wp-config.php', 'wp-load.php', 'wp-settings.php', 'wp-includes/version.php'] as $file) {
    if (!is_readable($root . '/' . $file)) {
        http_response_code(503);
        echo "fail: $file missing or unreadable - webroot not populated\n";
        return;
    }
}

// Confirms a real WordPress tree rather than files with the right names.
// version.php only defines globals, so no database connection is made.
require $root . '/wp-includes/version.php';

if (empty($wp_version)) {
    http_response_code(503);
    echo "fail: wp-includes/version.php defines no \$wp_version\n";
    return;
}

if (!$deep) {
    echo "ok: WordPress $wp_version, database not checked\n";
    return;
}

// Deep only from here.
//
// SHORTINIT stops WordPress after the database layer - no plugins, no theme, no
// query - so a slow plugin cannot influence the result. If the database is
// unreachable, wpdb's constructor bails and WordPress prints its own "Error
// establishing a database connection" page with a 500 before reaching the query
// below. Monitoring reads the status code either way; only the body differs.
// WP_INSTALLING stops ms-settings.php resolving the request host to a site in
// wp_blogs. Without it a probe or monitor calling this with a Host header that
// is not a known site (localhost, the pod IP, the Service name) gets a 302 from
// multisite before any query runs. The same reason wp-cli sets it.
define('WP_INSTALLING', true);
define('SHORTINIT', true);
require $root . '/wp-load.php';

$wpdb = $GLOBALS['wpdb'] ?? null;

if (!$wpdb || (int) $wpdb->get_var('SELECT 1') !== 1) {
    http_response_code(503);
    echo "fail: database did not answer SELECT 1\n";
    return;
}

echo "ok: WordPress $wp_version, database answering\n";
