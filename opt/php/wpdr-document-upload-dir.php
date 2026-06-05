<?php

/**
 * Plugin Name: WPDR Document Upload Dir (S3)
 * Description: Point wp-document-revisions at the s3-uploads bucket so document
 * file paths resolve via the s3:// stream wrapper instead of a stale local
 * basedir cached in wpdr's constructor before s3-uploads filters upload_dir.
 *
 * Only active when s3-uploads is in play (non-local environments, matching the
 * gate in mu-plugins/load.php) and the WP Document Revisions plugin is loaded.
 */

add_action('plugins_loaded', function () {
    if (
        !class_exists('WP_Document_Revisions') ||
        !defined('S3_UPLOADS_BUCKET') ||
        !S3_UPLOADS_BUCKET ||
        getenv('WP_ENVIRONMENT_TYPE') === 'local'
    ) {
        return;
    }

    add_filter(
        'pre_site_option_document_upload_directory',
        fn () => 's3://' . S3_UPLOADS_BUCKET . '/uploads/sites/%site_id%'
    );
});
