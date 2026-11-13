// On a site that logs in through Auth0, a WordPress password does not sign
// anyone in without the login bypass's secret (password-fallback.spec.js).
// Replacing the login form is not enough: wp-login.php checks a posted
// password on other actions too. entered_recovery_mode, the action
// recovery-mode links use, runs the same code as the login action without
// firing login_form_login, where the plugin sends people to Auth0.

const { test, expect } = require("../../support/test");
const { LOGIN_PATH, PASSWORD, users } = require("../../support/stack");
const { auth0Sites } = require("../../support/auth0");

const { main } = auth0Sites;

for (const [label, query] of [
  ["the login page", ""],
  ["the recovery-mode login action", "?action=entered_recovery_mode"],
]) {
  test(`a WordPress password posted to ${label} does not sign in`, async ({ page }) => {
    await page.request.post(`${LOGIN_PATH}${query}`, {
      form: { log: users.admin, pwd: PASSWORD },
      maxRedirects: 0,
    });

    const cookies = await page.context().cookies();
    expect(cookies.map((cookie) => cookie.name)).not.toContainEqual(
      expect.stringMatching(/^wordpress_logged_in_/),
    );

    await page.goto(main.url);
    await expect(page.locator("#wpadminbar")).toHaveCount(0);
  });
}
