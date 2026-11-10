const {test, expect} = require("../../support/test");

test("Check homepage does not scroll sideways on mobile", async ({ page, site}) => {
    await page.goto("./");

   const canScrollH = await page.evaluate(() => {

        horizontalScroll = (ele) => {
            if(!(ele)){
                return false;
            }

            const overflowX = getComputedStyle(ele).overflowX;

            //Hale uses overflowX: clip -> prevenets scrolling if overflow

            if(overflowX === 'clip' || overflowX === 'hidden'){
                return false;
            }

            const originalPos = ele.scrollLeft;

            //scroll horizontally

            ele.scrollLeft = ele.scrollWidth;

            const newPos = ele.scrollLeft;

            //reset scrolling
            ele.scrollLeft = originalPos;

            return newPos !== originalPos;

        }

        // check both html and body

        const htmlCanScroll = horizontalScroll(document.scrollingElement);
        const bodyCanScroll = horizontalScroll(document.body);

        return htmlCanScroll || bodyCanScroll;
    });

        expect(canScrollH, `${site.key} homepage allows horozontal scrolling`).toBe(false);
   

});


//Extra test to check for overflow
test("homepage content does not overflow on mobile", async ({page, site}) => {

        await page.goto("./");

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

        // Ensure the width measurement is valid
        expect(Number.isFinite(widths.contentWidth)).toBe(true);

        expect(widths.contentWidth, `${site.key} homepage content exceeds the mobile viewport`).toBeLessThanOrEqual(widths.viewportWidth);
   });
     
    