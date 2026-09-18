import type { Page, Response } from "@playwright/test";

/**
 * Navigeert naar `url` en wacht daarna zo lang als redelijk op een stil netwerk.
 *
 * Waarom dit bestaat: `waitUntil: "networkidle"` wacht tot er 500 ms lang geen
 * netwerkverkeer is, en op /login en /register wordt dat nooit gehaald. De
 * Turnstile-widget van Cloudflare houdt verbindingen open, dus de navigatie
 * loopt door tot de test-time-out van 45 seconden en valt dan om -- op iets wat
 * niets te maken heeft met wat die test controleert. Precies dat gebeurde: de
 * alt-tekstcontrole op /register werd rood omdat de pagina "niet klaar" was,
 * terwijl hij allang stond.
 *
 * Een suite die af en toe om de verkeerde reden rood wordt, is een suite die
 * niemand meer leest, en dan mist hij ook de keer dat het wél ergens over gaat.
 *
 * Dus: wachten op `load` (dat komt altijd), en daarna hooguit tien seconden
 * proberen of het netwerk stil valt. Lukt dat niet, dan is dat geen fout maar
 * een derde partij die aan het werk is -- de pagina staat er, en de test kan
 * meten wat hij komt meten.
 */
export async function ga(page: Page, url: string): Promise<Response | null> {
  const res = await page.goto(url, { waitUntil: "load" });
  await page.waitForLoadState("networkidle", { timeout: 10_000 }).catch(() => {});
  return res;
}
