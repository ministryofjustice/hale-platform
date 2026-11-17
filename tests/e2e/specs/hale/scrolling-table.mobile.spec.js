const { test, expect } = require("../../support/test");

test("Table allows horizontal scrolling on mobile devices", async ({ page }) => {

    await page.goto("/table-scroll/");

    //Target the table block
    const tableContainer = page.locator(".wp-block-table").first();

    //Target the last table column
    const lastCol = tableContainer.locator("thead th").last();

    //Is the table visible on the page
    await expect(tableContainer).toBeVisible();

    //Get container width and width of scrollable content
    const widths = await tableContainer.evaluate((containerEL) =>({
        scrollWidth: containerEL.scrollWidth,
        clientWidth: containerEL.clientWidth,
        overflowX: getComputedStyle(containerEL).overflowX,
        scrollLeft: containerEL.scrollLeft
    }));

    await expect(lastCol).toHaveText("Author");

     //Is the final column currently visible
    await expect(lastCol).not.toBeInViewport();


   //Table content should be wider than the container
    expect(widths.scrollWidth).toBeGreaterThan(widths.clientWidth);

     //Is scolling enabled
     expect(widths.overflowX).toContain("auto");
    

    //Move the table inside the container to the far right
    await tableContainer.evaluate((containerEL)=> {
        containerEL.scrollLeft = containerEL.scrollWidth;
    })

    //Move the overflow content into the viewport
    const scrollPosition = await tableContainer.evaluate(
        (containerEl) => containerEl.scrollLeft
    ) 
   
     //Confirm that scrolling moved the container content
    expect(scrollPosition).toBeGreaterThan(widths.scrollLeft);


    //Is the final column is visible
    await expect(lastCol).toBeInViewport();
})