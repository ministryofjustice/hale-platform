// @ts-check
const { defineConfig, devices } = require("@playwright/test");

module.exports = defineConfig({
  //location of test directory
  testDir: "./tests",

  //opens report automatically after playwright tests run
  reporter: [["html", { open: process.env.PLAYWRIGHT_HTML_OPEN || "always" }]],

  use: {
    baseURL: "https://hale.docker",
    ignoreHTTPSErrors: true,

    //faliure diagnostics
    screenshot: "only-on-failure",
    video: "retain-on-failure",

    //record and retain traces on fail
    trace: "retain-on-failure",
  },

  //run tests using chronium with a desktop chrome-like browser
  //ensures tests are carried out on matching platform types
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
      testIgnore: "**/mobile-navigation.spec.js",
    },
    {
      name: "firefox",
      use: { ...devices["Desktop Firefox"] },
      testIgnore: "**/mobile-navigation.spec.js",
    },
    {
      name: "webkit",
      use: { ...devices["Desktop Safari"] },
      testIgnore: "**/mobile-navigation.spec.js",
    },
    {
      name: "Mobile Chrome",
      use: { ...devices["Pixel 5"] },
      testMatch: "**/mobile-navigation.spec.js",
    },
    {
      name: "Mobile Safari",
      use: { ...devices["iPhone 12"] },
      testMatch: "**/mobile-navigation.spec.js",
    },
  ],
});
