// What the page cache stores and serves, on every site: a published page is
// rendered once, then served from Redis to visitors who are not signed in;
// anything personal or dynamic goes to WordPress every time.

const { test, expect } = require("../../support/test");
const { authFile, sites } = require("../../support/stack");
const { visitor, fetchPage, warm, expectCacheEnabled, Pages } = require("../../support/pagecache");

test.use({ storageState: authFile("editor") });

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

for (const site of sites) {
  test(`${site.key}: a published page is rendered once, then served from the cache`, async () => {
    const created = await pages.create(site);

    const first = await fetchPage(api, created.link);
    expect(first.status).toBe(200);
    expect(first.cache).toBe("MISS");
    expect(first.body).toContain(created.marker);

    await warm(api, created.link);
    const hit = await fetchPage(api, created.link);
    expect(hit.status).toBe(200);
    expect(hit.body).toBe(first.body);
  });
}

test("a page served from the cache works in a browser", async ({ browser }) => {
  const created = await pages.create(sites[0]);
  await warm(api, created.link);

  // Signed out: browser.newContext() takes the spec's storageState otherwise.
  const context = await browser.newContext({ ignoreHTTPSErrors: true, storageState: { cookies: [], origins: [] } });
  const page = await context.newPage();
  const response = await page.goto(created.link);
  expect(response.headers()["x-page-cache"]).toBe("HIT");
  expect(response.headers()["content-type"]).toContain("text/html");
  await expect(page.getByRole("heading", { level: 1, name: `Page cache ${created.marker}` })).toBeVisible();
  await context.close();
});

test.describe("signed in", () => {
  // No console check: the hale theme's stylesheet asks for
  // /assets/images/govuk-crest.svg (govuk-frontend's footer crest), which is a
  // 404. This spec is about the cache, not the page's assets.
  test.use({ ignoreConsoleErrors: true });

  test("a signed-in user always gets the page from WordPress", async ({ page }) => {
    const created = await pages.create(sites[0]);
    await warm(api, created.link);

    const response = await page.goto(created.link);
    expect(response.headers()["x-page-cache"]).toBe("BYPASS");
    await expect(page.locator("#wpadminbar")).toBeVisible();
  });
});

test("a page with a query string is not served from the cache", async () => {
  const created = await pages.create(sites[0]);
  await warm(api, created.link);

  const withQuery = await fetchPage(api, `${created.link}?pagecache=1`);
  expect(withQuery.status).toBe(200);
  expect(withQuery.cache).toBe("BYPASS");
});

test("a page that is not found is not cached", async () => {
  const url = `${sites[0].url}pagecache-not-found-${Date.now()}/`;
  for (let i = 0; i < 2; i++) {
    const missing = await fetchPage(api, url);
    expect(missing.status).toBe(404);
    expect(missing.cache).toBe("BYPASS");
  }
});

test("the REST API is not cached", async () => {
  for (let i = 0; i < 2; i++) {
    const rest = await fetchPage(api, `${sites[0].url}wp-json/`);
    expect(rest.status).toBe(200);
    expect(rest.cache).toBe("BYPASS");
  }
});
