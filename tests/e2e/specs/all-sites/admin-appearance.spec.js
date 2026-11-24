const { test, expect } = require("../../support/test");
const { authFile } = require("../../support/stack");

// The network admin is a super admin on every site, so one login covers all of them.
test.use({ storageState: authFile("admin") });

test("the theme Customizer loads with its preview", async ({ page }) => {
  const response = await page.goto("wp-admin/customize.php");
  expect(response?.status()).toBe(200);

  // The controls panel, and the site's own front end inside the preview frame.
  await expect(page.locator("#customize-controls")).toBeVisible();
  await expect(page.locator("#customize-preview iframe")).toBeAttached();
  await page.waitForFunction(() => window.wp?.customize?.state?.("previewerAlive")?.get());
  await expect(page.locator("#customize-info .preview-notice")).toContainText("You are customizing");
});

// The themes whose templates the Site Editor can open. The others (ppo,
// justice) are classic themes with no support for it, and WordPress says so.
const SITE_EDITOR_THEMES = ["hale", "govwind"];

test("the Site Editor loads, or says the theme does not support it", async ({ page, site }) => {
  const response = await page.goto("wp-admin/site-editor.php");
  expect(response?.status()).toBe(200);

  await page.waitForFunction(() => window.wp?.data?.select("core/edit-site"));

  if (!SITE_EDITOR_THEMES.includes(site.theme)) {
    await expect(page.getByText("The theme you are currently using does not support this screen.").first()).toBeVisible();
    return;
  }

  // A dialog (such as a welcome guide) can open once the editor is up.
  await page.addLocatorHandler(page.getByRole("dialog"), async () => {
    await page.keyboard.press("Escape");
  });
  await expect(page.locator(".edit-site-layout")).toBeVisible();
  // The sidebar lists the design areas; Patterns is in it for every supported theme.
  await expect(page.getByRole("button", { name: "Patterns" }).first()).toBeVisible();
});
