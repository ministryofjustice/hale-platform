// User migration endpoints (opt/php/auth0.php).
//
// Until Auth0 has imported a user, its database connection asks WordPress to
// check their email and password, or whether their email has an account.
// These tests POST the same way the connection's scripts do: to the main
// site's index.php, with AUTH0_ENV_MIGRATION_TOKEN (docker-compose.test.yml).
// The ingress puts the caller's IP address in X-Forwarded-For, so the tests
// send one of Auth0's EU addresses there.

const { test, expect } = require("../../support/test");
const { NETWORK_URL, PASSWORD, users } = require("../../support/stack");
const { MIGRATION_TOKEN, auth0Sites, identities } = require("../../support/auth0");

const ENDPOINT = `${NETWORK_URL}index.php`;
const LOGIN = "migration-ws-login";
const GET_USER = "migration-ws-get-user";
const { editor, author, stranger, suspended } = identities;

function post(request, action, form, { url = ENDPOINT, from = "18.197.9.11" } = {}) {
  return request.post(`${url}?a0_action=${action}`, {
    form,
    headers: { "X-Forwarded-For": from },
    maxRedirects: 0,
  });
}

// Responses are always HTTP 200 with JSON, as in 4.x, because the scripts
// read `error`. A migration check never logs anyone in.
async function ask(request, action, form, options) {
  const response = await post(request, action, form, options);
  expect(response.status()).toBe(200);
  expect(response.headers()["set-cookie"] ?? "").not.toContain("wordpress_logged_in_");
  return response.json();
}

const login = (email, password = PASSWORD, access_token = MIGRATION_TOKEN) => ({ username: email, password, access_token });
const getUser = (email) => ({ username: email, access_token: MIGRATION_TOKEN });

for (const [action, form, login_name] of [
  [LOGIN, login(editor.email), users.editor],
  [GET_USER, getUser(author.email), users.author],
]) {
  test(`${action} gives the scripts the user, and nothing else`, async ({ request }) => {
    const { data } = await ask(request, action, form);

    expect(Object.keys(data).sort()).toEqual(["ID", "display_name", "user_email", "user_login"]);
    expect(data).toMatchObject({ user_login: login_name, user_email: form.username });
  });
}

for (const [label, action, form, options, error] of [
  ["a wrong password", LOGIN, login(editor.email, `${PASSWORD}-wrong`), {}, [401, "Invalid credentials"]],
  ["a suspended user's password", LOGIN, login(suspended.email), {}, [401, "Invalid credentials"]],
  ["an email address with no account", GET_USER, getUser(stranger.email), {}, [401, "User not found"]],
  ["a suspended user", GET_USER, getUser(suspended.email), {}, [401, "User not found"]],
  ["a wrong token", LOGIN, login(editor.email, PASSWORD, `${MIGRATION_TOKEN}-wrong`), {}, [401, "Invalid token"]],
  ["a missing token", LOGIN, login(editor.email, PASSWORD, ""), {}, [401, "Unauthorized: missing authorization header"]],
  ["an address that is not Auth0's", LOGIN, login(editor.email), { from: "203.0.113.9" }, [401, "Unauthorized"]],
]) {
  test(`refuses ${label}`, async ({ request }) => {
    const [status, message] = error;
    expect(await ask(request, action, form, options)).toEqual({ status, error: message });
  });
}

test("answers only a POST to the main site's index.php", async ({ request }) => {
  const notAnswered = async (response) =>
    expect(response.headers()["content-type"] ?? "").not.toContain("json");

  await notAnswered(await request.get(`${ENDPOINT}?a0_action=${LOGIN}`, { maxRedirects: 0 }));
  for (const url of [NETWORK_URL, `${auth0Sites.main.url}index.php`, `${auth0Sites.second.url}index.php`]) {
    await notAnswered(await post(request, LOGIN, login(editor.email), { url }));
  }
});
