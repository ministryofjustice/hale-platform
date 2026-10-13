const { test, expect } = require("../../support/test");

test("homepage renders with the site's theme", async ({ page, site }) => {
  const response = await page.goto("./");

  expect(response?.status()).toBe(200);
  await expect(page).toHaveTitle(new RegExp(site.title));
  // The theme's own CSS or JavaScript is on the page.
  await expect(
    page.locator(`link[href*="/themes/${site.theme}/"], script[src*="/themes/${site.theme}/"]`).first(),
  ).toBeAttached();
});
