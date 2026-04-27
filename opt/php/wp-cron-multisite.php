<?php
/**
 * Multisite cron sweep -- one HTTP request per site to wp-cron.php.
 * Invoked every minute by helm_deploy/wordpress/templates/cron-wp-multisite.yaml.
 *
 * Use HTTP requests in favour of `shell_exec(wp cron event run --due-now --url='')`
 * because, HTTP requests leverage in process opcache, and shell_exec was compiling
 * PHP on each invocation. HTTP requests are an order of magnitude quicker.
 */

if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', dirname( __FILE__ ) . '/' );
}

require ABSPATH . 'wp-load.php';

/** @var wpdb $wpdb */
global $wpdb;

// Default targets prod (in-cluster `wordpress` service on plain HTTP).
// Local docker-compose overrides via WP_CRON_INTERNAL_URL=https://nginx.
$internal_base = rtrim( getenv( 'WP_CRON_INTERNAL_URL' ) ?: 'http://wordpress:8080', '/' );

$blogs = $wpdb->get_results(
    "SELECT domain, path FROM $wpdb->blogs WHERE archived = '0' AND deleted = '0' LIMIT 0, 300"
);

$failures = array();

foreach ( $blogs as $blog ) {
    $path = $blog->path ?: '/';
    // No `?doing_wp_cron=` query string -- when called externally, wp-cron.php
    // expects to manage its own `doing_cron` transient lock. Passing our own
    // value never matches the stored transient and causes wp-cron.php to bail
    // at the lock-check without firing any hooks.
    $url = $internal_base . $path . 'wp-cron.php';

    $response = wp_remote_get( $url, array(
        'timeout'   => 30,
        'sslverify' => false,
        'headers'   => array( 'Host' => $blog->domain ),
    ) );

    if ( is_wp_error( $response ) ) {
        $failures[] = $blog->domain . $path . ' err=' . $response->get_error_message();
    } elseif ( ( $code = wp_remote_retrieve_response_code( $response ) ) >= 300 ) {
        $failures[] = $blog->domain . $path . ' status=' . $code;
    }
}

if ( $failures ) {
    error_log( '[wp-cron-multisite] failures: ' . implode( '; ', $failures ) );
}
