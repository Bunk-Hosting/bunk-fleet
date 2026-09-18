import type { Page, Response, ConsoleMessage, Request } from "@playwright/test";

export type PageProblems = {
  consoleErrors: string[];
  pageErrors: string[];
  failedRequests: string[];
  badStatus: string[];
  mixedContent: string[];
};

/**
 * Ruis die niets over deze applicatie zegt en die je anders elke run opnieuw
 * moet wegkijken. Bewust kort: hoe langer deze lijst, hoe minder de test meet.
 *  - Turnstile/Cloudflare-insights praten tegen hun eigen endpoints; een
 *    timeout daar is hun infra, niet die van ons.
 *  - favicon 404 wordt apart getest, niet als "gebroken request" geteld.
 */
const IGNORE_PATTERNS = [
  /challenges\.cloudflare\.com/,
  /static\.cloudflareinsights\.com/,
  /cloudflareinsights\.com\/cdn-cgi/,
  /Download the React DevTools/,
  // Next.js haalt bij het zweven over een <Link> alvast de RSC-payload op en
  // breekt die af zodra je niet klikt of de pagina sluit. ERR_ABORTED op een
  // `?_rsc=`-request is dus het ontwerp aan het werk, geen gebroken request.
  // Zonder deze regel faalt elke pagina met een link erop willekeurig.
  // Let op de vorm: de regel luidt "GET <url>?_rsc=xyz :: net::ERR_ABORTED",
  // met een spatie vóór de dubbele dubbelepunt. Een patroon dat die spatie niet
  // toelaat matcht niets en dan faalt elke pagina met een <Link> erop alsnog.
  /_rsc=.*ERR_ABORTED/,
];

function ignored(text: string): boolean {
  return IGNORE_PATTERNS.some((p) => p.test(text));
}

/**
 * Hangt luisteraars aan een pagina vóór de eerste navigatie en verzamelt alles
 * wat een bezoeker niet hoort te zien: console-errors, onafgevangen excepties,
 * mislukte requests, 4xx/5xx op subresources en http:// op een https-pagina.
 *
 * Belangrijk: aanroepen VOOR page.goto(), anders mis je alles wat tijdens het
 * laden van het document zelf gebeurt.
 */
export function collectProblems(page: Page): PageProblems {
  const problems: PageProblems = {
    consoleErrors: [],
    pageErrors: [],
    failedRequests: [],
    badStatus: [],
    mixedContent: [],
  };

  page.on("console", (msg: ConsoleMessage) => {
    if (msg.type() !== "error") return;
    const text = `${msg.text()} @ ${msg.location().url}`;
    if (!ignored(text)) problems.consoleErrors.push(text);
  });

  page.on("pageerror", (err: Error) => {
    if (!ignored(err.message)) problems.pageErrors.push(err.message);
  });

  page.on("requestfailed", (req: Request) => {
    const text = `${req.method()} ${req.url()} :: ${req.failure()?.errorText ?? "?"}`;
    if (!ignored(text)) problems.failedRequests.push(text);
  });

  page.on("response", (res: Response) => {
    const url = res.url();
    if (ignored(url)) return;
    // Redirects zijn geen fout; die volgt de browser zelf.
    if (res.status() >= 400) {
      problems.badStatus.push(`${res.status()} ${res.request().method()} ${url}`);
    }
    if (url.startsWith("http://") && !url.startsWith("http://localhost")) {
      problems.mixedContent.push(url);
    }
  });

  return problems;
}

/** Leesbare samenvatting voor in een assertion-melding. */
export function summarize(p: PageProblems): string {
  return JSON.stringify(p, null, 2);
}

/** Headers van een response als lowercase map, want casing verschilt per hop. */
export function headerMap(res: Response | null): Record<string, string> {
  if (!res) return {};
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(res.headers())) out[k.toLowerCase()] = v;
  return out;
}
