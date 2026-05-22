/** @type {import('next').NextConfig} */

const API_URL = process.env.NEXT_PUBLIC_API_URL || "https://api.bunkhosting.nl";
const WS_URL  = (process.env.NEXT_PUBLIC_WS_URL  || "wss://api.bunkhosting.nl").replace(/^http/, "ws");

const securityHeaders = [
  // Clickjacking: pagina mag niet in een iframe worden geladen
  { key: "X-Frame-Options",           value: "DENY" },
  // Voorkom MIME-type sniffing
  { key: "X-Content-Type-Options",    value: "nosniff" },
  // HSTS: forceer HTTPS voor 1 jaar, inclusief subdomeinen
  { key: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains; preload" },
  // Stuur geen volledige Referer-header mee naar externe sites
  { key: "Referrer-Policy",           value: "strict-origin-when-cross-origin" },
  // Schakel ongebruikte browser-API's uit
  { key: "Permissions-Policy",        value: "camera=(), microphone=(), geolocation=(), payment=(), usb=()" },
  // Content-Security-Policy
  // - script-src: Next.js heeft 'unsafe-inline' nodig voor hydration-scripts;
  //   Cloudflare Turnstile vereist challenges.cloudflare.com
  // - style-src: 'unsafe-inline' nodig voor Tailwind utility classes;
  //   fonts.googleapis.com voor Material Symbols stylesheet
  // - img-src: data: voor TOTP QR-codes; blob: voor xterm canvas
  // - font-src: fonts.gstatic.com voor Material Symbols woff2-bestanden
  // - connect-src: API + WebSocket endpoints
  // - frame-src: Cloudflare Turnstile widget (iframe)
  // - worker-src: blob: voor xterm.js Web Worker
  {
    key: "Content-Security-Policy",
    value: [
      "default-src 'self'",
      `script-src 'self' 'unsafe-inline' https://challenges.cloudflare.com`,
      "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
      "img-src 'self' data: blob: https:",
      "font-src 'self' data: https://fonts.gstatic.com",
      `connect-src 'self' ${API_URL} ${WS_URL} https://challenges.cloudflare.com`,
      "frame-src 'self' https://challenges.cloudflare.com",
      "frame-ancestors 'none'",
      "worker-src blob:",
      "base-uri 'self'",
      "form-action 'self'",
      "upgrade-insecure-requests",
    ].join("; "),
  },
];

const nextConfig = {
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
