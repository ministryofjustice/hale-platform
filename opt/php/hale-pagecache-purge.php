<?php
/**
 * Plugin Name: Hale page cache purge
 * Description: Clears the OpenResty/Redis full-page cache when a page or post
 *              goes live - manual publish, scheduled publish (WP-Cron), or an
 *              edit to already-published content. Page cache ONLY; this never
 *              touches any object cache.
 *
 * Why transition_post_status (not save_post): save_post does NOT fire when
 * WP-Cron publishes a scheduled post. transition_post_status fires for manual
 * publish, scheduled publish, and edits of already-live content.
 */

if (! defined('ABSPATH')) {
    exit;
}

add_action('transition_post_status', 'hale_pagecache_on_transition', 10, 3);

/**
 * @param string  $new_status
 * @param string  $old_status
 * @param WP_Post $post
 */
function hale_pagecache_on_transition($new_status, $old_status, $post): void
{
    // Only act when the result is a live, publicly viewable page/post.
    if ('publish' !== $new_status) {
        return;
    }
    if (wp_is_post_revision($post) || wp_is_post_autosave($post)) {
        return;
    }
    if (! is_post_type_viewable(get_post_type($post))) {
        return;
    }

    // URLs whose cached HTML is now stale.
    $paths   = ['/'];                                       // home lists/links new content
    $paths[] = hale_pagecache_path(get_permalink($post));

    // Hierarchical pages: ancestors show breadcrumbs / child listings.
    foreach (get_post_ancestors($post) as $ancestor_id) {
        $paths[] = hale_pagecache_path(get_permalink($ancestor_id));
    }

    hale_pagecache_purge_paths(array_values(array_unique(array_filter($paths))));
}

/**
 * Reduce a full permalink to the path used in the cache key (e.g. "/about/").
 */
function hale_pagecache_path($url): string
{
    $path = wp_parse_url((string) $url, PHP_URL_PATH);
    return $path ?: '/';
}

/**
 * DELETE the page-cache keys for the given paths on the current site.
 *
 * Fail-soft: any Redis error is logged and swallowed so a cache problem can
 * never block an editor from publishing.
 *
 * @param string[] $paths
 */
function hale_pagecache_purge_paths(array $paths): void
{
    if ('true' !== getenv('PAGECACHE_ENABLED') || empty($paths)) {
        return;
    }
    if (! class_exists('Redis')) {
        error_log('pagecache purge: phpredis (Redis class) not available');
        return;
    }

    try {
        $host = getenv('REDIS_HOST') ?: 'redis';
        $port = (int) (getenv('REDIS_PORT') ?: 6379);

        // ElastiCache in-transit encryption needs the tls:// scheme.
        // Local dev sets REDIS_SSL=false.
        if ('false' !== getenv('REDIS_SSL')) {
            $host = 'tls://' . $host;
        }

        $redis = new Redis();
        if (! $redis->connect($host, $port, 1.0)) {
            error_log('pagecache purge: Redis connect failed');
            return;
        }
        if ($auth = getenv('REDIS_AUTH')) {
            $redis->auth($auth);
        }
        // Page cache lives in its own DB; the firewall is db0.
        $redis->select((int) (getenv('PAGECACHE_DB') ?: 1));

        $version  = (int) ($redis->get('pagecache:version') ?: 0);
        $hostname = wp_parse_url(home_url(), PHP_URL_HOST);   // multisite: scope to this site

        foreach ($paths as $path) {
            // Must match the Lua key scheme: pagecache:v{ver}:{host}:{uri}
            $redis->del("pagecache:v{$version}:{$hostname}:{$path}");
        }

        $redis->close();
    } catch (\Throwable $t) {
        error_log('pagecache purge failed: ' . $t->getMessage());
    }
}
