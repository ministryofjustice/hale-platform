<?php

$envType = getenv('ENV_TYPE');

if ($envType === 'dev') {

    error_reporting(E_ALL);
} else {
    error_reporting(0);
}