const { test, expect } = require("../../support/test");
const { authFile, sites } = require("../../support/stack");
const { auth0Sites } = require("../../support/auth0");

test.use({ storageState: authFile("admin") });

test("network admin can see every test site", async ({ page }) => {
  await page.goto("wp-admin/network/sites.php");

  const rows = page.locator("#the-list tr");
  // sites.json, plus the sites seed.sh makes for the Auth0 login tests.
  await expect(rows).toHaveCount(sites.length + Object.keys(auth0Sites).length);
  // The list shows each site as host/path, with no scheme or trailing slash.
  for (const site of sites.filter((s) => s.path)) {
    const { host } = new URL(site.url);
    await expect(page.locator("#the-list")).toContainText(`${host}/${site.path}`);
  }
});
