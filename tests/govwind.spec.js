const { describe, test, expect } = require("@playwright/test");

describe("Header and footer tests", () => {
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

    await expect(heading).toContainText(
      "Secure, seamless communication across the justice community",
    );
  });

  test("footer is visible", async ({ page }) => {
    await page.goto("/cjsm");

    await expect(page.locator("footer")).toBeVisible();
  });
});

describe("Govwind desktop navigation", () => {
  const navigationLinks = [
    "About CJSM",
    "Server or webmail",
    "Administrators",
    "How to apply",
    "Video guides",
    "CJSM changes 2026",
    "Support",
  ];
  test("main navigation is visible", async ({ page }) => {
    await page.goto("/cjsm");
    const mainNav = page.locator("header").getByRole("navigation");

    await expect(mainNav).toBeVisible();
  });

  test("main navigation contains links", async ({ page }) => {
    await page.goto("/cjsm");
    const mainNav = page.locator("header").getByRole("navigation");
    const links = mainNav.getByRole("link");
    expect(await links.count()).toBeGreaterThan(0);
  });

  test("All CJSM nav link exis", async ({ page }) => {
    await page.goto("/cjsm");
    const mainNav = page.locator("header").getByRole("navigation");
    const navItems = mainNav.locator("ul > li");
    await expect(navItems).toHaveText(navigationLinks);
  });

  //Test 3 representive links for now
  test("About CJSM nav link works", async ({ page }) => {
    await page.goto("/cjsm");
    const mainNav = page.locator("header").getByRole("navigation");
    const linkName = mainNav.getByRole("link", {
      name: "About CJSM",
    });
    await expect(linkName).toBeVisible();

    await linkName.click();
    await expect(page).toHaveURL(/\/cjsm\/about-cjsm/);
  });

  test("How to apply nav link works", async ({ page }) => {
    await page.goto("/cjsm");
    const mainNav = page.locator("header").getByRole("navigation");
    const linkName = mainNav.getByRole("link", {
      name: "How to apply",
    });
    await expect(linkName).toBeVisible();

    await linkName.click();
    await expect(page).toHaveURL(/\/cjsm\/how-to-apply/);
  });

  test("Support nav link works", async ({ page }) => {
    await page.goto("/cjsm");
    const mainNav = page.locator("header").getByRole("navigation");
    const linkName = mainNav.getByRole("link", {
      name: "Support",
    });
    await expect(linkName).toBeVisible();

    await linkName.click();
    await expect(page).toHaveURL(/\/cjsm\/support/);
  });

  test("Mobile navigation is hidden", async ({ page }) => {
    await page.goto("/cjsm");
    const mobileNav = page.locator("header nav.wb-mobile-only");

    await expect(mobileNav).toHaveCount(1);
    await expect(mobileNav).toBeHidden();
  });
});
