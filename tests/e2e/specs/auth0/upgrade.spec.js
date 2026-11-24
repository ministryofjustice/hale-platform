// A site that activated the Auth0 plugin before the upgrade from 4.x
// (auth0-legacy in seed.sh): its active plugins still list the 4.x main file,
// auth0/WP_Auth0.php. From 5.x the file is auth0/wpAuth0.php, and WordPress
// skips a listed plugin whose file is missing, so without opt/php/auth0.php
// the plugin would be off and the login page the WordPress password form.

const { test, expect } = require("../../support/test");
const { LOGIN_PATH } = require("../../support/stack");
const { AUTHORIZE_URL, auth0Sites, identities, signInAtAuth0 } = require("../../support/auth0");

const { legacy } = auth0Sites;

test("signing in works on a site activated before the upgrade from 4.x", async ({ page }) => {
  await page.goto(`${legacy.url}${LOGIN_PATH}`);
  await expect(page).toHaveURL(AUTHORIZE_URL);

  await signInAtAuth0(page, identities.editor);

  await expect(page).toHaveURL(legacy.url);
  await expect(page.locator("#wpadminbar")).toBeVisible();
  await page.goto(`${legacy.url}wp-admin/`);
  await expect(page.locator("#wpbody h1")).toHaveText("Dashboard");
});
