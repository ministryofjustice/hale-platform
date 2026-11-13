// The WordPress password login on a site where Auth0 has replaced the login
// form: the login bypass staff use when they sign in with a WordPress
// password. opt/php/auth0.php shows the form when the login page's address
// has the bypass parameter set to the secret, both from the environment
// (test-only values in support/auth0.js).
//
// Skipped on the 4.x plugin: it has its own fixed bypass parameter, which is
// deliberately kept out of this codebase, so the test cannot ask for it.

const { test, expect } = require("../../support/test");
const { LOGIN_PATH, PASSWORD, users } = require("../../support/stack");
const { FALLBACK_PARAM, FALLBACK_SECRET, auth0PluginVersion, auth0Sites } = require("../../support/auth0");

const { main } = auth0Sites;

test("the WordPress password login is still available", async ({ page, request }) => {
  const version = await auth0PluginVersion(request);
  test.skip(version?.startsWith("4."), "The 4.x plugin's own bypass parameter is not in the codebase");

  await page.goto(`${LOGIN_PATH}?${FALLBACK_PARAM}=${FALLBACK_SECRET}`);

  await page.locator("#user_login").fill(users.admin);
  await page.locator("#user_pass").fill(PASSWORD);
  await page.locator("#wp-submit").click();

  await expect(page.locator("#wpadminbar")).toBeVisible();

  // Still signed in on the site and in wp-admin: nothing logs out a session
  // that did not come from Auth0.
  await page.goto(main.url);
  await expect(page.locator("#wpadminbar")).toBeVisible();
  await page.goto("wp-admin/");
  await expect(page.locator("#wpbody h1")).toHaveText("Dashboard");
});
