// The end-to-end test stack: its address, its sites and users, and the
// docker compose commands that start, seed and remove it. Shared by
// playwright.config.js, the global setup and teardown, and the specs.

const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../../..");
const E2E_DIR = path.join(ROOT, "tests/e2e");
const STATE_DIR = path.join(E2E_DIR, ".stack");
const AUTH_DIR = path.join(E2E_DIR, ".auth");

const PROJECT = process.env.HALE_TEST_PROJECT || "hale-test";
const PORT = process.env.HALE_TEST_PORT || "8443";
const NETWORK_URL = `https://localhost:${PORT}/`;
// Test-only wps-hide-login slug, set by seed/seed.sh.
const LOGIN_PATH = "e2e-test-login/";
const PASSWORD = process.env.E2E_PASSWORD || "hale-e2e-test-only";

// Same file the seed reads, so a site added there gets a Playwright project.
const sites = require("../seed/sites.json").map((site) => ({
  ...site,
  url: site.path ? `${NETWORK_URL}${site.path}/` : NETWORK_URL,
}));

// Logins the auth setup saves a session for. The seed creates them.
const users = {
  admin: "e2eadmin",
  editor: "e2eeditor",
  author: "e2eauthor",
  contributor: "e2econtributor",
};

const authFile = (role) => path.join(AUTH_DIR, `${role}.json`);

const IMAGES = ["hale-test/wordpress", "hale-test/nginx", "hale-test/wptools"];

function run(command, args, options = {}) {
  return execFileSync(command, args, {
    cwd: ROOT,
    stdio: "inherit",
    env: { ...process.env, HALE_TEST_PROJECT: PROJECT, HALE_TEST_PORT: PORT },
    ...options,
  });
}

function compose(...args) {
  return run("docker", ["compose", "-p", PROJECT, "-f", "docker-compose.test.yml", ...args]);
}

// True when every image exists and hale-test/wordpress was built from the
// current composer.lock. An image from an older lock would test old plugins.
function imagesCurrent() {
  try {
    run("docker", ["image", "inspect", ...IMAGES], { stdio: "ignore" });
    const built = execFileSync(
      "docker",
      ["image", "inspect", "-f", '{{ index .Config.Labels "hale-test.composer-lock" }}', "hale-test/wordpress"],
      { cwd: ROOT, encoding: "utf8" },
    ).trim();
    const lock = execFileSync("git", ["hash-object", "composer.lock"], { cwd: ROOT, encoding: "utf8" }).trim();
    return built === lock;
  } catch {
    return false;
  }
}

// Self-signed certificate for localhost, under the file names
// opt/nginx/localwordpress.conf expects. The key is test-only and world
// readable, because nginx runs as a different user from whoever made it.
function ensureCertificate() {
  const dir = path.join(STATE_DIR, "certs");
  const cert = path.join(dir, "hale.docker.pem");
  const key = path.join(dir, "hale.docker-key.pem");
  if (fs.existsSync(cert) && fs.existsSync(key)) return;

  fs.mkdirSync(dir, { recursive: true });
  run("openssl", [
    "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
    "-subj", "/CN=localhost",
    "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
    "-keyout", key, "-out", cert,
  ], { stdio: "ignore" });
  fs.chmodSync(key, 0o644);
}

function isRunning() {
  try {
    const out = execFileSync(
      "docker",
      ["compose", "-p", PROJECT, "-f", "docker-compose.test.yml", "ps", "--status", "running", "-q", "nginx"],
      { cwd: ROOT, encoding: "utf8" },
    );
    return out.trim() !== "";
  } catch {
    return false;
  }
}

function down() {
  compose("--profile", "seed", "down", "-v", "--remove-orphans");
}

module.exports = {
  ROOT,
  AUTH_DIR,
  PROJECT,
  PORT,
  NETWORK_URL,
  LOGIN_PATH,
  PASSWORD,
  sites,
  users,
  authFile,
  run,
  compose,
  imagesCurrent,
  ensureCertificate,
  isRunning,
  down,
};
