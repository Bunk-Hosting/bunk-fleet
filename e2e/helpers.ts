import { Page } from "@playwright/test";

/**
 * Log in als een specifieke gebruiker via de login-pagina.
 * Wacht tot het dashboard zichtbaar is.
 */
export async function loginAs(page: Page, email: string, password: string) {
  await page.goto("/login");
  await page.getByLabel("E-mailadres").fill(email);
  await page.getByLabel("Wachtwoord").fill(password);
  await page.getByRole("button", { name: "Inloggen" }).click();
  await page.waitForURL("**/dashboard**");
}

/**
 * Log uit via de navigatie.
 */
export async function logout(page: Page) {
  // Klik op het gebruikersmenu (dropdown rechtsbovenin)
  await page.getByRole("button", { name: /uitloggen/i }).click();
  await page.waitForURL("**/login**");
}
