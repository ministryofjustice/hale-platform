// Mock Auth0 tenant for the end-to-end tests: the auth0-mock service in
// docker-compose.test.yml, at https://auth0.e2e.test/ on both test networks,
// so the browser (playwright service) and WordPress (wordpress service) reach
// it at the same address, as they would a real tenant.
//
// It implements the parts of Auth0 the Login by Auth0 plugin talks to:
//
//   GET  /authorize                    Universal Login. Signs in straight away
//                                      when the browser has a mock session
//                                      cookie, else shows a one-field login form
//   POST /u/login                      that form: starts the mock session
//   POST /oauth/token                  authorization_code (with PKCE when the
//                                      authorize request sent a challenge),
//                                      client_credentials and refresh_token
//   GET  /.well-known/jwks.json        the ID token signing key, with x5c
//   GET  /.well-known/openid-configuration
//   GET  /userinfo
//   GET  /api/v2/users/{id}            Management API, client_credentials token
//   GET  /v2/logout, /oidc/logout      ends the mock session
//
// Who signs in, and whether Auth0 returns an error instead, is the mock
// session: a cookie on this domain holding the identity as JSON. A test sets
// it through the login form or with context.addCookies (support/auth0.js), so
// tests running in parallel never share a sign-in.
//
// The tenant's Allowed Callback URLs and Allowed Logout URLs are checked as
// Auth0 checks them (AUTH0_MOCK_CALLBACKS, AUTH0_MOCK_LOGOUT_URLS), so a
// plugin that sends users back to a different address fails here as it would
// against the real tenant.
//
// Every request except /__test/* and the favicon is recorded;
// GET /__test/requests returns them. specs/auth0-requests/ compares their shape with a baseline.
//
// No npm packages: it runs on the plain node image.

"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const https = require("node:https");
const path = require("node:path");

const DOMAIN = required("AUTH0_ENV_DOMAIN");
const CLIENT_ID = required("AUTH0_ENV_CLIENT_ID");
const CLIENT_SECRET = required("AUTH0_ENV_CLIENT_SECRET");
const ISSUER = `https://${DOMAIN}/`;
const MANAGEMENT_AUDIENCE = `${ISSUER}api/v2/`;
const CALLBACKS = list(process.env.AUTH0_MOCK_CALLBACKS);
const LOGOUT_URLS = list(process.env.AUTH0_MOCK_LOGOUT_URLS);
const CERTS = process.env.AUTH0_MOCK_CERTS || "/certs";
const PORT = Number(process.env.AUTH0_MOCK_PORT || "443");

const SESSION_COOKIE = "auth0_mock_session";
const MANAGEMENT_SCOPE = "read:users update:users create:users delete:users create:user_tickets read:connections";
const CODE_TTL_MS = 60_000;
const TOKEN_TTL_S = 86_400;

// ID tokens are signed with this key. The JWKS publishes it as a certificate
// (x5c) as well as n and e: the 4.x plugin reads only the certificate.
const signingKey = crypto.createPrivateKey(read("auth0-signing-key.pem"));
const signingCert = new crypto.X509Certificate(read("auth0-signing.pem"));
const KID = crypto.createHash("sha256").update(signingCert.raw).digest("base64url").slice(0, 16);
const publicJwk = signingCert.publicKey.export({ format: "jwk" });
const JWKS = {
  keys: [
    {
      kty: "RSA",
      use: "sig",
      alg: "RS256",
      kid: KID,
      n: publicJwk.n,
      e: publicJwk.e,
      x5c: [signingCert.raw.toString("base64")],
      x5t: crypto.createHash("sha1").update(signingCert.raw).digest("base64url"),
    },
  ],
};

const requests = []; // recorded requests, oldest first
const codes = new Map(); // authorization code -> the authorize request it answers
const accessTokens = new Map(); // access token -> { kind, identity?, scope }
const refreshTokens = new Map(); // refresh token -> { identity, scope }
const users = new Map(); // Auth0 user ID -> identity, for the Management API

function required(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`[auth0-mock] ${name} is not set`);
    process.exit(1);
  }
  return value;
}

function list(value) {
  return (value || "").split(",").map((item) => item.trim()).filter(Boolean);
}

function read(file) {
  return fs.readFileSync(path.join(CERTS, file));
}

function random(bytes = 24) {
  return crypto.randomBytes(bytes).toString("base64url");
}

