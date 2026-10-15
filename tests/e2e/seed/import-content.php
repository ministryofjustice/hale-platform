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
 *   items          pages and posts: id, type, slug, title, file, and
 *                  optionally featuredImage (true to attach a generated
 *                  placeholder image), parent (slug of an earlier page),
 *                  template (page template), meta (post meta to set) and date
 *   images         placeholder images, by name: width, height and optionally
 *                  alt
 *   documents      WP Document Revisions documents with generated files, by
 *                  name: type (pdf, docx or xlsx), and optionally title,
 *                  slug and lines of text
 *   logo           name of the image to use as the site logo
 *   themeMods      theme mods to set, such as the Hale Customizer colours
 *   styleVariation title of the theme style variation to apply, as choosing
 *                  it in the Site Editor would (block themes)
 *   navigations    navigation menus for block themes, by name: the .html file
 *                  of navigation-link blocks
 *   templateParts  template parts that replace the theme's own, by slug: area
 *                  and file (block themes)
 *   frontPage      slug of the page to use as the static front page
 *   postsPage      slug of the page to list posts on
 *   menu           slugs to put in a classic menu, assigned to the site's
 *                  menuLocation
 *
 * The .html files can refer to what the seed creates:
 *   {{image:<name>.url}}  {{image:<name>.id}}
 *   {{page:<slug>.url}}   {{page:<slug>.id}}
 *   {{document:<name>.url}}   {{document:<name>.id}}
 *   {{navigation:<name>.id}}   (template parts only)
 *
 * @var array $args Positional arguments from `wp eval-file`.
 */

require_once ABSPATH . 'wp-admin/includes/file.php';
require_once ABSPATH . 'wp-admin/includes/image.php';
require_once ABSPATH . 'wp-admin/includes/media.php';
require_once '/seed/documents.php';

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

// A theme or plugin hook that calls exit (the justice theme does on saving a
// post) would end the import early with status 0, and the seed would carry on
// with a half-built site.
$e2e_import_finished = false;
register_shutdown_function(function () use ($key, &$e2e_import_finished) {
    if (!$e2e_import_finished) {
        fwrite(STDERR, "Error: the {$key} import did not finish. If no error is above, a hook called exit.\n");
        exit(1);
    }
});

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
function e2e_placeholder_image(string $label, int $width = 1200, int $height = 630, ?string $alt = null): int
{
    $image = imagecreatetruecolor($width, $height);
    imagefill($image, 0, 0, imagecolorallocate($image, 29, 112, 184));
    $margin = min(40, intdiv($width, 10));
    imagestring($image, 5, $margin, $margin, $label, imagecolorallocate($image, 255, 255, 255));
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
    update_post_meta($id, '_wp_attachment_image_alt', $alt ?? $label);
    return $id;
}

/**
 * Read one of the site's .html files with its {{...}} references filled in.
 */
function e2e_fill(string $dir, string $file, array $tokens): string
{
    $content = strtr(file_get_contents("{$dir}/{$file}"), $tokens);
    if (preg_match('/\{\{[a-z]+:[^}]*\}\}/', $content, $unknown)) {
        WP_CLI::error("{$file}: {$unknown[0]} does not match anything this site's content.json creates");
    }
    return $content;
}

foreach ($manifest['themeMods'] ?? [] as $name => $value) {
    set_theme_mod($name, $value);
}

// Images first, so their automatic IDs come before the fixed page and post IDs.
$tokens = [];
$image_ids = [];
foreach ($manifest['images'] ?? [] as $name => $image) {
    $id = e2e_placeholder_image($name, $image['width'], $image['height'], $image['alt'] ?? '');
    $image_ids[$name] = $id;
    $tokens["{{image:{$name}.id}}"] = $id;
    $tokens["{{image:{$name}.url}}"] = wp_get_attachment_url($id);
}

// Featured images too: made after their post, one would take the next fixed ID.
$featured = [];
foreach ($manifest['items'] as $item) {
    if (!empty($item['featuredImage'])) {
        $featured[$item['slug']] = e2e_placeholder_image($item['title']);
    }
}

if (!empty($manifest['logo'])) {
    set_theme_mod('custom_logo', $image_ids[$manifest['logo']]);
    update_option('site_logo', $image_ids[$manifest['logo']]);
}

// Documents and their files take automatic IDs too, so they come before the
// fixed ones. Their addresses are WPDR permalinks, known once each exists,
// without the trailing slash the permalink structure adds, as live content
// links them.
foreach ($manifest['documents'] ?? [] as $name => $document) {
    $id = e2e_document($name, $document, $author);
    $tokens["{{document:{$name}.id}}"] = $id;
    $tokens["{{document:{$name}.url}}"] = untrailingslashit(get_permalink($id));
}

