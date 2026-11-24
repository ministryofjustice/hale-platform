// Log in once per role and save the session, so specs start logged in with
// test.use({ storageState: authFile("editor") }) instead of filling in the
// login form. Cookies are set on path "/", so one session covers every site.

const { test: setup, expect } = require("@playwright/test");
const { NETWORK_URL, LOGIN_PATH, PASSWORD, users, authFile } = require("./support/stack");
const { setMode } = require("./support/pagecache");

for (const [role, login] of Object.entries(users)) {
  setup(`log in as ${role}`, async ({ page }) => {
    await page.goto(LOGIN_PATH);
    await page.locator("#user_login").fill(login);
    await page.locator("#user_pass").fill(PASSWORD);
    await page.locator("#wp-submit").click();

    // opt/php/load.php sends every login to the home page.
    await expect(page.locator("#wpadminbar")).toBeVisible();
    await page.context().storageState({ path: authFile(role) });
  });
}

// The seed leaves the page cache inactive, and pagecache-off makes it inactive
// again after specs/pagecache/. A run stopped before pagecache-off leaves it
// active on a stack that make test-e2e-run reuses, so every run makes it
// inactive before any spec starts. After the logins: it needs the admin's.
setup("make the page cache inactive", async ({ browser }) => {
  const context = await browser.newContext({
    baseURL: NETWORK_URL,
    ignoreHTTPSErrors: true,
    storageState: authFile("admin"),
  });
  await setMode(await context.newPage(), "inactive");
  await context.close();
});
