// Signing in and out through Auth0, on the sites seed.sh activates the Auth0
// plugin on, against the mock tenant (auth0-mock/server.js). Every test starts
// with a fresh browser: no saved WordPress login and no tenant session.
//
// The assertions are about what a person sees, not how the plugin gets there,
// so they hold for any version of the plugin that keeps the same behaviour.
// specs/auth0-requests/ checks what it sends the tenant.

const { test, expect } = require("../../support/test");
const { LOGIN_PATH } = require("../../support/stack");
const {
  AUTH0_DOMAIN,
  AUTHORIZE_URL,
  CLIENT_ID,
  auth0Sites,
  identities,
  signInAtAuth0,
} = require("../../support/auth0");

const { main, second } = auth0Sites;

test("the login page sends people to Auth0, which signs them in", async ({ page }) => {
  await page.goto(LOGIN_PATH);

  await expect(page).toHaveURL(AUTHORIZE_URL);
  const authorize = new URL(page.url()).searchParams;
  expect(authorize.get("client_id")).toBe(CLIENT_ID);
  expect(authorize.get("response_type")).toBe("code");
  expect(authorize.get("state")).toBeTruthy();
  // Back to the site the person started on, wherever on it the plugin listens.
  expect(authorize.get("redirect_uri")).toMatch(new RegExp(`^${main.url}`));

  await signInAtAuth0(page, identities.editor);

  // The home page of the site they signed in on, logged in.
  await expect(page).toHaveURL(main.url);
  await expect(page.locator("#wpadminbar")).toBeVisible();

  await page.goto("wp-admin/");
  await expect(page.locator("#wpbody h1")).toHaveText("Dashboard");
  await expect(page.locator("#wp-admin-bar-my-account")).toContainText("E2E editor");
});

test("a second sign-in uses the Auth0 session without the login form", async ({ page }) => {
  await page.goto(LOGIN_PATH);
  await signInAtAuth0(page, identities.author);
  await expect(page.locator("#wpadminbar")).toBeVisible();

  // Signed out of WordPress only: the tenant session is still there.
  await page.context().clearCookies({ domain: new URL(main.url).hostname });
  await page.goto(main.url);
  await expect(page.locator("#wpadminbar")).toHaveCount(0);

  await page.goto(LOGIN_PATH);
  await expect(page).toHaveURL(main.url);
  await expect(page.locator("#wp-admin-bar-my-account")).toContainText("E2E author");
});

test("signing in on one Auth0 site also signs in on another on the same domain", async ({ page }) => {
  await page.goto(LOGIN_PATH);
  await signInAtAuth0(page, identities.editor);
  await expect(page.locator("#wpadminbar")).toBeVisible();

  await page.goto(second.url);
  await expect(page.locator("#wpadminbar")).toBeVisible();

  await page.goto(`${second.url}wp-admin/`);
  await expect(page.locator("#wpbody h1")).toHaveText("Dashboard");

  // And the first site still has them.
  await page.goto(main.url);
  await expect(page.locator("#wpadminbar")).toBeVisible();
});

test("logging out ends the WordPress and the Auth0 session", async ({ page }) => {
  await page.goto(LOGIN_PATH);
  await signInAtAuth0(page, identities.editor);
  await expect(page.locator("#wpadminbar")).toBeVisible();

  // The admin bar's own Log Out link, nonce included.
  const logout = await page.locator("#wp-admin-bar-logout a").getAttribute("href");
  expect(logout).toBeTruthy();
  await page.goto(logout);

  // Back on the site, logged out.
  await expect(page).toHaveURL(main.url);
  await expect(page.locator("#wpadminbar")).toHaveCount(0);

  // The tenant session is gone too: the next login asks again.
  await page.goto(LOGIN_PATH);
  await expect(page).toHaveURL(AUTHORIZE_URL);
  await expect(page.getByRole("heading", { name: "Log in" })).toBeVisible();
  expect(new URL(page.url()).hostname).toBe(AUTH0_DOMAIN);
});

test("a logout link without WordPress's nonce does not log anyone out", async ({ page, context }) => {
  await page.goto(LOGIN_PATH);
  await signInAtAuth0(page, identities.editor);
  await expect(page.locator("#wpadminbar")).toBeVisible();

  // What a link or image on another site could point the browser at. Without
  // the nonce WordPress asks the person to confirm instead of logging out.
  await page.goto(`${LOGIN_PATH}?action=logout`);

  await page.goto(main.url);
  await expect(page.locator("#wpadminbar")).toBeVisible();
  // Nor did it go to the tenant to end the Auth0 session.
  const tenantSession = (await context.cookies(`https://${AUTH0_DOMAIN}/`)).find(
    (cookie) => cookie.name === "auth0_mock_session",
  );
  expect(tenantSession).toBeTruthy();
});
