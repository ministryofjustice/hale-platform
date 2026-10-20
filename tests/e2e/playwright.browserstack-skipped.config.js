// @ts-check
// Lists the BrowserStack tests as skipped, for when make test-e2e cannot run
// them (bs_skipped in stack/stack.sh). The same tests under the same project
// names as a BrowserStack run, taken from the platforms in browserstack.yml;
// support/test.js skips every one with E2E_SKIP_REASON, so the merged report
// shows each BrowserStack test and why it did not run. No browser is opened.
const fs = require("node:fs");
const path = require("node:path");
// Without the global setup: nothing runs, so there is nothing to wait for.
const { globalSetup, ...base } = require("./playwright.config");

// name, testMatch and testIgnore from each platform's playwrightConfigOptions.
function platformProjects() {
  const yml = fs.readFileSync(path.join(__dirname, "browserstack.yml"), "utf8");
  const projects = [];
  for (const line of yml.split("\n")) {
    const match = line.match(/^\s+(name|testMatch|testIgnore):\s*"?([^"]*?)"?\s*$/);
    if (!match) continue;
    const [, key, value] = match;
    if (key === "name") projects.push({ name: value });
    else if (projects.length) projects[projects.length - 1][key] = value;
  }
  return projects;
}

// .stack/ holds the build's copies of the dev/ clones, some with test files
// of their own. A BrowserStack run never sees it (docker/entrypoint.sh leaves
// it out of the copy the SDK runs from), so neither does this listing.
const projects = platformProjects().map((project) => ({
  ...project,
  testIgnore: [project.testIgnore, "**/.stack/**"].filter(Boolean),
}));

module.exports = { ...base, projects };
