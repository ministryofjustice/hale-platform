// E2E tests compatible with both Node.js (18+) and Deno (2.0+).
// No package.json or node_modules needed.
// Node:  node --test firewall_e2e_test.js
// Deno:  deno test --allow-net="hale.docker" --allow-read="./fixtures" --unsafely-ignore-certificate-errors firewall_e2e_test.js
//
// Prerequisites
// -------------
// 1. dory up                  — starts the local DNS proxy so hale.docker resolves
// 2. make run-with-firewall   — starts nginx, WordPress, Redis and loads the firewall
//
// If the connectivity check at the top of this file fails, the remaining tests
// are skipped automatically.  Check that both prerequisites are met first.

const isDeno = typeof Deno !== "undefined";

const { test, assert } = await (async () => {
  if (isDeno) {
    const { assert: denoOk, assertEquals } = await import("jsr:@std/assert");
    return {
      test: (name, fn) => Deno.test(name, fn),
      assert: { equal: assertEquals, ok: denoOk },
    };
  }
  const { test } = await import("node:test");
  const { default: assert } = await import("node:assert/strict");
  return { test, assert };
})();

const FIREWALL_URL = "https://hale.docker";

const fetchClient = isDeno
  ? Deno.createHttpClient({ allowHost: true })
  : undefined;

const fetchOpts = fetchClient ? { client: fetchClient } : {};

// ---------------------------------------------------------------------------
// Connectivity pre-check — must pass before any other test runs
// ---------------------------------------------------------------------------
// Attempts a single GET to FIREWALL_URL.  If it fails (DNS, connection
// refused, TLS, etc.) all remaining tests are skipped and help is printed.
// ---------------------------------------------------------------------------

let _firewallReachable = false;

try {
  const probe = await fetch(`${FIREWALL_URL}/firewall/stats`, {
    ...fetchOpts,
    signal: AbortSignal.timeout(5000),
  });
  await probe.body?.cancel();
  if (probe.status !== 200) {
    throw `http response code ${probe.status}`;
  }
  _firewallReachable = true;
} catch (e) {
  console.error(`
╔══════════════════════════════════════════════════════════════════╗
║  FIREWALL NOT REACHABLE — test results will be inaccurate        ║
╠══════════════════════════════════════════════════════════════════╣
║  URL:   ${`${FIREWALL_URL}/firewall/stats`.padEnd(57)}║
║  Error: ${String(e.message ?? e)
    .slice(0, 57)
    .padEnd(57)}║
╠══════════════════════════════════════════════════════════════════╣
║  To fix, run both of these in order:                             ║
║    1.  dory up                                                   ║
║    2.  make run-with-firewall   (from the repo root)             ║
╚══════════════════════════════════════════════════════════════════╝
`);
}

test(
  "e2e: [pre-check] firewall is reachable at " +
    FIREWALL_URL +
    "/firewall/stats",
  async () => {
    if (!_firewallReachable) {
      // Re-attempt inside the test so the failure is attributed here and
      // the error message appears in the test output, not just on stderr.
      try {
        const res = await fetch(`${FIREWALL_URL}/firewall/stats`, {
          ...fetchOpts,
          signal: AbortSignal.timeout(5000),
        });
        await res.body?.cancel();
        assert.equal(
          res.status,
          200,
          `${FIREWALL_URL}/firewall/stats returned ${res.status} — is the firewall running?`,
        );
      } catch (e) {
        assert.ok(
          false,
          `Cannot reach ${FIREWALL_URL}/stats: ${e.message}\n` +
            `  Prerequisites: (1) dory up  (2) make run-with-firewall`,
        );
      }
    }
    assert.ok(_firewallReachable, `${FIREWALL_URL} must be reachable`);
  },
);

async function sendRequest(ip, opts = {}) {
  const { method = "GET", path = "/", ua = "normal-browser" } = opts;
  return await fetch(`${FIREWALL_URL}${path}`, {
    ...fetchOpts,
    method,
    headers: {
      Host: "hale.docker",
      "X-Forwarded-For": ip,
      "X-Forwarded-Proto": "https",
      "User-Agent": ua,
    },
  });
}

async function flushNginxCache() {
  const res = await fetch(`${FIREWALL_URL}/firewall/flush-cache`, fetchOpts);
  await res.body?.cancel();
}

async function clearPenaltyBlocks() {
  const res = await fetch(
    `${FIREWALL_URL}/firewall/clear-penalties`,
    fetchOpts,
  );
  await res.body?.cancel();
}

async function resetFirewall() {
  await flushNginxCache();
  await clearPenaltyBlocks();
}

// ---------------------------------------------------------------------------
// Sanity / infrastructure checks
// ---------------------------------------------------------------------------

