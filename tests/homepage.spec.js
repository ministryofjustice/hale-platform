const { test, expect } = require("@playwright/test");

test("Hale homepage loads", async ({ page }) => {
  await page.goto("/");

  await expect(page).toHaveTitle(/.+/);
});

test("Hale homepage has a main heading", async ({ page }) => {
  await page.goto("/");

  const heading = page.getByRole("heading", { level: 1 });

  await expect(heading).toBeVisible();
});

test("Home page contains a title ", async ({ page }) => {
  await page.goto("/");

  await expect(page).toHaveTitle("Ministry of Justice Website Build");
});

test("user can navigate to the designing your site page", async ({ page }) => {
  await page.goto("/");

  await page
    .getByRole("link", { name: "How to make a good website" })
    .first()
    .click();

  await expect(page).toHaveURL(/\/designing-your-site\/$/);
});

test("footer is visible", async ({ page }) => {
  await page.goto("/");

  const footer = page.getByRole("contentinfo");

  await expect(footer).toBeVisible();
});
