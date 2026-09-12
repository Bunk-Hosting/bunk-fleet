import { test, expect } from "@playwright/test";

/**
 * Authenticatie flows: inloggen, uitloggen, beschermde routes.
 *
 * Vereiste testgebruikers in de control plane:
 *   - user@test.bunkhosting.nl / TestPass123! (gewone gebruiker, e-mail bevestigd)
 *   - admin@test.bunkhosting.nl / AdminPass123! (admin)
 */

const USER_EMAIL = process.env.TEST_USER_EMAIL || "user@test.bunkhosting.nl";
const USER_PASS = process.env.TEST_USER_PASS || "TestPass123!";

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

    // De toast zet dezelfde tekst zowel zichtbaar als in een aria-live-regio
    // neer; een losse getByText(/inloggen mislukt/i) matcht er dus twee. Exact
    // matchen pakt alleen de zichtbare titel.
    await expect(page.getByText("Inloggen mislukt", { exact: true })).toBeVisible({
      timeout: 10000,
    });
    await expect(page).toHaveURL(/\/login/);
  });

  test("redirect naar /dashboard na succesvol inloggen", async ({ page }) => {
    await page.goto("/login");
    await page.getByLabel("E-mailadres").fill(USER_EMAIL);
    await page.getByLabel("Wachtwoord").fill(USER_PASS);
    await page.getByRole("button", { name: "Inloggen" }).click();

    await expect(page).toHaveURL(/\/dashboard/, { timeout: 10000 });
    // Aangekomen is niet hetzelfde als geladen: zonder dit slaagt de test ook
    // als het dashboard een lege pagina rendert.
    await expect(page.getByRole("heading", { name: /welkom terug/i })).toBeVisible({
      timeout: 15000,
    });
  });
});

test.describe("Beschermde routes", () => {
  test("redirect naar /login als niet ingelogd", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page).toHaveURL(/\/login/, { timeout: 5000 });
  });

  test("een gewone gebruiker krijgt het beheerpaneel niet te zien", async ({ page }) => {
    await page.goto("/login");
    await page.getByLabel("E-mailadres").fill(USER_EMAIL);
    await page.getByLabel("Wachtwoord").fill(USER_PASS);
    await page.getByRole("button", { name: "Inloggen" }).click();
    await page.waitForURL(/\/dashboard/);

    await page.goto("/dashboard/beheer");

    // De pagina blijft op zijn URL staan en weigert in plaats van te redirecten
    // (AdminGuard). Wat telt is dat er geen beheerinhoud verschijnt: de echte
    // grens is de API, die elke /beheer-call van een :user met 403 beantwoordt.
    await expect(page.getByText(/geen toegang/i)).toBeVisible({ timeout: 10000 });
    await expect(page.getByRole("heading", { name: "Beheer", exact: true })).toHaveCount(0);
  });
});
