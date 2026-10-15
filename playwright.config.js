// @ts-check
const { defineConfig, devices } = require("@playwright/test");
const { NETWORK_URL, sites } = require("./tests/e2e/support/stack");

const REPORT_DIR = "./tests/e2e/playwright-report";

// End-to-end tests against the disposable test multisite in
// docker-compose.test.yml. The global setup starts and seeds it; the global
// teardown removes it. See tests/e2e/README.md.
module.exports = defineConfig({
  testDir: "./tests/e2e",
  // Run output stays under tests/e2e/ with everything else test related.
  outputDir: "./tests/e2e/test-results",

  globalSetup: require.resolve("./tests/e2e/global-setup"),
  globalTeardown: require.resolve("./tests/e2e/global-teardown"),

  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,

  reporter: process.env.CI
    ? [["html", { outputFolder: REPORT_DIR, open: "never" }], ["github"]]
    : [["html", { outputFolder: REPORT_DIR, open: process.env.PLAYWRIGHT_HTML_OPEN || "on-failure" }]],

  use: {
    // Self-signed certificate on the test stack.
    ignoreHTTPSErrors: true,
    screenshot: "only-on-failure",
    video: "retain-on-failure",
    // Locally there are no retries, so keep the trace of any failure.
    trace: process.env.CI ? "on-first-retry" : "retain-on-failure",
  },

  projects: [
    {
      name: "setup",
      testMatch: /auth\.setup\.js/,
      use: { baseURL: NETWORK_URL },
    },
    // One project per site: the specs in all-sites/ plus the site's own folder.
    ...sites.map((site) => ({
      name: site.key,
      testMatch: [/specs\/all-sites\/.*\.spec\.js/, new RegExp(`specs/${site.key}/.*\\.spec\\.js`)],
      dependencies: ["setup"],
      use: { ...devices["Desktop Chrome"], baseURL: site.url, site },
    })),
    {
      name: "network",
      testMatch: /specs\/network\/.*\.spec\.js/,
      dependencies: ["setup"],
      use: { ...devices["Desktop Chrome"], baseURL: NETWORK_URL },
    },
  ],
});
