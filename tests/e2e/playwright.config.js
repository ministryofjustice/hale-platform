// @ts-check
const { defineConfig, devices } = require("@playwright/test");
const { NETWORK_URL, sites } = require("./support/stack");

const REPORT_DIR = "./output/playwright-report";

// End-to-end tests against the disposable test multisite in
// docker-compose.test.yml. Runs inside the playwright container, after
// stack/stack.sh has started and seeded the stack; the global setup only
// waits for the sites to answer. See README.md.
module.exports = defineConfig({
  testDir: ".",
  outputDir: "./output/test-results",

  globalSetup: require.resolve("./global-setup"),

  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,

  // The report is never opened from here: a report server inside the
  // container would keep the run from exiting. make test-e2e-report serves it.
  reporter: process.env.CI
    ? [["html", { outputFolder: REPORT_DIR, open: "never" }], ["github"]]
    : [["html", { outputFolder: REPORT_DIR, open: "never" }], ["list"]],

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
      testIgnore:  /\.mobile\.spec\.js/,
      dependencies: ["setup"],
      use: { ...devices["Desktop Chrome"], baseURL: site.url, site },
    })),
    //Mobile chrome tests for each site
     ...sites.map((site) => ({
      name: `${site.key}-mobile-chrome`,
      testMatch: [/specs\/all-sites\/.*\.mobile\.spec\.js/, new RegExp(`specs/${site.key}/.*\.mobile\\.spec\\.js$`)],
      dependencies: ["setup"],
      use: { ...devices["Pixel 5"], baseURL: site.url, site },
    })),




    {
      name: "network",
      testMatch: /specs\/network\/.*\.spec\.js/,
      dependencies: ["setup"],
      use: { ...devices["Desktop Chrome"], baseURL: NETWORK_URL },
    },
  ],
});
