const { test, expect } = require("@playwright/test");

test("header is visible", async ({ page }) => {
  await page.goto("/justice");

  await expect(page.locator("header")).toBeVisible();
});

//These tests would work if there was only one H1 on the page
/*test("Justice homepage has a main heading", async ({ page }) => {
  await page.goto("/justice");

  const heading = page.getByRole("heading", { level: 1 });

  await expect(heading).toBeVisible();
});

test("Check heading contents", async ({ page }) => {
  await page.goto("/justice");

  const heading = page.getByRole("heading", { level: 1 });

  await expect(heading).toContainText("Justice.gov.uk");
 
});*/

//Given that the Justice homepage contains two H1's the test needs
//to target a specfic h1
test("check justice page has a main heading", async ({ page })=>{
    await page.goto("/justice");
    const heading = page.getByRole("heading", {
        level:1,
        name:"Justice.gov.uk",
        exact:true,
    })
    await expect(heading).toHaveText("Justice.gov.uk")
})
test("footer is visible", async ({ page }) => {
  await page.goto("/justice");

  await expect(page.locator("footer")).toBeVisible();
});