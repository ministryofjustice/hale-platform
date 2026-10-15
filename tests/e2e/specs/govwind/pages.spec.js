const { test, expect } = require("../../support/test");

// The govwind site follows the IPA site (websitebuilder.service.justice.gov.uk/ipa-fse/):
// its style variation, header, footer, menu and pages. See seed/content/govwind/.
const menu = ["About us", "Get support", "News", "Briefings", "Contact us"];
const pages = [
  "about-us/",
  "get-support/",
  "get-support/get-support-from-the-independent-public-advocate/",
  "news/",
  "briefings/",
  "contact-us/",
];

test("site has the IPA colours", async ({ page }) => {
  await page.goto("./");

  // govwind's IPA palette applies to .website-61, so the site needs that ID.
  await expect(page.locator("html")).toHaveClass(/\bwebsite-61\b/);
  // colour-Z exists only in the IPA style variation.
  const colourZ = await page.evaluate(() =>
    getComputedStyle(document.documentElement).getPropertyValue("--wp--preset--color--colour-z").trim(),
  );
  expect(colourZ).not.toBe("");
});

test("header shows the logo and the menu", async ({ page }) => {
  await page.goto("./");

  const header = page.getByRole("banner");
  await expect(header.locator(".wp-block-site-logo img")).toBeVisible();

  const items = header.locator(
    "nav.wb-md-desktop-only ul.wp-block-navigation__container > li > .wp-block-navigation-item__content",
  );
  await expect(items).toHaveText(menu);
});

test("Get support opens its submenu", async ({ page }) => {
  await page.goto("./");

  const nav = page.getByRole("banner").locator("nav.wb-md-desktop-only");
  await nav.getByRole("button", { name: "Get support submenu" }).click();
  await nav.getByRole("link", { name: "Get support from the Independent Public Advocate" }).click();

  await expect(page).toHaveURL(/\/get-support\/get-support-from-the-independent-public-advocate\/$/);
});

for (const path of pages) {
  test(`${path} loads`, async ({ page }) => {
    const response = await page.goto(path);

    expect(response?.status()).toBe(200);
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
  });
}

test("homepage lists the latest news, newest first", async ({ page }) => {
  await page.goto("./");

  await expect(page.locator(".wb-block-filterable-listing h2 a")).toHaveText([
    "Third news story",
    "Second news story",
    "First news story",
  ]);
});
