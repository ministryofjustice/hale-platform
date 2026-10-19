const { test, expect } = require("../../support/test");

test("homepage renders with the site's theme", async ({ page, site }) => {
  const response = await page.goto("./");

  expect(response?.status()).toBe(200);
  await expect(page).toHaveTitle(new RegExp(site.title));
  // The theme's own CSS or JavaScript is on the page.
  await expect(
    page.locator(`link[href*="/themes/${site.theme}/"], script[src*="/themes/${site.theme}/"]`).first(),
  ).toBeAttached();
});

// Files the plugins enqueue but do not ship: they 404 on the live sites too.
// Listed here so the test still catches anything new; each is shown as an
// annotation in the report. Remove an entry once its plugin is fixed.
const KNOWN_MISSING = {
  // ppo loads jQuery from ajax.googleapis.com and falls back to this file when
  // that fails, which it always does from the test container (no internet).
  // On the live site it 404s only for visitors who cannot reach the CDN.
  "/wp-content/themes/ppo/assets/js/vendor/jquery.min.js":
    "ppo's jQuery CDN fallback points at assets/js/vendor/jquery.min.js, which the theme does not ship",
  // wp-moj-blocks enqueues it on every theme but Hale, which dequeues it.
  "/wp-content/plugins/wp-moj-blocks/build/mojblocks.min.js":
    "wp-moj-blocks enqueues build/mojblocks.min.js, which its build does not produce",
  // Enqueued on pages with a filterable listing block.
  "/wp-content/plugins/website-builder-blocks/build/moj-frontend.js":
    "website-builder-blocks enqueues build/moj-frontend.js, which its build does not produce",
};

test("every stylesheet and script from the site loads", async ({ page, site }) => {
  // Only the site's own files: third-party ones (fonts, analytics) are not the
  // stack's to serve, and WordPress cannot reach them anyway.
  const { host, pathname: sitePath } = new URL(site.url);
  const broken = new Map();
  const isOwnAsset = (request) =>
    ["stylesheet", "script"].includes(request.resourceType()) && new URL(request.url()).host === host;

  page.on("response", (response) => {
    if (isOwnAsset(response.request()) && response.status() >= 400) {
      broken.set(response.url(), `${response.status()} ${response.url()}`);
    }
  });
  page.on("requestfailed", (request) => {
    if (isOwnAsset(request) && !broken.has(request.url())) {
      broken.set(request.url(), `${request.failure()?.errorText} ${request.url()}`);
    }
  });

  await page.goto("./", { waitUntil: "load" });

  const unexpected = [];
  for (const [url, failure] of broken) {
    // Path within the site, so the main site and /ppo/ match the same entry.
    const path = "/" + new URL(url).pathname.slice(sitePath.length);
    if (KNOWN_MISSING[path]) {
      test.info().annotations.push({ type: "known issue", description: `${KNOWN_MISSING[path]} (${failure})` });
    } else {
      unexpected.push(failure);
    }
  }

  expect(unexpected, "stylesheets or scripts that failed to load").toEqual([]);
});
