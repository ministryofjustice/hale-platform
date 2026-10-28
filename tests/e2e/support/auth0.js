// The mock Auth0 tenant and the sites that sign in through it, shared by
// specs/auth0/, specs/auth0-requests/ and playwright.config.js. See "Auth0
// login tests" in README.md.

const { expect } = require("@playwright/test");
const { NETWORK_URL } = require("./stack");

// The tenant's domain and the test application's client ID:
// x-auth0-tenant in docker-compose.test.yml, which WordPress and the mock
// (auth0-mock/server.js) both read.
const AUTH0_DOMAIN = "auth0.e2e.test";
const AUTH0_URL = `https://${AUTH0_DOMAIN}/`;
const CLIENT_ID = "e2e-auth0-client-id";
const CLIENT_SECRET = "e2e-auth0-client-secret-test-only";

// The login bypass: <login page>?<parameter>=<secret> shows the WordPress
// login form on a site that logs in through Auth0. Test-only values:
// AUTH0_ENV_FALLBACK_PARAM and AUTH0_ENV_FALLBACK_SECRET in
// docker-compose.test.yml.
const FALLBACK_PARAM = "e2e_login_bypass";
const FALLBACK_SECRET = "e2e-login-bypass-secret-test-only";

// The mock's session cookie (SESSION_COOKIE in auth0-mock/server.js).
const SESSION_COOKIE = "auth0_mock_session";

// The sites seed.sh activates the Auth0 plugin on. The mock's Allowed
// Callback and Logout URLs (docker-compose.test.yml) list the same paths.
const auth0Site = (path) => ({ path, url: `${NETWORK_URL}${path}/` });
const auth0Sites = {
  // The plugin's default settings.
  main: auth0Site("auth0"),
  // The same, to move between two Auth0 sites on one domain.
  second: auth0Site("auth0-two"),
  // Also wp-force-login: a site that is not public yet.
  private: auth0Site("auth0-private"),
  // The plugin active without its activation hook having run there, as on
  // every site but one when the plugin is network-activated.
  network: auth0Site("auth0-network"),
  // Listed as active by the 4.x plugin's file name (auth0/WP_Auth0.php), as on
  // every site activated before the upgrade.
  legacy: auth0Site("auth0-legacy"),
};

// People who sign in at the tenant. Their email addresses are the seeded
// WordPress users' (seed.sh), so the plugin matches them to those accounts.
// Each has one fixed Auth0 user ID, as a real person would: the plugin links
// a WordPress user to the first Auth0 user ID that signs in as them, and
// refuses a different one afterwards.
const identities = {
  // The network admin.
  admin: { sub: "auth0|e2eadmin", email: "e2eadmin@example.test" },
  // Administrator of the auth0 site only.
  siteAdmin: { sub: "auth0|e2esiteadmin", email: "e2esiteadmin@example.test" },
  editor: { sub: "auth0|e2eeditor", email: "e2eeditor@example.test" },
  author: { sub: "auth0|e2eauthor", email: "e2eauthor@example.test" },
  // A WordPress user's address, but not verified at Auth0. A separate Auth0
  // user from the contributor's own, so it cannot be linked by an earlier test.
  unverified: { sub: "auth0|e2econtributor-unverified", email: "e2econtributor@example.test", email_verified: false },
  // Signs in at Auth0, but has no WordPress account anywhere.
  stranger: { sub: "auth0|e2estranger", email: "e2estranger@example.test" },
};

const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

const AUTHORIZE_URL = new RegExp(`^${escapeRegExp(AUTH0_URL)}authorize\\?`);

// Sign in on the mock tenant's login page, which the page must be heading to.
async function signInAtAuth0(page, identity) {
  await expect(page).toHaveURL(AUTHORIZE_URL);
  await page.getByLabel("Email address", { exact: true }).fill(identity.email);
  await page.getByLabel("Auth0 user ID").fill(identity.sub);
  await page.getByLabel("Email address verified").setChecked(identity.email_verified !== false);
  await page.getByRole("button", { name: "Continue" }).click();
}

// Give the browser a tenant session without the login page, as if the person
// had already signed in at Auth0: the next /authorize signs in as `identity`
// straight away. With `error` set, the tenant returns that error instead, as
// it does when an Action or a rule denies the login.
async function setAuth0Session(context, identity) {
  await context.addCookies([
    {
      name: SESSION_COOKIE,
      value: Buffer.from(JSON.stringify(identity)).toString("base64url"),
      domain: AUTH0_DOMAIN,
      path: "/",
      secure: true,
      httpOnly: true,
      sameSite: "Lax",
    },
  ]);
}

