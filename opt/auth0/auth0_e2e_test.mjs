// E2E tests for Node.js (18+).
// No package.json or node_modules needed.
// Run: GOV_NOTIFY_KEY_FOR_AUTH0='xyz' node --test auth0_e2e_test.mjs
//
// Prerequisites
// -------------
// 1. gov notify secret — GOV_NOTIFY_KEY_FOR_AUTH0

const { test } = await import("node:test");
const { default: assert } = await import("node:assert/strict");
const script = await import("./script.mjs");

console.log({
  execArgv: process.env,
});

test(
  "e2e: ",
  async () => {

    console.log(Object.keys(script))

    assert.equal(
      1,
      1,
      `Test?`,
    );
  },
);
