// Make the page cache inactive again once specs/pagecache/ has run, whether it
// passed or failed, so a reused stack (make test-e2e-run) runs the other specs
// without the cache. The teardown of pagecache-on.setup.js.

const { test: teardown } = require("@playwright/test");
const { setMode } = require("./support/pagecache");

teardown("make the page cache inactive", ({ page }) => setMode(page, "inactive"));
