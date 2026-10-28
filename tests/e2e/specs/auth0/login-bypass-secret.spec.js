// The login bypass needs its secret (opt/php/auth0.php). Without it, or with
// the wrong one, the login page goes to Auth0 as usual: the WordPress password
// form is not open to anyone who knows the parameter.

const { test, expect } = require("../../support/test");
const { LOGIN_PATH } = require("../../support/stack");
const { AUTHORIZE_URL, FALLBACK_PARAM } = require("../../support/auth0");

for (const [label, query] of [
  ["no secret", `?${FALLBACK_PARAM}`],
  ["the wrong secret", `?${FALLBACK_PARAM}=not-the-secret`],
]) {
  test(`the login bypass with ${label} goes to Auth0`, async ({ page }) => {
    await page.goto(`${LOGIN_PATH}${query}`);

    await expect(page).toHaveURL(AUTHORIZE_URL);
    await expect(page.locator("#user_pass")).toHaveCount(0);
  });
}
