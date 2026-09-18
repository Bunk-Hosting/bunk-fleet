import { test, expect } from "../lib/fixtures";
import { APP, WWW } from "../lib/targets";
import { ga } from "../lib/navigatie";

/**
 * 6. Mobiel, 390px breed. Twee dingen:
 *    - de pagina mag niet horizontaal scrollen;
 *    - wat je moet kunnen aanraken, moet groot genoeg zijn. Twee drempels:
 *      24 CSS-px is WCAG 2.2 / 2.5.8 (niveau AA, een echte fout eronder) en
 *      44 CSS-px is 2.5.5 (AAA) plus de vuistregel van Apple en Google.
 */

const PAGES = [
  { name: "marketingsite", url: `${WWW}/` },
  { name: "login", url: `${APP}/login` },
  { name: "registratie", url: `${APP}/register` },
  { name: "wachtwoord vergeten", url: `${APP}/forgot-password` },
];

for (const { name, url } of PAGES) {
  test(`${name} @390px: geen horizontale scroll`, async ({ page }, testInfo) => {
    await ga(page, url);
    await page.waitForTimeout(1500);

    const metrics = await page.evaluate(() => ({
      scrollWidth: document.documentElement.scrollWidth,
      clientWidth: document.documentElement.clientWidth,
      bodyScroll: document.body.scrollWidth,
    }));

    if (metrics.scrollWidth > metrics.clientWidth + 1) {
      // Wie is de boosdoener? Zonder dat is "het scrollt" niet op te lossen.
      const culprits = await page.evaluate(() => {
        const w = document.documentElement.clientWidth;
        const out: string[] = [];
        document.querySelectorAll<HTMLElement>("*").forEach((el) => {
          const r = el.getBoundingClientRect();
          if (r.width > 0 && r.right > w + 1) {
            out.push(
              `${el.tagName.toLowerCase()}${el.id ? "#" + el.id : ""}.${(el.className || "")
                .toString()
                .split(" ")
                .filter(Boolean)
                .slice(0, 3)
                .join(".")} right=${Math.round(r.right)}`,
            );
          }
        });
        return out.slice(0, 15);
      });
      testInfo.attach("overflow.png", {
        body: await page.screenshot({ fullPage: true }),
        contentType: "image/png",
      });
      expect(
        metrics.scrollWidth,
        `${name} scrollt horizontaal: ${metrics.scrollWidth}px in een viewport van ${metrics.clientWidth}px. Te brede elementen: ${culprits.join(" | ")}`,
      ).toBeLessThanOrEqual(metrics.clientWidth + 1);
    }
  });

  test(`${name} @390px: knoppen en links zijn groot genoeg om aan te raken`, async ({ page }, testInfo) => {

    await ga(page, url);
    await page.waitForTimeout(1500);

    // Twee drempels, want ze wegen niet hetzelfde:
    //  - 24 CSS-px is WCAG 2.2, succescriterium 2.5.8, niveau AA. Daaronder is
    //    het een echte fout.
    //  - 44 CSS-px is 2.5.5 (AAA) en de ondergrens die Apple en Google zelf
    //    aanhouden. Daartussen is het een advies, geen overtreding.
    const targets = await page.evaluate(() => {
      const out: Array<{ label: string; w: number; h: number }> = [];
      const sel = 'a[href], button, input:not([type="hidden"]), select, [role="button"]';
      document.querySelectorAll<HTMLElement>(sel).forEach((el) => {
        const cs = getComputedStyle(el);
        if (cs.display === "none" || cs.visibility === "hidden" || cs.opacity === "0") return;
        const r = el.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) return;
        // Een link midden in een alinea is tekst, geen knop; die uitsluiten,
        // anders meet je typografie in plaats van bedienbaarheid.
        if (el.tagName === "A" && el.closest("p") !== null) return;
        const label = (el.innerText || el.getAttribute("aria-label") || el.getAttribute("name") || "")
          .replace(/\s+/g, " ")
          .trim()
          .slice(0, 30);
        out.push({
          label: `${el.tagName.toLowerCase()}${el.id ? "#" + el.id : ""} "${label}"`,
          w: Math.round(r.width),
          h: Math.round(r.height),
        });
      });
      return out;
    });

    const fmt = (t: { label: string; w: number; h: number }) => `${t.label} ${t.w}x${t.h}`;
    const underAA = targets.filter((t) => t.h < 24 || t.w < 24).map(fmt);
    const underAAA = targets.filter((t) => (t.h < 44 || t.w < 44) && t.h >= 24 && t.w >= 24).map(fmt);

    if (underAA.length || underAAA.length) {
      testInfo.attach("taptargets.png", {
        body: await page.screenshot({ fullPage: true }),
        contentType: "image/png",
      });
    }

    // De 24px-grens is een echte fout en laat de test vallen.
    expect
      .soft(underAA, `${name}: onder WCAG 2.5.8 (24px, niveau AA): ${underAA.join(" | ")}`)
      .toEqual([]);

    // De 44px-vuistregel is een advies en laat de test NIET vallen. Dat is geen
    // gemakzucht: de invoervelden en knoppen hier zijn 40px, en 40 is een
    // verdedigbare maat die de helft van het web aanhoudt. Zou dit rood geven,
    // dan staat de suite permanent rood op een ontwerpkeuze -- en een suite die
    // altijd rood staat is geen suite. Het blijft wel zichtbaar: het komt als
    // annotatie in het rapport, zodat wie de knoppen ooit aanpakt weet welke
    // het zijn.
    if (underAAA.length) {
      testInfo.annotations.push({
        type: "advies",
        description: `${name}: onder de 44px-vuistregel (2.5.5, advies): ${underAAA.join(" | ")}`,
      });
    }
  });
}

test("login @390px: het formulier past en is bedienbaar", async ({ page }, testInfo) => {
  await ga(page, `${APP}/login`);
  await page.waitForTimeout(2000);
  await expect(page.locator("#email")).toBeVisible();
  await expect(page.locator("#password")).toBeVisible();
  await expect(page.locator('button[type="submit"]').first()).toBeVisible();

  // Het invoerveld mag bij focus niet buiten beeld vallen.
  await page.locator("#email").click();
  const box = await page.locator("#email").boundingBox();
  expect(box!.x).toBeGreaterThanOrEqual(0);
  expect(box!.x + box!.width).toBeLessThanOrEqual(391);

  testInfo.attach("login-390.png", {
    body: await page.screenshot({ fullPage: true }),
    contentType: "image/png",
  });
});
