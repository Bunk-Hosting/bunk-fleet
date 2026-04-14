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

  test("admin dashboard toont statistieken", async ({ page }) => {
    await page.goto("/dashboard/admin");
    // Stats worden geladen van /api/v1/admin/stats/
    await expect(page.locator("body")).not.toContainText("Error", { timeout: 10000 });
  });

  test("admin kan gebruikersoverzicht bekijken", async ({ page }) => {
    await page.goto("/dashboard/admin/users");
    await expect(page).toHaveURL(/\/dashboard\/admin\/users/);
    await expect(page.locator("body")).not.toContainText("500", { timeout: 10000 });
  });

  test("admin kan VPS-overzicht bekijken", async ({ page }) => {
    await page.goto("/dashboard/admin/vps");
    await expect(page).toHaveURL(/\/dashboard\/admin\/vps/);
    await expect(page.locator("body")).not.toContainText("500", { timeout: 10000 });
  });

  test("admin kan netwerkoverzicht bekijken", async ({ page }) => {
    await page.goto("/dashboard/admin/network");
    await expect(page).toHaveURL(/\/dashboard\/admin\/network/);
    await expect(page.locator("body")).not.toContainText("500", { timeout: 10000 });
  });

  test("admin kan auditlogs bekijken", async ({ page }) => {
    await page.goto("/dashboard/admin/logs");
    await expect(page).toHaveURL(/\/dashboard\/admin\/logs/);
    await expect(page.locator("body")).not.toContainText("500", { timeout: 10000 });
  });

  test("admin kan invite codes beheren", async ({ page }) => {
    await page.goto("/dashboard/admin/invite-codes");
    await expect(page).toHaveURL(/\/dashboard\/admin\/invite-codes/);
    await expect(page.locator("body")).not.toContainText("500", { timeout: 10000 });
  });

  test("admin kan reconciliatie pagina bekijken", async ({ page }) => {
    await page.goto("/dashboard/admin/reconcile");
    await expect(page).toHaveURL(/\/dashboard\/admin\/reconcile/);
    await expect(page.locator("body")).not.toContainText("500", { timeout: 10000 });
  });
});

test.describe("Admin VPS detail acties", () => {
  test.beforeEach(async ({ page }) => {
    await loginAs(page, ADMIN_EMAIL, ADMIN_PASS);
  });

  test("toont niet gevonden voor onbekende VPS", async ({ page }) => {
    await page.goto("/dashboard/admin/vps/99999");
    await expect(page.locator("body")).toContainText(/niet gevonden|404/i, { timeout: 10000 });
  });
});

test.describe("Admin gebruikersdetail", () => {
  test.beforeEach(async ({ page }) => {
    await loginAs(page, ADMIN_EMAIL, ADMIN_PASS);
  });

  test("toont niet gevonden voor onbekende gebruiker", async ({ page }) => {
    await page.goto("/dashboard/admin/users/99999");
    await expect(page.locator("body")).toContainText(/niet gevonden|404/i, { timeout: 10000 });
  });
});
