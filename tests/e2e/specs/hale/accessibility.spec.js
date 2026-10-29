const { test, expect } = require("../../support/test");
const AxeBuilder = require("@axe-core/playwright").default;

test("homepage has no WCAG 2.2 AA violations", async ({ page }) => {
  await page.goto("./");

  const results = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"])
    .analyze();

  expect(results.violations).toEqual([]);
});
