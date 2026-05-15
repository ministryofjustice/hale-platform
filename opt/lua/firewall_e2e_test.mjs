// E2E tests for Node.js (18+).
// No package.json or node_modules needed.
// Run: node --test firewall_e2e_test.mjs
//
// Prerequisites
// -------------
// 1. dory up                  — starts the local DNS proxy so hale.docker resolves
// 2. make run-with-firewall   — starts nginx, WordPress, Redis and loads the firewall
// 3. Seed rules in Redis     — the firewall defaults to monitor mode with no rules;
//    open http://redis-insight.docker and create these two string keys:
//
//    firewall:rules
//      [{"name":"req-base","phase":"req","cost":1,"match":{}},
//       {"name":"req-yisou","phase":"req","cost":50,"match":{"ua_pattern":"YisouSpider"}},
//       {"name":"req-jsp","phase":"req","cost":40,"match":{"uri_pattern":"\\.jsp$"}}]
//
//    firewall:config
//      {"mode":"enforce"}
//
//    Then increment firewall:cache_version to trigger an immediate reload.

// Allow our self-signed https cert.
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

const { test } = await import("node:test");
const { default: assert } = await import("node:assert/strict");

const FIREWALL_URL = "https://hale.docker";

// Redis connection — defaults to host.docker.internal:6379.
// Docker Desktop adds host.docker.internal to /etc/hosts on the Mac host too,
// so this resolves correctly whether node runs natively or inside a container.
// Override with:  REDIS_URL=host:port node --test firewall_e2e_test.mjs
const [_redisHost, _redisPort = "6379"] = (process.env.REDIS_URL ?? "127.0.0.1:6379").split(":");

// ---------------------------------------------------------------------------
// Connectivity pre-check — must pass before any other test runs
// ---------------------------------------------------------------------------
// Attempts a single GET to FIREWALL_URL.  If it fails (DNS, connection
// refused, TLS, etc.) all remaining tests are skipped and help is printed.
// ---------------------------------------------------------------------------

let _firewallReachable = false;

try {
  const probe = await fetch(`${FIREWALL_URL}/firewall/stats`, {
    signal: AbortSignal.timeout(5000),
  });
  await probe.body?.cancel();
  if (probe.status !== 200) {
    throw `http response code ${probe.status}`;
  }
  _firewallReachable = true;
} catch (e) {
  console.error(e);
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
    method,
    headers: {
      "X-Forwarded-For": ip,
      "X-Forwarded-Proto": "https",
      "User-Agent": ua,
    },
  });
}

async function resetRateLimitState() {
  const res = await fetch(`${FIREWALL_URL}/firewall/clear-rate-limits`);
  await res.body?.cancel();
}

// ---------------------------------------------------------------------------
// Minimal RESP2 Redis client — talks directly to Redis over TCP.
// No docker binary or redis-cli needed.
//
// Returns the response as a string: integers and simple strings as-is,
// bulk strings as their value, nil bulk strings ($-1) as "".
// Redis errors throw.
// ---------------------------------------------------------------------------
async function redisCmd(...args) {
  const { createConnection } = await import("node:net");
  return new Promise((resolve, reject) => {
    const cmd =
      `*${args.length}\r\n` +
      args.map((a) => `$${Buffer.byteLength(String(a))}\r\n${a}\r\n`).join("");
    const sock = createConnection({ host: _redisHost, port: Number(_redisPort) });
    let buf = "";
    sock.setEncoding("utf8");
    sock.on("connect", () => sock.write(cmd));
    sock.on("data", (chunk) => {
      buf += chunk;
      const type = buf[0];
      if (type === "+" || type === "-" || type === ":") {
        const end = buf.indexOf("\r\n");
        if (end === -1) return;
        sock.destroy();
        if (type === "-") return reject(new Error(buf.slice(1, end)));
        resolve(buf.slice(1, end));
      } else if (type === "$") {
        const firstCrlf = buf.indexOf("\r\n");
        if (firstCrlf === -1) return;
        const len = parseInt(buf.slice(1, firstCrlf), 10);
        if (len === -1) { sock.destroy(); return resolve(""); }
        const dataStart = firstCrlf + 2;
        if (buf.length < dataStart + len + 2) return;
        sock.destroy();
        resolve(buf.slice(dataStart, dataStart + len));
      }
    });
    sock.on("error", reject);
  });
}

// ---------------------------------------------------------------------------
// Sanity / infrastructure checks
// ---------------------------------------------------------------------------

test("e2e: normal GET request returns 200", async () => {
  await resetRateLimitState();
  const res = await sendRequest("10.3.0.1");
  assert.equal(res.status, 200, "clean request should be allowed");
  await res.body?.cancel();
});

