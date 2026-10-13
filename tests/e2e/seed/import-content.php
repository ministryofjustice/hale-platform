<?php

/**
 * Load one site's content fixtures into the end-to-end test multisite.
 *
 * Run by seed.sh for each site in sites.json:
 *
 *   wp --url=<site url> eval-file /seed/import-content.php <site key>
 *
 * Reads content/<site key>/content.json. Each item becomes a published page or
 * post whose content is the block markup in its .html file, with the fixed ID
 * and slug the manifest gives it, so tests can address content directly.
 *
 * content.json:
 *   items      pages and posts: id, type, slug, title, file, and optionally
 *              featuredImage (true to attach a generated placeholder image)
 *   frontPage  slug of the page to use as the static front page
 *   postsPage  slug of the page to list posts on
 *   menu       slugs to put in a menu, assigned to the site's menuLocation
 *
 * @var array $args Positional arguments from `wp eval-file`.
 */

require_once ABSPATH . 'wp-admin/includes/file.php';
require_once ABSPATH . 'wp-admin/includes/image.php';
require_once ABSPATH . 'wp-admin/includes/media.php';

$key = $args[0] ?? '';
$dir = "/seed/content/{$key}";
$sites = json_decode(file_get_contents('/seed/sites.json'), true, 512, JSON_THROW_ON_ERROR);
$site = current(array_filter($sites, fn ($s) => $s['key'] === $key));
if (!$site || !is_file("{$dir}/content.json")) {
    WP_CLI::error("No site '{$key}' in sites.json, or no {$dir}/content.json");
}
$manifest = json_decode(file_get_contents("{$dir}/content.json"), true, 512, JSON_THROW_ON_ERROR);

// Block markup is stored as written. kses would otherwise filter it as if the
// anonymous CLI user had typed it.
kses_remove_filters();

// Start from nothing: drop the posts and pages WordPress creates with a site.
$defaults = get_posts([
    'post_type' => ['post', 'page'],
    'post_status' => 'any',
    'numberposts' => -1,
]);
foreach ($defaults as $post) {
    wp_delete_post($post->ID, true);
}

$author = get_user_by('login', 'e2eeditor');
if (!$author) {
    WP_CLI::error('User e2eeditor does not exist');
}

/**
 * Generate a placeholder image and add it to the media library.
 * Made here with GD, so the repo holds no binary test images.
 */
function e2e_placeholder_image(string $label): int
{
    $image = imagecreatetruecolor(1200, 630);
    imagefill($image, 0, 0, imagecolorallocate($image, 29, 112, 184));
    imagestring($image, 5, 40, 40, $label, imagecolorallocate($image, 255, 255, 255));
    $tmp = wp_tempnam('e2e-placeholder.png');
    imagepng($image, $tmp);
    imagedestroy($image);

    $id = media_handle_sideload(
        ['name' => sanitize_title($label) . '.png', 'tmp_name' => $tmp],
        0,
        $label
    );
    if (is_wp_error($id)) {
        WP_CLI::error("Placeholder image '{$label}': " . $id->get_error_message());
    }
    update_post_meta($id, '_wp_attachment_image_alt', $label);
    return $id;
}

$ids = [];
foreach ($manifest['items'] as $item) {
    $id = wp_insert_post([
        'import_id' => $item['id'],
        'post_type' => $item['type'],
        'post_name' => $item['slug'],
        'post_title' => $item['title'],
        'post_content' => wp_slash(file_get_contents("{$dir}/{$item['file']}")),
        'post_status' => 'publish',
        'post_author' => $author->ID,
        // Fixed, so dates in listings never change between runs.
        'post_date' => '2026-01-05 09:00:00',
    ], true);

    if (is_wp_error($id)) {
        WP_CLI::error("{$item['slug']}: " . $id->get_error_message());
    }
    if ($id !== $item['id']) {
        WP_CLI::error("{$item['slug']} was given ID {$id}, not {$item['id']}. IDs must be unused.");
    }
    if (!empty($item['featuredImage'])) {
        set_post_thumbnail($id, e2e_placeholder_image($item['title']));
    }
    $ids[$item['slug']] = $id;
}

if (!empty($manifest['frontPage'])) {
    update_option('show_on_front', 'page');
    update_option('page_on_front', $ids[$manifest['frontPage']]);
}
if (!empty($manifest['postsPage'])) {
    update_option('page_for_posts', $ids[$manifest['postsPage']]);
}

if (!empty($manifest['menu']) && !empty($site['menuLocation'])) {
    $menu_id = wp_create_nav_menu('E2E menu');
    foreach ($manifest['menu'] as $position => $slug) {
        wp_update_nav_menu_item($menu_id, 0, [
            'menu-item-object-id' => $ids[$slug],
            'menu-item-object' => get_post_type($ids[$slug]),
            'menu-item-type' => 'post_type',
            'menu-item-status' => 'publish',
            'menu-item-position' => $position + 1,
        ]);
    }
    set_theme_mod('nav_menu_locations', [$site['menuLocation'] => $menu_id]);
}

WP_CLI::success(sprintf('%s: %d items', $key, count($ids)));
