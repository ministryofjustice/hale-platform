const { test, expect } = require('@playwright/test');

test.describe('Ministry of Justice Website Builder', () => {
  test('homepage has correct title', async ({ page }) => {
    await page.goto('/');
    
    // Check that the page title is correct
    await expect(page).toHaveTitle('Ministry of Justice Website Builder');
  });

  test('homepage has header', async ({ page }) => {
    await page.goto('/');
    
    // Check that a header element exists
    await expect(page.locator('header')).toBeVisible();
  });

  test('homepage has footer', async ({ page }) => {
    await page.goto('/');
    
    // Check that a footer element exists
    await expect(page.locator('footer')).toBeVisible();
  });
});
