<?php

/**
 * Theme setup that WordPress itself does not do when a theme is activated.
 * Run by seed.sh for each site, after its theme is active:
 *
 *   wp --url=<site url> eval-file /seed/theme-setup.php
 *
 * `make theme-setup` runs it on every site of the local hale.docker stack.
 *
 * Hale (and its child themes) assume the Customizer has been saved at least
 * once. On a new site that never has been:
 *
 * - The header shows no logo or site name. The Customizer defaults "Show Logo
 *   and Site Name?" (logo_configuration) to both, but partials/logo.php reads
 *   the theme mod without a default and shows neither. The search box then
 *   becomes the header's first child and drops 60px (header.scss).
 * - uploads/custom-colours.css is linked on every page but does not exist: only
 *   a Customizer save writes it (the preview writes temp-colours.css, the save
 *   renames it).
 *
 * This applies the Customizer's defaults and runs the same two colour steps.
 * Other themes are left alone.
 */

if (!function_exists('hale_generate_custom_colours')) {
    WP_CLI::log(get_stylesheet() . ': not a Hale theme, nothing to set up.');
    return;
}

// The Customizer's default (inc/customizer.php), only if the site has none.
if (get_theme_mod('logo_configuration') === false) {
    set_theme_mod('logo_configuration', 'both');
}

hale_generate_custom_colours();
hale_action_customize_save_after(null);

$file = wp_upload_dir()['basedir'] . '/custom-colours.css';
if (!is_file($file) || filesize($file) === 0) {
    WP_CLI::error("Hale colours were not written to {$file}");
}
WP_CLI::log(get_stylesheet() . ": header shows logo and site name; wrote {$file}");
