const { describe, test, expect, beforeEach } = require("@playwright/test");

describe("Govwind mobile navigation tests", () => {
  beforeEach(async ({ page }) => {
    await page.goto("cjsm");
  });
  test("mobile navigation is visible", async ({ page }) => {
    await page.goto("/cjsm");

    const mobileNav = page.locator("header nav.wb-mobile-only");
    await expect(mobileNav).toHaveCount(1);
    await expect(mobileNav).toBeVisible();
  });

  test("desktop navigation is hidden", async ({ page }) => {
    await page.goto("/cjsm");

    const desktopNav = page.locator("header nav.wp-desktop-only");
    await expect(desktopNav).toHaveCount(0);
    await expect(desktopNav).toBeHidden();
  });

  test("mobile nav menu opens", async ({ page }) => {
    const mobileNav = page.locator("header nav.wb-mobile-only");
    const menuBtn = mobileNav.getByRole("button", {
      name: "Open menu",
    });

    await expect(menuBtn).toBeVisible();

    await menuBtn.click();

    await expect(
      mobileNav.getByRole("button", {
        name: "Close menu",
      }),
    ).toBeVisible();

    await expect(
      mobileNav.getByRole("link", {
        name: "About CJSM",
      }),
    ).toBeVisible();
  });

  test("mobile nav menu closes", async ({ page }) => {
    const mobileNav = page.locator("header nav.wb-mobile-only");
    const openBtn = mobileNav.getByRole("button", {
      name: "Open menu",
    });

    await openBtn.click();

    const closeBtn = mobileNav.getByRole("button", {
      name: "Close menu",
    });

    expect(closeBtn).toBeVisible();

    await closeBtn.click();
    expect(openBtn).toBeVisible();

    await expect(
      mobileNav.getByRole("button", {
        name: "Close menu",
      }),
    ).toBeVisible();

    await expect(
      mobileNav.getByRole("link", {
        name: "About CJSM",
      }),
    ).toBeHidden();
  });

  test("About CJSM mobile nav link works", async ({page})=>{
    const mobileNav = page.locator("header nav.wb-mobile-only");

    mobileNav.getByRole("button", {
      name: "Open menu",
    }).click();
    const linkName = mobileNav.getByRole("link", {
        name: "About CJSM",
        exact:true,
    }) ;

    await expect(linkName).toBeVisible();
    await linkName.click();
    await expect(page).toHaveURL(/\/cjsm\/about-cjsm/);

  })
});
