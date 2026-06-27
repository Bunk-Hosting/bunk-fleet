import { test, expect } from "@playwright/test";
import { loginAs } from "./helpers";

const USER_EMAIL = process.env.TEST_USER_EMAIL || "user@test.bunkhosting.nl";
const USER_PASS = process.env.TEST_USER_PASS || "TestPass123!";

test.describe("Billing pagina's", () => {
  test.beforeEach(async ({ page }) => {
    await loginAs(page, USER_EMAIL, USER_PASS);
  });

  test("toont het billing overzicht", async ({ page }) => {
    await page.goto("/dashboard/billing");
    await expect(page).toHaveURL(/\/dashboard\/billing/);
    await expect(page.locator("body")).not.toContainText("500", { timeout: 10000 });
  });

  test("toont niet gevonden voor onbekende factuur", async ({ page }) => {
    await page.goto("/dashboard/billing/invoices/99999");
    await expect(page.locator("body")).toContainText(/niet gevonden|404/i, { timeout: 10000 });
  });
});
