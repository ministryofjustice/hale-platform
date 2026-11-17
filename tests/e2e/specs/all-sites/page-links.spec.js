const { test, expect } = require("../../support/test");
/*
✅ step 1: get all href links on a page
step 2: remove repeated links
step 3: check Playwright for response checking methods
step 4: build paths - may not be needed since using href
step 5: loop through links and test the status response
step 6: expand the check to all nested sites - use the helper function developed for the hoirzontal test
 to return an array of all nested sites
step 7: test.step on nested sites,  evaluate inside step and .test.soft so that a failure does not stop during a site test

note: how to deal with external links
resource: https://www.checklyhq.com/docs/learn/playwright/how-to-detect-broken-links/
*/

test("Page links return a 200 status response", async ({page, site}) => {
   
    await page.goto("./");

    //Target 'a' links
    const links = page.locator("a");
    //Get all a links on the page
    const allLinks = await links.all();

    
    //get all paths from hrefs 
    const allLinksHref = await Promise.all(
        allLinks.map((link) => link.getAttribute("href"))
    );

    console.log(`${site.key}, links: ${allLinks.length} allLinks: ${allLinksHref.length}: \n ${allLinksHref.join("\n")}`)
   
    //Remove in-page links, placeholder links (example.test) and empty links (do weneed to exclude mailto tel etc too?)
     const filteredLinks = allLinksHref.filter((link) => link && !link.startsWith("#") && link && !link.includes("example.test"));
    console.log("Filtered Links:", filteredLinks);

    
})