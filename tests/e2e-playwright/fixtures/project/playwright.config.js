// Playwright config for the fixture. The e2e-playwright composite sets
// BASE_URL from its target-url input; without it the config starts server.js.
import { defineConfig } from '@playwright/test';

const baseURL = process.env.BASE_URL || 'http://127.0.0.1:4173';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  reporter: 'list',
  use: { baseURL, trace: 'retain-on-failure' },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
  webServer: process.env.BASE_URL
    ? undefined
    : { command: 'node server.js', url: 'http://127.0.0.1:4173', reuseExistingServer: true, timeout: 30_000 },
});
