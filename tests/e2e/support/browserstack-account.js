// Check the BrowserStack account at the start of a run that includes the
// BrowserStack tests, so that credentials BrowserStack rejects, or an account
// whose Automate plan has expired, skip those tests with one message instead
// of failing every test.
// First asks the Automate plan API, which rejects bad credentials. An expired
// plan still answers there as if it were active, so it then opens one
// BrowserStack browser session the way the tests do, and closes it again: an
// expired plan refuses that session. Prints the outcome and exits 1 when the
// tests cannot run; never prints the credentials. Run by tests/e2e/stack/stack.sh in the
// browserstack container, which has the credentials and the internet.

const { chromium } = require("playwright");

const PLAN_URL = "https://api.browserstack.com/automate/plan.json";
const CDP_URL = "wss://cdp.browserstack.com/playwright";

function skip(reason) {
  console.log(`[e2e] BrowserStack account check failed: ${reason}.`);
  process.exitCode = 1;
}

// BrowserStack's own explanation, when the body has one.
function apiMessage(body) {
  try {
    const parsed = JSON.parse(body);
    return parsed.message || parsed.error || "";
  } catch {
    return body.trim().slice(0, 200);
  }
}

// The first line of an error, with the credentials taken out: Playwright's
// connect errors can quote the endpoint, whose caps hold them.
function firstLine(error, secrets) {
  let line = String(error?.message || error).split("\n")[0];
  for (const secret of secrets.filter(Boolean)) {
    line = line.split(secret).join("***").split(encodeURIComponent(secret)).join("***");
  }
  return line
    .replace(/\?caps=\S*/g, "")
    .replace(/^browserType\.connect: /, "")
    .replace(/^Error: /, "")
    .replace(/\.$/, "");
}

// One browser session on the desktop platform in browserstack.yml, closed as
// soon as it opens. Shows as a "Hale account check" build in Automate.
async function openSession(user, key) {
  const caps = {
    browser: "chrome",
    os: "OS X",
    os_version: "Sequoia",
    build: "Hale account check",
    name: "account check",
    "browserstack.username": user,
    "browserstack.accessKey": key,
    "client.playwrightVersion": require("playwright/package.json").version,
  };
  const endpoint = `${CDP_URL}?caps=${encodeURIComponent(JSON.stringify(caps))}`;
  const browser = await chromium.connect(endpoint, { timeout: 90000 });
  await browser.close();
}

async function main() {
  const user = process.env.BROWSERSTACK_USERNAME || "";
  const key = process.env.BROWSERSTACK_ACCESS_KEY || "";
  if (!user || !key) {
    return skip("BROWSERSTACK_USERNAME or BROWSERSTACK_ACCESS_KEY is empty");
  }

  let response;
  try {
    response = await fetch(PLAN_URL, {
      headers: {
        Authorization: `Basic ${Buffer.from(`${user}:${key}`).toString("base64")}`,
      },
      signal: AbortSignal.timeout(15000),
    });
  } catch (error) {
    return skip(`could not reach api.browserstack.com (${error.cause?.code || error.name})`);
  }

  const body = await response.text();
  if (response.status === 401) {
    return skip("BrowserStack rejected BROWSERSTACK_USERNAME and BROWSERSTACK_ACCESS_KEY");
  }
  if (!response.ok) {
    const message = apiMessage(body);
    return skip(`BrowserStack answered ${response.status}${message ? `: ${message}` : ""}`);
  }

  let plan;
  try {
    plan = JSON.parse(body);
  } catch {
    return skip("BrowserStack's plan API answered with something other than JSON");
  }
  if (!(plan.parallel_sessions_max_allowed > 0)) {
    return skip(
      `the account has no Automate sessions (plan: ${plan.automate_plan || "none"}). ` +
        "Its Automate plan may have expired",
    );
  }
  try {
    await openSession(user, key);
  } catch (error) {
    return skip(`BrowserStack would not start a browser: ${firstLine(error, [key, user])}`);
  }
  console.log(
    `[e2e] BrowserStack account OK: ${plan.automate_plan}, ` +
      `${plan.parallel_sessions_max_allowed} parallel sessions`,
  );
}

main();
