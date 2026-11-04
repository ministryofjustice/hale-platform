// The Auth0 plugin on a site where its activation hook never ran
// (auth0-network in seed.sh). That is every site but one when the plugin is
// network-activated: WordPress runs the hook once, on the site the network
// admin activated it from. Anything the plugin only sets up on activation is
// missing on these sites.

const { test, expect } = require("../../support/test");
const { LOGIN_PATH } = require("../../support/stack");
const { AUTHORIZE_URL, auth0Sites, identities, signInAtAuth0 } = require("../../support/auth0");

const { network } = auth0Sites;

test("signing in works on a site the plugin was not activated on", async ({ page }) => {
  await page.goto(`${network.url}${LOGIN_PATH}`);
  await expect(page).toHaveURL(AUTHORIZE_URL);

  await signInAtAuth0(page, identities.editor);

  await expect(page).toHaveURL(network.url);
  await expect(page.locator("#wpadminbar")).toBeVisible();
  await page.goto(`${network.url}wp-admin/`);
  await expect(page.locator("#wpbody h1")).toHaveText("Dashboard");
});