function base64url(value) {
  return Buffer.from(typeof value === "string" ? value : JSON.stringify(value)).toString("base64url");
}

function signJwt(claims) {
  const input = `${base64url({ alg: "RS256", typ: "JWT", kid: KID })}.${base64url(claims)}`;
  return `${input}.${crypto.sign("sha256", Buffer.from(input), signingKey).toString("base64url")}`;
}

// ---------------------------------------------------------------------------
// Identities
// ---------------------------------------------------------------------------

// A mock session identity, from the cookie or the login form. Only sub is
// required; email_verified defaults to true, as for most connections.
function normaliseIdentity(raw) {
  if (!raw || typeof raw !== "object" || typeof raw.sub !== "string" || !raw.sub.includes("|")) {
    return null;
  }
  const email = typeof raw.email === "string" && raw.email !== "" ? raw.email : undefined;
  return {
    sub: raw.sub,
    email,
    email_verified: email ? raw.email_verified !== false : undefined,
    name: raw.name || email || raw.sub,
    nickname: raw.nickname || (email ? email.split("@")[0] : raw.sub.split("|")[1]),
    // When set, /authorize returns this error to the callback instead of a code.
    error: raw.error || undefined,
    error_description: raw.error_description || undefined,
  };
}

function profileClaims(identity) {
  const claims = {
    sub: identity.sub,
    name: identity.name,
    nickname: identity.nickname,
    picture: `${ISSUER}avatar/${encodeURIComponent(identity.nickname)}.png`,
    updated_at: new Date().toISOString(),
  };
  if (identity.email) {
    claims.email = identity.email;
    claims.email_verified = identity.email_verified;
  }
  return claims;
}

// The Management API's user object, as GET /api/v2/users/{id} returns it.
function managementUser(identity) {
  const [provider, ...rest] = identity.sub.split("|");
  const userId = rest.join("|");
  return {
    ...profileClaims(identity),
    user_id: identity.sub,
    identities: [
      {
        provider,
        user_id: userId,
        connection: provider === "auth0" ? "Username-Password-Authentication" : provider,
        isSocial: !["auth0", "waad", "samlp", "adfs", "oidc", "google-apps"].includes(provider),
      },
    ],
    created_at: "2020-01-01T00:00:00.000Z",
    last_login: new Date().toISOString(),
    logins_count: 1,
  };
}

function idToken(identity, clientId, nonce) {
  const now = Math.floor(Date.now() / 1000);
  return signJwt({
    ...profileClaims(identity),
    iss: ISSUER,
    aud: clientId,
    iat: now,
    exp: now + 36_000,
    auth_time: now,
    sid: random(16),
    ...(nonce ? { nonce } : {}),
  });
}

function issueUserTokens(identity, scope, clientId, nonce) {
  const accessToken = random();
  accessTokens.set(accessToken, { kind: "user", identity, scope });
  const body = {
    access_token: accessToken,
    id_token: idToken(identity, clientId, nonce),
    scope,
    expires_in: TOKEN_TTL_S,
    token_type: "Bearer",
  };
  if (scope.split(" ").includes("offline_access")) {
    body.refresh_token = random();
    refreshTokens.set(body.refresh_token, { identity, scope });
  }
  return body;
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

function parseCookies(header) {
  const cookies = {};
  for (const part of (header || "").split(";")) {
    const index = part.indexOf("=");
    if (index > 0) cookies[part.slice(0, index).trim()] = decodeURIComponent(part.slice(index + 1).trim());
  }
  return cookies;
}

// JSON when it looks like JSON, whatever the Content-Type says: the 4.x
// plugin sends JSON bodies without one. Otherwise a form.
function parseBody(raw) {
  if (raw === "") return null;
  const trimmed = raw.trim();
  if (trimmed.startsWith("{")) {
    try {
      return JSON.parse(trimmed);
    } catch {
      return raw;
    }
  }
  return Object.fromEntries(new URLSearchParams(raw));
}

function sessionFrom(req) {
  const value = parseCookies(req.headers.cookie)[SESSION_COOKIE];
  if (!value) return null;
  try {
    return normaliseIdentity(JSON.parse(Buffer.from(value, "base64url").toString("utf8")));
  } catch {
    return null;
  }
}

function sessionCookie(identity) {
  return `${SESSION_COOKIE}=${base64url(identity)}; Path=/; Secure; HttpOnly; SameSite=Lax`;
}

const CLEAR_SESSION = `${SESSION_COOKIE}=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0`;

function send(res, status, body, headers = {}) {
  const isJson = body !== null && typeof body === "object";
  res.writeHead(status, {
    "Cache-Control": "no-store",
    "Content-Type": isJson ? "application/json" : "text/html; charset=utf-8",
    ...headers,
  });
  res.end(isJson ? JSON.stringify(body) : body ?? "");
}

function redirect(res, location, headers = {}) {
  res.writeHead(302, { Location: location, "Cache-Control": "no-store", ...headers });
  res.end();
}

function withParams(url, params) {
  const target = new URL(url);
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null) target.searchParams.set(key, value);
  }
  return target.toString();
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

