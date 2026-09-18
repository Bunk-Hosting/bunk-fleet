import { test, expect, pwRequest } from "../lib/fixtures";
import { APP, WWW } from "../lib/targets";

/**
 * 8. /healthz, /robots.txt, /sitemap.xml, /.well-known/security.txt
 * 9. Een pagina die niet bestaat -> nette 404, geen Phoenix-debugpagina.
 */

type Expectation = {
  host: string;
  path: string;
  status: number | number[];
  contentType?: RegExp;
  bodyMatch?: RegExp;
  why: string;
};

const CHECKS: Expectation[] = [
  {
    host: APP,
    path: "/healthz",
    status: 200,
    why: "een watchdog buiten de machine moet 200/503 kunnen lezen",
  },
  {
    host: APP,
    path: "/robots.txt",
    status: 200,
    contentType: /text\/plain/,
    bodyMatch: /User-agent/i,
    why: "crawlers moeten /dashboard/ kunnen overslaan",
  },
  {
    host: APP,
    path: "/.well-known/security.txt",
    status: 200,
    bodyMatch: /^Contact:/m,
    why: "RFC 9116: waar een onderzoeker een vondst kwijt kan",
  },
  {
    host: WWW,
    path: "/robots.txt",
    status: 200,
    contentType: /text\/plain/,
    bodyMatch: /User-agent/i,
    why: "de marketingsite is de kant die geïndexeerd wordt",
  },
  {
    host: WWW,
    path: "/sitemap.xml",
    status: 200,
    contentType: /xml/,
    bodyMatch: /<urlset|<sitemapindex/,
    why: "zonder sitemap moet Google de site zelf uitpuzzelen",
  },
  {
    host: WWW,
    path: "/.well-known/security.txt",
    status: 200,
    bodyMatch: /^Contact:/m,
    why: "een onderzoeker zoekt dit op het hoofddomein, niet op app.",
  },
  {
    host: APP,
    path: "/sitemap.xml",
    status: [200, 404],
    why: "het klantpaneel zit achter de login; een sitemap is er optioneel",
  },
];

for (const c of CHECKS) {
  const label = `${c.host.replace("https://", "")}${c.path}`;
  test(`${label} (${c.why})`, async ({}, testInfo) => {

    const ctx = await pwRequest.newContext();
    const res = await ctx.get(`${c.host}${c.path}`);
    const body = await res.text();
    testInfo.attach(`${label.replace(/[\/.]/g, "_")}.txt`, {
      body: `${res.status()}\n${JSON.stringify(res.headers(), null, 2)}\n\n${body.slice(0, 2000)}`,
      contentType: "text/plain",
    });

    const want = Array.isArray(c.status) ? c.status : [c.status];
    expect.soft(want, `${label} gaf ${res.status()}, verwacht ${want.join("/")}`).toContain(res.status());

    if (res.status() === 200) {
      if (c.contentType) {
        expect
          .soft(res.headers()["content-type"] ?? "", `${label} content-type`)
          .toMatch(c.contentType);
      }
      if (c.bodyMatch) {
        expect.soft(body, `${label} inhoud past niet bij het formaat`).toMatch(c.bodyMatch);
      }
    }
    await ctx.dispose();
  });
}

test("security.txt heeft een Expires die nog niet verstreken is", async () => {
  const ctx = await pwRequest.newContext();
  const res = await ctx.get(`${APP}/.well-known/security.txt`);
  const body = await res.text();
  const m = /^Expires:\s*(.+)$/m.exec(body);
  expect(m, "security.txt zonder verplicht Expires-veld (RFC 9116 §2.5.5)").not.toBeNull();
  const when = new Date(m![1].trim());
  expect(when.getTime(), `Expires onleesbaar: ${m![1]}`).not.toBeNaN();
  expect(
    when.getTime() > Date.now(),
    `security.txt is verlopen op ${when.toISOString()}; een verlopen bestand hoort genegeerd te worden`,
  ).toBe(true);
  await ctx.dispose();
});

test("healthz zegt niets meer dan nodig", async () => {
  const ctx = await pwRequest.newContext();
  const res = await ctx.get(`${APP}/healthz`);
  const body = await res.text();
  expect(res.status()).toBe(200);
  expect
    .soft(body.length, `healthz-body is ${body.length} bytes: ${body.slice(0, 200)}`)
    .toBeLessThan(200);
  for (const leak of [/\d+\.\d+\.\d+/, /Elixir/, /postgres/i, /version/i]) {
    expect.soft(body, `healthz lekt ${leak}`).not.toMatch(leak);
  }
  await ctx.dispose();
});

for (const host of [APP, WWW]) {
  test(`${host.replace("https://", "")}: onbekend pad geeft een nette 404`, async ({ page }, testInfo) => {
    const path = "/deze-pagina-bestaat-niet-" + Date.now();
    const res = await page.goto(`${host}${path}`, { waitUntil: "domcontentloaded" });
    expect.soft(res!.status(), `${host}${path} gaf ${res!.status()}`).toBe(404);

    const html = await page.content();
    for (const leak of [
      "Phoenix",
      "Elixir",
      "NoRouteError",
      "stacktrace",
      "lib/control_plane",
      "Ecto",
    ]) {
      expect.soft(html, `404 op ${host} lekt "${leak}"`).not.toContain(leak);
    }

    // Een 404 die er niet uitziet als de site is een doodlopende weg voor de
    // bezoeker: hij hoort een weg terug te hebben.
    const links = await page.locator("a[href]").count();
    expect.soft(links, `404 op ${host} heeft geen enkele link terug`).toBeGreaterThan(0);

    testInfo.attach("404.png", {
      body: await page.screenshot({ fullPage: true }),
      contentType: "image/png",
    });
  });
}

test("een pad dat naar een debugroute ruikt is niet bereikbaar", async () => {
  const ctx = await pwRequest.newContext();
  const paths = [
    "/api/v1/debug/",
    "/api/v1/internal/",
    "/.env",
    "/dev/dashboard",
    "/phoenix/live_reload/socket",
    "/adminer.php",
    "/wp-login.php",
    "/.git/config",
  ];
  for (const p of paths) {
    const res = await ctx.get(`${APP}${p}`, { maxRedirects: 0 });
    const body = await res.text();
    expect.soft([401, 403, 404], `${p} gaf ${res.status()}`).toContain(res.status());
    expect.soft(body, `${p} lekt Elixir/Phoenix`).not.toMatch(/Elixir\.|LiveReload|Phoenix\.Router/);
  }
  await ctx.dispose();
});
