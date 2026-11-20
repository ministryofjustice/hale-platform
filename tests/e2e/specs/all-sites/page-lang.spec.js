const { test, expect } = require("../../support/test");

test("html element has a lang attribute", async ({ page }) => {
    await page.goto("/");

    await expect(page.locator("html")).toHaveAttribute(
        "lang",
        /\S+/,
    );
});