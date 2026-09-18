import { test, expect } from "../lib/fixtures";
import { APP } from "../lib/targets";
import { alleenEchteBrowser } from "../lib/openstaand";
import { ga } from "../lib/navigatie";

/**
 * 4. Clientvalidatie op login en registratie.
 *
 * GRENS: er wordt hier niets verstuurd dat een account, een mail of een
 * betaling oplevert. Op /register en /forgot-password drukken we alleen op
 * verzendknoppen waarvan we eerst hebben vastgesteld dat ze uitgeschakeld zijn,
 * of we controleren de validatie via de DOM-API (checkValidity) in plaats van
 * via een echte submit.
 */

test("login: e-mailveld en wachtwoordveld zijn verplicht en correct getypeerd", async ({ page }) => {
  await page.goto(`${APP}/login`, { waitUntil: "domcontentloaded" });

  const email = page.locator("#email");
  const password = page.locator("#password");

  await expect(email).toHaveAttribute("type", "email");
  await expect(email).toHaveAttribute("required", "");
  await expect(password).toHaveAttribute("type", "password");
  await expect(password).toHaveAttribute("required", "");

  // Leeg formulier: de browser hoort het te blokkeren, niet de server.
  const emptyValid = await email.evaluate((el: HTMLInputElement) => el.checkValidity());
  expect(emptyValid, "leeg e-mailveld wordt als geldig gezien").toBe(false);

  // Ongeldig adres: type=email hoort dit te vangen zonder netwerkverkeer.
  await email.fill("geen-adres");
  const badValid = await email.evaluate((el: HTMLInputElement) => el.checkValidity());
  expect(badValid, '"geen-adres" wordt als geldig e-mailadres gezien').toBe(false);

  await email.fill("iemand@voorbeeld.nl");
  expect(await email.evaluate((el: HTMLInputElement) => el.checkValidity())).toBe(true);
});

test("login: een submit met een leeg formulier gaat niet over het net", async ({ page }) => {
  await ga(page, `${APP}/login`);

  const calls: string[] = [];
  page.on("request", (r) => {
    if (r.url().includes("/api/v1/auth/login")) calls.push(r.url());
  });

  await page.locator('button[type="submit"]').first().click({ trial: false }).catch(() => {});
  await page.waitForTimeout(1500);
  expect(calls, "een leeg loginformulier stuurde toch een request").toEqual([]);
});

test("login: de wachtwoordvelden lekken niets naar de URL (geen GET-form)", async ({ page }) => {
  await page.goto(`${APP}/login`, { waitUntil: "domcontentloaded" });
  const method = await page.locator("form").first().getAttribute("method");
  expect.soft(method === null || method.toLowerCase() === "post", `form method=${method}`).toBe(true);
});

test("login: de honeypot staat er en is voor mensen onzichtbaar", async ({ page }) => {
  await page.goto(`${APP}/login`, { waitUntil: "domcontentloaded" });
  // In login/page.tsx zit een blok dat met aria-hidden en display:none verstopt
  // is en dat nepgegevens bevat om geautomatiseerde invullers te betrappen.
  // We controleren ALLEEN dat het onzichtbaar is voor een echte bezoeker en
  // niet in de focusvolgorde zit. De inhoud laten we met rust.
  const hidden = page.locator('[aria-hidden="true"]');
  const count = await hidden.count();
  expect(count, "geen enkel aria-hidden element op de loginpagina").toBeGreaterThan(0);
  for (let i = 0; i < count; i++) {
    const el = hidden.nth(i);
    if (await el.isVisible()) continue;
    const focusables = el.locator("a, button, input, select, textarea, [tabindex]");
    const n = await focusables.count();
    for (let j = 0; j < n; j++) {
      const tab = await focusables.nth(j).getAttribute("tabindex");
      expect
        .soft(tab, "een verborgen element is met Tab bereikbaar (tabindex ontbreekt of is >= 0)")
        .toBe("-1");
    }
  }
});

test("registratie: velden zijn verplicht en de knop blijft dicht zonder captcha", async ({ page }) => {
  await ga(page, `${APP}/register`);

  for (const id of ["#name", "#email", "#password", "#password_confirm"]) {
    await expect(page.locator(id), `${id} ontbreekt`).toHaveCount(1);
    await expect(page.locator(id), `${id} is niet verplicht`).toHaveAttribute("required", "");
  }
  await expect(page.locator("#email")).toHaveAttribute("type", "email");
  await expect(page.locator("#password")).toHaveAttribute("type", "password");
  await expect(page.locator("#password_confirm")).toHaveAttribute("type", "password");

  // De knop hoort uit te staan zolang er geen Turnstile-token is. Dat is ook
  // wat maakt dat deze test op productie mag draaien: hij kan niet per ongeluk
  // een account aanmaken.
  const submit = page.locator('button[type="submit"]');
  await page.waitForTimeout(3000);
  await expect(submit, "verzendknop staat aan zonder ingevulde velden").toBeDisabled();
});

