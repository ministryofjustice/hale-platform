// @ts-check
const { defineConfig, devices } = require("@playwright/test");

module.exports = defineConfig({
  //location of tests
  testDir: "./tests",

  use: {
    baseURL: "https://hale.docker",
    ignoreHTTPSErrors: true,
  },

  //run tests using chronium with a desktop chrome-like browser
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
