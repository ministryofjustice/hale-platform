<?php

/** @var string Directory containing all of the site's files */
$root_dir = dirname(__DIR__);

require $root_dir . '/wp-content/vendor/autoload.php';

/**
 * Initialise Sentry
 */
if (function_exists('sentry\init')) {
    Sentry\init(['dsn' => 'https://f1d6c41335d94ca49536a80ed1d6ae1c@o345774.ingest.sentry.io/4504955899478016' ]);
    Sentry\captureLastError();
    trigger_error('Sentry loaded.', $error_level = E_USER_NOTICE);
} else {
    trigger_error('Sentry not loaded.', $error_level = E_USER_NOTICE);
}
