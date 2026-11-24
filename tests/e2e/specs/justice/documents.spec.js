const { test, expect } = require("../../support/test");

// The Civil page links three WP Document Revisions documents, as the live page
// does under "Practice direction updates". The seed generates their files; see
// seed/documents.php and seed/content/justice/content.json.
const documents = [
  { label: "PD Making Document", format: "PDF", type: "application/pdf", magic: "%PDF-" },
  {
    label: "CPR e-mail address list",
    format: "DOCX",
    type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    magic: "PK",
  },
  {
    label: "destination table",
    format: "XLSX",
    type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    magic: "PK",
  },
];

test("document links show their format and size", async ({ page }) => {
  await page.goto("courts/procedure-rules/civil/");

  const links = page.locator(".rich-text a.file-download");
  await expect(links).toHaveCount(documents.length);
  for (const [i, { label, format }] of documents.entries()) {
    await expect(links.nth(i)).toHaveText(new RegExp(`${label} \\(${format}, \\d+ K?B\\)$`));
  }
  // The theme drops the "(PDF)" an editor typed after the link, as the link
  // now says it.
  const pdfItem = page.locator(".rich-text li").filter({ has: page.locator("a.file-download") }).first();
  await expect(pdfItem).toContainText(`${documents[0].label} (PDF,`);
  await expect(pdfItem).not.toContainText("(PDF)");
});

test("documents download without logging in", async ({ page, request }) => {
  await page.goto("courts/procedure-rules/civil/");

  for (const { label, type, magic } of documents) {
    // Read from the page, so the test follows whatever permalink WPDR gives.
    const href = await page.locator("a.file-download", { hasText: label }).getAttribute("href");
    expect(href, label).toMatch(/\/documents\/[a-z0-9-]+\.(pdf|docx|xlsx)$/);

    const response = await request.get(href);
    expect(response.status(), href).toBe(200);
    expect(response.headers()["content-type"], href).toContain(type);
    expect((await response.body()).subarray(0, magic.length).toString("latin1"), href).toBe(magic);
  }
});
