const { test, expect } = require("../../support/test");
const { getSitePageUrls } = require("../../support/page-urls");

test("Check pages do not scroll sideways on mobile", async ({ page, site }) => {
  //get all seeded page urls for the current site
  const urls = getSitePageUrls(site);

  console.log("URLS:", urls);

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

//Extra test to check for overflow
test("Page content does not overflow on mobile", async ({ page, site }) => {
  const urls = getSitePageUrls(site);

  for (const url of urls) {
    await test.step(`Check content for overflow: ${url}`, async (step) => {
      await page.goto(url);

      const widths = await page.evaluate(() => {
        const htmlEl = document.documentElement;
        const bodyEl = document.body;

        return {
          viewportWidth: htmlEl.clientWidth,
          contentWidth: Math.max(
            htmlEl.scrollWidth,
            bodyEl.scrollWidth
          )
        };
      });
   
      //record screenshot when overflow is detected
      if (widths.contentWidth > widths.viewportWidth) {
        const screenshot = await page.screenshot({ fullPage: true });

        await step.attach(`Overflow - ${new URL(url).pathname}`, {
            body: screenshot,
            contentType: "image/png"
        });
        }

      // Ensure the width measurement is valid
      expect.soft(Number.isFinite(widths.contentWidth)).toBe(true);

    //   if(widths.overflowingEles.length > 0){
    //     console.log(`${site.key}: ${url}`, widths.overflowingEles);
    //   }
//     if (widths.contentWidth > widths.viewportWidth) {
//     console.log(`${site.key}: ${url}`, {
//         viewportWidth: widths.viewportWidth,
//         contentWidth: widths.contentWidth,
//         overflowingEles: widths.overflowingEles
//     });
// }

      expect.soft(
        widths.contentWidth,
        `${site.key}: ${url} content width ${widths.contentWidth}px exceeds viewport width ${widths.viewportWidth}px`
        ).toBeLessThanOrEqual(widths.viewportWidth);
    });
  }
});
