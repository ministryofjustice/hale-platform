<?php

$envType = getenv('ENV_TYPE');

if ($envType === 'dev') {

    // Turn on error reporting
    error_reporting(E_ALL);

    // Exclude deprecated warnings
    error_reporting(error_reporting() & ~E_DEPRECATED);

    $errorConstants = [
        'WP_DEBUG' => 'true',
        'WP_DEBUG_LOG' => 'true',
        'WP_DEBUG_DISPLAY' => 'true'
    ];

} else {
    error_reporting(0);
    @ini_set( 'display_errors', 0 );

    $errorConstants = [
        'WP_DEBUG' => 'true',
        'WP_DEBUG_LOG' => 'true',
        'WP_DEBUG_DISPLAY' => 'false'
    ];
}

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

}

