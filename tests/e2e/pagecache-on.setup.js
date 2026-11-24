// Make the page cache active for specs/pagecache/. The seed leaves it inactive
// so the other projects see pages rendered by WordPress; this runs once they
// have finished (playwright.config.js), and pagecache-off.setup.js, its
// teardown, makes it inactive again.

const { test: setup } = require("@playwright/test");
const { setMode } = require("./support/pagecache");

setup("make the page cache active", ({ page }) => setMode(page, "active"));
