import { test, expect } from "@playwright/test";

/**
 * Authenticatie flows: inloggen, uitloggen, beschermde routes.
 *
 * Vereiste testgebruikers in de backend:
 *   - user@test.bunkhosting.nl / TestPass123! (gewone gebruiker, e-mail geverifieerd)
 *   - admin@test.bunkhosting.nl / AdminPass123! (admin)
 */

const USER_EMAIL = process.env.TEST_USER_EMAIL || "user@test.bunkhosting.nl";
const USER_PASS = process.env.TEST_USER_PASS || "TestPass123!";
const ADMIN_EMAIL = process.env.TEST_ADMIN_EMAIL || "admin@test.bunkhosting.nl";
const ADMIN_PASS = process.env.TEST_ADMIN_PASS || "AdminPass123!";

test.describe("Login pagina", () => {
  test("toont het loginformulier", async ({ page }) => {
    await page.goto("/login");
    await expect(page.getByLabel("E-mailadres")).toBeVisible();
    await expect(page.getByLabel("Wachtwoord")).toBeVisible();
    await expect(page.getByRole("button", { name: "Inloggen" })).toBeVisible();
  });

  test("toont een foutmelding bij foute gegevens", async ({ page }) => {
    await page.goto("/login");
    await page.getByLabel("E-mailadres").fill("wrong@example.com");
    await page.getByLabel("Wachtwoord").fill("WrongPassword!");
    await page.getByRole("button", { name: "Inloggen" }).click();
    await expect(page.getByText(/inloggen mislukt/i)).toBeVisible({ timeout: 5000 });
  });

  test("redirect naar /dashboard na succesvol inloggen", async ({ page }) => {
    await page.goto("/login");
    await page.getByLabel("E-mailadres").fill(USER_EMAIL);
    await page.getByLabel("Wachtwoord").fill(USER_PASS);
    await page.getByRole("button", { name: "Inloggen" }).click();
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 10000 });
  });
});

test.describe("Beschermde routes", () => {
  test("redirect naar /login als niet ingelogd", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page).toHaveURL(/\/login/, { timeout: 5000 });
  });

  test("gewone gebruiker kan geen admin-pagina bezoeken", async ({ page }) => {
    await page.goto("/login");
    await page.getByLabel("E-mailadres").fill(USER_EMAIL);
    await page.getByLabel("Wachtwoord").fill(USER_PASS);
    await page.getByRole("button", { name: "Inloggen" }).click();
    await page.waitForURL(/\/dashboard/);

    await page.goto("/dashboard/admin");
    await expect(page).not.toHaveURL(/\/dashboard\/admin$/, { timeout: 5000 });
  });
});
