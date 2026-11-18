const { test, expect } = require("../../support/test");
const { getSitePageUrls } = require("../../support/page-urls");
/*
My plan: To be removed after test has been completed
✅ step 1: get all href links on a page
✅ step 2: Throw a slirent error if there is an empty or missing href
✅ step 3: remove in-page, placeholder and empty links from the test
✅ step 4: normalise links so they all use an absolute path
✅ step 5: remove repeated links
✅ step 6: check Playwright for response checking methods
✅ step 7: build paths - may not be needed since using href
✅ step 8: loop through links and test the status response
✅ step 9: expand the check to all nested pages in a site - use the helper function developed for the hoirzontal test
 to return an array of all nested sites
✅ step 10: test.step on nested sites,  and .test.soft so that a failure does not stop testing runs
step 11: refactor

note: how to deal with external links
resource: https://www.checklyhq.com/docs/learn/playwright/how-to-detect-broken-links/
*/

test("Page links return a 200 status response", async ({page, site}) => {
    const pageUrls = getSitePageUrls(site);

    //check all valid links on each seeded site page
    for(const pageUrl of pageUrls){

        await test.step(`Link returns a status code of 200 on page ${pageUrl}`, async ()=>{
            await page.goto(pageUrl);

             //Target 'a' links
            const links = page.locator("a");
            //Get all a links on the page
            const allLinks = await links.all();

            
            //get all paths from hrefs 
            const allLinksHref = await Promise.all(
                allLinks.map((link) => link.getAttribute("href"))
            );

            //catch any missing or empty href's
            for(const hrefLink of allLinksHref){
                expect.soft(hrefLink, `Missing or empty href on ${site.key}`).toBeTruthy();
            }

            //console.log(`${site.key}, links: ${allLinks.length} allLinks: ${allLinksHref.length}: \n ${allLinksHref.join("\n")}`)
        
            //Remove in-page links, placeholder links (example.test) and empty links (do we need to exclude mailto tel etc too?)
            const filteredLinks = allLinksHref.filter((link) => link && !link.startsWith("#") && link && !link.includes("example"));
            //console.log("Filtered Links:", filteredLinks);

            //normalise links - use absolute paths
            //repeated links need to be included here since a mixture of relative and abslute paths point to the same pages
            const absoluteLinks = filteredLinks.map((hrefLink) => {
                return hrefLink.startsWith("https://") || 
                    hrefLink.startsWith("http://")
                    ? hrefLink
                    : new URL(hrefLink, page.url()).href;
            })
            //console.log("absolute links", absoluteLinks);

            //include links within test stack seeded pages only
            const siteOrigin = new URL(page.url()).origin;
            const internalLinks = absoluteLinks.filter((link) => {
                return new URL(link).origin === siteOrigin;
            })
            //console.log( siteOrigin);

            //remove any repeated links
            const validHrefs = [...new Set(internalLinks)]
        

            //loop through all the valid page urls
            for (const url of validHrefs) {
                try{
                    const res = await page.request.get(url);
                    //console.log(res.status(), `${site.key}:  - ${url}`)
                    expect.soft(res.status(), `${site.key}: ${url} did not return 200`).toBe(200);

                } catch (error){
                    expect.soft(false, `${site.key}: ${url} - ${error.message}`).toBeTruthy()

                }
            }

            console.log(`/********  site:${site.key} page: ${pageUrl}********************************/`)
            
            console.log("valid links:", validHrefs.length);
            for(const url of validHrefs){
                console.log(url)
            }
            console.log("valid links:", validHrefs.length);
        })
    }
})