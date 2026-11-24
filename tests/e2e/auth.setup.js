// Log in once per role and save the session, so specs start logged in with
// test.use({ storageState: authFile("editor") }) instead of filling in the
// login form. Cookies are set on path "/", so one session covers every site.

const { test: setup, expect } = require("@playwright/test");
const { LOGIN_PATH, PASSWORD, users, authFile } = require("./support/stack");

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
