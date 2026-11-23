// Changing a published page clears it from the page cache, so visitors never
// get an old copy. hale-components purges on transition_post_status
// (inc/pagecache-purge.php): the page, its parents and the site's home page.
// The home page is not checked here.

const { test, expect } = require("../../support/test");
const { authFile, sites } = require("../../support/stack");
const { visitor, warm, expectRendered, expectCacheEnabled, Pages } = require("../../support/pagecache");

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

// A subsite as well as the main site, whose path "/" is the start of every
// other site's.
for (const site of [sites[0], sites[1]]) {
  test(`${site.key}: editing a published page clears it from the cache`, async () => {
    const created = await pages.create(site);
    await warm(api, created.link);

    const marker = await pages.edit(created);

    const edited = await expectRendered(api, created.link);
    expect(edited.body).toContain(marker);
    expect(edited.body).not.toContain(`<p>${created.marker}</p>`);
  });
}

test("editing a child page clears its parent from the cache", async () => {
  const parent = await pages.create(sites[0]);
  const child = await pages.create(sites[0], { parent });
  await warm(api, parent.link);

  await pages.edit(child);

  await expectRendered(api, parent.link);
});