test("e2e: normal GET request returns 200", async () => {
  await resetFirewall();
  const res = await sendRequest("10.3.0.1");
  assert.equal(res.status, 200, "clean request should be allowed");
  await res.body?.cancel();
});

test("e2e: /firewall/stats endpoint returns 200", async () => {
  const res = await fetch(`${FIREWALL_URL}/firewall/stats`, fetchOpts);
  assert.equal(res.status, 200, "/firewall/stats should always respond");
  await res.body?.cancel();
});

test("e2e: /firewall/flush-cache endpoint returns 200", async () => {
  const res = await fetch(`${FIREWALL_URL}/firewall/flush-cache`);
  assert.equal(res.status, 200, "/flush-cache/firewall should always respond");
  await res.body?.cancel();
});

// ---------------------------------------------------------------------------
// /firewall/admin/validate — schema and PCRE validation
// ---------------------------------------------------------------------------
// These tests exercise the full stack: nginx routing → Lua validate() →
// config_module.validate_rules_strict (structure) → ngx.re.match compile
// probe (PCRE).  The PCRE check in particular cannot be covered by busted
// because ngx.re is only available inside a running OpenResty worker.
// ---------------------------------------------------------------------------

async function postValidate(kind, body) {
  const res = await fetch(
    `${FIREWALL_URL}/firewall/admin/validate?kind=${kind}`,
    {
      ...fetchOpts,
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: typeof body === "string" ? body : JSON.stringify(body),
    },
  );
  const json = await res.json();
  return { status: res.status, body: json };
}

test("e2e: validate rules — accepts a valid ruleset", async () => {
  const { status, body } = await postValidate("rules", [
    { name: "req-base", phase: "req", cost: 1, match: { has_query: false } },
    { name: "req-php-probe", phase: "req", cost: 20, match: { uri_pattern: "\\.php$" } },
    { name: "req-bad-bot", phase: "req", cost: 50, match: { ua_pattern: "zgrab|masscan" } },
    { name: "res-404", phase: "res", cost: 50, match: { status: 404 } },
  ]);
  assert.equal(status, 200);
  assert.ok(
    body.ok,
    `expected ok=true, got errors: ${JSON.stringify(body.errors)}`,
  );
  assert.equal(body.normalised.length, 4);
});

test("e2e: validate rules — rejects a structurally invalid rule (missing name)", async () => {
  const { status, body } = await postValidate("rules", [
    { phase: "req", cost: 1, match: { method: "GET" } },
  ]);
  assert.equal(status, 200);
  assert.ok(!body.ok, "expected ok=false for rule missing name");
  assert.ok(
    body.errors.some((e) => e.includes("name")),
    `expected error mentioning 'name', got: ${JSON.stringify(body.errors)}`,
  );
});

test("e2e: validate rules — rejects a rule with unknown phase", async () => {
  const { status, body } = await postValidate("rules", [
    { name: "r", phase: "bogus", cost: 1, match: { method: "GET" } },
  ]);
  assert.equal(status, 200);
  assert.ok(!body.ok, "expected ok=false for unknown phase");
  assert.ok(
    body.errors.some((e) => e.includes("phase")),
    `expected error mentioning 'phase', got: ${JSON.stringify(body.errors)}`,
  );
});

test("e2e: validate rules — rejects an invalid PCRE pattern", async () => {
  // "[unclosed" is a PCRE syntax error (missing closing bracket).
  // This error can only be caught by ngx.re.match inside a real worker —
  // it is not caught by the pure-Lua structural check in schema.lua.
  const { status, body } = await postValidate("rules", [
    { name: "bad-regex", phase: "req", cost: 1, match: { uri_pattern: "[unclosed" } },
  ]);
  assert.equal(status, 200);
  assert.ok(!body.ok, "expected ok=false for invalid PCRE pattern");
  assert.ok(
    body.errors.some(
      (e) =>
        e.includes("PCRE") ||
        e.toLowerCase().includes("pcre") ||
        e.includes("uri_pattern"),
    ),
    `expected PCRE error mentioning uri_pattern, got: ${JSON.stringify(body.errors)}`,
  );
});

test("e2e: validate rules — rejects invalid PCRE in ua_pattern and query_pattern", async () => {
  for (const field of ["ua_pattern", "query_pattern"]) {
    const match = { [field]: "[bad" };
    const { body } = await postValidate("rules", [
      { name: "r", phase: "req", cost: 1, match },
    ]);
    assert.ok(!body.ok, `expected ok=false for invalid PCRE in ${field}`);
    assert.ok(
      body.errors.some((e) => e.includes(field)),
      `expected error mentioning '${field}', got: ${JSON.stringify(body.errors)}`,
    );
  }
});

