// @ts-check
const path = require("node:path");
const { defineConfig, devices } = require("@playwright/test");
const { NETWORK_URL, sites } = require("./support/stack");

// The browserstack service sets E2E_OUTPUT_DIR, so a BrowserStack run after
// the local one (make test-e2e) does not replace its report and traces.
const OUTPUT_DIR = process.env.E2E_OUTPUT_DIR || "./output";
const REPORT_DIR = `${OUTPUT_DIR}/playwright-report`;

// Each run also writes a blob report, named after its output folder
// (output.zip, browserstack.zip). After a BrowserStack run, or the skipped
// listing of one, stack/stack.sh merges the blobs into output/playwright-report,
// so the report page shows the local and the BrowserStack tests together.
const BLOB = ["blob", {
  outputDir: `${OUTPUT_DIR}/blob`,
  fileName: `${path.basename(path.resolve(OUTPUT_DIR))}.zip`,
}];

// End-to-end tests against the disposable test multisite in
// docker-compose.test.yml. Runs inside the playwright container, after
// stack/stack.sh has started and seeded the stack; the global setup only
// waits for the sites to answer. See README.md.
module.exports = defineConfig({
  testDir: ".",
  outputDir: `${OUTPUT_DIR}/test-results`,

  globalSetup: require.resolve("./global-setup"),

  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,

  // The report is never opened from here: a report server inside the
  // container would keep the run from exiting. make test-e2e-report serves it.
  reporter: process.env.CI
    ? [["html", { outputFolder: REPORT_DIR, open: "never" }], BLOB, ["github"]]
    : [["html", { outputFolder: REPORT_DIR, open: "never" }], BLOB, ["list"]],

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
