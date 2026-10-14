const { test, expect } = require("../../support/test");

// The hale site's pages follow websitebuilder.service.justice.gov.uk: three
// menu sections, each with one page below it. See seed/content/hale/.
const sections = [
  { title: "About Website Builder", path: "about-website-builder/", child: "about-website-builder/features/" },
  { title: "How to make a good website", path: "designing-your-site/", child: "designing-your-site/creating-content/" },
  { title: "User guides", path: "user-guides/", child: "user-guides/get-started/" },
];

test("main menu lists the three sections", async ({ page }) => {
  await page.goto("./");

  const menu = page.getByRole("navigation", { name: "Primary navigation" });

  await expect(menu.getByRole("link")).toHaveText(sections.map((s) => s.title));
});

for (const section of sections) {
  test(`${section.title} and the page below it load`, async ({ page }) => {
    for (const path of [section.path, section.child]) {
      const response = await page.goto(path);

      expect(response?.status(), path).toBe(200);
      await expect(page.getByRole("heading", { level: 1 }), path).toBeVisible();
    }
  });
}

test("homepage images load", async ({ page }) => {
  await page.goto("./", { waitUntil: "load" });

  const images = page.locator("main img");
  await expect(images.first()).toBeAttached();

  // Lazy-loaded images below the fold only load once scrolled to.
  for (const image of await images.all()) {
    await image.scrollIntoViewIfNeeded();
    await expect
      .poll(() => image.evaluate((img) => img.complete && img.naturalWidth > 0), { message: await image.getAttribute("src") })
      .toBe(true);
  }
});