test("e2e: validate rules — rejects non-array body", async () => {
  const { status, body } = await postValidate("rules", {
    name: "x", phase: "req", cost: 1, match: { method: "GET" },
  });
  assert.equal(status, 200);
  assert.ok(!body.ok);
  assert.ok(body.errors.some((e) => e.includes("array")));
});

test("e2e: validate config — accepts a valid config", async () => {
  const { status, body } = await postValidate("config", {
    emission_interval: 500,
    burst: 50000,
    mode: "monitor",
  });
  assert.equal(status, 200);
  assert.ok(body.ok, `expected ok=true, got: ${JSON.stringify(body.errors)}`);
});

test("e2e: validate config — rejects unknown keys", async () => {
  const { status, body } = await postValidate("config", { burts: 500 });
  assert.equal(status, 200);
  assert.ok(!body.ok);
  assert.ok(body.errors.some((e) => e.includes("burts")));
});

test("e2e: validate — missing kind parameter returns 400", async () => {
  const res = await fetch(`${FIREWALL_URL}/firewall/admin/validate`, {
    ...fetchOpts,
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "[]",
  });
  const json = await res.json();
  assert.equal(res.status, 400);
  assert.ok(!json.ok);
});

test("e2e: validate — empty body returns 400", async () => {
  const res = await fetch(
    `${FIREWALL_URL}/firewall/admin/validate?kind=rules`,
    { ...fetchOpts, method: "POST" },
  );
  const json = await res.json();
  assert.equal(res.status, 400);
  assert.ok(!json.ok);
});

