import { test, expect } from '@playwright/test';

test('Hale homepage loads', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveTitle(/Ministry of Justice Website Builder/);
});
