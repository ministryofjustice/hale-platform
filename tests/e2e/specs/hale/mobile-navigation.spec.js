const { test, expect } = require("../../support/test");

test("Burger menu displays at 762px", async ({ page }) => {
  await page.setViewportSize({ width: 762, height: 800 });
  await page.goto("./");

  const burgerButton = page.getByRole("button", { name: "Menu" });

  await expect(burgerButton).toBeVisible();
});