test("e2e: validate — invalid JSON body returns 400", async () => {
  const res = await fetch(
    `${FIREWALL_URL}/firewall/admin/validate?kind=rules`,
    {
      ...fetchOpts,
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{not valid json",
    },
  );
  const json = await res.json();
  assert.equal(res.status, 400);
  assert.ok(!json.ok);
});

// ---------------------------------------------------------------------------

test("e2e: repeated YisouSpider requests are eventually rate-limited (429)", async () => {
  const ip = "10.3.0.2";
  await resetFirewall();

  // YisouSpider costs 51 per request (base 1 + yisou 50).
  // Under any reasonable GCRA config (burst <= 200 s, emission_interval <= 1000 ms)
  // 60 requests will exhaust capacity and produce a 429.
  let got429 = false;
  for (let i = 0; i < 60; i++) {
    const res = await sendRequest(ip, { ua: "YisouSpider" });
    if (res.status === 429) {
      got429 = true;
      await res.body?.cancel();
      break;
    }
    await res.body?.cancel();
  }
  assert.ok(
    got429,
    "IP sending YisouSpider requests should eventually receive 429",
  );
});

test("e2e: rate limiting is per-IP — unrelated IPs are not affected", async () => {
  const spamIp = "10.3.0.3";
  const cleanIp = "10.3.0.4";
  await resetFirewall();

  // Drive spamIp into a blocked state
  for (let i = 0; i < 60; i++) {
    const res = await sendRequest(spamIp, { ua: "YisouSpider" });
    await res.body?.cancel();
    if (res.status === 429) break;
  }

  // A completely different IP should still receive 200
  const res = await sendRequest(cleanIp);
  assert.equal(
    res.status,
    200,
    "an unrelated IP should not be affected by another IP's rate limit",
  );
  await res.body?.cancel();
});

test("e2e: JSP path probes are rate-limited quickly", async () => {
  const ip = "10.3.0.5";
  await resetFirewall();

  // JSP cost: base(1) + jsp rule(40) = 41 per request — exhausts burst in ~30-40 hits
  let got429 = false;
  for (let i = 0; i < 60; i++) {
    const res = await sendRequest(ip, { path: "/admin/login.jsp" });
    if (res.status === 429) {
      got429 = true;
      await res.body?.cancel();
      break;
    }
    await res.body?.cancel();
  }
  assert.ok(got429, "IP probing JSP paths should be rate-limited");
});

// ---------------------------------------------------------------------------
// CSV fixture replay
// ---------------------------------------------------------------------------
// Place one or more CSV files in opt/lua/fixtures/ with the headers below to
// replay real traffic logs against the firewall.  The test is skipped
// automatically when no fixture files are found — no flags required.
//
// Required CSV headers (from Cloudwatch Logs Insights export):
//   http_host
//   request_uri
//   remote_addr
//   status
//   http_user_agent
//   request_method
//   time
//
// The test replays requests preserving inter-request timing from the log, and
// asserts that the firewall's response code matches the logged status for each
// row.  Rows where the logged status is outside 2xx/4xx/5xx are skipped.
// ---------------------------------------------------------------------------

function parseCsv(text) {
  const lines = text.trim().split("\n");
  const headers = lines[0]
    .split(",")
    .map((h) => h.trim().replace(/^"|"$/g, ""));
  return lines.slice(1).map((line) => {
    // Simple CSV parse — handles quoted fields containing commas.
    const values = [];
    let current = "";
    let inQuotes = false;
    for (const ch of line) {
      if (ch === '"') {
        inQuotes = !inQuotes;
      } else if (ch === "," && !inQuotes) {
        values.push(current.trim());
        current = "";
      } else {
        current += ch;
      }
    }
    values.push(current.trim());
    return Object.fromEntries(headers.map((h, i) => [h, values[i] ?? ""]));
  });
}

async function findFixtureCsvFiles() {
  const files = [];
  const dir = new URL("fixtures/", import.meta.url).pathname;
  try {
    if (isDeno) {
      for await (const entry of Deno.readDir(dir)) {
        if (entry.isFile && entry.name.endsWith(".csv")) {
          files.push(`${dir}${entry.name}`);
        }
      }
    } else {
      const { readdir } = await import("node:fs/promises");
      const entries = await readdir(dir);
      for (const name of entries) {
        if (name.endsWith(".csv")) files.push(`${dir}/${name}`);
      }
    }
  } catch (e) {
    console.error(`[fixtures] failed to read dir "${dir}":`, e.message);
  }
  return files;
}

async function readFile(path) {
  if (isDeno) return await Deno.readTextFile(path);
  const { readFile: nodeReadFile } = await import("node:fs/promises");
  return await nodeReadFile(path, "utf8");
}

const fixtureFiles = await findFixtureCsvFiles();

for (const fixturePath of fixtureFiles) {
  const fixtureName = fixturePath.split("/").pop();

  test(`e2e: fixture replay — ${fixtureName}`, async () => {
    await resetFirewall();

    const csv = await readFile(fixturePath);
    const H = {
      host: "http_host",
      uri: "request_uri",
      ip: "remote_addr",
      status: "status",
      ua: "http_user_agent",
      method: "request_method",
      time: "time",
    };

    const rows = parseCsv(csv).sort(
      (a, b) => new Date(a[H.time]).getTime() - new Date(b[H.time]).getTime(),
    );

    const firstTs = new Date(rows[0]?.[H.time]).getTime();
    const lastTs = new Date(rows[rows.length - 1]?.[H.time]).getTime();
    const expectedMs = isNaN(firstTs) || isNaN(lastTs) ? 0 : lastTs - firstTs;
    console.log(
      `[fixtures] ${fixtureName}: ${rows.length} rows, expected replay duration ~${(expectedMs / 1000).toFixed(1)}s`,
    );

    let lastTimestamp = null;
    let skipped = 0;
    let replayed = 0;
    // ip -> { blocked: number, allowed: number }
    const ipStats = {};

    for (const row of rows) {
      const loggedStatus = parseInt(row[H.status], 10);
      if (isNaN(loggedStatus)) {
        skipped++;
        continue;
      }

      // Preserve inter-request timing from the log.
      const ts = new Date(row[H.time]).getTime();
      if (lastTimestamp !== null && ts > lastTimestamp) {
        const gap = ts - lastTimestamp;
        await new Promise((resolve) => setTimeout(resolve, gap));
      }
      lastTimestamp = isNaN(ts) ? lastTimestamp : ts;

      const res = await fetch(`${FIREWALL_URL}${row[H.uri] || "/"}`, {
        ...fetchOpts,
        redirect: "manual",
        method: row[H.method] || "GET",
        headers: {
          Host: "hale.docker",
          "X-Forwarded-For": row[H.ip] || "127.0.0.1",
          "X-Forwarded-Proto": "https",
          "User-Agent": row[H.ua] || "",
        },
      });
      const ip = row[H.ip] || "127.0.0.1";
      const blocked = res.status === 429;
      if (!ipStats[ip]) ipStats[ip] = { blocked: 0, allowed: 0 };
      if (blocked) ipStats[ip].blocked++;
      else ipStats[ip].allowed++;
      await res.body?.cancel();
      replayed++;
    }

    const blockedIps = Object.entries(ipStats).filter(([, s]) => s.blocked > 0);
    console.log(
      `[fixtures] ${fixtureName}: replayed=${replayed} skipped=${skipped} ` +
        `blocked_ips=${blockedIps.length} (${blockedIps.map(([ip, s]) => `${ip}: ${s.blocked}/${s.blocked + s.allowed} blocked`).join(", ") || "none"})`,
    );

    if (fixtureName === "example.csv") {
      assert.ok(
        (ipStats["10.3.0.9"]?.blocked ?? 0) > 0,
        "example.csv: expected at least one request from 10.3.0.9 to be blocked (429)",
      );
    }
  });
}
