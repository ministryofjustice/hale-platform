// Unit tests for Node.js (24+).
// No package.json or node_modules needed.
// node --test main_test.cjs

const test = require("node:test");
const assert = require("node:assert/strict");

const { onExecuteCustomEmailProvider } = require("./main.cjs");

const event = {
  notification: {
    text: "Hello world",
    to: "test@example.com",
    subject: "Test subject",
    message_type: "test",
  },
  secrets: {
    NOTIFY_API_KEY: "test",
    NOTIFY_TEMPLATE_ID: "template-id",
  },
};

function makeApi() {
  return {
    notification: {
      retry(reason) {
        return { type: "retry", reason };
      },
      drop(reason) {
        return { type: "drop", reason };
      },
    },
  };
}

test("drops empty body", async () => {
  const result = await onExecuteCustomEmailProvider(
    {
      notification: {
        text: "   ",
      },
    },
    makeApi(),
  );

  assert.deepEqual(result, {
    type: "drop",
    reason: "Empty text body",
  });
});

test("drops when secrets are missing", async (t) => {
  const originalFetch = global.fetch;

  t.after(() => {
    global.fetch = originalFetch;
  });

  global.fetch = async () => {
    throw new Error("fetch should not be called");
  };

  for (const secrets of [
    { NOTIFY_TEMPLATE_ID: "template-id" },
    { NOTIFY_API_KEY: "", NOTIFY_TEMPLATE_ID: "template-id" },
    { NOTIFY_API_KEY: "test" },
  ]) {
    const result = await onExecuteCustomEmailProvider(
      { ...event, secrets },
      makeApi(),
    );

    assert.deepEqual(result, {
      type: "drop",
      reason: "Notify secrets missing",
    });
  }
});

test("retries when fetch throws", async (t) => {
  const originalFetch = global.fetch;

  t.after(() => {
    global.fetch = originalFetch;
  });

  global.fetch = async () => {
    throw new Error("connection refused");
  };

  const result = await onExecuteCustomEmailProvider(event, makeApi());

  assert.equal(result.type, "retry");
  assert.match(result.reason, /connection refused/);
});

test("retries on 429", async (t) => {
  const originalFetch = global.fetch;

  t.after(() => {
    global.fetch = originalFetch;
  });

  global.fetch = async () => ({
    status: 429,
    ok: false,
    text: async () => "rate limited",
  });

  const result = await onExecuteCustomEmailProvider(event, makeApi());

  assert.deepEqual(result, {
    type: "retry",
    reason: "Notify: 429, rate limited",
  });
});

test("retries on 500", async (t) => {
  const originalFetch = global.fetch;

  t.after(() => {
    global.fetch = originalFetch;
  });

  global.fetch = async () => ({
    status: 503,
    ok: false,
    text: async () => "service unavailable",
  });

  const result = await onExecuteCustomEmailProvider(event, makeApi());

  assert.deepEqual(result, {
    type: "retry",
    reason: "Notify: 503, service unavailable",
  });
});

test("drops on 400", async (t) => {
  const originalFetch = global.fetch;

  t.after(() => {
    global.fetch = originalFetch;
  });

  global.fetch = async () => ({
    status: 400,
    ok: false,
    text: async () => "bad request",
  });

  const result = await onExecuteCustomEmailProvider(event, makeApi());

  assert.deepEqual(result, {
    type: "drop",
    reason: "Notify: 400, bad request",
  });
});

test("returns undefined on success", async (t) => {
  const originalFetch = global.fetch;

  t.after(() => {
    global.fetch = originalFetch;
  });

  global.fetch = async () => ({
    status: 201,
    ok: true,
    text: async () => "",
  });

  const result = await onExecuteCustomEmailProvider(event, makeApi());

  assert.equal(result, undefined);
});

test("sends expected request to Notify", async (t) => {
  const originalFetch = global.fetch;

  let url;
  let options;

  t.after(() => {
    global.fetch = originalFetch;
  });

  global.fetch = async (u, o) => {
    url = u;
    options = o;

    return {
      status: 201,
      ok: true,
      text: async () => "",
    };
  };

  await onExecuteCustomEmailProvider(event, makeApi());

  assert.equal(
    url,
    "https://api.notifications.service.gov.uk/v2/notifications/email",
  );

  const body = JSON.parse(options.body);

  assert.equal(body.email_address, "test@example.com");
  assert.equal(body.template_id, "template-id");
  assert.equal(body.personalisation.subject, "Test subject");
  assert.equal(body.personalisation.body, "Hello world");
  assert.equal(body.reference, "test");

  assert.match(options.headers.Authorization, /^Bearer /);
});
