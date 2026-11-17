const { test, expect } = require("../../support/test");

//Need to skip the shared fixture's console error check sinc eit logsbe an error
//for the expected 404 response in this spec.  Without ignoring colsole errors
//the test would fail
test.use({ ignoreConsoleErrors: true });

test("check 404 error page displays correctly", async ({ page, site }) => {
  //create a nonexisiting url for the current page
  const badPageUrl = new URL(site.url);

  const sitePath = badPageUrl.pathname.replace(/\/$/, "");

  badPageUrl.pathname = `${sitePath}/path-not-found/`;

  //Direct to nonexistant page
  const res = await page.goto(badPageUrl.href);

  //check a 404 status code is returned
  expect(res?.status()).toBe(404);

  //error pages should contain both a header and footer
  await expect(page.locator("header")).toBeVisible();
  await expect(page.locator("footer")).toBeVisible();

  //ppo 404 template does not contain a h1 therfore need to target a different element
  if (site.key === "ppo") {
    //target alert div
    const ppoTextCheckEle = page.locator("div.alert.alert-warning");
    //check expected test for ppo is displayed
    await expect(ppoTextCheckEle).toBeVisible();
    await expect(ppoTextCheckEle).toContainText("Sorry, but the page");
  } else {
    //check expected text is displayed
    await expect(
      page.getByRole("heading", { name: "Page not found", exact: false }),
    ).toBeVisible();
  }
});
