<?php

$envType = getenv('ENV_TYPE');

if ($envType === 'dev' || $envType === 'local') {
    ini_set('display_errors', 0);
    ini_set('log_errors', 1);
    ini_set('error_log', 'syslog');
    error_log("This is an error message for the development environment.");
} else {
    error_reporting(0);
}
