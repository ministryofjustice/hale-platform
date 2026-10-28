// Logins Auth0 completes but WordPress must not accept, and logins Auth0
// refuses. None of them may leave the person signed in.

const { test, expect } = require("../../support/test");
const { LOGIN_PATH } = require("../../support/stack");
const {
  AUTH0_DOMAIN,
  auth0Sites,
  identities,
  setAuth0Session,
  signInAtAuth0,
} = require("../../support/auth0");

const { main } = auth0Sites;

test("an error from Auth0 is shown, and nobody is signed in", async ({ page }) => {
  // As when an Auth0 Action or rule denies the login.
  await setAuth0Session(page.context(), {
    ...identities.editor,
    error: "access_denied",
    error_description: "Denied by an Auth0 Action",
  });

  await page.goto(LOGIN_PATH);

  await expect(page.getByText(/There was a problem/)).toBeVisible();
  expect(new URL(page.url()).origin).toBe(new URL(main.url).origin);

  await page.goto(main.url);
  await expect(page.locator("#wpadminbar")).toHaveCount(0);
});

test("an email address Auth0 has not verified does not sign in", async ({ page }) => {
  await page.goto(LOGIN_PATH);
  await signInAtAuth0(page, identities.unverified);
  await page.waitForURL((url) => url.hostname !== AUTH0_DOMAIN);

  await page.goto(main.url);
  await expect(page.locator("#wpadminbar")).toHaveCount(0);
});

test("someone with no WordPress account is not signed in", async ({ page }) => {
  await page.goto(LOGIN_PATH);
  await signInAtAuth0(page, identities.stranger);
  await page.waitForURL((url) => url.hostname !== AUTH0_DOMAIN);

  await page.goto(main.url);
  await expect(page.locator("#wpadminbar")).toHaveCount(0);
});
