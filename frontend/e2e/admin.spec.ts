import { test, expect } from "@playwright/test";
import { loginAs } from "./helpers";

const ADMIN_EMAIL = process.env.TEST_ADMIN_EMAIL || "admin@test.bunkhosting.nl";
const ADMIN_PASS = process.env.TEST_ADMIN_PASS || "AdminPass123!";

/**
 * Het beheerpaneel zit op /dashboard/beheer, niet op /dashboard/admin: Cloudflare's
 * managed WAF beantwoordt elk pad met "/admin" erin met een challenge-pagina
 * voordat het de origin bereikt.
 */
test.describe("Beheerpaneel", () => {
  test.beforeEach(async ({ page }) => {
    await loginAs(page, ADMIN_EMAIL, ADMIN_PASS);
  });

  test("een admin komt het beheerpaneel binnen", async ({ page }) => {
    await page.goto("/dashboard/beheer");

    await expect(page.getByRole("heading", { name: "Beheer", exact: true })).toBeVisible({
      timeout: 10000,
    });
    await expect(page.getByText(/geen toegang/i)).toHaveCount(0);
  });

  test("een admin ziet het vlootbrede VPS-overzicht", async ({ page }) => {
    await page.goto("/dashboard/beheer/vps");

    await expect(page.getByRole("heading", { name: /vps-beheer/i })).toBeVisible({
      timeout: 10000,
    });
  });

  test("een admin ziet de gebruikerslijst", async ({ page }) => {
    await page.goto("/dashboard/beheer/users");

    await expect(page.getByRole("heading", { name: "Gebruikers", exact: true })).toBeVisible({
      timeout: 10000,
    });
  });

  test("toont niet gevonden voor onbekende VPS", async ({ page }) => {
    await page.goto("/dashboard/beheer/vps/99999");
    await expect(page.locator("body")).toContainText(/niet gevonden|404/i, { timeout: 10000 });
  });

  test("toont niet gevonden voor onbekende gebruiker", async ({ page }) => {
    await page.goto("/dashboard/beheer/users/99999");
    await expect(page.locator("body")).toContainText(/niet gevonden|404/i, { timeout: 10000 });
  });

  test("een admin ziet de cijfers", async ({ page }) => {
    await page.goto("/dashboard/beheer/metrics");

    await expect(page.getByRole("heading", { name: "Cijfers", exact: true })).toBeVisible({
      timeout: 15000,
    });
    await expect(page.getByText(/capaciteit per node/i)).toBeVisible();

    // De belofte van de pagina, afgedwongen waar iemand hem zou breken: in de
    // inhoud mag geen e-mailadres staan. Niet op de body, want de zijbalk toont
    // het adres van wie er zelf is ingelogd — dat is de app-omlijsting, geen
    // klantgegeven dat deze pagina laat zien.
    const content = page.getByRole("heading", { name: "Cijfers", exact: true })
      .locator("xpath=ancestor::div[contains(@class,'space-y-8')][1]");
    await expect(content).not.toContainText("@");
  });

  test("een admin ziet het nodeoverzicht", async ({ page }) => {
    await page.goto("/dashboard/beheer/nodes");

    await expect(page.getByRole("heading", { name: "Nodes", exact: true })).toBeVisible({
      timeout: 15000,
    });
  });
});
