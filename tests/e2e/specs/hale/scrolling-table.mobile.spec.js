const { test, expect } = require("../../support/test");

test("Table allows horizontal scrolling on mobile devices", async ({ page }) => {

    await page.goto("/table-scroll/");

    //target the table block
    const tableContainer = page.locator(".wp-block-table").first();

    //target the last table column
    const lastCol = tableContainer.locator("thead th").last();

    //Is the table is visible on the page
    await expect(tableContainer).toBeVisible();

    //get container width and width of scrollable content
    const widths = await tableContainer.evaluate((containerEL) =>({
        scrollWidth: containerEL.scrollWidth,
        clientWidth: containerEL.clientWidth,
        overflowX: getComputedStyle(containerEL).overflowX,
        scrollLeft: containerEL.scrollLeft
    }));

    await expect(lastCol).toHaveText("Author");

     //check that the final column is not currently visible
    await expect(lastCol).not.toBeInViewport();


   //table content should be wider than the container
    expect(widths.scrollWidth).toBeGreaterThan(widths.clientWidth);

     //check scolling is enabled
     expect(widths.overflowX).toContain("auto");
    

    //move the table inside the container to the far right
    await tableContainer.evaluate((containerEL)=> {
        containerEL.scrollLeft = containerEL.scrollWidth;
    })

    //move the overflow content into the viewport
    const scrollPosition = await tableContainer.evaluate(
        (containerEl) => containerEl.scrollLeft
    ) 
   
     //confirm that scrolling moved the container content
    expect(scrollPosition).toBeGreaterThan(widths.scrollLeft);


    //check that the final column is visible
    await expect(lastCol).toBeInViewport();
})