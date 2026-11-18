// The page cache (opt/lua/pagecache) as a visitor sees it, and the pages the
// cache specs create. Shared by specs/pagecache/.
//
// The tests never talk to Redis: nginx says what the cache did in the
// X-Page-Cache header, which is MISS (rendered by WordPress and stored), HIT
// (served from Redis, WordPress never ran) or BYPASS (not cacheable, so
// neither looked up nor stored). The Redis write after a MISS happens once
// the response has been sent, so a HIT can take a moment to appear.
//
// Every page here is new and has a unique slug. A seeded page can be purged at
// any moment by another project's test: publishing anything on a site purges
// its home page.

const { request } = require("@playwright/test");
const { expect } = require("./test");

// A cleared cache is seen by each nginx worker within a second
// (STATE_TTL in opt/lua/pagecache/init.lua), and the write after a MISS takes
// milliseconds, so this is plenty for both.
const SETTLE_MS = 10_000;

// A client with no cookies: a visitor who is not signed in.
async function visitor() {
  return request.newContext({ ignoreHTTPSErrors: true });
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

// Stop at once on a stack whose nginx runs without the page cache, as one
// started before docker-compose.test.yml turned it on would, instead of
// every test timing out waiting for a HIT. nginx answers the REST API with
// BYPASS whenever the cache is enabled, and with no header when it is not.
async function expectCacheEnabled(url) {
  const api = await visitor();
  const { cache } = await fetchPage(api, `${url}wp-json/`);
  await api.dispose();
  expect(
    cache,
    "nginx sent no X-Page-Cache header, so PAGECACHE_ENABLED is not true on this stack. " +
      "A stack started before the page cache was turned on keeps running without it: make test-e2e-up",
  ).toBe("BYPASS");
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

module.exports = { visitor, fetchPage, warm, expectRendered, expectCacheEnabled, Pages };
