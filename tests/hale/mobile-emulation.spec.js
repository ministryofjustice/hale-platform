const { test, expect } = require("@playwright/test");

test("Burger menu displays at 762px", async ({ page, browserName }) => {
    /*playwright test using chronium only for responsive test
    comment out when running in browserstack*/
    //test.skip(browserName != "chromium");

  await page.setViewportSize({ width: 762, height: 800 });
  await page.goto("/");

  const burgerButton = page.getByRole("button", {name: "Menu"});

  await expect(burgerButton).toBeVisible();
});
