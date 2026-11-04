// hale-components' switch user: an administrator acts as another user
// (moj-components/component/Users/UserSwitch.php), on a site where it is on
// (auth0-two in seed.sh). The administrator signed in through Auth0, so the
// Auth0 session stays theirs while WordPress's is the other user's.

const { test, expect } = require("../../support/test");
const { LOGIN_PATH } = require("../../support/stack");
const { auth0Sites, identities, signInAtAuth0 } = require("../../support/auth0");

const { second } = auth0Sites;

test("an administrator can switch to another user and browse as them", async ({ page }) => {
  await page.goto(`${second.url}${LOGIN_PATH}`);
  await signInAtAuth0(page, identities.admin);
  await expect(page.locator("#wp-admin-bar-my-account")).toContainText("e2eadmin");

  // The Switch user link in the editor's row of the Users screen.
  await page.goto(`${second.url}wp-admin/users.php`);
  const row = page.locator("#the-list tr").filter({ hasText: "e2eeditor" });
  await row.getByRole("link", { name: "Switch user" }).click();
  await expect(page.locator("#wp-admin-bar-my-account")).toContainText("E2E editor");

  // Still the editor on the site itself, and back in wp-admin.
  await page.goto(second.url);
  await expect(page.locator("#wp-admin-bar-my-account")).toContainText("E2E editor");
  await page.goto(`${second.url}wp-admin/`);
  await expect(page.locator("#wp-admin-bar-my-account")).toContainText("E2E editor");
});
