<?php

$envType = getenv('ENV_TYPE');

include_once dirname(__DIR__) . '/vendor/autoload.php';

/**
 * Initialise Sentry
 */
// $environment = '';

// switch ($envType) {
//     case 'prod':
//         $environment = 'Production';
//         break;
//     case 'staging':
//         $environment = 'Staging';
//         break;
//     case 'dev':
//         $environment = 'Development';
//         break;
//     case 'demo':
//         $environment = 'Demonstration';
//         break;
// }

// if (function_exists('sentry\init')) {
//     \Sentry\init([
//         'dsn' => "https://4d7a410074614517899f22cf025d2e74@o345774.ingest.sentry.io/4505040969400320",
//         'environment' => "$environment",
//     ]);

//     \Sentry\captureLastError();
// }

/**
 * Handle errors in different environments
 */

include_once dirname(__DIR__, 2) . '/error-handling.php';