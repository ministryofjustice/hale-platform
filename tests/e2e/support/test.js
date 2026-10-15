// The `test` every spec imports. Adds a `site` fixture: the sites.json entry
// for the Playwright project running the test, so a spec in all-sites/ knows
// which theme and title to expect.
//
// Each project's baseURL is its site's URL with a trailing slash, so specs use
// relative paths - page.goto("about/"), not page.goto("/about/"), which would
// leave the site and go to the main one.

const base = require("@playwright/test");
const { sites } = require("./stack");

const test = base.test.extend({
  site: [sites[0], { option: true }],
});

module.exports = { test, expect: base.expect };
