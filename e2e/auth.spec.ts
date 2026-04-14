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

  test("redirect naar ?next= parameter na inloggen", async ({ page }) => {
    await page.goto("/login?next=/dashboard/vps");
    await page.getByLabel("E-mailadres").fill(USER_EMAIL);
    await page.getByLabel("Wachtwoord").fill(USER_PASS);
    await page.getByRole("button", { name: "Inloggen" }).click();
    await expect(page).toHaveURL(/\/dashboard\/vps/, { timeout: 10000 });
  });
});

test.describe("Beschermde routes", () => {
  test("redirect naar /login als niet ingelogd", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page).toHaveURL(/\/login/, { timeout: 5000 });
  });

  test("redirect naar /login voor admin routes als niet ingelogd", async ({ page }) => {
    await page.goto("/dashboard/admin");
    await expect(page).toHaveURL(/\/login/, { timeout: 5000 });
  });

  test("gewone gebruiker kan geen admin-pagina bezoeken", async ({ page }) => {
    await page.goto("/login");
    await page.getByLabel("E-mailadres").fill(USER_EMAIL);
    await page.getByLabel("Wachtwoord").fill(USER_PASS);
    await page.getByRole("button", { name: "Inloggen" }).click();
    await page.waitForURL(/\/dashboard/);

    await page.goto("/dashboard/admin");
    // Middleware redirectt naar /dashboard of toont 403/404
    await expect(page).not.toHaveURL(/\/dashboard\/admin$/, { timeout: 5000 });
  });
});

test.describe("Registratie pagina", () => {
  test("toont het registratieformulier", async ({ page }) => {
    await page.goto("/register");
    await expect(page.getByLabel("Naam")).toBeVisible();
    await expect(page.getByLabel("E-mailadres")).toBeVisible();
    await expect(page.getByLabel(/wachtwoord/i)).toBeVisible();
  });

  test("toont foutmelding bij wachtwoord mismatch", async ({ page }) => {
    await page.goto("/register");
    await page.getByLabel("Naam").fill("Test Gebruiker");
    await page.getByLabel("E-mailadres").fill("nieuw@example.com");
    // Vul het wachtwoord en bevestigingsveld afzonderlijk
    const passwordFields = page.getByLabel(/wachtwoord/i);
    await passwordFields.first().fill("StrongPass123!");
    await passwordFields.last().fill("DifferentPass!");
    await page.getByRole("button", { name: /registreer/i }).click();
    await expect(page.getByText(/wachtwoord/i)).toBeVisible({ timeout: 5000 });
  });
});
