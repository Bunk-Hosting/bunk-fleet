import { test, expect, pwRequest } from "../lib/fixtures";
import { APP, WWW } from "../lib/targets";
import { ga } from "../lib/navigatie";

/**
 * 2. Securityheaders, TLS en cookievlaggen op beide domeinen.
 *
 * Alles met expect.soft: één ontbrekende header moet de rest van het rapport
 * niet afkappen. Een run die faalt hoort ALLE gaten te laten zien, niet de
 * eerste.
 */

type Hdrs = Record<string, string>;

async function headersOf(url: string): Promise<{ status: number; headers: Hdrs }> {
  const ctx = await pwRequest.newContext({ ignoreHTTPSErrors: false });
  const res = await ctx.get(url, { maxRedirects: 0 });
  const headers: Hdrs = {};
  for (const [k, v] of Object.entries(res.headers())) headers[k.toLowerCase()] = v;
  const status = res.status();
  await ctx.dispose();
  return { status, headers };
}

for (const [label, base] of [
  ["app", APP],
  ["www", WWW],
] as const) {
  test(`${label}: verplichte securityheaders staan er`, async ({}, testInfo) => {

    const { headers } = await headersOf(`${base}/`);
    testInfo.attach(`${label}-headers.json`, {
      body: JSON.stringify(headers, null, 2),
      contentType: "application/json",
    });

    // HSTS: minstens een jaar, en subdomeinen mee. Zonder includeSubDomains
    // blijft elk toekomstig subdomein een ongepinde eerste verbinding houden.
    const hsts = headers["strict-transport-security"] ?? "";
    expect.soft(hsts, `${label} mist HSTS`).not.toBe("");
    const maxAge = Number(/max-age=(\d+)/.exec(hsts)?.[1] ?? 0);
    expect.soft(maxAge, `${label} HSTS max-age (${hsts})`).toBeGreaterThanOrEqual(31536000);
    expect.soft(hsts, `${label} HSTS zonder includeSubDomains: "${hsts}"`).toContain("includeSubDomains");

    expect.soft(headers["x-content-type-options"], `${label} nosniff`).toBe("nosniff");

    // Clickjacking: X-Frame-Options EN frame-ancestors. De eerste voor oude
    // browsers, de tweede omdat XFO officieel dood is.
    const xfo = (headers["x-frame-options"] ?? "").toUpperCase();
    expect.soft(["DENY", "SAMEORIGIN"], `${label} X-Frame-Options "${xfo}"`).toContain(xfo);

    const csp = headers["content-security-policy"] ?? "";
    expect.soft(csp, `${label} mist CSP`).not.toBe("");
    expect.soft(csp, `${label} CSP zonder frame-ancestors`).toContain("frame-ancestors");
    expect.soft(csp, `${label} CSP zonder object-src 'none'`).toContain("object-src 'none'");
    expect.soft(csp, `${label} CSP zonder base-uri`).toContain("base-uri");
    expect.soft(csp, `${label} CSP zonder form-action`).toContain("form-action");

    // 'unsafe-inline' in script-src maakt van de CSP een decoratie: elke XSS
    // die je erin krijgt voert gewoon uit.
    const scriptSrc = /script-src([^;]*)/.exec(csp)?.[1] ?? "";
    expect
      .soft(scriptSrc, `${label} script-src staat 'unsafe-inline' toe: "${scriptSrc.trim()}"`)
      .not.toContain("'unsafe-inline'");
    expect
      .soft(scriptSrc, `${label} script-src staat 'unsafe-eval' toe: "${scriptSrc.trim()}"`)
      .not.toContain("'unsafe-eval'");

    const ref = headers["referrer-policy"] ?? "";
    expect
      .soft(
        ["no-referrer", "same-origin", "strict-origin", "strict-origin-when-cross-origin"],
        `${label} Referrer-Policy "${ref}"`,
      )
      .toContain(ref);

    expect.soft(headers["permissions-policy"], `${label} Permissions-Policy`).toBeTruthy();
  });
}

test("app: de CSP-nonce verschilt per request (anders is hij geen nonce)", async () => {
  const a = await headersOf(`${APP}/login`);
  const b = await headersOf(`${APP}/login`);
  const nonceA = /'nonce-([a-zA-Z0-9+/=_-]+)'/.exec(a.headers["content-security-policy"] ?? "")?.[1];
  const nonceB = /'nonce-([a-zA-Z0-9+/=_-]+)'/.exec(b.headers["content-security-policy"] ?? "")?.[1];
  expect(nonceA, "geen nonce in de CSP van /login").toBeTruthy();
  expect(nonceA).not.toBe(nonceB);
});

