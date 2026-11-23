// The page cache (opt/lua/pagecache) as a visitor sees it, and the pages the
// cache specs create. Shared by specs/pagecache/.
//
// The tests never talk to Redis: nginx says what the cache did in the
// X-Page-Cache header, which is MISS (rendered by WordPress and stored), HIT
// (served from Redis, WordPress never ran) or BYPASS (not cacheable, so
// neither looked up nor stored). The Redis write after a MISS happens once
// the response has been sent, so a HIT can take a moment to appear.
//
// Every page here is new and has a unique slug, so no test sees a page
// another test cached or purged: publishing anything on a site purges its home
// page. The other projects have finished before these run, with the cache
// inactive (pagecache-on.setup.js), so nothing else visits these pages.

const { request } = require("@playwright/test");
const { expect } = require("./test");
const { NETWORK_URL } = require("./stack");

const DASHBOARD = "wp-admin/network/settings.php?page=hale-components-network-dashboard";

// A cleared cache is seen by each nginx worker within a second
// (STATE_TTL in opt/lua/pagecache/init.lua), and the write after a MISS takes
// milliseconds, so this is plenty for both.
const SETTLE_MS = 10_000;

// A client with no cookies: a visitor who is not signed in. The empty
// storageState matters: Playwright gives request.newContext() the project's
// and the spec's `use` options, so without it a spec's
// test.use({ storageState }) would sign the visitor in too.
async function visitor() {
  return request.newContext({ ignoreHTTPSErrors: true, storageState: { cookies: [], origins: [] } });
}

// Fetch a URL and say what the cache did with it. Redirects are not followed,
// so the status is the one nginx sent for that address.
async function fetchPage(api, url) {
  const response = await api.get(url, { maxRedirects: 0 });
  return {
    status: response.status(),
    cache: response.headers()["x-page-cache"],
    body: await response.text(),
  };
}

// Stop at once when nginx is not caching pages, instead of every test timing
// out waiting for a HIT. nginx answers a visitor's request for a page with an
// X-Page-Cache header only while the cache is enabled and its mode is active.
// The REST API tells the two apart: it gets BYPASS whenever the cache is
// enabled, whatever the mode.
async function expectCacheEnabled(url) {
  const api = await visitor();
  const rest = await fetchPage(api, `${url}wp-json/`);
  const home = await fetchPage(api, url);
  await api.dispose();
  expect(
    rest.cache,
    "nginx sent no X-Page-Cache header, so PAGECACHE_ENABLED is not true on this stack. " +
      "A stack started before the page cache was turned on keeps running without it: make test-e2e-up",
  ).toBe("BYPASS");
  expect(
    home.cache,
    "The page cache's mode is inactive. The pagecache-on project makes it active: run these specs " +
      "with their dependencies, not with --no-deps",
  ).toBeDefined();
}

// Each nginx worker keeps its own copy of the mode for up to STATE_TTL (1s,
// opt/lua/pagecache/init.lua), so one worker can act on a new mode while
// another still acts on the old one. Past this long after the change, none
// can.
const MODE_SETTLE_MS = 1_500;

// Set the cache's runtime mode, active or inactive, from the network
// dashboard, as a network administrator signed in on `page`, then wait until
// every nginx worker acts on it. A visitor's request for a page gets an
// X-Page-Cache header while the mode is active, and none while it is
// inactive. A change of mode raises the cache version, so the cache starts
// empty; setting the mode it already has leaves the cache as it is.
async function setMode(page, mode) {
  await page.goto(DASHBOARD);
  // The firewall's mode form, on the same dashboard, has an "Update mode"
  // button too.
  const form = page.locator("form").filter({ has: page.locator('select[name="pagecache_mode"]') });
  await form.locator('select[name="pagecache_mode"]').selectOption(mode);
  await form.getByRole("button", { name: "Update mode" }).click();
  await expect(page.getByText(`Page cache mode updated to ${mode}.`)).toBeVisible();
  await page.waitForTimeout(MODE_SETTLE_MS);

  const api = await visitor();
  const { cache } = await fetchPage(api, NETWORK_URL);
  await api.dispose();
  expect(cache !== undefined, `nginx sees the page cache as ${mode}`).toBe(mode === "active");
}

