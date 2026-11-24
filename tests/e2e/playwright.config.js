// @ts-check
const path = require("node:path");
const { defineConfig, devices } = require("@playwright/test");
const { NETWORK_URL, sites, authFile } = require("./support/stack");
const { auth0Sites } = require("./support/auth0");

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

// Every project but setup and the page cache's. They run with the page cache
// inactive, so they see pages rendered by WordPress, never a cached copy.
const suiteProjects = [
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
    // Login through the mock Auth0 tenant, on the sites seed.sh activates the
    // Auth0 plugin on. These start logged out, but log in as the seeded users,
    // and WordPress keeps a user's sessions in one user meta value it rewrites
    // without a lock: two logins as one user at the same moment can each drop
    // the other's session. So one test at a time, after setup's logins.
    {
      name: "auth0",
      testMatch: /specs\/auth0\/.*\.spec\.js/,
      testIgnore: /specs\/auth0\/request-shapes\.spec\.js/,
      dependencies: ["setup"],
      workers: 1,
      use: { ...devices["Desktop Chrome"], baseURL: auth0Sites.main.url },
    },
    // What the plugin sent the tenant during the auth0 project's tests.
    {
      name: "auth0-requests",
      testMatch: /specs\/auth0\/request-shapes\.spec\.js/,
      dependencies: ["auth0"],
    },
];

// The page cache projects wait for every other project, as Playwright runs a
// project's dependencies in full even when the command line picks only some
// tests. So when the command line picks only the page cache's specs, by file
// (make test-e2e-run FILE=specs/pagecache/) or by project
// (make test-e2e ARGS=--project=pagecache), they wait for setup alone.
// Anything else, such as another file filter alongside, a title filter or UI
// mode, runs the other projects first.
//
// Every argument that is not an option counts as a file filter, as Playwright
// matches each one against every spec's path (homepage.spec.js picks
// specs/all-sites/homepage.spec.js). An option's value given as a separate
// argument (-g foo, -j 4) counts as one too, which only makes this run the
// other projects first when it need not.
const cliFilters = [];
const cliProjects = [];
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (arg.startsWith("--project=")) cliProjects.push(arg.slice("--project=".length));
  else if (arg === "--project") cliProjects.push(args[++i] ?? "");
  else if (!arg.startsWith("-")) cliFilters.push(arg);
}
// The command itself: `playwright test`.
if (cliFilters[0] === "test") cliFilters.shift();
const pagecacheOnly =
  cliFilters.length + cliProjects.length > 0 &&
  cliFilters.every((arg) => /(^|\/)specs\/pagecache(\/|$)/.test(arg)) &&
  cliProjects.every((name) => name.startsWith("pagecache"));

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
    ...suiteProjects,
    // The page cache, across every site, after every other project: the seed
    // leaves the cache inactive, pagecache-on makes it active for these specs,
    // and pagecache-off, its teardown, makes it inactive again, whether they
    // pass or fail. One test at a time: the clear buttons empty the cache other
    // cache tests have just filled.
    {
      name: "pagecache-on",
      testMatch: /pagecache-on\.setup\.js/,
      dependencies: pagecacheOnly ? ["setup"] : ["setup", ...suiteProjects.map((project) => project.name)],
      teardown: "pagecache-off",
      use: { baseURL: NETWORK_URL, storageState: authFile("admin") },
    },
    {
      name: "pagecache",
      testMatch: /specs\/pagecache\/.*\.spec\.js/,
      dependencies: ["pagecache-on"],
      workers: 1,
      use: { ...devices["Desktop Chrome"], baseURL: NETWORK_URL },
    },
    {
      name: "pagecache-off",
      testMatch: /pagecache-off\.setup\.js/,
      use: { baseURL: NETWORK_URL, storageState: authFile("admin") },
    },
  ],
});
