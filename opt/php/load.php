<?php

// Autoloads mu-plugins

require WPMU_PLUGIN_DIR .'/wp-gov-uk-notify/wp-gov-uk-notify.php';
require WPMU_PLUGIN_DIR .'/wp-moj-components/wp-moj-components.php';
require WPMU_PLUGIN_DIR .'/hale-components/hale-components.php';
require WPMU_PLUGIN_DIR .'/wp-user-roles/wp-user-roles.php';

# Turn off s3 upload plugin in the local environment
# so it doesn't rewrite media urls to an s3 address

if (getenv('WP_ENVIRONMENT_TYPE') != 'local') {
    require WPMU_PLUGIN_DIR .'/wp-s3-uploads/s3-uploads.php';
}
