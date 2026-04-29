<?php

// Autoloads mu-plugins

require WPMU_PLUGIN_DIR .'/wp-gov-uk-notify/wp-gov-uk-notify.php';
require WPMU_PLUGIN_DIR .'/hale-components/hale-components.php';

# Turn off s3 upload plugin in the local environment
# so it doesn't rewrite media urls to an s3 address

if (getenv('WP_ENVIRONMENT_TYPE') != 'local') {
    require WPMU_PLUGIN_DIR .'/wp-s3-uploads/s3-uploads.php';
}

/**
 * Replace symlink mount path (/mnt/dev/mu-plugins) with target path (/var/www/html/wp-content/mu-plugins).
 *
 * This fixes an issue where the value for `$plugin` is a path that WordPress doesn't recognise,
 * e.g. /mnt/dev/mu-plugins/hale-components/moj-components/component/Users/UserSwitch.php
 *
 * @param string $url    The complete URL to the plugins directory including scheme and path.
 * @param string $path   Path relative to the URL to the plugins directory. Blank string
 *                       if no path is specified.
 * @param string $plugin The plugin file path to be relative to. Blank string if no plugin
 *                       is specified.
 */
function wb_reformat_mu_plugin_urls($url, $path, $plugin)
{
    // If $plugin doesn't start with the mount path, then do nothing.
    if (!str_starts_with($plugin, '/mnt/dev/mu-plugins/')) {
        return $url;
    }

    // Replace symlink mount path (/mnt/dev) with 
    // target path WP_CONTENT_DIR (e.g. /var/www/html/wp-content).
    $plugin_reformatted = str_replace('/mnt/dev/mu-plugins', WPMU_PLUGIN_DIR, $plugin);

    // Recall plugins_url with the reformatted path.
    // No infinite loop, because we replaced `/mnt/dev`
    return plugins_url($path, $plugin_reformatted);
}

if (getenv('WP_ENVIRONMENT_TYPE') === 'local') {
    add_filter('plugins_url', 'wb_reformat_mu_plugin_urls', 10, 3);
}
