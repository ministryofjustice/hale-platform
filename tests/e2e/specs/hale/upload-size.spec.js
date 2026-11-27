const { rm, stat } = require("node:fs/promises");
const { test, expect } = require("../../support/test");
const { authFile } = require("../../support/stack");
const { MB, UPLOAD_LIMIT, uploadFile, deleteUploads, syntheticFile, pngOfSize, pngFileOfSize } = require("../../support/uploads");

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

  if(file.buffer) {
    const stored = await page.request.get(result.url);
    expect(stored.status()).toBe(200);
    expect((await stored.body()).length, "stored file size").toBe(file.buffer.length);
  }

  if(!file.buffer) {
    const head = await page.request.fetch(result.url, {
      method: "HEAD",
    });
    expect(head.status()).toBe(200);
    const expectedSize = (await stat(file)).size;
    expect(
      Number(head.headers()["content-length"]),
      "stored file size"
    ).toBe(expectedSize);
  }
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
    const file = await pngFileOfSize(page, UPLOAD_LIMIT, "e2e-at-limit.png");

    try {
      await expectUploaded(page, file);
    } finally {
      await rm(file, { force: true });
    }
  });

  test("a file one byte over the limit is refused", async ({ page }) => {
    const file = await pngFileOfSize(page, UPLOAD_LIMIT + 1, "e2e-over-limit.png");

    try {
      const result = await uploadFile(page, file);
      expect(result.uploaded).toBe(false);
      expect(result.message).toContain("exceeds the maximum upload size for this site");
    } finally {
      await rm(file, { force: true });
    }
  });
});
