import { defineConfig, devices } from "@playwright/test";

/**
 * Playwright E2E-configuratie voor Bunk Hosting frontend.
 *
 * Draai tegen de lokale dev-stack:
 *   1. Start de backend: cd vps-backend && python manage.py runserver
 *   2. Start de frontend: npm run dev
 *   3. Voer tests uit: npm run test:e2e
 *
 * Of tegen productie (read-only flows):
 *   BASE_URL=https://app.bunkhosting.nl npm run test:e2e
 */

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: "html",

  use: {
    baseURL: process.env.BASE_URL || "http://localhost:3000",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },

  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
    {
      name: "firefox",
      use: { ...devices["Desktop Firefox"] },
    },
    {
      name: "Mobile Chrome",
      use: { ...devices["Pixel 5"] },
    },
  ],
});
