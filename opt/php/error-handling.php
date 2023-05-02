<?php

// Turn on error reporting
error_reporting(E_ALL);

// Exclude deprecated warnings
error_reporting(error_reporting() & ~E_DEPRECATED);

if ($envType === 'dev') {

    $errorConstants = [
        'WP_DEBUG' => 'true',
        'WP_DEBUG_LOG' => 'true',
        'WP_DEBUG_DISPLAY' => 'true'
    ];

} else {

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