// Page addresses are known before any page exists: IDs are fixed, and a
// page's path is its parents' slugs and its own.
$items = array_column($manifest['items'], null, 'slug');
foreach ($items as $slug => $item) {
    $path = $slug;
    for ($parent = $item['parent'] ?? null; $parent; $parent = $items[$parent]['parent'] ?? null) {
        $path = "{$parent}/{$path}";
    }
    $tokens["{{page:{$slug}.id}}"] = $item['id'];
    $tokens["{{page:{$slug}.url}}"] = $slug === ($manifest['frontPage'] ?? null)
        ? home_url('/')
        : home_url("/{$path}/");
}

$ids = [];
foreach ($manifest['items'] as $item) {
    $content = e2e_fill($dir, $item['file'], $tokens);
    $id = wp_insert_post([
        'import_id' => $item['id'],
        'post_type' => $item['type'],
        'post_name' => $item['slug'],
        'post_title' => $item['title'],
        'post_content' => wp_slash($content),
        'post_parent' => isset($item['parent']) ? $ids[$item['parent']] : 0,
        'page_template' => $item['template'] ?? '',
        'meta_input' => $item['meta'] ?? [],
        'post_status' => 'publish',
        'post_author' => $author->ID,
        // Fixed, so dates in listings never change between runs.
        'post_date' => $item['date'] ?? '2026-01-05 09:00:00',
    ], true);

    if (is_wp_error($id)) {
        WP_CLI::error("{$item['slug']}: " . $id->get_error_message());
    }
    if ($id !== $item['id']) {
        WP_CLI::error("{$item['slug']} was given ID {$id}, not {$item['id']}. IDs must be unused.");
    }
    if (isset($featured[$item['slug']])) {
        set_post_thumbnail($id, $featured[$item['slug']]);
    }
    $ids[$item['slug']] = $id;
}

// After the pages, so their automatic IDs cannot take a fixed one.
foreach ($manifest['navigations'] ?? [] as $name => $file) {
    $id = wp_insert_post([
        'post_type' => 'wp_navigation',
        'post_title' => ucfirst($name),
        'post_content' => wp_slash(e2e_fill($dir, $file, $tokens)),
        'post_status' => 'publish',
    ], true);
    if (is_wp_error($id)) {
        WP_CLI::error("Navigation '{$name}': " . $id->get_error_message());
    }
    $tokens["{{navigation:{$name}.id}}"] = $id;
}

// A saved template part replaces the theme file of the same slug, as editing
// it in the Site Editor would.
foreach ($manifest['templateParts'] ?? [] as $slug => $part) {
    $id = wp_insert_post([
        'post_type' => 'wp_template_part',
        'post_name' => $slug,
        'post_title' => $slug,
        'post_content' => wp_slash(e2e_fill($dir, $part['file'], $tokens)),
        'post_status' => 'publish',
    ], true);
    if (is_wp_error($id)) {
        WP_CLI::error("Template part '{$slug}': " . $id->get_error_message());
    }
    // Not tax_input: wp_insert_post drops terms the (anonymous) CLI user
    // cannot assign.
    wp_set_post_terms($id, [get_stylesheet()], 'wp_theme');
    wp_set_post_terms($id, [$part['area']], 'wp_template_part_area');
}

if (!empty($manifest['styleVariation'])) {
    $variations = array_filter(
        WP_Theme_JSON_Resolver::get_style_variations(),
        fn ($variation) => ($variation['title'] ?? '') === $manifest['styleVariation']
    );
    if (!$variations) {
        WP_CLI::error(get_stylesheet() . " has no style variation '{$manifest['styleVariation']}'");
    }
    // Choosing a variation in the Site Editor copies its settings and styles
    // into the site's user global styles.
    $user_styles = WP_Theme_JSON_Resolver::get_user_data_from_wp_global_styles(wp_get_theme(), true);
    $variation = current($variations);
    wp_update_post([
        'ID' => $user_styles['ID'],
        'post_content' => wp_slash(wp_json_encode([
            'version' => WP_Theme_JSON::LATEST_SCHEMA,
            'isGlobalStylesUserThemeJSON' => true,
            'settings' => $variation['settings'] ?? new stdClass(),
            'styles' => $variation['styles'] ?? new stdClass(),
        ])),
    ]);
    WP_Theme_JSON_Resolver::clean_cached_data();
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

$e2e_import_finished = true;
WP_CLI::success(sprintf('%s: %d items, %d documents', $key, count($ids), count($manifest['documents'] ?? [])));
