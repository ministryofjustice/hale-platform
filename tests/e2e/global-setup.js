// Start the test stack, seed it and wait until every site answers.
//
// Every run starts from an empty database: anything a previous run left
// behind is removed first. REUSE_STACK=1 skips all of this when a stack from
// an earlier KEEP_STACK=1 run is still up, for a faster edit-and-rerun loop.

const { request } = require("@playwright/test");
const stack = require("./support/stack");

function timed(label, fn) {
  const start = Date.now();
  const result = fn();
  console.log(`[e2e] ${label}: ${((Date.now() - start) / 1000).toFixed(1)}s`);
  return result;
}

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
  if (process.env.REUSE_STACK === "1" && stack.isRunning()) {
    console.log(`[e2e] Reusing the running ${stack.PROJECT} stack`);
    return;
  }

  const start = Date.now();
  try {
    if (process.env.E2E_BUILD === "1" || !stack.imagesCurrent()) {
      timed("build images", () => stack.run("tests/e2e/stack/build.sh", []));
    }
    stack.ensureCertificate();
    timed("remove previous stack", () => stack.down());
    timed("start stack", () =>
      stack.compose("up", "-d", "--wait", "--wait-timeout", "300", "nginx"),
    );
    timed("seed", () => stack.compose("--profile", "seed", "run", "--rm", "seed"));
    const ready = Date.now();
    await waitForSites();
    console.log(`[e2e] sites ready: ${((Date.now() - ready) / 1000).toFixed(1)}s`);
  } catch (error) {
    if (process.env.KEEP_STACK !== "1") stack.down();
    throw error;
  }
  console.log(`[e2e] stack ready in ${((Date.now() - start) / 1000).toFixed(1)}s at ${stack.NETWORK_URL}`);
};
