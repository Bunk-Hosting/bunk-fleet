/** @type {import('next').NextConfig} */

// Fallbacks are the live origin; api.bunkhosting.nl has no DNS/tunnel.
const API_URL = process.env.NEXT_PUBLIC_API_URL || "https://app.bunkhosting.nl";
const WS_URL  = (process.env.NEXT_PUBLIC_WS_URL  || "wss://app.bunkhosting.nl").replace(/^http/, "ws");
// No trailing slash: that was a Django-era path, and the endpoint it pointed at
// did not exist — every violation report a browser sent got a 404, so the
// reporting was decoration. This matches the route the control plane serves.
const CSP_REPORT_URI = `${API_URL}/api/v1/security/csp-report`;

// Only the headers that are specific to the HTML this app serves. Everything
// else — frame options, nosniff, HSTS, referrer policy, permissions policy,
// COOP — is set once at the nginx edge, which also fronts the API and is
// therefore the only layer that can cover every response. Setting them in both
// places is how a policy drifts apart: you change one and the other keeps
// answering.
const securityHeaders = [
  // Reporting API (modern). Browsers die alleen report-uri ondersteunen
  // vallen terug op de directive 'report-uri' verderop in de CSP.
  {
    key: "Report-To",
    value: JSON.stringify({
      group: "csp-endpoint",
      max_age: 10886400,
      endpoints: [{ url: CSP_REPORT_URI }],
    }),
  },
  // Content-Security-Policy
  // - script-src: Next.js heeft 'unsafe-inline' nodig voor hydration-scripts;
  //   Cloudflare Turnstile vereist challenges.cloudflare.com
  // - style-src: 'unsafe-inline' nodig voor Tailwind utility classes;
  //   fonts.googleapis.com voor Material Symbols stylesheet
  // - img-src: data: voor TOTP QR-codes; blob: voor xterm canvas
  // - font-src: fonts.gstatic.com voor Material Symbols woff2-bestanden
  // - connect-src: API + WebSocket endpoints + Turnstile + CSP-report endpoint
  // - frame-src: Cloudflare Turnstile widget (iframe)
  // - worker-src: blob: voor xterm.js Web Worker
  // - report-uri: legacy + report-to: modern → backend security endpoint
  {
    key: "Content-Security-Policy",
    value: [
      "default-src 'self'",
      `script-src 'self' 'unsafe-inline' https://challenges.cloudflare.com`,
      "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
      // No remote images are ever loaded (QR codes are data: URLs, xterm uses
      // blob:) — drop the https: wildcard to shut off tracking-pixel/exfil vectors.
      "img-src 'self' data: blob:",
      "font-src 'self' data: https://fonts.gstatic.com",
      `connect-src 'self' ${API_URL} ${WS_URL} https://challenges.cloudflare.com`,
      "frame-src 'self' https://challenges.cloudflare.com",
      "frame-ancestors 'none'",
      // No <object>/<embed>/<applet> anywhere; block them outright.
      "object-src 'none'",
      "worker-src blob:",
      "base-uri 'self'",
      "form-action 'self'",
      "upgrade-insecure-requests",
      `report-uri ${CSP_REPORT_URI}`,
      "report-to csp-endpoint",
    ].join("; "),
  },
];

const nextConfig = {
  typescript: { ignoreBuildErrors: false },
  eslint: { ignoreDuringBuilds: true },
  async rewrites() {
    const target = process.env.BUNK_API_URL || "http://bf-prod-cp:4000";
    return [{ source: "/api/v1/:path*", destination: `${target}/api/v1/:path*` }];
  },
  output: "standalone",

  async headers() {
    return [
      {
        source: "/:path*",
        headers: securityHeaders,
      },
    ];
  },
};

export default nextConfig;
