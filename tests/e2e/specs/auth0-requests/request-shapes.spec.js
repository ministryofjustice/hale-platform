// What the Auth0 plugin sent the tenant during the specs/auth0/ run, compared
// with the shapes recorded for that major version of the plugin. Runs after
// the auth0 project (playwright.config.js), so the mock has seen every login,
// logout and error those tests make.
//
// The version is the one the sites run: the test-only mu-plugin
// (seed/mu-plugins/e2e-auth0-mock.php) sends it in X-E2E-Auth0-Plugin. Each
// major version has its own baseline, auth0-mock/request-shapes.v<major>.json,
// so the same test checks 4.x and 6.x.
//
// The shapes are written to output/auth0-request-shapes.v<major>.json on every
// run. After a deliberate change, review the difference against the baseline,
// then copy the new file over it:
//
//   cp tests/e2e/output/auth0-request-shapes.v6.json tests/e2e/auth0-mock/request-shapes.v6.json

const fs = require("node:fs");
const path = require("node:path");
const { test, expect } = require("../../support/test");
const { auth0PluginVersion, requestShapes, tenantRequests } = require("../../support/auth0");

test("the plugin sends Auth0 the same requests as before", async ({ request }, testInfo) => {
  const version = await auth0PluginVersion(request);
  expect(version, "the site did not say which Auth0 plugin version it runs (X-E2E-Auth0-Plugin)").toBeTruthy();
  const major = version.split(".")[0];
  testInfo.annotations.push({ type: "auth0 plugin", description: version });

  const baseline = path.resolve(__dirname, `../../auth0-mock/request-shapes.v${major}.json`);
  const output = path.resolve(__dirname, `../../output/auth0-request-shapes.v${major}.json`);

  const shapes = requestShapes(await tenantRequests(request));
  const json = `${JSON.stringify(shapes, null, 2)}\n`;
  fs.writeFileSync(output, json);
  await testInfo.attach(path.basename(output), { body: json, contentType: "application/json" });

  expect(shapes.length, "the mock tenant recorded no requests").toBeGreaterThan(0);
  expect(
    fs.existsSync(baseline),
    `No baseline for plugin ${version}. This run's shapes are in tests/e2e/output/${path.basename(output)}`,
  ).toBe(true);
  expect(shapes).toEqual(JSON.parse(fs.readFileSync(baseline, "utf8")));
});
