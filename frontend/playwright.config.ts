import { defineConfig, devices } from "@playwright/test";

/**
 * Playwright E2E-configuratie voor Bunk Hosting frontend.
 *
 * Draai tegen de lokale dev-stack:
 *   1. Start de control plane: cd control_plane && mix phx.server
 *   2. Start de frontend: npm run dev
 *   3. Voer tests uit: npm run test:e2e
 *
 * Of tegen de live app:
 *   BASE_URL=https://app.bunkhosting.nl npm run test:e2e
 *
 * De suite heeft twee testaccounts nodig, die bestaan in de control plane:
 * user@test.bunkhosting.nl en admin@test.bunkhosting.nl. Overschrijf ze met
 * TEST_USER_EMAIL / TEST_USER_PASS / TEST_ADMIN_EMAIL / TEST_ADMIN_PASS.
 *
 * Niet onderdeel van CI: deze tests hebben een draaiende stack nodig en de
 * CI-runner heeft die niet. Ze horen bij een deploy, niet bij een push.
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
      // Firefox' eerste navigatie van een run kost ~8s tegen deze app (gemeten:
      // domcontentloaded 8,3s koud, 0,4s daarna) en daar komt het starten van het
      // browserproces met een verse profielmap bovenop. Met de standaard van 30s
      // viel de eerste test elke run om op een timeout die niets over de app zei.
      // Alleen de eerste test heeft dit nodig, maar Playwright kent geen
      // per-test-timeout per project, dus staat het op het project.
      timeout: 60_000,
    },
    {
      name: "Mobile Chrome",
      use: { ...devices["Pixel 5"] },
    },
  ],
});
