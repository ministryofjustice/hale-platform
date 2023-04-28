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

//Enable error reporting

if ($envType === 'demo') {
    
    // Turn on error reporting
    error_reporting(E_ALL);

    // Exclude deprecated warnings
    error_reporting(error_reporting() & ~E_DEPRECATED);

    $errorConstants = [
        'WP_DEBUG' => 'true',
        'WP_DEBUG_LOG' => 'true',
        'WP_DEBUG_DISPLAY' => 'true'
    ];

    foreach ($errorConstants as $errorConstant => $value) {

    // Set the WP-CLI command to run
    $command = "wp config set $errorConstant $value --raw";

    // Execute the command using exec()
    exec($command, $output, $return_var);

    // Check the return status
    if ($return_var !== 0) {
        echo 'WP-CLI command failed';
        exit;
    }

    // Print the output of the command to the screen
    echo implode("\n", $output);

    }
}