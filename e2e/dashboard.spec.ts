import { test, expect } from "@playwright/test";
import { loginAs } from "./helpers";

const USER_EMAIL = process.env.TEST_USER_EMAIL || "user@test.bunkhosting.nl";
const USER_PASS = process.env.TEST_USER_PASS || "TestPass123!";

test.describe("Dashboard navigatie", () => {
  test.beforeEach(async ({ page }) => {
    await loginAs(page, USER_EMAIL, USER_PASS);
  });

  test("toont het dashboard overzicht", async ({ page }) => {
    await expect(page).toHaveURL(/\/dashboard/);
    // Dashboard moet kernonderdelen bevatten
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
  });

  test("navigeert naar VPS-overzicht", async ({ page }) => {
    await page.goto("/dashboard/vps");
    await expect(page).toHaveURL(/\/dashboard\/vps/);
  });

  test("navigeert naar facturatieoverzicht", async ({ page }) => {
    await page.goto("/dashboard/billing");
    await expect(page).toHaveURL(/\/dashboard\/billing/);
    await expect(page.getByRole("heading")).toBeVisible();
  });

  test("toont de eigen VPS-lijst", async ({ page }) => {
    await page.goto("/dashboard/vps");
    // Pagina laadt zonder errors (VPS-lijst of lege staat)
    await expect(page.locator("body")).not.toContainText("500");
    await expect(page.locator("body")).not.toContainText("Error");
  });
});

test.describe("VPS detail pagina", () => {
  test.beforeEach(async ({ page }) => {
    await loginAs(page, USER_EMAIL, USER_PASS);
  });

  test("toont 404 voor niet-bestaande VPS", async ({ page }) => {
    await page.goto("/dashboard/vps/99999");
    // Pagina toont "niet gevonden" of redirect
    await expect(page.locator("body")).toContainText(/niet gevonden|404/i, { timeout: 10000 });
  });
});

test.describe("Nieuwe VPS aanvragen", () => {
  test.beforeEach(async ({ page }) => {
    await loginAs(page, USER_EMAIL, USER_PASS);
  });

  test("toont de pakketkeuze pagina", async ({ page }) => {
    await page.goto("/dashboard/vps/new");
    await expect(page).toHaveURL(/\/dashboard\/vps\/new/);
    // Pakketten worden geladen van de backend
    await expect(page.locator("body")).not.toContainText("500", { timeout: 10000 });
  });
});
