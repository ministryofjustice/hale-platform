// A site behind wp-force-login (auth0-private in seed.sh): every page sends a
// logged-out visitor to the login page, which the Auth0 plugin sends on to
// the tenant.

const { test, expect } = require("../../support/test");
const { auth0Sites, identities, signInAtAuth0 } = require("../../support/auth0");

const membersArea = `${auth0Sites.private.url}members-area/`;

test("signing in returns people to the page they asked for", async ({ page }) => {
  await page.goto(membersArea);
  await signInAtAuth0(page, identities.editor);

  await expect(page).toHaveURL(membersArea);
  await expect(page.getByRole("heading", { name: "Members area" })).toBeVisible();
  await expect(page.locator("#wpadminbar")).toBeVisible();
});

test("someone with no WordPress account gets an error page, not a redirect loop", async ({ page }) => {
  await page.goto(membersArea);
  await signInAtAuth0(page, identities.stranger);

  // A page from the site that says the login failed. A loop between the
  // site, the login page and Auth0 ends in the browser's own
  // ERR_TOO_MANY_REDIRECTS page instead.
  await expect(page.getByText(/There was a problem/)).toBeVisible();
  expect(new URL(page.url()).origin).toBe(new URL(auth0Sites.private.url).origin);
  await expect(page.locator("#wpadminbar")).toHaveCount(0);
});
