// The login page's address is kept secret (WPS Hide Login, LOGIN_PATH here):
// nobody who has not been given it should be able to find it. Each of these
// addresses is one a visitor could try. None may answer with the address, in
// a redirect (to the site, or to Auth0 as the callback address) or in a page.
// Redirects are followed on the test network only.

const { request: newRequest } = require("@playwright/test");
const { test, expect } = require("../../support/test");
const { LOGIN_PATH, NETWORK_URL } = require("../../support/stack");
const { auth0Sites, identities, signInAtAuth0 } = require("../../support/auth0");

const SLUG = LOGIN_PATH.replace(/\/$/, "");
const MAX_HOPS = 8;

// Relative to each site's address.
const PROBES = [
  "", "wp-admin", "wp-admin/", "wp-admin/index.php", "wp-admin/profile.php",
  "wp-admin/options.php", "wp-admin/options-general.php", "wp-admin/network/",
  "wp-admin/customize.php", "wp-admin/admin-post.php", "wp-admin/admin-ajax.php",
  "wp-admin/?interim-login=1", "wp-admin/post-new.php",
  "wp-login.php", "wp-login.php?action=logout", "wp-login.php?action=lostpassword",
  "wp-login.php?action=register", "wp-login.php?action=rp", "wp-login.php?action=resetpass",
  "wp-login.php?action=entered_recovery_mode", "wp-login.php?action=postpass",
  "wp-login.php?interim-login=1", "wp-login", "wp-login/",
  "login", "login/", "admin", "admin/", "dashboard", "dashboard/",
  "wp-signup.php", "wp-activate.php", "wp-register.php",
  "?auth0=1", "index.php?auth0=1", "?code=x&state=y", "?error=access_denied&state=y",
  "?auth0_bcl=", "?action=logout", "?redirect_to=wp-admin%2F",
  "wp-json/", "wp-json/wp/v2/users", "xmlrpc.php", "feed/", "comments/feed/",
  "wp-sitemap.xml", "robots.txt", "this-page-does-not-exist/",
];

// A private site (wp-force-login) sends every visitor to the login page, so
// its address is not secret there: known, and expected to fail until changed.
const SITES = [
  ["the network's main site", NETWORK_URL],
  ["an Auth0 site", auth0Sites.main.url],
  ["a private Auth0 site", auth0Sites.private.url, "wp-force-login sends visitors to the login page"],
];

// Every place the address turns up on the way: the URL and the headers of
// each response, and the body of the last one.
async function leaks(api, url, headers = {}) {
  const found = [];
  for (let hop = 0; hop < MAX_HOPS; hop++) {
    const response = await api.get(url, { maxRedirects: 0, failOnStatusCode: false, headers });
    for (const [name, value] of Object.entries(response.headers())) {
      if (decodeURIComponent(value).includes(SLUG)) found.push(`${url} -> ${response.status()} ${name}: ${value}`);
    }
    const location = response.headers().location;
    if (!location) {
      if ((await response.text()).includes(SLUG)) found.push(`${url} -> ${response.status()} body`);
      break;
    }
    const next = new URL(location, url).href;
    if (!next.startsWith(NETWORK_URL)) break;
    url = next;
  }
  return found;
}

async function probe(api, base) {
  const found = [];
  for (const path of PROBES) found.push(...(await leaks(api, new URL(path, base).href)));

  // wps-hide-login sends wp-login.php to the login page when the referrer is
  // an activation link for an account that is already active.
  found.push(...(await leaks(api, new URL("wp-login.php", base).href, {
    Referer: new URL("wp-activate.php?key=x", base).href,
  })));
  return found;
}

for (const [label, base, knownLeak] of SITES) {
  test(`${label} does not give away the login page's address`, async () => {
    test.fail(Boolean(knownLeak), knownLeak);
    // A fresh client, with no cookies: a visitor who is not signed in.
    const api = await newRequest.newContext({ ignoreHTTPSErrors: true });
    const found = await probe(api, base);
    await api.dispose();

    expect(found).toEqual([]);
  });
}

// The same with a WordPress login cookie that is no longer valid
// (stale-login-cookie.spec.js), as someone signed out by an expired session
// would have.
test("an Auth0 site does not give away the login page's address to a stale login", async ({ page }) => {
  await page.goto(LOGIN_PATH);
  await signInAtAuth0(page, identities.editor);
  await expect(page.locator("#wpadminbar")).toBeVisible();

  const context = page.context();
  const cookies = (await context.cookies()).filter((cookie) => /^wordpress_(logged_in|sec)_/.test(cookie.name));
  await context.addCookies(cookies.map((cookie) => ({ ...cookie, value: "stale" })));

  expect(await probe(page.request, auth0Sites.main.url)).toEqual([]);
});
