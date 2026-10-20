const { test, expect } = require("../../support/test");

// The govwind site follows the IPA site (websitebuilder.service.justice.gov.uk/ipa-fse/):
// its style variation, header, footer, menu and pages. See seed/content/govwind/.

const mobileMenuLinks = [
  { name: "About us", path: "about-us/" },
  { name: "News", path: "news/" },
  { name: "Briefings", path: "briefings/" },
  { name: "Contact us", path: "contact-us/" },
];

test.describe("Govwind mobile tests", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("./");
  });
  test("mobile navigation is visible", async ({ page }) => {
    const mobileNav = page.locator("header nav.wb-md-mobile-only");
    await expect(mobileNav).toHaveCount(1);
    await expect(mobileNav).toBeVisible();
  });

  test("desktop navigation is hidden", async ({ page }) => {
    // In the page, as on desktop, but hidden by the theme's CSS.
    const desktopNav = page.locator("header nav.wb-md-desktop-only");
    await expect(desktopNav).toHaveCount(1);
    await expect(desktopNav).toBeHidden();
  });

  test("mobile nav menu opens", async ({ page }) => {
    const mobileNav = page.locator("header nav.wb-md-mobile-only");
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
        name: "About us",
      }),
    ).toBeVisible();
  });
  test("mobile nav menu closes", async ({ page }) => {
    const mobileNav = page.locator("header nav.wb-md-mobile-only");

    const openBtn = mobileNav.getByRole("button", {
      name: "Open menu",
    });

    await openBtn.click();

    const closeBtn = mobileNav.getByRole("button", {
      name: "Close menu",
    });

    await expect(closeBtn).toBeVisible();

    await closeBtn.click();
    await expect(openBtn).toBeVisible();
    await expect(closeBtn).toBeHidden();

    await expect(
      mobileNav.getByRole("link", {
        name: "About us",
      }),
    ).toBeHidden();
  });

  test("Get support opens its submenu", async ({ page }) => {
    const mobileNav = page.getByRole("banner").locator("nav.wb-md-mobile-only");

    await mobileNav.getByRole("button", { name: "Open Menu" }).click();

    const subMenuBtn = mobileNav.getByRole("button", {
      name: "Get support submenu",
      exact: true,
    });

    await expect(subMenuBtn).toHaveCount(1);
    await expect(subMenuBtn).toBeVisible();
    await expect(subMenuBtn).toHaveAttribute("aria-expanded", "false");

    //open submenu
    await subMenuBtn.click();

    await expect(subMenuBtn).toHaveAttribute("aria-expanded", "true");

    const subLink = mobileNav.getByRole("link", {
      name: "Get support from the Independent public advocate",
    });

    await expect(subLink).toHaveCount(1);
    await expect(subLink).toBeVisible();

    await subLink.click();

    await expect(page).toHaveURL(
      /\/get-support\/get-support-from-the-independent-public-advocate\/$/,
    );
  });

  //testing using a loop based on approach used for desktop nav link tests
  //"test support" link omitted here.  Tested seperately to include sub menu tests
  mobileMenuLinks.forEach(({ name, path }) => {
    test(`${name} mobile nav links work`, async ({ page }) => {
      const mobileNav = page
        .getByRole("banner")
        .locator("nav.wb-md-mobile-only");

      await mobileNav
        .getByRole("button", {
          name: "Open menu",
        })
        .click();

      const navLink = mobileNav.getByRole("link", {
        name,
        exact: true,
      });
      await expect(navLink).toBeVisible();
      await navLink.click();

      await expect(page).toHaveURL(path);
    });
  });
});
