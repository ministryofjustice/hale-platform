const { test, expect } = require("../../support/test");
const { getSitePageUrls } = require("../../support/page-urls");

test("Check pages do not scroll sideways on mobile", async ({ page, site }) => {
  //get all seeded page urls for the current site
  const urls = getSitePageUrls(site);

  //run the test on each page
  for (const url of urls) {
    await test.step(`Check horizontal scrolling: ${url}`, async () => {
      await page.goto(url);

      const canScrollH = await page.evaluate(() => {
        const horizontalScroll = (ele) => {
          if (!ele) {
            return false;
          }

          const overflowX = getComputedStyle(ele).overflowX;

          // Hidden and clip prevent user scrolling
          if (overflowX === "clip" || overflowX === "hidden") {
            return false;
          }

          const originalPos = ele.scrollLeft;

          // Attempt horizontal scrolling
          ele.scrollLeft = ele.scrollWidth;

          const newPos = ele.scrollLeft;

          // Restore original position
          ele.scrollLeft = originalPos;

          return newPos !== originalPos;
        };

        // Check both the document scrolling element and body
        const htmlCanScroll = horizontalScroll(document.scrollingElement);
        const bodyCanScroll = horizontalScroll(document.body);

        return htmlCanScroll || bodyCanScroll;
      });

      expect
        .soft(canScrollH, `${site.key}: ${url} allows horizontal scrolling`)
        .toBe(false);
    });
  }
});
