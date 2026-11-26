const { test, expect } = require("../../support/test");
const { getSitePageUrls } = require("../../support/page-urls");

test("Page links return a 200 status response", async ({page, site}) => {

    const pageUrls = getSitePageUrls(site);

    //remove draft pages from the list of page URLs
    const publishedPageUrls = pageUrls.filter((url) => !url.includes('/draft-page/'));

    //check all valid links on each seeded site page
    for(const pageUrl of publishedPageUrls){

        await test.step(`Link returns a status code of 200 on page ${pageUrl}`, async ()=>{
            await page.goto(pageUrl);

             //Target 'a href' links
            const links = page.locator("a[href]");

            //Get all a links on the page
            const allLinks = await links.all();

            
            //get all paths from hrefs 
            const allLinksHref = await Promise.all(
                allLinks.map((link) => link.getAttribute("href"))
            );

            //catch any missing or empty href's
            for(const hrefLink of allLinksHref){
                expect.soft(hrefLink, `Missing or empty href on ${site.key} page ${pageUrl}`).toBeTruthy();
            }

        
            //Remove in-page links, placeholder links and empty links (do we need to exclude mailto tel etc too?)
            const filteredLinks = allLinksHref.filter((link) => link && !link.startsWith("#")  && link);
           
            //normalise links - use absolute paths
            //repeated links need to be included here since a mixture of relative and abslute paths point to the same pages
            const absoluteLinks = filteredLinks.map((hrefLink) => {
                return hrefLink.startsWith("https://") || 
                    hrefLink.startsWith("http://")
                    ? hrefLink
                    : new URL(hrefLink, page.url()).href;
            })
           

            //include links within test stack seeded pages only
            const siteOrigin = new URL(page.url()).origin;
            const internalLinks = absoluteLinks.filter((link) => {
                return new URL(link).origin === siteOrigin;
            })
           
            //remove any repeated links
            const validHrefs = [...new Set(internalLinks)]
        

            //loop through all the valid page urls
            for (const url of validHrefs) {
                try{
                    const res = await page.request.get(url);
                    expect.soft(res.status(), `${site.key}: ${url} did not return 200`).toBe(200);

                } catch (error){
                    expect.soft(false, `${site.key}: ${url} - ${error.message}`).toBeTruthy()

                }
            }
            
        })
    }
})