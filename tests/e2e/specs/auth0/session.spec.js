// The WordPress session an Auth0 login leaves behind.
//
// These record the plugin's current settings (its defaults: the seed changes
// none), so an upgrade that changes them fails here and the change can be
// decided on rather than slipped in.

const { test, expect } = require("../../support/test");
const { LOGIN_PATH, NETWORK_URL } = require("../../support/stack");
const { auth0Sites, identities, loggedInCookie, signInAtAuth0 } = require("../../support/auth0");

const { main } = auth0Sites;

const DAY_IN_SECONDS = 24 * 60 * 60;

test("the WordPress login lasts for the browser session", async ({ page, browser }) => {
  await page.goto(LOGIN_PATH);
  await signInAtAuth0(page, identities.editor);
  await expect(page.locator("#wpadminbar")).toBeVisible();

  // Every WordPress login cookie: the logged-in cookie the site reads, and
  // the secure auth cookie wp-admin reads. -1 is a session cookie, which the
  // browser drops when it closes; a "remember me" login sets a date instead.
  const loginCookies = (await page.context().cookies(NETWORK_URL)).filter((cookie) =>
    /^wordpress_(logged_in|sec)_[0-9a-f]+$/.test(cookie.name),
  );
  expect(loginCookies.map((cookie) => cookie.name.replace(/_[0-9a-f]+$/, "")).sort()).toEqual([
    "wordpress_logged_in",
    "wordpress_sec",
  ]);
  for (const cookie of loginCookies) {
    expect(cookie.expires, `${cookie.name} expires`).toBe(-1);
  }

  // WordPress also ends the session itself, at the time written into the
  // cookie (user|expiration|token|hmac): 2 days for a login without
  // "remember me", 14 with it.
  const loggedIn = await loggedInCookie(page.context());
  const expiration = Number(decodeURIComponent(loggedIn.value).split("|")[1]);
  const lifetime = expiration - Date.now() / 1000;
  expect(lifetime).toBeGreaterThan(2 * DAY_IN_SECONDS - 600);
  expect(lifetime).toBeLessThan(2 * DAY_IN_SECONDS + 600);

  // Closing and reopening the browser: keep only the cookies that outlive it.
  // Nothing left may still log the person in.
  const state = await page.context().storageState();
  const reopened = await browser.newContext({
    ignoreHTTPSErrors: true,
    storageState: { ...state, cookies: state.cookies.filter((cookie) => cookie.expires !== -1) },
  });
  try {
    const reopenedPage = await reopened.newPage();
    await reopenedPage.goto(main.url);
    await expect(reopenedPage.locator("body")).toBeVisible();
    await expect(reopenedPage.locator("#wpadminbar")).toHaveCount(0);
  } finally {
    await reopened.close();
  }
});

test("browsing the site keeps the same WordPress session", async ({ page }) => {
  await page.goto(LOGIN_PATH);
  await signInAtAuth0(page, identities.editor);
  await expect(page.locator("#wpadminbar")).toBeVisible();
  const before = await loggedInCookie(page.context());

  for (const path of ["members-area/", "", "members-area/"]) {
    await page.goto(`${main.url}${path}`);
    await expect(page.locator("#wpadminbar")).toBeVisible();
  }

  // The same cookie: page views do not start new WordPress sessions.
  const after = await loggedInCookie(page.context());
  expect(after.value).toBe(before.value);
});
