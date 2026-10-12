import { test, expect } from '@playwright/test';

// Enabled by E2E_FIXTURE_FAIL=1 so CI can prove the gate fails and annotates.
test('deliberately failing when E2E_FIXTURE_FAIL is set', async ({ page }) => {
  test.skip(!process.env.E2E_FIXTURE_FAIL, 'set E2E_FIXTURE_FAIL=1 to run');
  await page.goto('/');
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Goodbye');
});
