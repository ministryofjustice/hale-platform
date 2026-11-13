const { test, expect } = require("../../support/test");
const { getSitePageUrls } = require("../../support/page-urls");


test("check for elements overflowing and crossing the mobile viewport", async ({ page, site }) => {
  const urls = getSitePageUrls(site);


  for (const url of urls) {

    //test nested pages for each theme site   
    await test.step(`Check viewport boundaries: ${url}`, async () => {
      await page.goto(url);

      const overflowingEles = await page.evaluate(() => {
        const viewportWidth = document.documentElement.clientWidth;

        // Check whether the element is inside a scrollable container
        //if container is scrollable this hould pass the test
        function hasScrollableParent(ele) {
          let parent = ele.parentElement;

          while (
            parent &&
            parent !== document.body &&
            parent !== document.documentElement
          ) {
            const overflowX = getComputedStyle(parent).overflowX;

            if (
              ["auto", "scroll"].includes(overflowX) &&
              parent.scrollWidth > parent.clientWidth
            ) {
              return true;
            }

            parent = parent.parentElement;
          }

          return false;
        }

        // Find elements crossing the viewport boundaries
        //Any element crossing the boundry with a scrollable parent
        //should pass the test (table check)
        return [...document.body.querySelectorAll("*")]
          .filter(ele => {
            const rect = ele.getBoundingClientRect();

            const crossesViewport =
                (rect.left < 0 && rect.right > 0) ||
                (rect.left < viewportWidth && rect.right > viewportWidth);

            return rect.width > 0 &&
              rect.height > 0 &&
              crossesViewport &&
              !hasScrollableParent(ele);
          })
          .map(ele => {
            const rect = ele.getBoundingClientRect();

            return {
              tag: ele.tagName,
              id: ele.id,
              className: String(ele.className),
              left: Math.round(rect.left),
              right: Math.round(rect.right)
            };
          });
      });
      //elements array should be 0 if no overflowing elements cross the viewport boundaries
      expect.soft(
        overflowingEles,
        `${site.key}: ${url} has elements crossing the mobile viewport`
        ).toHaveLength(0);
    });
  }
});