// A browser that still has a WordPress login cookie WordPress no longer
// accepts: one from before the upgrade whose session has gone, or one kept
// past its expiry by a browser that restores the last session. The login page
// sends them to Auth0, and Auth0, which still has its own session, signs them
// straight back in. That has to work: the person should not have to clear
// their cookies first. (Logged out, wp-admin/ is a 404: WPS Hide Login keeps
// the login page's address hidden, so people sign in from the login page.)

const { test, expect } = require("../../support/test");
const { LOGIN_PATH } = require("../../support/stack");
const { auth0Sites, identities, signInAtAuth0 } = require("../../support/auth0");

const { main } = auth0Sites;

// WordPress's login cookies hold user|expiration|token|hmac, URL-encoded.
const edit = (change) => (value) => encodeURIComponent(change(decodeURIComponent(value).split("|")).join("|"));

for (const [label, stale] of [
  ["a hash that does not match", edit(([user, expiration, token]) => [user, expiration, token, "0".repeat(64)])],
  ["an expiry in the past", edit(([user, , token, hmac]) => [user, "1", token, hmac])],
  ["a malformed value", () => "stale"],
]) {
  test(`Auth0 signs in again over a WordPress login cookie with ${label}`, async ({ page }) => {
    await page.goto(LOGIN_PATH);
    await signInAtAuth0(page, identities.editor);
    await expect(page.locator("#wpadminbar")).toBeVisible();

    const context = page.context();
    const cookies = (await context.cookies()).filter((cookie) => /^wordpress_(logged_in|sec)_/.test(cookie.name));
    expect(cookies.length).toBeGreaterThan(0);
    await context.addCookies(cookies.map((cookie) => ({ ...cookie, value: stale(cookie.value) })));

    await page.goto(LOGIN_PATH);

    await expect(page).toHaveURL(main.url);
    await expect(page.locator("#wpadminbar")).toBeVisible();
    await page.goto("wp-admin/");
    await expect(page.locator("#wpbody h1")).toHaveText("Dashboard");
    await expect(page.locator("#wp-admin-bar-my-account")).toContainText("E2E editor");
  });
}