test("e2e: /firewall/stats endpoint returns 200", async () => {
  const res = await fetch(`${FIREWALL_URL}/firewall/stats`);
  assert.equal(res.status, 200, "/firewall/stats should always respond");
  await res.body?.cancel();
});

test("e2e: /firewall/clear-rate-limits returns ok:true and unblocks a rate-limited IP", async () => {
  const ip = "10.3.0.6";
  await resetRateLimitState();

  // Pre-condition: drive the IP to 429 so there is state to clear.
  let got429 = false;
  for (let i = 0; i < 60; i++) {
    const res = await sendRequest(ip, { ua: "YisouSpider" });
    const s = res.status;
    await res.body?.cancel();
    if (s === 429) { got429 = true; break; }
  }
  assert.ok(got429, "IP should be rate-limited before clear (pre-condition)");

  // Call the endpoint explicitly and assert the response shape.
  const clearRes = await fetch(`${FIREWALL_URL}/firewall/clear-rate-limits`);
  const clearBody = await clearRes.json();
  assert.equal(clearRes.status, 200);
  assert.ok(clearBody.ok, `expected ok:true, got: ${JSON.stringify(clearBody)}`);
  assert.ok(
    clearBody.deleted > 0,
    `expected at least one key deleted, got deleted=${clearBody.deleted}`,
  );

  // The IP should now be allowed again.
  const after = await sendRequest(ip);
  assert.equal(after.status, 200, "IP should be unblocked after clear-rate-limits");
  await after.body?.cancel();
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
    { name: "req-base", phase: "req", cost: 1, match: {} },
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
  assert.equal(status, 400);
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

// ---------------------------------------------------------------------------
// /firewall/admin/validate — allowlist and blocklist
// ---------------------------------------------------------------------------

test("e2e: validate allowlist — accepts valid CIDRs and bare IPs", async () => {
  const { status, body } = await postValidate("allowlist", [
    "10.0.0.0/8",
    "192.168.1.0/24",
    "172.16.5.5",
  ]);
  assert.equal(status, 200);
  assert.ok(body.ok, `expected ok=true, got: ${JSON.stringify(body.errors)}`);
  assert.equal(body.normalised.length, 3);
});

test("e2e: validate allowlist — rejects an invalid CIDR", async () => {
  const { status, body } = await postValidate("allowlist", [
    "10.0.0.0/8",
    "not-an-ip",
  ]);
  assert.equal(status, 200);
  assert.ok(!body.ok, "expected ok=false for invalid entry");
  assert.ok(
    body.errors.some((e) => e.includes("not-an-ip")),
    `expected error mentioning the bad entry, got: ${JSON.stringify(body.errors)}`,
  );
});

test("e2e: validate allowlist — rejects a non-array body", async () => {
  const { status, body } = await postValidate("allowlist", { cidr: "10.0.0.0/8" });
  assert.equal(status, 400);
  assert.ok(!body.ok);
});

test("e2e: validate blocklist — accepts valid CIDRs", async () => {
  const { status, body } = await postValidate("blocklist", [
    "203.0.113.0/24",
    "198.51.100.1",
  ]);
  assert.equal(status, 200);
  assert.ok(body.ok, `expected ok=true, got: ${JSON.stringify(body.errors)}`);
  assert.equal(body.normalised.length, 2);
});

test("e2e: validate blocklist — rejects an out-of-range prefix", async () => {
  const { status, body } = await postValidate("blocklist", ["10.0.0.0/33"]);
  assert.equal(status, 200);
  assert.ok(!body.ok, "expected ok=false for /33 prefix");
});

test("e2e: validate — unknown kind returns 400", async () => {
  const res = await fetch(
    `${FIREWALL_URL}/firewall/admin/validate?kind=unknown`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "[]",
    },
  );
  const json = await res.json();
  assert.equal(res.status, 400);
  assert.ok(!json.ok);
});

test("e2e: validate — missing kind parameter returns 400", async () => {
  const res = await fetch(`${FIREWALL_URL}/firewall/admin/validate`, {
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
    { method: "POST" },
  );
  const json = await res.json();
  assert.equal(res.status, 400);
  assert.ok(!json.ok);
});

test("e2e: validate — invalid JSON body returns 400", async () => {
  const res = await fetch(
    `${FIREWALL_URL}/firewall/admin/validate?kind=rules`,
    {
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
  await resetRateLimitState();

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
  await resetRateLimitState();

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
  await resetRateLimitState();

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
// Cache invalidation — version counter propagation
// ---------------------------------------------------------------------------
// INCRs firewall:cache_version directly in Redis and polls /firewall/stats
// until the cache_version field advances.  Proves the 1 s background poller
// fired and load_rules_and_config was triggered — no rule writes needed.
// ---------------------------------------------------------------------------

test("e2e: cache_version in stats advances when firewall:cache_version is incremented", async () => {
  const before = await (await fetch(`${FIREWALL_URL}/firewall/stats`)).json();

  await redisCmd("INCR", "firewall:cache_version");

  // Poll until the background poller mirrors the new value into rc_shared and
  // a stats call triggers load_rules_and_config.  The poller fires every 1 s;
  // allow 3 s as headroom.
  let after;
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 200));
    after = await (await fetch(`${FIREWALL_URL}/firewall/stats`)).json();
    if (after.cache_version > before.cache_version) break;
  }

  assert.ok(
    after.cache_version > before.cache_version,
    `cache_version should have advanced within 3 s (before=${before.cache_version}, after=${after?.cache_version})`,
  );
});

// ---------------------------------------------------------------------------
// /firewall/clear-penalties — cluster-wide blocked_cache flush
// ---------------------------------------------------------------------------

test("e2e: penalties_version in stats advances after clear-penalties", async () => {
  await resetRateLimitState();
  const before = await (await fetch(`${FIREWALL_URL}/firewall/stats`)).json();

  const clearRes = await fetch(`${FIREWALL_URL}/firewall/clear-penalties`);
  await clearRes.body?.cancel();

  // Poll until the background poller mirrors the new penalties_version value.
  // The poller fires every 1 s; allow 3 s as headroom.
  let after;
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 200));
    after = await (await fetch(`${FIREWALL_URL}/firewall/stats`)).json();
    if (after.penalties_version > before.penalties_version) break;
  }

  assert.ok(
    after.penalties_version > before.penalties_version,
    `penalties_version should have advanced within 3 s (before=${before.penalties_version}, after=${after?.penalties_version})`,
  );
});