// WordPress's logged-in cookie for the test network, or undefined.
async function loggedInCookie(context) {
  return (await context.cookies(NETWORK_URL)).find((cookie) => cookie.name.startsWith("wordpress_logged_in_"));
}

// The version of the Auth0 plugin the test sites run, which they send in a
// header (seed/mu-plugins/e2e-auth0-mock.php). For anything that differs by
// version on purpose.
async function auth0PluginVersion(request) {
  return (await request.get(auth0Sites.main.url)).headers()["x-e2e-auth0-plugin"];
}

// Every request the mock tenant has recorded since the stack started.
async function tenantRequests(request) {
  const response = await request.get(`${AUTH0_URL}__test/requests`);
  expect(response.ok()).toBe(true);
  return (await response.json()).requests;
}

// ---------------------------------------------------------------------------
// Request shapes
//
// What the plugin sends the tenant, without the values that change on every
// request: one entry for each distinct kind of request, sorted. Random values
// (state, nonce, code...) become <random>, the client's credentials
// <client_id> and <client_secret>, a test site's address {site} and the
// tenant's {tenant}/. Everything else is kept as sent.
// ---------------------------------------------------------------------------

const RANDOM_PARAMS = new Set([
  "state", "nonce", "code", "code_challenge", "code_verifier",
  "refresh_token", "id_token_hint", "logout_token", "login_hint",
]);

// The longest paths first, so auth0 does not match the start of auth0-two.
const SITE_URL = new RegExp(
  `^${escapeRegExp(NETWORK_URL)}(?:${Object.values(auth0Sites)
    .map((site) => escapeRegExp(site.path))
    .sort((a, b) => b.length - a.length)
    .join("|")})(?=/|\\?|$)`,
);

function normaliseValue(key, value) {
  if (typeof value !== "string") return value;
  if (RANDOM_PARAMS.has(key)) return "<random>";
  if (key === "client_id") return value === CLIENT_ID ? "<client_id>" : value;
  if (key === "client_secret") return "<client_secret>";
  return value.replace(SITE_URL, "{site}").replaceAll(AUTH0_URL, "{tenant}/");
}

function normaliseParams(params) {
  if (params === null || params === undefined) return null;
  if (typeof params !== "object") return "<unparsed body>";
  return Object.fromEntries(
    Object.keys(params)
      .sort()
      .map((key) => [key, normaliseValue(key, params[key])]),
  );
}

function requestShape(recorded) {
  return {
    from: recorded.from,
    method: recorded.method,
    path: recorded.path
      .replace(/^\/api\/v2\/users\/[^/]+$/, "/api/v2/users/{id}")
      // The profile picture the mock gives each person (picture in the ID
      // token). The 4.x plugin shows it in place of the WordPress avatar, so
      // the browser asks the tenant for it.
      .replace(/^\/avatar\/[^/]+$/, "/avatar/{name}"),
    contentType: recorded.contentType ? recorded.contentType.split(";")[0].trim() : null,
    authorization: recorded.authorization,
    // The Auth0-Client telemetry header's package name, not its versions.
    client: recorded.client ? recorded.client.name ?? "<unnamed>" : null,
    query: normaliseParams(recorded.query),
    body: normaliseParams(recorded.body),
  };
}

// The mock's own login form is the tenant's page, not something the plugin
// sends, so it is left out.
function requestShapes(requests) {
  const unique = new Map();
  for (const recorded of requests) {
    if (recorded.path.startsWith("/u/")) continue;
    const shape = requestShape(recorded);
    unique.set(JSON.stringify(shape), shape);
  }
  return [...unique.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([, shape]) => shape);
}

module.exports = {
  AUTH0_DOMAIN,
  AUTH0_URL,
  CLIENT_ID,
  CLIENT_SECRET,
  FALLBACK_PARAM,
  FALLBACK_SECRET,
  AUTHORIZE_URL,
  auth0Sites,
  identities,
  signInAtAuth0,
  setAuth0Session,
  loggedInCookie,
  auth0PluginVersion,
  tenantRequests,
  requestShapes,
};
