const { test, expect } = require("@playwright/test");

test("header is visible", async ({ page }) => {
  await page.goto("/cjsm");

  await expect(page.locator("header")).toBeVisible();
});

test("Govwind homepage has a main heading", async ({ page }) => {
  await page.goto("/cjsm");

  const heading = page.getByRole("heading", { level: 1 });

  await expect(heading).toBeVisible();
});

test("Check heading contents", async ({ page }) => {
  await page.goto("/cjsm");

  const heading = page.getByRole("heading", { level: 1 });

  await expect(heading).toContainText("Secure, seamless communication across the justice community");
 
});

test("footer is visible", async ({ page }) => {
  await page.goto("/cjsm");

  await expect(page.locator("footer")).toBeVisible();
});