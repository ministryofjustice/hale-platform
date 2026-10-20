const { test, expect } = require("../../support/test");
const { authFile } = require("../../support/stack");

test.use({ storageState: authFile("editor") });

test("editor publishes a page with a reveal block", async ({ page }) => {
  const title = `Editor reveal ${Date.now()}`;

  await page.goto("wp-admin/post-new.php?post_type=page");
  await page.waitForFunction(() => window.wp?.data?.select("core/editor")?.getCurrentPostId());

  // A new user gets the welcome guide, and a new page may offer patterns.
  // Either can open a moment after the editor loads, so Playwright closes any
  // dialog whenever one is in the way of the next action.
  await page.evaluate(() => {
    window.wp.data.dispatch("core/preferences").set("core/edit-post", "welcomeGuide", false);
  });
  await page.addLocatorHandler(page.getByRole("dialog"), async () => {
    await page.keyboard.press("Escape");
  });

  // The block an editor on a hale site can insert: the theme's allow-list
  // (hale/inc/restrict-blocks.php) has mojblocks/reveal, not wb-blocks/reveal,
  // and the editor silently drops a block it does not allow.
  const block = "mojblocks/reveal";
  expect(
    await page.evaluate((name) => window.wp.data.select("core/block-editor").canInsertBlockType(name), block),
    `${block} is not allowed in the hale editor`,
  ).toBe(true);

  // Content goes in through the editor's own data API: the block's editing UI
  // is not what this test is about.
  await page.evaluate(
    ({ pageTitle, name }) => {
      const { dispatch } = window.wp.data;
      const { createBlock } = window.wp.blocks;
      dispatch("core/editor").editPost({ title: pageTitle });
      dispatch("core/block-editor").insertBlocks(
        createBlock(name, { revealTitle: "Added by the editor test" }, [
          createBlock("core/paragraph", { content: "Revealed text from the editor test." }),
        ]),
      );
    },
    { pageTitle: title, name: block },
  );

  // Publish the way an editor does: the toolbar button, then the confirm panel.
  await page.getByRole("region", { name: "Editor top bar" }).getByRole("button", { name: "Publish" }).click();
  await page
    .getByRole("region", { name: "Editor publish" })
    .getByRole("button", { name: "Publish", exact: true })
    .click();
  await expect(page.getByRole("region", { name: "Editor publish" }).getByText("is now live")).toBeVisible();

  const permalink = await page.evaluate(() => window.wp.data.select("core/editor").getPermalink());
  await page.goto(permalink);

  await expect(page.getByRole("heading", { level: 1, name: title })).toBeVisible();
  const reveal = page.locator(".mojblocks-reveal");
  const content = reveal.getByText("Revealed text from the editor test.");

  await expect(content).toBeHidden();
  await reveal.getByText("Added by the editor test").click();
  await expect(content).toBeVisible();
});
