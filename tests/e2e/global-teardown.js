// Remove the test stack - containers, network and volumes - pass or fail.
// KEEP_STACK=1 (or REUSE_STACK=1) leaves it running to inspect or rerun.

const stack = require("./support/stack");

module.exports = async function globalTeardown() {
  if (process.env.KEEP_STACK === "1" || process.env.REUSE_STACK === "1") {
    console.log(`[e2e] Leaving the ${stack.PROJECT} stack running at ${stack.NETWORK_URL}`);
    console.log("[e2e] Remove it with: make test-e2e-down");
    return;
  }
  stack.down();
};