test("e2e: clear-penalties unblocks an auto-banned IP without touching manual bans", async () => {
  const autoIp  = "10.3.1.1";
  const manualIp = "10.3.1.2";
  await resetRateLimitState();

  // Place a manual ban (value "1") and an auto-ban (value "gcra") in Redis.
  await redisCmd("SET", `firewall:block:${manualIp}`, "1");
  await redisCmd("SET", `firewall:block:${autoIp}`,   "gcra");

  const clearRes = await fetch(`${FIREWALL_URL}/firewall/clear-penalties`);
  const clearBody = await clearRes.json();
  assert.equal(clearRes.status, 200);
  assert.ok(clearBody.ok, `expected ok:true, got: ${JSON.stringify(clearBody)}`);
  assert.ok(
    clearBody.deleted >= 1,
    `expected at least one key deleted, got deleted=${clearBody.deleted}`,
  );

  // Auto-ban key should be gone from Redis.
  // redis-cli returns "" (empty) for a missing key in non-TTY mode, so use EXISTS.
  const autoExists = await redisCmd("EXISTS", `firewall:block:${autoIp}`);
  assert.equal(autoExists, "0", `firewall:block:${autoIp} should have been deleted`);

  // Manual ban key must still exist.
  const manualVal = await redisCmd("GET", `firewall:block:${manualIp}`);
  assert.equal(manualVal, "1", `firewall:block:${manualIp} (manual ban) must be untouched`);

  // Auto-banned IP should now be allowed through (blocked_cache flushed by poller).
  // Poll briefly to give the 1 s poller time to fire.
  let autoAllowed = false;
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    const res = await sendRequest(autoIp);
    await res.body?.cancel();
    if (res.status === 200) { autoAllowed = true; break; }
    await new Promise((r) => setTimeout(r, 200));
  }
  assert.ok(autoAllowed, `auto-banned IP ${autoIp} should be allowed after clear-penalties`);

  // Clean up the manual ban so later tests are unaffected.
  await redisCmd("DEL", `firewall:block:${manualIp}`);
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
// summarizes the observed firewall behavior for the replayed traffic.
// Rows where the logged status is not a valid integer are skipped.
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
    const { readdir } = await import("node:fs/promises");
    const entries = await readdir(dir);
    for (const name of entries) {
      if (name.endsWith(".csv")) files.push(`${dir}/${name}`);
    }
  } catch (e) {
    console.error(`[fixtures] failed to read dir "${dir}":`, e.message);
  }
  return files;
}

async function readFile(path) {
  const { readFile: nodeReadFile } = await import("node:fs/promises");
  return await nodeReadFile(path, "utf8");
}

const fixtureFiles = await findFixtureCsvFiles();

for (const fixturePath of fixtureFiles) {
  const fixtureName = fixturePath.split("/").pop();

  test(`e2e: fixture replay — ${fixtureName}`, async () => {
    await resetRateLimitState();

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