test("registratie: het wachtwoordveld noemt de minimumlengte niet in de HTML", async ({ page }) => {
  // De server eist minimaal 12 tekens (User.validate_length/:password).
  // Als het formulier dat niet aangeeft, leert de bezoeker het pas na een
  // mislukte poging — en dat kost bij een captcha-formulier een hele ronde.
  await page.goto(`${APP}/register`, { waitUntil: "domcontentloaded" });
  const minLength = await page.locator("#password").getAttribute("minlength");
  const described = await page.locator("#password").getAttribute("aria-describedby");
  const bodyText = (await page.locator("form").innerText()).toLowerCase();
  const mentionsRule = /12|minimaal|minstens|tekens|karakters/.test(bodyText);
  expect
    .soft(
      Boolean(minLength) || Boolean(described) || mentionsRule,
      "registratieformulier noemt de wachtwoordeis (min. 12 tekens) nergens en zet ook geen minlength",
    )
    .toBe(true);
});

test("wachtwoord-vergeten: formulier bekijken, niet versturen", async ({ page }) => {
  const posted: string[] = [];
  page.on("request", (r) => {
    if (r.method() === "POST" && r.url().includes("password-reset")) posted.push(r.url());
  });

  await page.goto(`${APP}/forgot-password`, { waitUntil: "domcontentloaded" });
  const email = page.locator("#email");
  await expect(email).toHaveAttribute("type", "email");
  await expect(email).toHaveAttribute("required", "");
  await expect(page.locator('button[type="submit"]')).toBeVisible();

  // Bewust geen click(): dat stuurt een echte mail.
  expect(posted, "er is toch een wachtwoord-reset verstuurd").toEqual([]);
});

test("registratie: Turnstile houdt een headless browser tegen", async ({ page }) => {
  alleenEchteBrowser("of de Turnstile-widget verschijnt");

  // Dit isoleert de captcha van de lege-velden-controle: alle velden gevuld,
  // dus als de knop dan nog dicht zit komt dat uitsluitend doordat er geen
  // Turnstile-token is. Er wordt NIET geklikt — er wordt dus geen account
  // aangemaakt, wat er ook uit komt.
  await ga(page, `${APP}/register`);
  await page.locator("#name").fill("Testpersoon");
  await page.locator("#email").fill(`e2e-${Date.now()}@voorbeeld.invalid`);
  await page.locator("#password").fill("een-voldoende-lang-wachtwoord");
  await page.locator("#password_confirm").fill("een-voldoende-lang-wachtwoord");
  await page.waitForTimeout(8000); // Turnstile alle tijd geven.

  const submit = page.locator('button[type="submit"]');
  const disabled = await submit.isDisabled();
  const widget = await page.locator('iframe[src*="challenges.cloudflare.com"]').count();

  console.log(
    `registratie: turnstile-iframes=${widget}, verzendknop ${disabled ? "UIT" : "AAN"} met alle velden gevuld`,
  );

  // Geen assertie op "moet dicht blijven": of Turnstile een headless browser
  // doorlaat is een bevinding, geen eis. Wat wél een eis is: het widget staat
  // er. Een registratieformulier zonder captcha is de bevinding.
  expect(widget, "geen Turnstile-widget op het registratieformulier").toBeGreaterThan(0);
});

test("login: de Turnstile-sleutel is geconfigureerd", async ({ page }) => {
  // Dit is het deel dat headless wél iets zegt: staat de sleutel er? Zo niet,
  // dan meldt de frontend dat zelf op het scherm en staat het formulier open
  // voor bots. Of de widget vervolgens tekent, hangt af van wat Cloudflare van
  // de bezoeker vindt -- zie de test hierboven.
  await ga(page, `${APP}/login`);
  await expect(page.getByText("CAPTCHA configuratie ontbreekt")).toHaveCount(0);
});

test("login: Turnstile-widget staat op het inlogformulier", async ({ page }) => {
  alleenEchteBrowser("of de Turnstile-widget verschijnt");

  await ga(page, `${APP}/login`);
  await page.waitForTimeout(5000);
  const widget = await page.locator('iframe[src*="challenges.cloudflare.com"]').count();
  const missingKey = await page.getByText("CAPTCHA configuratie ontbreekt").count();
  expect.soft(missingKey, "de frontend meldt dat de Turnstile-sleutel ontbreekt").toBe(0);
  expect.soft(widget, "geen Turnstile-widget op het inlogformulier").toBeGreaterThan(0);
});