function page(title, body) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${escapeHtml(title)}</title></head>` +
    `<body><main><h1>${escapeHtml(title)}</h1>${body}</main></body></html>`;
}

// Client authentication for /oauth/token: client_secret_post or _basic.
function clientFrom(req, body) {
  const basic = /^Basic (.+)$/i.exec(req.headers.authorization || "");
  if (basic) {
    const [id, secret] = Buffer.from(basic[1], "base64").toString("utf8").split(":");
    return { id: decodeURIComponent(id), secret: decodeURIComponent(secret ?? "") };
  }
  return { id: body?.client_id, secret: body?.client_secret };
}

function bearer(req) {
  const match = /^Bearer (.+)$/i.exec(req.headers.authorization || "");
  return match ? accessTokens.get(match[1]) : undefined;
}

function record(req, url, rawBody) {
  const telemetry = req.headers["auth0-client"];
  let client = null;
  if (telemetry) {
    try {
      client = JSON.parse(Buffer.from(telemetry, "base64").toString("utf8"));
    } catch {
      client = { unreadable: telemetry };
    }
  }
  const authorization = /^(\w+)/.exec(req.headers.authorization || "");
  requests.push({
    seq: requests.length + 1,
    time: new Date().toISOString(),
    // WordPress's HTTP API sends "WordPress/<version>; <site>"; anything else
    // here is the browser.
    from: /^WordPress\//.test(req.headers["user-agent"] || "") ? "server" : "browser",
    method: req.method,
    path: url.pathname,
    query: Object.fromEntries(url.searchParams),
    contentType: req.headers["content-type"] || null,
    authorization: authorization ? authorization[1] : null,
    client,
    body: parseBody(rawBody),
  });
}

// ---------------------------------------------------------------------------
// Endpoints
// ---------------------------------------------------------------------------

function authorize(req, res, url) {
  const params = Object.fromEntries(url.searchParams);
  const redirectUri = params.redirect_uri;

  if (params.client_id !== CLIENT_ID) {
    return send(res, 400, page("Unknown client", `<p>client_id ${escapeHtml(params.client_id ?? "(none)")} is not an application on this tenant.</p>`));
  }
  if (!redirectUri || (CALLBACKS.length && !CALLBACKS.includes(redirectUri))) {
    return send(res, 400, page("Callback URL mismatch", `<p>${escapeHtml(redirectUri ?? "(none)")} is not in the list of Allowed Callback URLs.</p>`));
  }
  if (params.response_type !== "code") {
    return redirect(res, withParams(redirectUri, {
      error: "unsupported_response_type",
      error_description: `Unsupported response type: ${params.response_type}`,
      state: params.state,
    }));
  }
  if (params.response_mode && params.response_mode !== "query") {
    return send(res, 400, page("Unsupported response mode", `<p>The mock tenant only answers with response_mode=query.</p>`));
  }

  const identity = sessionFrom(req);
  if (!identity) {
    return send(res, 200, loginForm(url));
  }

  if (identity.error) {
    return redirect(res, withParams(redirectUri, {
      error: identity.error,
      error_description: identity.error_description ?? identity.error,
      state: params.state,
    }));
  }

  if (params.code_challenge && params.code_challenge_method !== "S256") {
    return redirect(res, withParams(redirectUri, {
      error: "invalid_request",
      error_description: "code_challenge_method must be S256",
      state: params.state,
    }));
  }

  users.set(identity.sub, identity);
  const code = random();
  codes.set(code, {
    identity,
    clientId: params.client_id,
    redirectUri,
    nonce: params.nonce,
    scope: params.scope || "openid",
    codeChallenge: params.code_challenge,
    expires: Date.now() + CODE_TTL_MS,
  });
  return redirect(res, withParams(redirectUri, { code, state: params.state }));
}

function loginForm(url) {
  const returnTo = `${url.pathname}${url.search}`;
  return page("Log in", `
    <form method="post" action="/u/login">
      <input type="hidden" name="return_to" value="${escapeHtml(returnTo)}">
      <p><label for="email">Email address</label>
        <input id="email" name="email" type="email" required autocomplete="off"></p>
      <p><label for="sub">Auth0 user ID</label>
        <input id="sub" name="sub" type="text" autocomplete="off" placeholder="auth0|..."></p>
      <p><label><input name="email_verified" type="checkbox" value="true" checked> Email address verified</label></p>
      <p><button type="submit">Continue</button></p>
    </form>`);
}

function login(req, res, body) {
  const returnTo = typeof body?.return_to === "string" ? body.return_to : "";
  if (!returnTo.startsWith("/authorize?")) {
    return send(res, 400, page("Bad request", "<p>Missing return_to.</p>"));
  }
  const email = body.email || "";
  const identity = normaliseIdentity({
    sub: body.sub || `auth0|${email.split("@")[0]}`,
    email,
    email_verified: body.email_verified === "true",
  });
  if (!identity) {
    return send(res, 400, page("Bad request", "<p>An email address or an Auth0 user ID is required.</p>"));
  }
  return redirect(res, returnTo, { "Set-Cookie": sessionCookie(identity) });
}

function token(req, res, body) {
  const client = clientFrom(req, body);
  if (client.id !== CLIENT_ID || client.secret !== CLIENT_SECRET) {
    return send(res, 401, { error: "access_denied", error_description: "Unauthorized" });
  }

  switch (body?.grant_type) {
    case "authorization_code": {
      const grant = codes.get(body.code);
      codes.delete(body.code);
      if (!grant || grant.expires < Date.now() || grant.clientId !== client.id) {
        return send(res, 403, { error: "invalid_grant", error_description: "Invalid authorization code" });
      }
      if (body.redirect_uri !== grant.redirectUri) {
        return send(res, 403, { error: "invalid_grant", error_description: "redirect_uri does not match the authorize request" });
      }
      if (grant.codeChallenge) {
        const verifier = body.code_verifier || "";
        const challenge = crypto.createHash("sha256").update(verifier).digest("base64url");
        if (challenge !== grant.codeChallenge) {
          return send(res, 403, { error: "invalid_grant", error_description: "Failed to verify code verifier" });
        }
      }
      return send(res, 200, issueUserTokens(grant.identity, grant.scope, client.id, grant.nonce));
    }

    case "client_credentials": {
      if (body.audience !== MANAGEMENT_AUDIENCE) {
        return send(res, 403, { error: "access_denied", error_description: `Service not found: ${body.audience}` });
      }
      const accessToken = random();
      accessTokens.set(accessToken, { kind: "management", scope: MANAGEMENT_SCOPE });
      return send(res, 200, {
        access_token: accessToken,
        scope: MANAGEMENT_SCOPE,
        expires_in: TOKEN_TTL_S,
        token_type: "Bearer",
      });
    }

    case "refresh_token": {
      const grant = refreshTokens.get(body.refresh_token);
      if (!grant) {
        return send(res, 403, { error: "invalid_grant", error_description: "Unknown or invalid refresh token." });
      }
      const issued = issueUserTokens(grant.identity, grant.scope, client.id);
      delete issued.refresh_token;
      return send(res, 200, issued);
    }

    default:
      return send(res, 403, { error: "unsupported_grant_type", error_description: `Unsupported grant type: ${body?.grant_type}` });
  }
}

function userinfo(req, res) {
  const grant = bearer(req);
  if (!grant || grant.kind !== "user") return send(res, 401, "Unauthorized");
  return send(res, 200, profileClaims(grant.identity));
}

function managementApi(req, res, url) {
  const grant = bearer(req);
  if (!grant || grant.kind !== "management") {
    return send(res, 401, { statusCode: 401, error: "Unauthorized", message: "Missing or invalid token" });
  }
  const match = /^\/api\/v2\/users\/([^/]+)$/.exec(url.pathname);
  if (req.method === "GET" && match) {
    const identity = users.get(decodeURIComponent(match[1]));
    if (!identity) return send(res, 404, { statusCode: 404, error: "Not Found", message: "The user does not exist.", errorCode: "inexistent_user" });
    return send(res, 200, managementUser(identity));
  }
  return send(res, 501, { statusCode: 501, error: "Not Implemented", message: `The mock tenant does not implement ${req.method} ${url.pathname}` });
}

function logout(req, res, url, returnParam) {
  const returnTo = url.searchParams.get(returnParam);
  const clientId = url.searchParams.get("client_id");
  if (clientId && clientId !== CLIENT_ID) {
    return send(res, 400, page("Unknown client", "<p>Unknown client_id.</p>"), { "Set-Cookie": CLEAR_SESSION });
  }
  if (!returnTo) {
    return send(res, 200, page("Logged out", "<p>You have been logged out.</p>"), { "Set-Cookie": CLEAR_SESSION });
  }
  if (LOGOUT_URLS.length && !LOGOUT_URLS.includes(returnTo)) {
    return send(res, 400, page("Logout URL mismatch", `<p>${escapeHtml(returnTo)} is not in the list of Allowed Logout URLs.</p>`), { "Set-Cookie": CLEAR_SESSION });
  }
  return redirect(res, returnTo, { "Set-Cookie": CLEAR_SESSION });
}

function route(req, res, url, rawBody) {
  const body = parseBody(rawBody);
  const key = `${req.method} ${url.pathname}`;

  switch (key) {
    case "GET /authorize":
      return authorize(req, res, url);
    case "POST /u/login":
      return login(req, res, body);
    case "POST /oauth/token":
      return token(req, res, body);
    case "GET /.well-known/jwks.json":
      return send(res, 200, JWKS);
    case "GET /.well-known/openid-configuration":
      return send(res, 200, {
        issuer: ISSUER,
        authorization_endpoint: `${ISSUER}authorize`,
        token_endpoint: `${ISSUER}oauth/token`,
        userinfo_endpoint: `${ISSUER}userinfo`,
        jwks_uri: `${ISSUER}.well-known/jwks.json`,
        end_session_endpoint: `${ISSUER}oidc/logout`,
        response_types_supported: ["code"],
        response_modes_supported: ["query"],
        subject_types_supported: ["public"],
        id_token_signing_alg_values_supported: ["RS256"],
        token_endpoint_auth_methods_supported: ["client_secret_post", "client_secret_basic"],
        code_challenge_methods_supported: ["S256"],
        scopes_supported: ["openid", "profile", "email", "offline_access"],
      });
    case "GET /userinfo":
      return userinfo(req, res);
    case "GET /v2/logout":
      return logout(req, res, url, "returnTo");
    case "GET /oidc/logout":
      return logout(req, res, url, "post_logout_redirect_uri");
  }

  if (url.pathname.startsWith("/api/v2/")) return managementApi(req, res, url);

  return send(res, 404, { error: "not_found", error_description: `The mock tenant has no ${key}` });
}

// Test-only endpoints, never recorded.
function testEndpoint(req, res, url) {
  switch (`${req.method} ${url.pathname}`) {
    case "GET /__test/health":
      return send(res, 200, { ok: true });
    case "GET /__test/requests":
      return send(res, 200, { requests });
    default:
      return send(res, 404, { error: "not_found" });
  }
}

const server = https.createServer({ key: read("auth0-mock-key.pem"), cert: read("auth0-mock.pem") }, (req, res) => {
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    const url = new URL(req.url, ISSUER);
    const rawBody = Buffer.concat(chunks).toString("utf8");
    try {
      if (url.pathname.startsWith("/__test/")) return testEndpoint(req, res, url);
      // The browser asks for one when it shows the login form.
      if (url.pathname === "/favicon.ico") return send(res, 204, "");
      record(req, url, rawBody);
      route(req, res, url, rawBody);
    } catch (error) {
      console.error(`[auth0-mock] ${req.method} ${req.url}:`, error);
      send(res, 500, { error: "server_error", error_description: String(error) });
    }
  });
});

server.listen(PORT, () => {
  console.log(`[auth0-mock] ${ISSUER} listening on ${PORT}`);
  console.log(`[auth0-mock] Allowed Callback URLs: ${CALLBACKS.join(", ") || "(any)"}`);
  console.log(`[auth0-mock] Allowed Logout URLs: ${LOGOUT_URLS.join(", ") || "(any)"}`);
});