// Visit a URL until the cache serves it.
async function warm(api, url) {
  await expect
    .poll(async () => (await fetchPage(api, url)).cache, { message: `${url} served from the cache`, timeout: SETTLE_MS })
    .toBe("HIT");
}

// Visit a URL until WordPress renders it again, then return that response.
// The first request after a purge is the one that MISSes, so this sees it:
// these pages get no other traffic.
async function expectRendered(api, url) {
  let last;
  await expect
    .poll(async () => (last = await fetchPage(api, url)).cache, { message: `${url} rendered again`, timeout: SETTLE_MS })
    .toBe("MISS");
  return last;
}

// The REST API nonce WordPress gives a logged-in user. Trimmed: anything on
// the network that prints whitespace ends up around it.
async function restNonce(page, site) {
  const body = await (await page.request.get(`${site.url}wp-admin/admin-ajax.php?action=rest-nonce`)).text();
  const nonce = body.trim();
  if (!/^[0-9a-f]{10}$/.test(nonce)) {
    throw new Error(`admin-ajax.php?action=rest-nonce returned ${JSON.stringify(body.slice(0, 200))}, not a nonce`);
  }
  return nonce;
}

// Block markup with a word no other page has, so a response shows which
// version of a page it is.
const paragraph = (text) => `<!-- wp:paragraph --><p>${text}</p><!-- /wp:paragraph -->`;

// Published pages, created and changed through the REST API as the logged-in
// user on `page`. The REST API saves with wp_insert_post() as the editor does,
// so the same post status hooks, and so the same purges, run. Pages it made
// are deleted by cleanup().
class Pages {
  constructor(page) {
    this.page = page;
    this.created = [];
    this.nonces = new Map();
  }

  async api(site, method, route, data) {
    if (!this.nonces.has(site.key)) this.nonces.set(site.key, await restNonce(this.page, site));
    const response = await this.page.request.fetch(`${site.url}wp-json/wp/v2/${route}`, {
      method,
      headers: { "X-WP-Nonce": this.nonces.get(site.key) },
      data,
    });
    expect(response.ok(), `${method} ${site.url}wp-json/wp/v2/${route}: ${response.status()}`).toBe(true);
    return response.json();
  }

  // A published page with a unique marker, which is also its slug unless
  // `slug` is given. Returns its id, link and marker.
  async create(site, { parent, slug } = {}) {
    const marker = `pagecache-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const post = await this.api(site, "POST", "pages", {
      title: `Page cache ${marker}`,
      slug: slug ?? marker,
      content: paragraph(marker),
      status: "publish",
      ...(parent ? { parent: parent.id } : {}),
    });
    const created = { site, id: post.id, link: post.link, marker };
    this.created.push(created);
    return created;
  }

  async update(created, data) {
    return this.api(created.site, "POST", `pages/${created.id}`, data);
  }

  // Replace a page's text with a new marker, as an editor's Update does.
  async edit(created) {
    const marker = `${created.marker}-edited`;
    await this.update(created, { content: paragraph(marker) });
    return marker;
  }

  // Move a page to the trash, as Trash in the page list does.
  async trash(created) {
    return this.api(created.site, "DELETE", `pages/${created.id}`);
  }

  // Delete every page this made, so a reused stack does not fill up. Deleting
  // for good does not change the post status, so it purges nothing; entries
  // left behind expire after PAGECACHE_TTL.
  async cleanup() {
    for (const { site, id } of this.created.reverse()) {
      await this.api(site, "DELETE", `pages/${id}?force=true`);
    }
    this.created = [];
  }
}

module.exports = { visitor, fetchPage, setMode, warm, expectRendered, expectCacheEnabled, Pages };
