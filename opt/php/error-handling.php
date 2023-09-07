<?php

$envType = getenv('ENV_TYPE');

if ($envType === 'dev' || $envType === 'local') {
    // Enable debugging
    define('WP_DEBUG', true);

    // Log errors to a file
    define('WP_DEBUG_LOG', true);

    // Display errors on the webpage (optional)
    define('WP_DEBUG_DISPLAY', false);

    ini_set('display_errors', 0);
    ini_set('log_errors', 1);
    ini_set('error_log', 'syslog');
    error_log("This is an error message for the development environment.");
} else {
    error_reporting(0);
}
