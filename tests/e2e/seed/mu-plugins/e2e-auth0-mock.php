<?php

/**
 * Test stack only: trust the mock Auth0 tenant's TLS certificate.
 *
 * seed.sh copies this into wp-content/mu-plugins. The mock tenant
 * (tests/e2e/auth0-mock/server.js) serves https://auth0.e2e.test/ with a
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
 * specs/auth0-requests/ can compare against that version's request shapes.
 * The 4.x plugin defines WPA0_VERSION, 5.x and later WP_AUTH0_VERSION.
 */
add_action('send_headers', function () {
    $version = defined('WP_AUTH0_VERSION') ? WP_AUTH0_VERSION : (defined('WPA0_VERSION') ? WPA0_VERSION : '');
    if ($version !== '') {
        header('X-E2E-Auth0-Plugin: ' . $version);
    }
});
