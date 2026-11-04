// The Auth0 plugin's settings screens, as a site administrator sees them.
// The tenant's domain, client ID and client secret come from the
// environment, set once for the network: a site administrator must not be
// able to read the secret or point their site at a different tenant.
//
// The screens are the admin menu's Auth0 entries, whatever the plugin calls
// them, and every version's settings screens opened directly by address, in
// case the menu hides one that can still be reached.

const { test, expect } = require("../../support/test");

// The plugin's settings screens (admin.php?page=...): 4.x, then 5.x and later.
const SETTINGS_SCREENS = [
  "wpa0", "wpa0-help", "wpa0-errors", "wpa0-import-settings", "wpa0-setup",
  "auth0", "auth0_sync", "auth0_advanced", "auth0_tools",
];
const { LOGIN_PATH } = require("../../support/stack");
const {
  AUTH0_DOMAIN,
  CLIENT_ID,
  CLIENT_SECRET,
  auth0Sites,
  identities,
  signInAtAuth0,
} = require("../../support/auth0");

test("a site administrator cannot read or change the tenant settings", async ({ page }, testInfo) => {
  await page.goto(LOGIN_PATH);
  await signInAtAuth0(page, identities.siteAdmin);
  await page.goto("wp-admin/");
  await expect(page.locator("#wp-admin-bar-my-account")).toContainText("E2E site admin");

  const inMenu = await page
    .locator("#adminmenu a")
    .evaluateAll((links) => links.map((link) => link.href).filter((href) => /[?&]page=(wpa0|auth0)/i.test(href)));
  testInfo.annotations.push({ type: "auth0 settings screens in the menu", description: inMenu.join(" ") || "none" });
  const screens = [
    ...new Set([...inMenu, ...SETTINGS_SCREENS.map((slug) => `${auth0Sites.main.url}wp-admin/admin.php?page=${slug}`)]),
  ];

  const statuses = [];
  for (const screen of screens) {
    const response = await page.goto(screen);
    statuses.push(`${new URL(screen).searchParams.get("page")}=${response.status()}`);
    expect(await page.content(), `the client secret is on ${screen}`).not.toContain(CLIENT_SECRET);

    // A field that holds the tenant's domain or client ID can be shown, but
    // not edited.
    const tenantFields = await page.locator("input").evaluateAll(
      (inputs, values) =>
        inputs
          .filter((input) => values.includes(input.value))
          .map((input) => ({ name: input.name, locked: input.disabled || input.readOnly })),
      [AUTH0_DOMAIN, CLIENT_ID],
    );
    for (const field of tenantFields) {
      expect(field.locked, `${field.name} on ${screen} can be changed`).toBe(true);
    }
  }
  testInfo.annotations.push({ type: "auth0 settings screens opened", description: statuses.join(" ") });
});
