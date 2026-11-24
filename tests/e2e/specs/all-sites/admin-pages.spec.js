const { test, expect } = require("../../support/test");
const { authFile } = require("../../support/stack");

// The network admin is a super admin on every site, so one login covers all of them.
test.use({ storageState: authFile("admin") });

// Waits for the block editor to finish loading the post, and keeps the welcome
// guide and pattern pickers out of the way: a new user gets the guide, and a
// new page may offer patterns. Either can open a moment after the editor loads.
async function openEditor(page, url) {
  const response = await page.goto(url);
  expect(response?.status()).toBe(200);
  await page.waitForFunction(() => window.wp?.data?.select("core/editor")?.getCurrentPostId());
  await page.evaluate(() => {
    window.wp.data.dispatch("core/preferences").set("core/edit-post", "welcomeGuide", false);
  });
  await page.addLocatorHandler(page.getByRole("dialog"), async () => {
    await page.keyboard.press("Escape");
  });
}

test("the admin Pages list loads and shows the site's pages", async ({ page }) => {
  const response = await page.goto("wp-admin/edit.php?post_type=page");

  expect(response?.status()).toBe(200);
  await expect(page.getByRole("heading", { name: "Pages", level: 1 })).toBeVisible();
  // At least one page row, so the "No pages found" message does not count.
  await expect(page.locator("#the-list tr.iedit").first()).toBeVisible();
});

test("the Add Page screen loads the block editor", async ({ page }) => {
  await openEditor(page, "wp-admin/post-new.php?post_type=page");

  // A new page: the editor's top bar has the Publish button. The title field
  // is inside the editor's canvas iframe, so the post is read from the editor's
  // data store instead.
  await expect(page.getByRole("region", { name: "Editor top bar" }).getByRole("button", { name: "Publish" })).toBeVisible();
  const post = await page.evaluate(() => {
    const editor = window.wp.data.select("core/editor");
    return { type: editor.getCurrentPostType(), status: editor.getCurrentPost().status };
  });
  expect(post).toEqual({ type: "page", status: "auto-draft" });
});

test("the Edit Page screen loads an existing page in the block editor", async ({ page }) => {
  await page.goto("wp-admin/edit.php?post_type=page");
  // The seeded page's post ID, from the row's id attribute ("post-12").
  const row = page.locator("#the-list tr.iedit").first();
  const id = (await row.getAttribute("id")).replace("post-", "");
  const title = (await row.locator(".row-title").innerText()).trim();

  await openEditor(page, `wp-admin/post.php?post=${id}&action=edit`);

  // The editor holds this page, with its own title, not an empty new page.
  await expect(page.getByRole("region", { name: "Editor top bar" })).toBeVisible();
  const post = await page.evaluate(() => {
    const editor = window.wp.data.select("core/editor");
    return { id: editor.getCurrentPostId(), type: editor.getCurrentPostType(), title: editor.getEditedPostAttribute("title") };
  });
  expect(post).toEqual({ id: Number(id), type: "page", title });
});
