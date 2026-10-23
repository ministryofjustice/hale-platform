// Wait until every site answers before any test starts.
//
// stack/stack.sh has already started and seeded the stack by the time
// Playwright runs; this covers the moment between the seed finishing and
// nginx serving every site, and the forwarder (support/forward.js) starting.

const { request } = require("@playwright/test");
const stack = require("./support/stack");

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

module.exports = async function globalSetup() {
  const start = Date.now();
  await waitForSites();
  console.log(`[e2e] sites ready in ${((Date.now() - start) / 1000).toFixed(1)}s at ${stack.NETWORK_URL}`);
};
