import { test, expect } from "../lib/fixtures";
import AxeBuilder from "@axe-core/playwright";
// Het Page-type zoals axe het kent; zie de opmerking bij het gebruik hieronder.
type AxePage = ConstructorParameters<typeof AxeBuilder>[0]["page"];
import { APP, WWW } from "../lib/targets";
import { alleenEchteBrowser } from "../lib/openstaand";
import { ga } from "../lib/navigatie";

/**
 * 7. Toegankelijkheid op de publieke pagina's.
 *
 * axe-core doet het meetbare werk (labels, contrast, alt, landmarks); daarnaast
 * een paar handmatige controles die axe niet dekt: focusvolgorde en een
 * zichtbare focusring.
 */

const PAGES = [
  { name: "marketingsite", url: `${WWW}/` },
  { name: "login", url: `${APP}/login` },
  { name: "registratie", url: `${APP}/register` },
  { name: "wachtwoord vergeten", url: `${APP}/forgot-password` },
];

for (const { name, url } of PAGES) {
  test(`${name}: axe-core WCAG 2.1 A/AA`, async ({ page }, testInfo) => {
    await ga(page, url);
    // Bovenop het wachten in ga(): axe meet ook wat er na de hydratie bijkomt.
    await page.waitForTimeout(2000);

    // De cast is er omdat @axe-core/playwright zijn eigen, oudere playwright-core
    // meebrengt: twee `Page`-types die op elkaar lijken maar voor de compiler
    // niet hetzelfde zijn. Op de draaiende code maakt het niets uit -- het is
    // hetzelfde object -- en de alternatieven zijn beide slechter: axe op een
    // oude Playwright vastzetten, of de typecontrole van dit bestand uitzetten.
    const results = await new AxeBuilder({ page: page as unknown as AxePage })
      .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
      // De Turnstile-iframe is van Cloudflare; hun DOM is niet onze bug.
      .exclude("iframe[src*='challenges.cloudflare.com']")
      .analyze();

    const summary = results.violations.map((v) => ({
      id: v.id,
      impact: v.impact,
      help: v.help,
      nodes: v.nodes.slice(0, 5).map((n) => ({ target: n.target, html: n.html.slice(0, 160) })),
    }));

    testInfo.attach(`axe-${name}.json`, {
      body: JSON.stringify(summary, null, 2),
      contentType: "application/json",
    });

    const serious = results.violations.filter(
      (v) => v.impact === "critical" || v.impact === "serious",
    );

    // De selector van het eerste element staat in de melding zelf. Een rapport
    // dat zegt "één contrastfout" en niet waar, dwingt degene die het leest tot
    // precies het werk dat de test al gedaan heeft.
    expect
      .soft(
        serious.map(
          (v) =>
            `${v.id} (${v.nodes.length}x): ${v.help} — eerste: ${v.nodes[0]?.target.join(" ")}`,
        ),
        `${name}: ernstige toegankelijkheidsfouten`,
      )
      .toEqual([]);
    expect
      .soft(
        results.violations.map((v) => `${v.id} [${v.impact}] ${v.nodes.length}x`),
        `${name}: alle axe-overtredingen`,
      )
      .toEqual([]);
  });

  test(`${name}: elke afbeelding heeft een alt-tekst`, async ({ page }) => {
    await ga(page, url);
    const missing = await page.evaluate(() =>
      Array.from(document.querySelectorAll("img"))
        .filter((img) => img.getAttribute("alt") === null)
        .map((img) => img.getAttribute("src") || "(geen src)"),
    );
    expect.soft(missing, `${name}: <img> zonder alt-attribuut`).toEqual([]);
  });

  test(`${name}: pagina heeft een taalattribuut en een titel`, async ({ page }) => {
    await page.goto(url, { waitUntil: "domcontentloaded" });
    const lang = await page.locator("html").getAttribute("lang");
    expect.soft(lang, `${name}: <html lang> ontbreekt`).toBeTruthy();
    const title = await page.title();
    expect.soft(title.length, `${name}: lege <title>`).toBeGreaterThan(3);
    const h1 = await page.locator("h1").count();
    expect.soft(h1, `${name}: aantal <h1> is ${h1}`).toBeGreaterThanOrEqual(1);
  });
}

test("login: elk invoerveld heeft een gekoppeld label", async ({ page }) => {
  await ga(page, `${APP}/login`);
  const unlabeled = await page.evaluate(() => {
    const out: string[] = [];
    document
      .querySelectorAll<HTMLInputElement>('input:not([type="hidden"])')
      .forEach((el) => {
        const cs = getComputedStyle(el);
        if (cs.display === "none" || cs.visibility === "hidden") return; // honeypot
        const byFor = el.id ? document.querySelector(`label[for="${el.id}"]`) : null;
        const wrapped = el.closest("label");
        const aria = el.getAttribute("aria-label") || el.getAttribute("aria-labelledby");
        if (!byFor && !wrapped && !aria) out.push(el.id || el.name || el.outerHTML.slice(0, 100));
      });
    return out;
  });
  expect(unlabeled, "invoervelden zonder label").toEqual([]);
});

test("login: focusvolgorde loopt van e-mail naar wachtwoord naar verzenden", async ({ page }) => {
  // Zonder Turnstile-token blijft de inlogknop uitgeschakeld, en een
  // uitgeschakelde knop staat niet in de tabvolgorde. Deze test meet dan de
  // afwezigheid van een token in plaats van de focusvolgorde.
  alleenEchteBrowser("de focusvolgorde tot aan de inlogknop");

  await ga(page, `${APP}/login`);
  await page.waitForTimeout(2000);

  await page.locator("#email").focus();
  const order: string[] = [];
  for (let i = 0; i < 8; i++) {
    await page.keyboard.press("Tab");
    order.push(
      await page.evaluate(() => {
        const a = document.activeElement as HTMLElement | null;
        if (!a) return "(niets)";
        return `${a.tagName.toLowerCase()}${a.id ? "#" + a.id : ""}${
          a.getAttribute("type") ? "[" + a.getAttribute("type") + "]" : ""
        }`;
      }),
    );
  }

  const pw = order.findIndex((o) => o.includes("#password"));
  const submit = order.findIndex((o) => o.includes("[submit]"));
  expect(pw, `wachtwoordveld niet in de tabvolgorde: ${order.join(" -> ")}`).toBeGreaterThanOrEqual(0);
  expect(
    submit > pw,
    `verzendknop komt niet na het wachtwoordveld: ${order.join(" -> ")}`,
  ).toBe(true);

  // Geen honeypot-veld in de tabvolgorde.
  expect
    .soft(order.filter((o) => /honey|trap|bot/i.test(o)), "verborgen veld in de tabvolgorde")
    .toEqual([]);
});

test("login: een gefocust element is zichtbaar gemarkeerd", async ({ page }) => {
  await ga(page, `${APP}/login`);
  const ring = await page.locator("#email").evaluate((el) => {
    el.focus();
    const cs = getComputedStyle(el);
    return {
      outlineWidth: cs.outlineWidth,
      outlineStyle: cs.outlineStyle,
      boxShadow: cs.boxShadow,
      borderColor: cs.borderColor,
    };
  });
  const visible =
    (ring.outlineStyle !== "none" && parseFloat(ring.outlineWidth) > 0) ||
    (ring.boxShadow !== "none" && ring.boxShadow.length > 0);
  expect(visible, `geen zichtbare focusindicatie: ${JSON.stringify(ring)}`).toBe(true);
});
