<?php

// PHP error level, the same in every environment. Where errors go is set in
// the PHP-FPM pool (opt/php/www.conf): logged to stderr, which reaches the
// container logs, and never displayed on the page. Both are locked with
// php_admin there, so ini_set() cannot change them.
//
// The level has to be set again here. WordPress's wp_debug_mode() narrows it
// before any plugin loads, and the error_reporting() function is not blocked
// by php_admin_value, so the pool's E_ALL alone does not hold.
error_reporting(E_ALL);
