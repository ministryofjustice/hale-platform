const { test, expect } = require("../../support/test");
const { authFile } = require("../../support/stack");
const { MB, UPLOAD_LIMIT, uploadFile, deleteUploads, syntheticFile, pngOfSize } = require("../../support/uploads");

test.use({ storageState: authFile("editor") });
test.afterEach(async ({ page }) => deleteUploads(page));

// The size limit is the same on every site, so it is tested on the main site
// only. specs/all-sites/uploads.spec.js checks the site's limit is
// UPLOAD_LIMIT. Not on BrowserStack: these push about 70MB through its tunnel.
test.skip(!!process.env.BROWSERSTACK_USERNAME, "Large uploads are too slow through the BrowserStack tunnel");

// The stored file is fetched back, to show it arrived whole.
async function expectUploaded(page, file) {
  const result = await uploadFile(page, file, { timeout: 120_000 });
  expect(result.uploaded, result.message).toBe(true);

  const stored = await page.request.get(result.url);
  expect(stored.status()).toBe(200);
  expect((await stored.body()).length, "stored file size").toBe(file.buffer.length);
}

test.describe("upload sizes", () => {
  test.describe.configure({ timeout: 180_000 });

  test("a very small file uploads", async ({ page }) => {
    const file = await syntheticFile(page, "png");
    test.info().annotations.push({ type: "size", description: `${file.buffer.length} bytes` });
    await expectUploaded(page, file);
  });

  test("a 10MB file uploads", async ({ page }) => {
    await expectUploaded(page, await pngOfSize(page, 10 * MB, "e2e-10mb.png"));
  });

  test("a file of exactly the limit uploads", async ({ page }) => {
    await expectUploaded(page, await pngOfSize(page, UPLOAD_LIMIT, "e2e-at-limit.png"));
  });

  test("a file one byte over the limit is refused", async ({ page }) => {
    const result = await uploadFile(page, await pngOfSize(page, UPLOAD_LIMIT + 1, "e2e-over-limit.png"));

    expect(result.uploaded).toBe(false);
    expect(result.message).toContain("exceeds the maximum upload size for this site");
  });
});
