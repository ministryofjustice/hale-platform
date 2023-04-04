<?php

// Autoloads mu-plugins

require WPMU_PLUGIN_DIR .'/wp-gov-uk-notify/wp-gov-uk-notify.php';
require WPMU_PLUGIN_DIR .'/wp-moj-components/wp-moj-components.php';
require WPMU_PLUGIN_DIR .'/wp-user-roles/wp-user-roles.php';
require WPMU_PLUGIN_DIR .'/wp-s3-uploads/s3-uploads.php';

/**
 * Initialise Sentry
 */
if (function_exists('sentry\init')) {
    Sentry\init(['dsn' => 'https://f1d6c41335d94ca49536a80ed1d6ae1c@o345774.ingest.sentry.io/4504955899478016' ]);
    Sentry\captureLastError();
} else {
    trigger_error('Sentry not loaded.', $error_level = E_USER_NOTICE);
}
