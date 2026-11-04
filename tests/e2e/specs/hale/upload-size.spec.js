const { test, expect } = require("../../support/test");
const { authFile } = require("../../support/stack");
const { MB, uploadSettings, uploadFile, syntheticFile, pngOfSize } = require("../../support/uploads");

test.use({ storageState: authFile("editor") });

// The size limit is the same on every site, so it is tested on the main site
// only. It is PHP's upload_max_filesize (opt/php/www.conf), which seed/seed.sh
// matches with the network's fileupload_maxk. nginx and the ingress accept a
// 32MB request, so a file at the limit gets to PHP.
const MAX_BYTES = 30 * MB;

// The stored file is fetched back, to show it arrived whole.
async function expectUploaded(page, file) {
  const result = await uploadFile(page, file, { timeout: 120_000 });
  expect(result.uploaded, result.message).toBe(true);

  const stored = await page.request.get(result.url);
  expect(stored.status()).toBe(200);
  expect((await stored.body()).length, "stored file size").toBe(file.buffer.length);
}

test.describe("upload sizes", () => {
  test.setTimeout(180_000);

  test.beforeEach(async ({ page }) => {
    const { maxBytes } = await uploadSettings(page);
    expect(maxBytes, "upload size limit").toBe(MAX_BYTES);
  });

  test("a very small file uploads", async ({ page }) => {
    const file = await syntheticFile(page, "png");
    test.info().annotations.push({ type: "size", description: `${file.buffer.length} bytes` });
    await expectUploaded(page, file);
  });

  test("a 10MB file uploads", async ({ page }) => {
    await expectUploaded(page, await pngOfSize(page, 10 * MB, "e2e-10mb.png"));
  });

  test("a file of exactly the 30MB limit uploads", async ({ page }) => {
    await expectUploaded(page, await pngOfSize(page, MAX_BYTES, "e2e-30mb.png"));
  });

  test("a file one byte over the limit is refused", async ({ page }) => {
    const result = await uploadFile(page, await pngOfSize(page, MAX_BYTES + 1, "e2e-over-30mb.png"));

    expect(result.uploaded).toBe(false);
    expect(result.message).toContain("exceeds the maximum upload size for this site");
  });
});
