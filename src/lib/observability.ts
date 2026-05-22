/**
 * Client-side observability — stuurt ongevangen JS-errors + unhandled
 * promise-rejections naar `POST /api/v1/security/client-error/`.
 *
 * Bewust géén axios/fetch-wrapper hier — bij een crash van het globale
 * error-pad wil je geen extra dependencies kunnen breken. Plain `fetch`
 * met `keepalive` zodat het verzoek de huidige page-unload overleeft.
 *
 * In-memory dedupe-buffer voorkomt dat een tight render-loop (b.v.
 * "Maximum update depth exceeded") in een seconde 100 reports stuurt.
 *
 * Privacy: geen URL-query/hash van de huidige pagina (zou tokens kunnen
 * lekken). Cookie-credentials worden NIET meegestuurd (`credentials:
 * "omit"`) zodat het rapport ook werkt vanaf uitgelogde sessies.
 */

const API_URL = process.env.NEXT_PUBLIC_API_URL || "https://api.bunkhosting.nl";
const ENDPOINT = `${API_URL}/api/v1/security/client-error/`;

// Per-message dedupe: zelfde message+stack binnen 5 s maar 1 keer rapporteren.
const recentlySent = new Map<string, number>();
const DEDUPE_WINDOW_MS = 5_000;
let installed = false;

function safeStringify(err: unknown): string {
  if (err instanceof Error) return err.stack || err.message;
  if (typeof err === "string") return err;
  try {
    return JSON.stringify(err).slice(0, 2000);
  } catch {
    return String(err);
  }
}

function report(payload: {
  message: string;
  stack?: string | null;
  url?: string | null;
  line?: number | null;
  column?: number | null;
  build_id?: string | null;
  digest?: string | null;
}): void {
  const key = `${payload.message}|${(payload.stack ?? "").slice(0, 200)}`;
  const now = Date.now();
  const last = recentlySent.get(key);
  if (last && now - last < DEDUPE_WINDOW_MS) return;
  recentlySent.set(key, now);

  // Cleanup ouder dan 60 s zodat we geen geheugen lekken.
  if (recentlySent.size > 200) {
    // Array.from + filter ipv for...of over .entries(): tsconfig "target":"es5"
    // staat MapIterator-iteratie niet toe (TS2802) zonder --downlevelIteration.
    const stale: string[] = [];
    recentlySent.forEach((t, k) => {
      if (now - t > 60_000) stale.push(k);
    });
    stale.forEach((k) => recentlySent.delete(k));
  }

  try {
    fetch(ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      credentials: "omit",
      keepalive: true, // overleeft pagenavigatie / unload
    }).catch(() => {
      /* swallow — observability mag nooit zelf crashen */
    });
  } catch {
    /* zelfde — fetch zelf kan in oude browsers throwen */
  }
}

/** Installeert globale error-handlers. Idempotent — meerdere keren
 * aanroepen heeft geen effect na de eerste keer. */
export function installClientObservability(): void {
  if (installed || typeof window === "undefined") return;
  installed = true;

  window.addEventListener("error", (event: ErrorEvent) => {
    report({
      message: event.message || "unknown error",
      stack: safeStringify(event.error),
      url: event.filename || null,
      line: event.lineno ?? null,
      column: event.colno ?? null,
      build_id: process.env.NEXT_PUBLIC_BUILD_ID || null,
    });
  });

  window.addEventListener("unhandledrejection", (event: PromiseRejectionEvent) => {
    report({
      message: safeStringify(event.reason).slice(0, 500) || "unhandled rejection",
      stack: safeStringify(event.reason),
      build_id: process.env.NEXT_PUBLIC_BUILD_ID || null,
    });
  });
}

/** Expliciet rapporteren — gebruik voor error-boundaries die de error
 * vangen vóór het bubble-event de window bereikt. */
export function reportClientError(
  message: string,
  details: { stack?: string; digest?: string } = {},
): void {
  report({
    message: message.slice(0, 500),
    stack: details.stack?.slice(0, 2000),
    digest: details.digest,
    build_id: process.env.NEXT_PUBLIC_BUILD_ID || null,
  });
}
