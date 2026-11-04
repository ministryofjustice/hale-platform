<?php

/**
 * Test stack only: trust the mock Auth0 tenant's TLS certificate.
 *
 * seed.sh copies this into wp-content/mu-plugins. The mock tenant
 * (tests/e2e/stack/auth0-mock.js) serves https://auth0.e2e.test/ with a
 * self-signed certificate, mounted at /etc/hale-e2e/auth0-mock.pem by
 * docker-compose.test.yml. WordPress's HTTP API checks certificates against
 * its own CA bundle, so requests to the tenant use the mock's certificate as
 * their CA instead. Verification stays on: the token exchange and the JWKS
 * fetch still check the certificate and the host name, as they do against
 * the real tenant.
 */

add_filter('http_request_args', function (array $args, string $url): array {
    if (defined('AUTH0_ENV_DOMAIN') && parse_url($url, PHP_URL_HOST) === AUTH0_ENV_DOMAIN) {
        $args['sslcertificates'] = '/etc/hale-e2e/auth0-mock.pem';
    }

    return $args;
}, 10, 2);

/**
 * Which version of the Auth0 plugin the site runs, in a response header, so
 * specs/auth0/request-shapes.spec.js can compare against that version's
 * request shapes. The 4.x plugin defines WPA0_VERSION, 5.x and later
 * WP_AUTH0_VERSION.
 */
add_action('send_headers', function () {
    $version = defined('WP_AUTH0_VERSION') ? WP_AUTH0_VERSION : (defined('WPA0_VERSION') ? WPA0_VERSION : '');
    if ($version !== '') {
        header('X-E2E-Auth0-Plugin: ' . $version);
    }
});

/**
 * No cached tenant keys or API token: the 4.x plugin keeps them in
 * transients, so on a stack kept between runs it would skip those requests
 * and request-shapes.spec.js would miss their shapes. Each run fetches them
 * again, so the request log depends on that run alone. The token's scope
 * is left alone: the plugin reads it back as soon as it stores a new token.
 */
foreach (['WP_Auth0_JWKS_cache', 'auth0_api_token'] as $e2e_auth0_transient) {
    add_filter("transient_{$e2e_auth0_transient}", '__return_false');
}
