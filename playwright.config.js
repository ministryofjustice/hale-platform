// @ts-check
const { defineConfig, devices } = require("@playwright/test");

module.exports = defineConfig({
  //location of test directory
  testDir: "./tests",

  reporter: "html",

  use: {
    baseURL: "https://hale.docker",
    ignoreHTTPSErrors: true,

    //faliure diagnostics
    screenshot: 'only-on-failure',
    video: "retain-on-failure",

    //record and retain traces on fail
    trace: 'retain-on-failure',
  },

  //run tests using chronium with a desktop chrome-like browser
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
    {
      name: 'firefox',
      use: {...devices['Desktop Firefox']},
    },
    {
      name: 'webkit',
      use: {...devices['Desktop Safari']},
    },
    {
      name: 'Mobile Chrome',
      use: { ...devices['Pixel 5'] },
    },
    {
      name: 'Mobile Safari',
      use: { ...devices['iPhone 12'] },
    },

  ],
});
