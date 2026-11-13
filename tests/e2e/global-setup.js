// Wait until every site answers before any test starts, then clear the mock
// Auth0 tenant's request log.
//
// stack/stack.sh has already started and seeded the stack by the time
// Playwright runs; this covers the moment between the seed finishing and
// nginx serving every site, and the forwarder (support/forward.js) starting.

const { request } = require("@playwright/test");
const stack = require("./support/stack");
const { AUTH0_URL } = require("./support/auth0");

async function waitForSites(timeoutMs = 60_000) {
  const context = await request.newContext({ ignoreHTTPSErrors: true });
  const deadline = Date.now() + timeoutMs;
  try {
    for (const site of stack.sites) {
      for (;;) {
        const status = await context
          .get(site.url, { maxRedirects: 0 })
          .then((response) => response.status())
          .catch(() => 0);
        if (status === 200) break;
        if (Date.now() > deadline) {
          throw new Error(`${site.url} did not return 200 (last status ${status})`);
        }
        await new Promise((resolve) => setTimeout(resolve, 1000));
      }
    }
  } finally {
    await context.dispose();
  }
}

// Clear the mock Auth0 tenant's request log, so specs/auth0/request-shapes.spec.js
// compares this run's requests alone, also on a stack kept between runs.
async function clearAuth0Requests() {
  const context = await request.newContext({ ignoreHTTPSErrors: true });
  try {
    const response = await context.delete(`${AUTH0_URL}__test/requests`);
    if (!response.ok()) {
      throw new Error(`The mock Auth0 tenant did not clear its request log (status ${response.status()})`);
    }
  } finally {
    await context.dispose();
  }
}

module.exports = async function globalSetup() {
  const start = Date.now();
  await waitForSites();
  console.log(`[e2e] sites ready in ${((Date.now() - start) / 1000).toFixed(1)}s at ${stack.NETWORK_URL}`);
  await clearAuth0Requests();
};
