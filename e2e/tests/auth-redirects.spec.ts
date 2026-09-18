import { test, expect, pwRequest } from "../lib/fixtures";
import { APP, APP_PROTECTED_PATHS, APP_LEGACY_PATHS } from "../lib/targets";

/**
 * 3. Routes achter de login. Drie eisen, en de tweede is de belangrijke:
 *    - redirect naar /login (niet 200, niet 500);
 *    - geen flits van de beschermde inhoud voordat de redirect valt;
 *    - de `next`-parameter blijft een relatief pad (geen open redirect).
 */

for (const path of APP_PROTECTED_PATHS) {
  test(`${path} stuurt een anonieme bezoeker naar de login`, async ({ page }) => {
    const seen: string[] = [];
    page.on("response", (r) => {
      if (r.request().resourceType() === "document") seen.push(`${r.status()} ${r.url()}`);
    });

    const res = await page.goto(`${APP}${path}`, { waitUntil: "domcontentloaded" });

    expect.soft(res!.status(), `eindstatus voor ${path}`).toBe(200);
    expect.soft(page.url(), `${path} eindigt op ${page.url()} (keten: ${seen.join(" -> ")})`).toContain(
      "/login",
    );
    // De originele bestemming hoort bewaard te blijven, anders landt de klant
    // na inloggen op het dashboard in plaats van waar hij heen wilde.
    expect
      .soft(decodeURIComponent(page.url()), `${path} verliest de next-parameter`)
      .toContain(`next=${path}`);

    // Geen 5xx onderweg.
    for (const s of seen) {
      expect.soft(Number(s.slice(0, 3)), `serverfout onderweg naar ${path}: ${s}`).toBeLessThan(500);
    }
  });
}

test("de redirect gebeurt server-side: de beschermde inhoud flitst niet", async () => {
  // Zonder JS uit te voeren: wat staat er in het HTTP-antwoord zelf? Als de
  // gate pas in de browser dichtvalt, staat de dashboardinhoud hier gewoon in
  // en heeft iedereen met curl hem al gezien.
  const ctx = await pwRequest.newContext();
  for (const path of ["/dashboard", "/dashboard/vps", "/dashboard/beheer/users"]) {
    const res = await ctx.get(`${APP}${path}`, { maxRedirects: 0 });
    expect
      .soft([301, 302, 307, 308], `${path} zonder redirect: status ${res.status()}`)
      .toContain(res.status());
    const body = await res.text();
    expect
      .soft(body.length, `${path} levert een body van ${body.length} bytes bij een redirect`)
      .toBeLessThan(4096);
    for (const leak of ["Mijn VPS", "Gebruikers", "Omzet", "Nodes"]) {
      expect.soft(body, `${path} lekt "${leak}" in het redirect-antwoord`).not.toContain(leak);
    }
  }
  await ctx.dispose();
});

test("de next-parameter kan niet naar een ander domein wijzen", async ({ page }) => {
  // safeNext() in login/page.tsx weigert alles wat niet met één slash begint.
  // We loggen niet in, dus we kunnen de redirect ná login niet uitvoeren; wat
  // we wél kunnen vaststellen is of de waarde ergens terechtkomt waar een
  // browser hem zou volgen: een href, een form-action, of een meta refresh.
  for (const evil of ["https://evil.example/", "//evil.example/", "/\\evil.example", "javascript:alert(1)"]) {
    await page.goto(`${APP}/login?next=${encodeURIComponent(evil)}`, {
      waitUntil: "domcontentloaded",
    });
    await page.waitForTimeout(1500);

    expect.soft(page.url(), `login met next=${evil} navigeerde weg`).toContain("app.bunkhosting.nl");

    const dangerous = await page.evaluate(() => {
      const out: string[] = [];
      document.querySelectorAll<HTMLAnchorElement>("a[href]").forEach((a) => {
        if (/evil\.example|^javascript:/i.test(a.getAttribute("href") || "")) {
          out.push(`a[href=${a.getAttribute("href")}]`);
        }
      });
      document.querySelectorAll<HTMLFormElement>("form[action]").forEach((f) => {
        if (/evil\.example/i.test(f.getAttribute("action") || "")) {
          out.push(`form[action=${f.getAttribute("action")}]`);
        }
      });
      document.querySelectorAll('meta[http-equiv="refresh"]').forEach((m) => {
        out.push(`meta refresh: ${m.getAttribute("content")}`);
      });
      return out;
    });
    expect
      .soft(dangerous, `next=${evil} komt terecht in een href/action/meta-refresh: ${dangerous.join(", ")}`)
      .toEqual([]);

    // Geen scriptuitvoering door de reflectie (de waarde staat wel in de RSC-
    // payload; dat is data, zolang hij daar niet uit breekt).
    const alerts: string[] = [];
    page.on("dialog", (d) => {
      alerts.push(d.message());
      d.dismiss();
    });
    expect.soft(alerts, `next=${evil} voerde script uit`).toEqual([]);
  }
});

for (const path of APP_LEGACY_PATHS) {
  test(`${path} (toplevel, zoals genoemd in de opdracht) bestaat niet en geeft een nette 404`, async ({
    page,
  }) => {
    const res = await page.goto(`${APP}${path}`, { waitUntil: "domcontentloaded" });
    expect.soft(res!.status(), `${path}`).toBe(404);
    const body = await page.content();
    expect.soft(body, `${path} toont een Phoenix-debugpagina`).not.toContain("Phoenix");
  });
}
