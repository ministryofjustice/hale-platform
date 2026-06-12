<?php

/**
 * WPDR Document Upload Dir (S3)
 *
 * Forces wp-document-revisions to resolve document paths through the
 * s3:// stream wrapper by filtering the `document_upload_directory`
 * site option directly.
 *
 * wpdr's constructor reads wp_upload_dir() and caches the basedir before
 * s3-uploads has registered its `upload_dir` filter, so without this
 * override wpdr writes documents to a local path that doesn't exist in
 * the container. Filtering the site option short-circuits that lookup.
 *
 * Only active when s3-uploads is in play (non-local environments,
 * matching the gate in mu-plugins/load.php) and WP Document Revisions
 * is loaded.
 */

if (
    defined('S3_UPLOADS_BUCKET') &&
    S3_UPLOADS_BUCKET &&
    getenv('WP_ENVIRONMENT_TYPE') !== 'local'
) {
    add_filter(
        'pre_site_option_document_upload_directory',
        fn () => 's3://' . S3_UPLOADS_BUCKET . '/uploads/sites/%site_id%'
    );
}
