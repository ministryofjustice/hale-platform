<?php

/**
 * Search Term Limit
 *
 * Caps the two Relevanssi Premium search operators that add a subquery each
 * time they are used, so one search cannot build an unbounded query.
 *
 * - Every "+word" (required word) adds
 *   `AND doc IN (SELECT DISTINCT(doc) FROM <prefix>relevanssi WHERE term = 'word')`.
 *   MariaDB turns each one into another table in the join. With a few dozen
 *   of them the optimizer can spend hours choosing a join order before it
 *   reads a single row.
 * - Every quoted phrase adds a subquery that searches post content, titles,
 *   taxonomy terms and custom fields with LIKE '%phrase%', which cannot use
 *   an index.
 *
 * Words past the limits stay in the search as ordinary words, so they still
 * count towards results; they are just no longer required or matched as a
 * phrase:
 * - "+" is removed from single letters, repeated words and every "+word"
 *   after the first $max_required.
 * - Quote marks after the first $max_phrases pairs are removed.
 *   Relevanssi needs two quote marks per phrase, so this caps phrases however
 *   the quotes are arranged.
 *
 * Runs on relevanssi_modify_wp_query, which fires for front-end and live
 * (AJAX) searches just before Relevanssi reads the search string.
 */

add_filter('relevanssi_modify_wp_query', function ($query) {
    $search = $query->query_vars['s'] ?? '';
    if (!is_string($search) || trim($search) === '') {
        return $query;
    }

    $max_required = 5;
    $max_phrases = 3;

    // Query vars are slashed, so a quote can arrive as \". Relevanssi also
    // treats the iOS quotes as phrase quotes.
    $quotes = 0;
    $limited = preg_replace_callback(
        '/\\\\?"|[“”„]/u',
        function ($match) use (&$quotes, $max_phrases) {
            return ++$quotes <= 2 * $max_phrases ? $match[0] : '';
        },
        $search
    );

    $required = [];
    $words = preg_split('/\s+/', trim($limited), -1, PREG_SPLIT_NO_EMPTY);

    foreach ($words as $i => $word) {
        if (!str_starts_with($word, '+')) {
            continue;
        }
        // ltrim, not substr: "++word" left as "+word" would still be required.
        $plain = ltrim($word, '+');
        $term = mb_strtolower($plain);
        if (mb_strlen($term) < 2 || isset($required[$term]) || count($required) >= $max_required) {
            $words[$i] = $plain;
            continue;
        }
        $required[$term] = true;
    }

    $limited = implode(' ', array_filter($words, fn ($word) => $word !== ''));

    // Leave ordinary searches exactly as typed.
    if ($limited !== preg_replace('/\s+/', ' ', trim($search))) {
        $query->query_vars['s'] = $limited;
    }

    return $query;
});
