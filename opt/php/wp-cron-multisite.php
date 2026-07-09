<?php
<<<<<<< HEAD
=======

>>>>>>> prototype-cache-lua-implementation
/**
 * Multisite cron sweep -- one HTTP request per site to wp-cron.php.
 * Invoked every minute by helm_deploy/wordpress/templates/cron-wp-multisite.yaml.
 *
 * Use HTTP requests in favour of `shell_exec(wp cron event run --due-now --url='')`
 * because, HTTP requests leverage in process opcache, and shell_exec was compiling
 * PHP on each invocation. HTTP requests are an order of magnitude quicker.
 *
 * Because this script handles cron, DISABLE_WP_CRON is set to true in
 * opt/scripts/config.sh. This prevents WordPress from spawning its own cron
 * requests to the public siteurl on every page load, which would route via the
 * public internet instead of the internal pod network.
 */

<<<<<<< HEAD
if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', dirname( __FILE__ ) . '/' );
}

if ( file_exists( ABSPATH . 'wp-load.php' ) ) {
    include( ABSPATH . 'wp-load.php' );
}else{
    status_header( 500 );
    exit("[". date('h:i:s') ."] File does not exist: " . ABSPATH . "wp-load.php" );
}

=======
if (! defined('ABSPATH')) {
    define('ABSPATH', dirname(__FILE__) . '/');
}

if (file_exists(ABSPATH . 'wp-load.php')) {
    include(ABSPATH . 'wp-load.php');
} else {
    status_header(500);
    exit("[" . date('h:i:s') . "] File does not exist: " . ABSPATH . "wp-load.php");
}

>>>>>>> prototype-cache-lua-implementation
/** @var wpdb $wpdb */
global $wpdb;
$sql = $wpdb->prepare("SELECT domain, path FROM $wpdb->blogs WHERE archived='0' AND deleted ='0' LIMIT 0,300", '');

// Default targets the nginx container (port 8080) on the same pod.
// Local docker-compose overrides via NGINX_INTERNAL_URL=https://nginx.
<<<<<<< HEAD
$internal_base = getenv( 'NGINX_INTERNAL_URL' ) ?: 'http://127.0.0.1:8080';
=======
$internal_base = getenv('NGINX_INTERNAL_URL') ?: 'http://127.0.0.1:8080';
>>>>>>> prototype-cache-lua-implementation

$blogs = $wpdb->get_results($sql);

$failures = [];

<<<<<<< HEAD
foreach ( $blogs as $blog ) {
=======
foreach ($blogs as $blog) {
>>>>>>> prototype-cache-lua-implementation
    $path = $blog->path ?: '/';
    // No `?doing_wp_cron=` query string -- when called externally, wp-cron.php
    // expects to manage its own `doing_cron` transient lock. Passing our own
    // value never matches the stored transient and causes wp-cron.php to bail
    // at the lock-check without firing any hooks.
    $url = $internal_base . $path . 'wp-cron.php';

<<<<<<< HEAD
    $response = wp_remote_get( $url, [
        'timeout'   => 30,
        'headers'   => [ 'Host' => $blog->domain ],
    ] );

    if ( is_wp_error( $response ) ) {
        $failures[] = $blog->domain . $path . ' err=' . $response->get_error_message();
    } elseif ( ( $code = wp_remote_retrieve_response_code( $response ) ) >= 300 ) {
=======
    $response = wp_remote_get($url, [
        'timeout'   => 30,
        'headers'   => ['Host' => $blog->domain],
    ]);

    if (is_wp_error($response)) {
        $failures[] = $blog->domain . $path . ' err=' . $response->get_error_message();
    } elseif (($code = wp_remote_retrieve_response_code($response)) >= 300) {
>>>>>>> prototype-cache-lua-implementation
        $failures[] = $blog->domain . $path . ' status=' . $code;
    }
}

<<<<<<< HEAD
if ( $failures ) {
    error_log( '[wp-cron-multisite] failures: ' . implode( '; ', $failures ) );
    status_header( 500 );
    exit( 'wp-cron-multisite encountered failures' );
=======
if ($failures) {
    error_log('[wp-cron-multisite] failures: ' . implode('; ', $failures));
    status_header(500);
    exit('wp-cron-multisite encountered failures');
>>>>>>> prototype-cache-lua-implementation
}
