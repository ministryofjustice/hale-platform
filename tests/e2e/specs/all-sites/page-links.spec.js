const { test, expect } = require("../../support/test");
/*
✅ step 1: get all href links on a page
✅ step 2: remove in-page, placeholder and empty links from the test
✅ step 3: normalise links so they all use an absolute path
✅ step 4: remove repeated links
step 5: check Playwright for response checking methods
step 6: build paths - may not be needed since using href
step 7: loop through links and test the status response
step 8: expand the check to all nested sites - use the helper function developed for the hoirzontal test
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
   
    //Remove in-page links, placeholder links (example.test) and empty links (do we need to exclude mailto tel etc too?)
     const filteredLinks = allLinksHref.filter((link) => link && !link.startsWith("#") && link && !link.includes("example.test"));
    console.log("Filtered Links:", filteredLinks);

    //normalise links - use absolute paths
    //repeated links need to be included here since a mixture of relative and abslute paths point to the same pages
    const absoluteLinks = filteredLinks.map((hrefLink) => {
        return hrefLink.startsWith("https://") || 
            hrefLink.startsWith("http://")
            ? hrefLink
            : new URL(hrefLink, page.url()).href;
    })
    console.log("absolute links", absoluteLinks);

    //remove any repeated links
    const uniqueLinks = [...new Set(absoluteLinks)]
    console.log("unique links:", uniqueLinks);
})