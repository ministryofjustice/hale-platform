// The network dashboard's "Clear page cache on all sites": a network
// administrator clears every cached page on every site at once, by bumping
// the cache version (hale-components inc/pagecache-controller.php).

const { test, expect } = require("../../support/test");
const { authFile, sites } = require("../../support/stack");
const { visitor, fetchPage, warm, expectRendered, expectCacheEnabled, Pages } = require("../../support/pagecache");

const DASHBOARD = "wp-admin/network/settings.php?page=hale-components-network-dashboard";

test.use({ storageState: authFile("admin") });

test.beforeAll(() => expectCacheEnabled(sites[0].url));

let pages;
let api;
test.beforeEach(async ({ page }) => {
  pages = new Pages(page);
  api = await visitor();
});
test.afterEach(async () => {
  await api.dispose();
  await pages.cleanup();
});

async function cacheVersion(page) {
  const text = await page.getByText(/Cache version: \d+\./).textContent();
  return Number(text.match(/Cache version: (\d+)\./)[1]);
}

test("clearing the cache on all sites clears every site's pages", async ({ page }) => {
  const created = [];
  for (const site of sites) created.push(await pages.create(site));
  for (const { link } of created) await warm(api, link);

  await page.goto(DASHBOARD);
  const before = await cacheVersion(page);
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByRole("button", { name: "Clear page cache on all sites" }).click();
  await expect(page.getByText("Page cache cleared on all sites.")).toBeVisible();
  expect(await cacheVersion(page)).toBe(before + 1);

  for (const { link } of created) await expectRendered(api, link);
  // And the cache fills again.
  for (const { link } of created) await warm(api, link);
});

test("cancelling the confirmation clears nothing", async ({ page }) => {
  const created = await pages.create(sites[0]);
  await warm(api, created.link);

  await page.goto(DASHBOARD);
  const before = await cacheVersion(page);
  page.once("dialog", (dialog) => dialog.dismiss());
  await page.getByRole("button", { name: "Clear page cache on all sites" }).click();

  await page.reload();
  expect(await cacheVersion(page)).toBe(before);
  expect((await fetchPage(api, created.link)).cache).toBe("HIT");
});
