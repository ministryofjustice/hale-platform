const { test, expect } = require("../../support/test");

// The justice site follows www.justice.gov.uk: the home page, then Procedure
// rules and one page below it. The header, footer and "Most popular" links are
// fixed in the theme; the left menu is built from the courts/procedure-rules
// page tree. See seed/content/justice/.

test("header has the theme's three links", async ({ page }) => {
  await page.goto("./");

  const nav = page.getByRole("navigation", { name: "Primary" });

  await expect(nav.getByRole("link")).toHaveText(["Courts", "Procedure rules", "Offenders"]);
});

test("home page has its title and the Most popular panel only", async ({ page }) => {
  await page.goto("./");

  await expect(page.getByRole("heading", { level: 1 })).toHaveText("Justice.gov.uk");

  const sidebar = page.locator(".one-sidebar__sidebar--desktop");
  await expect(sidebar.locator(".sidebar-block__heading-text")).toHaveText(["Most popular"]);
  await expect(sidebar.locator(".sidebar-block--brand")).toHaveCount(0);
});

test("Procedure rules leads to Civil", async ({ page }) => {
  await page.goto("./");
  await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Procedure rules" }).click();

  await expect(page).toHaveURL(/\/courts\/procedure-rules\/$/);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("Procedure rules");

  // The left menu lists the page below it, by its short title.
  await page.getByRole("navigation", { name: "Secondary" }).getByRole("link", { name: "Civil", exact: true }).click();

  await expect(page).toHaveURL(/\/courts\/procedure-rules\/civil\/$/);
});

test("Civil page has its breadcrumbs, search and Archived pages panel", async ({ page }) => {
  const response = await page.goto("courts/procedure-rules/civil/");

  expect(response?.status()).toBe(200);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("Civil Procedure Rules");
  await expect(page.getByRole("navigation", { name: "Breadcrumb" }).getByRole("listitem")).toHaveText([
    "Home",
    "Courts",
    "Procedure rules",
    "Civil",
  ]);
  await expect(page.locator("#searchbox-top")).toBeVisible();
  await expect(page.locator(".two-sidebars__sidebar--right .sidebar-block__heading-text")).toContainText([
    "Archived pages",
  ]);
});
