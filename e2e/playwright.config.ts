import { defineConfig, devices } from "@playwright/test";

/**
 * Deze suite draait tegen de LIVE productieomgeving. Daarom:
 *  - geen enkele test verstuurt een formulier dat mail, een account of een
 *    betaling oplevert (registratie, wachtwoord-vergeten, Mollie);
 *  - geen enkele test muteert een bestaande VPS, node, regio of gebruiker;
 *  - alles wat hier staat is read-only of stuurt hoogstens een request die
 *    sowieso 401 hoort te geven.
 *
 * `retries: 0` met opzet: een flake is hier informatie (de edge of de tunnel
 * hikte), geen ruis die je wegdrukt door het nog eens te proberen.
 */
export const APP = process.env.BUNK_APP_URL || "https://app.bunkhosting.nl";
export const WWW = process.env.BUNK_WWW_URL || "https://bunkhosting.nl";

export default defineConfig({
  testDir: "./tests",
  // Eén worker, niets parallel. VM102 heeft 2 vCPU en 4 GB en draait daarnaast
  // de control plane, de frontend, Postgres en de edge. Met vier Chromiums
  // erbij liep het load-gemiddelde naar 30+ en antwoordde de qemu-guest-agent
  // van die machine niet meer: de site bleef 200 geven, maar de machine was
  // niet meer te bedienen. Een suite die de productiemachine onder druk zet
  // meet zijn eigen ruis in plaats van de dienst.
  //
  // Wie hem ergens anders draait (een losse runner) mag dit opendraaien met
  // BUNK_WORKERS; tegen deze machine niet.
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: 0,
  workers: Number(process.env.BUNK_WORKERS || 1),
  reporter: [
    ["list"],
    ["html", { open: "never", outputFolder: "playwright-report" }],
    ["json", { outputFile: "results.json" }],
  ],
  timeout: 45_000,
  expect: { timeout: 10_000 },
  use: {
    baseURL: APP,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "off",
    ignoreHTTPSErrors: false,
    actionTimeout: 15_000,
  },
  projects: [
    {
      name: "desktop",
      use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 } },
      testIgnore: /mobile\.spec\.ts/,
    },
    {
      name: "mobile-390",
      // 390x844 = iPhone 12/13/14. De opdracht noemt expliciet 390px breed.
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 390, height: 844 },
        isMobile: false, // Chromium desktop met mobiele viewport: touch-emulatie
        hasTouch: true, //  hoeft niet, maar tap-targets meten wel.
        deviceScaleFactor: 2,
      },
      testMatch: /mobile\.spec\.ts/,
    },
  ],
});
