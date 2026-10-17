const { test, expect } = require("../../support/test");

//@1023 Most popular above main content - tablet
// image and text side-by-side
//everyting else stacked
////<768 everything is stacked 

//This test is for mobile devices 

const accordionLinks = [
    {
      name: 'Procedure rules',
      path: '/justice/courts/procedure-rules'
    },
    {
      name: 'Daily court lists',
      path: 'https://www.gov.uk/government/collections/royal-courts-of-justice-and-rolls-building-daily-court-lists'
    },
    {
      name: 'Prison finder',
      path: 'https://www.gov.uk/government/collections/prisons-in-england-and-wales'
    },
    {
      name: 'XHIBIT daily court status',
      path: 'https://www.gov.uk/courts/crown-court'
    },
    {
      name: 'Prison service instructions (PSIs)',
      path: 'https://www.gov.uk/guidance/prison-service-instructions-psis'
    }
  ];


test("navigation links are stacked", async ({ page })=> {
    await page.goto("./");

    const nav = page.locator(".navigation-main");

    const courtsLink = nav.getByRole("link", {
        name:"Courts"
    });
    const rulesLink = nav.getByRole("link", {
        name:"Procedure rules"
    });
    const offendersLink = nav.getByRole("link", {
        name:"Offenders"
    });

    
    await expect(courtsLink).toBeVisible();
    await expect(rulesLink).toBeVisible();
    await expect(offendersLink).toBeVisible();

    //using playwrights boundingBox method to determine location of element
    //this can be used to determine whether something is positioned above/below
    //  or side-by-side using x and y and width and height values
    // example { x: 32, y: 113.03125, width: 329, height: 41.03125 }
    //https://playwright.dev/docs/api/class-elementhandle#element-handle-bounding-box

    const courtsLinkBox = await courtsLink.boundingBox();
    const rulesLinkBox = await rulesLink.boundingBox();
    const offendersLinkBox = await offendersLink.boundingBox();

    expect(courtsLinkBox).not.toBeNull();
    expect(rulesLinkBox).not.toBeNull();
    expect(offendersLinkBox).not.toBeNull();

    
    //procedure rules below courts
    expect(rulesLinkBox.y).toBeGreaterThanOrEqual(courtsLinkBox.y + courtsLinkBox.height);
    //offedneers below  procedure rules
    expect(offendersLinkBox.y).toBeGreaterThanOrEqual(rulesLinkBox.y + rulesLinkBox.height);

});


test("mobile sidebar and and main content are stacked vertically", async ({ page })=>{
    await page.goto("./");

    const popular = page.locator(".one-sidebar__sidebar--mobile section.sidebar-block--list");
    const scalesImage= page.locator(".image-with-text__image");
    const content = page.locator(".image-with-text__content")

    const popularBox = await popular.boundingBox();
    const scalesImageBox = await scalesImage.boundingBox();
    const contentBox = await content.boundingBox();
    
    expect(popularBox).not.toBeNull();
    expect(scalesImageBox).not.toBeNull();
    expect(content).not.toBeNull();

    //Most popular appears above image
    expect(scalesImageBox.y).toBeGreaterThanOrEqual(popularBox.y + popularBox.height);
    //Image appears above content
    expect(contentBox.y).toBeLessThanOrEqual(scalesImageBox.y + scalesImageBox.height)

});

test("Most popular accordion opens and closes", async ({page})=>{

    await page.goto("./");
     const accordion = page.locator(".one-sidebar__sidebar--mobile")
     .getByRole("button", {
        name:"Most popular"
     });

     const accordionContent = page.locator("#sidebar-block-content-most-popular-mobile");

     await expect(accordion).toBeVisible()
     await expect(accordionContent).toBeHidden()

     //aria-attribute missing on initilisation therefore returns null
     //this could present a reader accessbility issue 
     //current state: null->click->true->click-> false
     //should state be: false->click->true->click->false...
     
     //After page load accordian should be collpased initially
     //await expect(accordion).toHaveAttribute("aria-expanded", "false");
      await expect(accordionContent).toBeHidden();

     //console.log('Before click:', await accordion.getAttribute("aria-expanded"));

     //open accirdion
    await accordion.click();
    await expect(accordion).toHaveAttribute("aria-expanded", "true");

    await expect(accordionContent).toHaveClass(/sidebar-block__content--open/);
    await expect(accordionContent).toBeVisible();
      
     //close accordion
    await accordion.click();
    await expect(accordion).toHaveAttribute("aria-expanded", "false");
     await expect(accordionContent).not.toHaveClass(/sidebar-block__content--open/);
    await expect(accordionContent).toBeHidden();

});

//linksare external apart from Procedure rules - using href to check correctness
test("Most popular accoridon links contain correct information", async ({ page })=> {
    await page.goto('./');

  const accordion = page.locator(".one-sidebar__sidebar--mobile")
     .getByRole("button", {
        name:"Most popular"
     });

     const accordionContent = page.locator("#sidebar-block-content-most-popular-mobile");
      //open accirdion
    await accordion.click();
    await expect(accordionContent).toBeVisible();

    //loop through links and check content
    for ( const {name, path } of  accordionLinks) {
        const link = accordionContent.getByRole("link",{
            name,
            exact: true
        });
        await expect(link).toBeVisible();
        const href = await link.getAttribute("href");
        expect(href).not.toBeNull();

        path.startsWith("/")? expect(new URL(href).pathname).toBe(path):
        expect(href).toBe(path);
    } 

   
    //close accordion
    await accordion.click();
    await expect(accordionContent).toBeHidden();

})