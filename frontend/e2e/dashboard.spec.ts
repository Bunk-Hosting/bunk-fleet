import { test, expect } from "@playwright/test";
import { loginAs } from "./helpers";

const USER_EMAIL = process.env.TEST_USER_EMAIL || "user@test.bunkhosting.nl";
const USER_PASS = process.env.TEST_USER_PASS || "TestPass123!";

test.describe("Dashboard navigatie", () => {
  test.beforeEach(async ({ page }) => {
    await loginAs(page, USER_EMAIL, USER_PASS);
  });

  test("toont de eigen VPS-lijst", async ({ page }) => {
    await page.goto("/dashboard/vps");

    // Op de kop wachten, niet op de afwezigheid van "500": dat laatste slaagt
    // ook op een blanco pagina.
    await expect(page.getByRole("heading", { name: /mijn vps/i })).toBeVisible({
      timeout: 10000,
    });
  });

  test("toont niet gevonden voor een VPS die niet bestaat", async ({ page }) => {
    await page.goto("/dashboard/vps/00000000-0000-0000-0000-000000000000");
    await expect(page.getByText(/niet gevonden/i).first()).toBeVisible({ timeout: 10000 });
  });

  test("een VPS-id dat geen id is loopt niet vast", async ({ page }) => {
    await page.goto("/dashboard/vps/99999");
    await expect(page.getByText(/niet gevonden/i).first()).toBeVisible({ timeout: 10000 });
  });
});
