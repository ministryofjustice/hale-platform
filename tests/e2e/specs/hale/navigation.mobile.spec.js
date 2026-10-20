const { test, expect } = require("../../support/test");

const mobileNavLinks = [
  {
    name: "About Website Builder",
    path: "/about-website-builder/"
  },
  {
    name: "How to make a good website",
    path: "/designing-your-site/"
  },
  {
    name: "User guides",
    path: "/user-guides/"
  }
];

test("Burger menu is visible", async ({ page}) => {
    
  await page.goto("./");

  const burgerBtn = page.getByRole("button", {name: "Menu"});

  await expect(burgerBtn).toBeVisible();
});

test("Mobile burger menu opens and closes", async ({ page }) => {
  await page.goto("./");

  const burgerBtn = page.getByRole("button", {
    name: "Show or hide navigation menu"
  });

  const nav = page.locator("#menu-menu-top-menu");

  // page load state
  await expect(burgerBtn).toBeVisible();
  await expect(burgerBtn).toHaveAttribute("aria-expanded", "false");
  await expect(nav).toBeHidden();

  // Open navigation menu
  await burgerBtn.click();

  await expect(burgerBtn).toHaveAttribute( "aria-expanded", "true");
  await expect(nav).toBeVisible();

  // Close navigation menu
  await burgerBtn.click();

  await expect(burgerBtn).toHaveAttribute(
    "aria-expanded", "false"
  );
  await expect(nav).toBeHidden();
});

test("Mobile navigation links contain correct information", async ({ page }) => {
  await page.goto("./");

  const burgerBtn = page.getByRole("button", {
    name: "Show or hide navigation menu"
  });

  const nav = page.locator("#menu-menu-top-menu");

  // Open menu once
  await burgerBtn.click();
  await expect(nav).toBeVisible();

  // Check each link
  for (const { name, path } of mobileNavLinks) {
    const link = nav.getByRole("link", {
      name,
      exact: true
    });

    await expect(link).toBeVisible();

    const href = await link.getAttribute("href");
    expect(href).not.toBeNull();

    expect(new URL(href).pathname).toBe(path);
  }
});