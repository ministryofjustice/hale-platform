const {test, expect} = require("../../support/test");

test("Detects horozontal overflow on mobile", async ({ page })=> {
    await page.goto("/mobile-overflow/");

    //target the oversized paragraph
    const paraContainer = page.locator(".hale-entry-content p");

    const width = await paraContainer.evaluate((containerEl) =>({
        rightEdge: containerEl.getBoundingClientRect().right,
        viewportWidth: document.documentElement.clientWidth
    }));

    console.log(width);
    expect(width.rightEdge).toBeGreaterThan(width.viewportWidth)

})