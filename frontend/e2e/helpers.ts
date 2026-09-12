import { Page, expect } from "@playwright/test";

/**
 * Log in als een specifieke gebruiker via de loginpagina en wacht tot het
 * dashboard geladen is.
 *
 * Het formulier wordt pas ingevuld als de knop er echt staat. Zonder die stap
 * is de eerste login van een browsersessie flaky: Firefox begint aan de eerste
 * navigatie met een koude cache, en fill() vindt dan een veld dat nog niet
 * gehydrateerd is — de test faalt op een timeout die niets over de app zegt.
 */
export async function loginAs(page: Page, email: string, password: string) {
  await page.goto("/login");

  const submit = page.getByRole("button", { name: "Inloggen" });
  // Alleen op zichtbaarheid wachten, niet op enabled: de knop staat disabled tot
  // beide velden gevuld zijn, dus dat kan hier nog niet waar zijn.
  await expect(submit).toBeVisible({ timeout: 30000 });

  await page.getByLabel("E-mailadres").fill(email);
  await page.getByLabel("Wachtwoord").fill(password);
  await expect(submit).toBeEnabled({ timeout: 10000 });
  await submit.click();

  await page.waitForURL("**/dashboard**", { timeout: 30000 });
}

/**
 * Log uit via de navigatie.
 */
export async function logout(page: Page) {
  // Klik op het gebruikersmenu (dropdown rechtsbovenin)
  await page.getByRole("button", { name: /uitloggen/i }).click();
  await page.waitForURL("**/login**");
}
