<?php
session_start();
// Turn on error reporting
error_reporting(E_ALL);

// Exclude deprecated warnings
error_reporting(error_reporting() & ~E_DEPRECATED);

if(!isset($_SESSION['ERROR_HANDLE_RUN'])) {

$envType = getenv('ENV_TYPE');

if ($envType === 'dev') {

    $errorConstants = [
        'WP_DEBUG' => 'true',
        'WP_DEBUG_LOG' => 'true',
        'WP_DEBUG_DISPLAY' => 'true'
    ];

} else {

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

// Print the output of the command to the screen
echo implode("\n", $output);

}

$_SESSION['ERROR_HANDLE_RUN'] = true;

}
