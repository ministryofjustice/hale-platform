// The end-to-end test stack: its address, its sites and users. Shared by
// playwright.config.js, the global setup, the specs and stack/endpoints.js.
// Starting, seeding and removing the stack is stack/stack.sh's job, on the
// host.

const path = require("node:path");

const AUTH_DIR = path.resolve(__dirname, "../.auth");

const PROJECT = process.env.HALE_TEST_PROJECT || "hale-test";
const PORT = process.env.HALE_TEST_PORT || "8443";
const NETWORK_URL = `https://localhost:${PORT}/`;
// Test-only wps-hide-login slug, set by seed/seed.sh.
const LOGIN_PATH = "e2e-test-login/";
const PASSWORD = process.env.E2E_PASSWORD || "hale-e2e-test-only";

// Same file the seed reads, so a site added there gets a Playwright project.
const sites = require("../seed/sites.json").map((site) => ({
  ...site,
  url: site.path ? `${NETWORK_URL}${site.path}/` : NETWORK_URL,
}));

// Logins the auth setup saves a session for. The seed creates them.
const users = {
  admin: "e2eadmin",
  editor: "e2eeditor",
  author: "e2eauthor",
  contributor: "e2econtributor",
};

const authFile = (role) => path.join(AUTH_DIR, `${role}.json`);

module.exports = {
  AUTH_DIR,
  PROJECT,
  PORT,
  NETWORK_URL,
  LOGIN_PATH,
  PASSWORD,
  sites,
  users,
  authFile,
};
