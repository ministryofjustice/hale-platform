<?php

/**
 * Test documents for the end-to-end seed: PDF, DOCX and XLSX files written
 * here, so the repo holds no binary fixtures, and the WP Document Revisions
 * posts that serve them. Required by import-content.php.
 *
 * Each file has the document's title and a few lines of text, and is the same
 * byte for byte on every run.
 */

// Zip entries carry a modification time; a fixed one keeps the files identical.
const E2E_DOCUMENT_MTIME = 1767603600; // 2026-01-05 09:00:00 UTC

/**
 * A one-page PDF 1.4 in Helvetica: the title, then each line.
 */
function e2e_pdf_file(string $title, array $lines): string
{
    // Helvetica with WinAnsiEncoding takes Windows-1252 bytes; \, ( and ) are
    // special inside a PDF string.
    $text = fn (string $s) => '(' . strtr(
        iconv('UTF-8', 'Windows-1252//TRANSLIT', $s),
        ['\\' => '\\\\', '(' => '\\(', ')' => '\\)']
    ) . ')';

    $stream = "BT /F1 18 Tf 56 780 Td {$text($title)} Tj ET\n"
        . "BT /F1 12 Tf 16 TL 56 744 Td\n"
        . implode('', array_map(fn ($line) => "{$text($line)} Tj T*\n", $lines))
        . "ET\n";

    $objects = [
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] '
            . '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
        '<< /Length ' . strlen($stream) . " >>\nstream\n{$stream}endstream",
        "<< /Title {$text($title)} >>",
    ];

    $pdf = "%PDF-1.4\n";
    $offsets = [];
    foreach ($objects as $i => $object) {
        $offsets[] = strlen($pdf);
        $pdf .= ($i + 1) . " 0 obj\n{$object}\nendobj\n";
    }
    $xref = strlen($pdf);
    $pdf .= "xref\n0 " . (count($objects) + 1) . "\n0000000000 65535 f \n";
    foreach ($offsets as $offset) {
        $pdf .= sprintf("%010d 00000 n \n", $offset);
    }
    $pdf .= 'trailer << /Size ' . (count($objects) + 1) . " /Root 1 0 R /Info 6 0 R >>\n"
        . "startxref\n{$xref}\n%%EOF\n";

    $path = wp_tempnam('e2e-document.pdf');
    file_put_contents($path, $pdf);
    return $path;
}

/**
 * Write a zip (the container DOCX and XLSX use) from path => content.
 */
function e2e_zip_file(string $name, array $entries): string
{
    $path = wp_tempnam($name);
    $zip = new ZipArchive();
    if ($zip->open($path, ZipArchive::CREATE | ZipArchive::OVERWRITE) !== true) {
        WP_CLI::error("Could not create {$name}");
    }
    foreach ($entries as $entry => $content) {
        $zip->addFromString($entry, $content);
        $zip->setMtimeName($entry, E2E_DOCUMENT_MTIME);
    }
    $zip->close();
    return $path;
}

/**
 * A Word document: the title as a heading, then a paragraph per line.
 */
function e2e_docx_file(string $title, array $lines): string
{
    $paragraph = fn (string $s, string $style = '') => '<w:p>'
        . ($style ? "<w:pPr><w:pStyle w:val=\"{$style}\"/></w:pPr>" : '')
        . '<w:r><w:t xml:space="preserve">' . esc_xml($s) . '</w:t></w:r></w:p>';

    return e2e_zip_file('e2e-document.docx', [
        '[Content_Types].xml' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            . '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            . '<Default Extension="xml" ContentType="application/xml"/>'
            . '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
            . '</Types>',
        '_rels/.rels' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            . '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
            . '</Relationships>',
        'word/document.xml' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
            . $paragraph($title, 'Heading1')
            . implode('', array_map($paragraph, $lines))
            . '</w:body></w:document>',
    ]);
}

/**
 * An Excel workbook with one sheet: the title in A1, then a row per line.
 */
function e2e_xlsx_file(string $title, array $lines): string
{
    $rows = '';
    foreach ([$title, ...$lines] as $i => $value) {
        $n = $i + 1;
        $rows .= "<row r=\"{$n}\"><c r=\"A{$n}\" t=\"inlineStr\"><is><t>" . esc_xml($value) . '</t></is></c></row>';
    }

    return e2e_zip_file('e2e-document.xlsx', [
        '[Content_Types].xml' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            . '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            . '<Default Extension="xml" ContentType="application/xml"/>'
            . '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
            . '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
            . '</Types>',
        '_rels/.rels' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            . '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
            . '</Relationships>',
        'xl/workbook.xml' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
            . 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            . '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>',
        'xl/_rels/workbook.xml.rels' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            . '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
            . '</Relationships>',
        'xl/worksheets/sheet1.xml' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            . '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            . "<sheetData>{$rows}</sheetData></worksheet>",
    ]);
}

/**
 * Create a published WP Document Revisions document with a generated file.
 *
 * WPDR keeps the file as an attachment whose parent is the document, and
 * finds it from the document's content: <!-- WPDR <attachment ID> -->.
 *
 * @param array $spec type (pdf, docx or xlsx), and optionally title, slug and
 *                    lines of text
 * @return int The document's ID.
 */
function e2e_document(string $name, array $spec, WP_User $author): int
{
    $makers = ['pdf' => 'e2e_pdf_file', 'docx' => 'e2e_docx_file', 'xlsx' => 'e2e_xlsx_file'];
    $type = $spec['type'] ?? '';
    if (!isset($makers[$type])) {
        WP_CLI::error("Document '{$name}': type must be one of " . implode(', ', array_keys($makers)));
    }
    $title = $spec['title'] ?? $name;
    $slug = $spec['slug'] ?? $name;

    $doc_id = wp_insert_post([
        'post_type' => 'document',
        'post_name' => $slug,
        'post_title' => $title,
        'post_status' => 'publish',
        'post_author' => $author->ID,
        'post_date' => '2026-01-05 09:00:00',
    ], true);
    if (is_wp_error($doc_id)) {
        WP_CLI::error("Document '{$name}': " . $doc_id->get_error_message());
    }

    $file = $makers[$type]($title, $spec['lines'] ?? ['A test document made by the end-to-end seed.']);
    // No preview images: making one from a PDF needs Ghostscript.
    add_filter('fallback_intermediate_image_sizes', '__return_empty_array');
    // Multisite allows only the network's upload file types, which leave out
    // documents. The justice theme adds them back when the upload's post_id is
    // a document, as it is for an upload in wp-admin.
    $_REQUEST['post_id'] = $doc_id;
    $attach_id = media_handle_sideload(['name' => "{$slug}.{$type}", 'tmp_name' => $file], $doc_id, $title);
    unset($_REQUEST['post_id']);
    remove_filter('fallback_intermediate_image_sizes', '__return_empty_array');
    if (is_wp_error($attach_id)) {
        WP_CLI::error("Document '{$name}': " . $attach_id->get_error_message());
    }

    // The justice theme's "(PDF, 1 KB)" label reads the size from here.
    $metadata = wp_get_attachment_metadata($attach_id) ?: [];
    $metadata['filesize'] = filesize(get_attached_file($attach_id));
    wp_update_attachment_metadata($attach_id, $metadata);

    $updated = wp_update_post([
        'ID' => $doc_id,
        'post_content' => "<!-- WPDR {$attach_id} -->",
    ], true);
    if (is_wp_error($updated)) {
        WP_CLI::error("Document '{$name}': " . $updated->get_error_message());
    }

    return $doc_id;
}
