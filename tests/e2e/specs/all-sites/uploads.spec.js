const { test, expect } = require("../../support/test");
const { authFile } = require("../../support/stack");
const { MB, uploadSettings, uploadFile, syntheticFile, fillerBytes } = require("../../support/uploads");

test.use({ storageState: authFile("editor") });

// The network's type list and size limit are set by seed/seed.sh. The themes
// change the list: hale adds SVG (hale/inc/image-management.php), and justice
// keeps documents out of the Media Library, for WP Document Revisions only
// (justice/inc/documents/documents.php).
const MAX_BYTES = 30 * MB;
const THEME_TYPES = {
  hale: { adds: ["svg", "svgz"] },
  justice: { removes: ["doc", "docx", "pdf", "xls", "xlsx"] },
};

// Types no site may accept: they run on the server or in the visitor's browser.
const NEVER = ["php", "phtml", "phar", "html", "htm", "js", "exe", "sh"];

test("Media Library allows the expected file types, up to 30MB", async ({ page, site }) => {
  const { extensions, maxBytes } = await uploadSettings(page);
  test.info().annotations.push({ type: "allowed types", description: extensions.join(", ") });

  expect(maxBytes, "upload size limit").toBe(MAX_BYTES);
  expect(extensions.filter((ext) => NEVER.includes(ext)), "types no site may accept").toEqual([]);

  const { adds = [], removes = [] } = THEME_TYPES[site.theme] ?? {};
  expect(adds.filter((ext) => !extensions.includes(ext)), `types the ${site.theme} theme adds`).toEqual([]);
  expect(extensions.filter((ext) => removes.includes(ext)), `types the ${site.theme} theme removes`).toEqual([]);
});

test("a synthetic file of every allowed type uploads", async ({ page }) => {
  // About 40 types, one upload each.
  test.setTimeout(240_000);
  const { extensions } = await uploadSettings(page);
  const failed = [];

  for (const ext of extensions) {
    await test.step(ext, async () => {
      const result = await uploadFile(page, await syntheticFile(page, ext));
      if (!result.uploaded) {
        failed.push(`.${ext}: ${result.message}`);
      }
    });
  }

  expect(failed, "allowed types WordPress refused").toEqual([]);
});

test("files that could run code are refused", async ({ page }) => {
  const php = Buffer.from("<?php echo 'e2e upload ran';\n");
  const files = [
    { name: "e2e-script.php", mimeType: "application/x-php", buffer: php },
    { name: "e2e-script.phtml", mimeType: "application/x-php", buffer: php },
    { name: "e2e-page.html", mimeType: "text/html", buffer: Buffer.from("<p>e2e upload</p>\n") },
    { name: "e2e-script.js", mimeType: "text/javascript", buffer: Buffer.from("console.log('e2e upload');\n") },
    { name: "e2e-program.exe", mimeType: "application/octet-stream", buffer: Buffer.concat([Buffer.from("MZ"), fillerBytes(2046)]) },
    // PHP under an image extension: WordPress checks the content, not just the name.
    { name: "e2e-disguised.jpg", mimeType: "image/jpeg", buffer: php },
  ];
  const accepted = [];

  for (const file of files) {
    await test.step(file.name, async () => {
      const result = await uploadFile(page, file);
      if (result.uploaded) {
        accepted.push(`${file.name}: ${result.url}`);
      }
    });
  }

  expect(accepted, "files WordPress should have refused").toEqual([]);
});

// safe-svg accepts SVG on every site, whatever the type list shows, and strips
// scripts from it on upload.
test("an uploaded SVG has its scripts removed", async ({ page }) => {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" onload="console.log('e2e onload')">
  <script>console.log('e2e script')</script>
  <rect width="10" height="10" fill="#1d70b8"/>
</svg>
`;
  const result = await uploadFile(page, { name: "e2e-scripted.svg", mimeType: "image/svg+xml", buffer: Buffer.from(svg) });
  expect(result.uploaded, result.message).toBe(true);

  const stored = await (await page.request.get(result.url)).text();
  expect(stored).toContain("<rect");
  expect(stored).not.toMatch(/<script|onload=/i);
});
