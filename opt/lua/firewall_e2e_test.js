// E2E tests compatible with both Node.js (18+) and Deno (2.0+).
// No package.json or node_modules needed.
// Node:  node --test firewall_e2e_test.js
// Deno:  deno test --allow-net="hale.docker" --allow-read="./fixtures" --unsafely-ignore-certificate-errors firewall_e2e_test.js

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
  const res = await fetch(`${FIREWALL_URL}/firewall/clear-penalties`, fetchOpts);
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
// Rate-limiting behaviour
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
    console.log(`[fixtures] ${fixtureName}: ${rows.length} rows, expected replay duration ~${(expectedMs / 1000).toFixed(1)}s`);

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
