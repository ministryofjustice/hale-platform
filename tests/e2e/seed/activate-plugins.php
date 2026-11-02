<?php

/**
 * Network-activate plugins by folder name. Run by seed.sh:
 *
 *   wp --url=<network> eval-file /seed/activate-plugins.php <plugin> [<plugin>...]
 *
 * Used instead of `wp plugin activate --network` because of how plugins that
 * print output while loading are handled. activate_plugin() activates them
 * anyway and returns an `unexpected_output` error carrying that output -
 * wp-admin shows it as a notice. WP-CLI reports it as a failed activation and
 * drops the output. Here the output is printed as a warning, so it can be
 * seen and fixed in the plugin, and the seed only fails on a real error.
 *
 * @var array $args Positional arguments from `wp eval-file`.
 */

require_once ABSPATH . 'wp-admin/includes/plugin.php';

foreach ($args as $slug) {
    $main = array_key_first(get_plugins("/{$slug}"));
    if ($main === null) {
        WP_CLI::error("No plugin in wp-content/plugins/{$slug}");
    }
    $plugin = "{$slug}/{$main}";

    $result = activate_plugin($plugin, '', true);
    if (is_wp_error($result) && $result->get_error_code() === 'unexpected_output') {
        $output = (string) $result->get_error_data();
        WP_CLI::warning(trim($output) === ''
            ? "{$slug} printed " . strlen($output) . ' bytes of whitespace while loading (text outside a PHP tag?)'
            : "{$slug} printed output while activating:\n" . trim($output));
    } elseif (is_wp_error($result)) {
        WP_CLI::error("{$slug}: " . $result->get_error_message());
    }

    if (!is_plugin_active_for_network($plugin)) {
        WP_CLI::error("{$slug} is not network active");
    }
    WP_CLI::log("Plugin '{$slug}' network activated.");
}
