import { test, expect } from '@playwright/test';

test('home page has the title', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveTitle('Fixture app');
});

test('home page greets', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Hello from the fixture');
});
