// The `test` every spec imports. Adds a `site` fixture: the sites.json entry
// for the Playwright project running the test, so a spec in all-sites/ knows
// which theme and title to expect. With E2E_SKIP_REASON set, every test is
// skipped with that reason instead: stack/stack.sh does this to list the
// BrowserStack tests in the report when they cannot run.
//
// Each project's baseURL is its site's URL with a trailing slash, so specs use
// relative paths - page.goto("about/"), not page.goto("/about/"), which would
// leave the site and go to the main one.
//
// A BrowserStack run has the platforms in browserstack.yml as its projects,
// which set neither, so there the site comes from the spec's folder:
// specs/<site key>/ for that site's specs, the main site for the rest
// (all-sites/ and network/). baseURL follows the site.

const path = require("node:path");
const base = require("@playwright/test");
const { sites } = require("./stack");

const SPECS_DIR = path.resolve(__dirname, "../specs");
const SKIP_REASON = process.env.E2E_SKIP_REASON || "";

function siteForSpec(file) {
  const folder = path.relative(SPECS_DIR, file).split(path.sep)[0];
  return sites.find((site) => site.key === folder) ?? sites[0];
}

const test = base.test.extend({
  site: [async ({}, use, testInfo) => use(siteForSpec(testInfo.file)), { option: true }],
  baseURL: async ({ baseURL, site }, use) => use(baseURL ?? site.url),
  skipAll: [
    async ({}, use, testInfo) => {
      testInfo.skip(!!SKIP_REASON, SKIP_REASON);
      await use();
    },
    { auto: true },
  ],
});

module.exports = { test, expect: base.expect };
