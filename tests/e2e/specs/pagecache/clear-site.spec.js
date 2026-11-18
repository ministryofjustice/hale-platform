// Settings, Cache: a site administrator clears every cached page of their own
// site, and only theirs (hale-components inc/pagecache-controller.php). On the
// main site, whose path "/" is the start of every subsite's path, the
// subsites' pages must stay cached.

const { test, expect } = require("../../support/test");
const { authFile, sites } = require("../../support/stack");
const { visitor, fetchPage, warm, expectRendered, expectCacheEnabled, Pages } = require("../../support/pagecache");

const SETTINGS_PAGE = "wp-admin/options-general.php?page=hale-cache-settings";

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

// The button asks for confirmation first, in a confirm() dialog.
async function clearSiteCache(page, site) {
  await page.goto(`${site.url}${SETTINGS_PAGE}`);
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByRole("button", { name: "Clear cache for this site" }).click();
  await expect(
    page.locator(".notice-success", { hasText: /Cache cleared: \d+ entr(y|ies) removed for this site\./ }),
  ).toBeVisible();
}

const [main, sub] = [sites[0], sites[1]];

for (const [cleared, other] of [[main, sub], [sub, main]]) {
  test(`clearing ${cleared.key}'s cache leaves ${other.key}'s cached`, async ({ page }) => {
    const clearedPages = [await pages.create(cleared), await pages.create(cleared)];
    const otherPage = await pages.create(other);
    for (const { link } of [...clearedPages, otherPage]) await warm(api, link);

    await clearSiteCache(page, cleared);

    for (const { link } of clearedPages) await expectRendered(api, link);
    expect((await fetchPage(api, otherPage.link)).cache).toBe("HIT");
  });
}

test("cancelling the confirmation clears nothing", async ({ page }) => {
  const created = await pages.create(main);
  await warm(api, created.link);

  await page.goto(`${main.url}${SETTINGS_PAGE}`);
  page.once("dialog", (dialog) => dialog.dismiss());
  await page.getByRole("button", { name: "Clear cache for this site" }).click();

  expect((await fetchPage(api, created.link)).cache).toBe("HIT");
});

test.describe("as an editor", () => {
  // WordPress refuses the page with a 403, which the browser logs as an error.
  test.use({ storageState: authFile("editor"), ignoreConsoleErrors: true });

  test("an editor cannot open the cache settings", async ({ page }) => {
    const response = await page.goto(`${main.url}${SETTINGS_PAGE}`);
    expect(response.status()).toBe(403);
    await expect(page.getByRole("button", { name: "Clear cache for this site" })).toHaveCount(0);
  });
});