test("TLS: http:// wordt naar https:// gestuurd en niet bediend", async () => {
  for (const host of ["app.bunkhosting.nl", "bunkhosting.nl"]) {
    const ctx = await pwRequest.newContext();
    const res = await ctx.get(`http://${host}/`, { maxRedirects: 0 });
    expect.soft([301, 302, 307, 308], `http://${host} gaf ${res.status()}`).toContain(res.status());
    const loc = res.headers()["location"] ?? "";
    expect.soft(loc, `http://${host} redirect naar ${loc}`).toMatch(/^https:\/\//);
    await ctx.dispose();
  }
});

test("TLS: een echte pagina wordt niet over plain http uitgeserveerd", async () => {
  // Het punt is niet of / een redirect geeft, maar of er ÉÉN pad bestaat dat
  // een volledige pagina over cleartext teruggeeft. Eén zo'n pad is genoeg voor
  // iemand die op het netwerk zit: HSTS geldt pas nadat de browser het domein
  // ooit over https heeft gezien, en de eerste keer is precies de keer die telt.
  const ctx = await pwRequest.newContext();
  for (const url of [
    "http://app.bunkhosting.nl/login",
    "http://app.bunkhosting.nl/register",
    "http://app.bunkhosting.nl/api/v1/packages",
    "http://bunkhosting.nl/",
  ]) {
    const res = await ctx.get(url, { maxRedirects: 0 });
    const body = await res.text();
    expect
      .soft(
        res.status() >= 300 && res.status() < 400,
        `${url} gaf ${res.status()} met ${body.length} bytes body over cleartext in plaats van een redirect naar https`,
      )
      .toBe(true);
  }
  await ctx.dispose();
});

test("TLS: een browser die op http begint eindigt op https", async ({ page }) => {
  await page.goto("http://app.bunkhosting.nl/login", { waitUntil: "domcontentloaded" });
  expect(
    page.url(),
    `een browser die http://app.bunkhosting.nl/login opent blijft op ${page.url()}`,
  ).toMatch(/^https:\/\//);
});

test("cookies die vóór login worden gezet hebben Secure/HttpOnly/SameSite", async ({ page }) => {
  await ga(page, `${APP}/login`);
  await page.waitForTimeout(2000);
  const cookies = (await page.context().cookies()).filter((c) =>
    c.domain.includes("bunkhosting.nl"),
  );

  // Er hoeft niets gezet te worden vóór login; als er wel iets staat, dan goed.
  // cf_* en __cf* komen van Cloudflare zelf (Turnstile, bot management). Die
  // vlaggen zijn hun keuze, niet die van deze applicatie; ze worden wel gemeld
  // zodat je weet wat er in de browser van je bezoeker staat.
  const own = cookies.filter((c) => !/^(cf_|__cf|_cf)/.test(c.name));
  const foreign = cookies.filter((c) => /^(cf_|__cf|_cf)/.test(c.name));
  console.log(
    "cookies vóór login:",
    JSON.stringify(
      cookies.map((c) => ({
        naam: c.name,
        domein: c.domain,
        secure: c.secure,
        httpOnly: c.httpOnly,
        sameSite: c.sameSite,
        vanCloudflare: foreign.includes(c),
      })),
      null,
      2,
    ),
  );

  for (const c of own) {
    const desc = `${c.name} (domain ${c.domain}, sameSite ${c.sameSite}, secure ${c.secure}, httpOnly ${c.httpOnly})`;
    expect.soft(c.secure, `eigen cookie zonder Secure: ${desc}`).toBe(true);
    expect
      .soft(["Lax", "Strict"], `eigen cookie zonder strikte SameSite: ${desc}`)
      .toContain(c.sameSite);
  }

  // Een CSRF-cookie is per definitie leesbaar voor JS; een sessiecookie niet.
  const session = cookies.find((c) => c.name === "bunk_session");
  if (session) expect.soft(session.httpOnly, "bunk_session is niet HttpOnly").toBe(true);
});

test("de Set-Cookie die de API bij een 401 terugstuurt draagt de juiste vlaggen", async () => {
  const ctx = await pwRequest.newContext();
  const res = await ctx.get(`${APP}/api/v1/vpses`);
  expect(res.status()).toBe(401);
  const setCookie = res.headersArray().filter((h) => h.name.toLowerCase() === "set-cookie");
  for (const h of setCookie) {
    // Ook een cookie die alleen wist gaat over het net; zonder Secure lekt de
    // naam (en het gedrag eromheen) over een gedowngrade verbinding.
    expect.soft(h.value, `Set-Cookie zonder Secure: ${h.value}`).toMatch(/;\s*secure/i);
    expect.soft(h.value, `Set-Cookie zonder SameSite: ${h.value}`).toMatch(/;\s*samesite=/i);
  }
  await ctx.dispose();
});
