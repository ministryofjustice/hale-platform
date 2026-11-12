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
// Every test also fails if its browser logs a console error (console.error,
// or a resource that failed to load, such as a 404) or throws an uncaught
// exception, on any page the test opens. A spec whose behaviour under test
// causes console errors turns the check off for itself, or for a describe block:
//   test.use({ ignoreConsoleErrors: true });
// Messages are collected for the test's own context only; a context made with
// browser.newContext() is not watched.
//
// A BrowserStack run has the platforms in browserstack.yml as its projects,
// which set neither, so there the site comes from the spec's folder:
// specs/<site key>/ for that site's specs, the main site for the rest
// (all-sites/ and network/). baseURL follows the site.

const fs = require("node:fs");
const path = require("node:path");
const base = require("@playwright/test");
const { sites } = require("./stack");

const { expect } = base;

// The test stack has no internet access, so a page that loads a file from an
// outside host would fail to resolve it and log a console error. Each outside
// host the sites load from is answered here instead; a host not listed still
// fails, so a new one shows up as a test failure. jQuery and its migrate
// plugin are WordPress core's own copies (support/mocks/), as the sites'
// scripts need a working jQuery; the rest return nothing. WordPress ends its
// jquery.min.js with jQuery.noConflict(), which drops the global $ that a CDN
// jQuery keeps, so that line is removed from the copy.
const MOCKS_DIR = path.join(__dirname, "mocks");
const JQUERY = fs.readFileSync(path.join(MOCKS_DIR, "jquery.min.js"));
const JQUERY_MIGRATE = fs.readFileSync(path.join(MOCKS_DIR, "jquery-migrate.min.js"));
// A 1x1 transparent GIF.
const PIXEL = Buffer.from("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7", "base64");

const EXTERNAL_MOCKS = [
  // ppo's jQuery, and the plugin that restores old APIs.
  { match: ({ host, pathname }) => host === "ajax.googleapis.com" && pathname.startsWith("/ajax/libs/jquery/") && pathname.endsWith("/jquery.min.js"),
    type: "application/javascript", body: JQUERY },
  { match: ({ host, pathname }) => host === "code.jquery.com" && pathname.startsWith("/jquery-migrate-") && pathname.endsWith(".js"),
    type: "application/javascript", body: JQUERY_MIGRATE },
  // The Auth0 plugin's verify-email page and the Option Tree plugin.
  { match: ({ host, pathname }) => host === "code.jquery.com" && pathname.startsWith("/jquery-") && pathname.endsWith(".js"),
    type: "application/javascript", body: JQUERY },
  // Google Fonts' stylesheets (css, css2); no stylesheet means no font files.
  { match: ({ host }) => host === "fonts.googleapis.com", type: "text/css", body: "" },
  // The Ace code editor, which an admin screen loads from cdnjs.
  { match: ({ host, pathname }) => host === "cdnjs.cloudflare.com" && pathname.startsWith("/ajax/libs/ace/"),
    type: "application/javascript", body: "" },
  // The block editor's welcome guide image.
  { match: ({ host }) => host === "s.w.org", type: "image/gif", body: PIXEL },
  // Avatars: any hash and size.
  { match: ({ host, pathname }) => host === "secure.gravatar.com" && pathname.startsWith("/avatar/"),
    type: "image/gif", body: PIXEL },
];

const SPECS_DIR = path.resolve(__dirname, "../specs");
const SKIP_REASON = process.env.E2E_SKIP_REASON || "";

function siteForSpec(file) {
  const folder = path.relative(SPECS_DIR, file).split(path.sep)[0];
  return sites.find((site) => site.key === folder) ?? sites[0];
}

const test = base.test.extend({
  site: [async ({}, use, testInfo) => use(siteForSpec(testInfo.file)), { option: true }],
  baseURL: async ({ baseURL, site }, use) => use(baseURL ?? site.url),
  externalMocks: [
    async ({ skipAll, context }, use) => {
      await context.route(/^https?:\/\/(?!localhost[:/])/, (route) => {
        const url = new URL(route.request().url());
        const mock = EXTERNAL_MOCKS.find(({ match }) => match(url));
        return mock ? route.fulfill({ contentType: mock.type, body: mock.body }) : route.fallback();
      });
      await use();
    },
    { auto: true },
  ],
  // True turns the console-error check off, see above.
  ignoreConsoleErrors: [false, { option: true }],
  consoleErrors: [
    async ({ skipAll, context, ignoreConsoleErrors }, use) => {
      const errors = [];
      const record = (text, where) => {
        const full = where ? `${text}\n    at ${where}` : text;
        errors.push(full);
      };
      context.on("console", (message) => {
        if (message.type() !== "error") return;
        const { url, lineNumber } = message.location();
        record(message.text(), url ? `${url}:${lineNumber}` : "");
      });
      context.on("weberror", (webError) => {
        const error = webError.error();
        record(`Uncaught: ${error.stack || error.message || error}`, "");
      });
      await use(errors);
      if (ignoreConsoleErrors) return;
      expect(errors, `Browser console errors:\n${errors.join("\n")}`).toEqual([]);
    },
    { auto: true },
  ],
  skipAll: [
    async ({}, use, testInfo) => {
      testInfo.skip(!!SKIP_REASON, SKIP_REASON);
      await use();
    },
    { auto: true },
  ],
});

module.exports = { test, expect };
