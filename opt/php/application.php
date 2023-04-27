<?php

$envType = getenv('ENV_TYPE');

include_once dirname(__DIR__) . '/vendor/autoload.php';

/**
 * Initialise Sentry
 */
$environment = '';

switch ($envType) {
    case 'prod':
        $environment = 'Production';
        break;
    case 'staging':
        $environment = 'Staging';
        break;
    case 'dev':
        $environment = 'Development';
        break;
    case 'demo':
        $environment = 'Demonstration';
        break;
}

if (function_exists('sentry\init')) {
    \Sentry\init([
        'dsn' => "https://4d7a410074614517899f22cf025d2e74@o345774.ingest.sentry.io/4505040969400320",
        'environment' => "$environment",
    ]);

    \Sentry\captureLastError();
}


// if ($envType === 'demo') {
//     // Enable error reporting
//     error_reporting(E_ALL);
//     ini_set('display_errors', 1);
//     define('WP_DEBUG', true);
//     define('WP_DEBUG_LOG', true);
//     define('WP_DEBUG_DISPLAY', true);
// }