import { test, expect } from "@playwright/test";
import { loginAs } from "./helpers";

const ADMIN_EMAIL = process.env.TEST_ADMIN_EMAIL || "admin@test.bunkhosting.nl";
const ADMIN_PASS = process.env.TEST_ADMIN_PASS || "AdminPass123!";

test.describe("Admin dashboard", () => {
  test.beforeEach(async ({ page }) => {
    await loginAs(page, ADMIN_EMAIL, ADMIN_PASS);
  });

  test("admin kan het admin-dashboard bezoeken", async ({ page }) => {
    await page.goto("/dashboard/admin");
    await expect(page).toHaveURL(/\/dashboard\/admin/);
    await expect(page.locator("body")).not.toContainText("403");
    await expect(page.locator("body")).not.toContainText("500");
  });

  test("admin kan VPS-overzicht bekijken", async ({ page }) => {
    await page.goto("/dashboard/admin/vps");
    await expect(page).toHaveURL(/\/dashboard\/admin\/vps/);
    await expect(page.locator("body")).not.toContainText("500", { timeout: 10000 });
  });

  test("toont niet gevonden voor onbekende VPS", async ({ page }) => {
    await page.goto("/dashboard/admin/vps/99999");
    await expect(page.locator("body")).toContainText(/niet gevonden|404/i, { timeout: 10000 });
  });

  test("toont niet gevonden voor onbekende gebruiker", async ({ page }) => {
    await page.goto("/dashboard/admin/users/99999");
    await expect(page.locator("body")).toContainText(/niet gevonden|404/i, { timeout: 10000 });
  });
});
