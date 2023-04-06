<?php

$envType = getenv('ENV_TYPE');

include_once dirname(__DIR__) . '/vendor/autoload.php';

/**
 * Initialise Sentry
 */
$dsnSentry = '';

switch ($envType) {
    case 'prod':
        $dsnSentry = 'https://089f64c901484b31aff96b3fd0c0e709@o345774.ingest.sentry.io/4504963493593088';
        break;
    case 'staging':
        $dsnSentry = 'https://14810aad50d046fb86df8f357de999d1@o345774.ingest.sentry.io/4504963487432704';
        break;
    case 'dev':
        $dsnSentry = 'https://f1d6c41335d94ca49536a80ed1d6ae1c@o345774.ingest.sentry.io/4504955899478016';
        break;
    case 'demo':
        $dsnSentry = 'https://2b3609a14a424859ab34254d47d731c1@o345774.ingest.sentry.io/4504963496148992';
        break;
}

if (function_exists('sentry\init')) {
        Sentry\init(['dsn' => "$dsnSentry" ]);
    try {
        $this->functionFailsForSure();
    } catch (\Throwable $exception) {
        \Sentry\captureException($exception);
    }
}
