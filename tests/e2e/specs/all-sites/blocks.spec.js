const { test, expect } = require("../../support/test");

test("seeded reveal block opens to show its content", async ({ page, site }) => {
  // The justice theme allows only its own short list of blocks
  // (justice/inc/block-editor.php), so it has no blocks page.
  test.skip(!site.customBlocks, `${site.theme} does not support the website-builder-blocks blocks`);

  await page.goto("blocks/");

  const reveal = page.locator(".wb-blocks-reveal");
  const content = reveal.getByText("Seeded reveal content for end-to-end tests.");

  await expect(content).toBeHidden();
  await reveal.getByText("What happens next").click();
  await expect(content).toBeVisible();
});
