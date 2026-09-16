"use client";

import * as React from "react";

interface GlobalErrorProps {
  error: Error & { digest?: string };
  reset: () => void;
}

/**
 * Root error-boundary (Next 14 App Router). Vangt fouten op die zelfs het
 * RootLayout crashen — render daarom html/body zelf. Bewust géén Tailwind/
 * design-system imports hier zodat ook bij een crash in globals.css of fonts
 * deze fallback nog rendert.
 */
export default function GlobalError({ error, reset }: GlobalErrorProps) {
  React.useEffect(() => {
    console.error("[global error boundary]", error);
  }, [error]);

  return (
    <html lang="nl">
      <body style={{ margin: 0, fontFamily: "system-ui, sans-serif", background: "#0a0a0a", color: "#e5e5e5", minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center", padding: "2rem" }}>
        <div style={{ maxWidth: 480, textAlign: "center" }}>
          <h1 style={{ fontSize: "1.5rem", marginBottom: "0.75rem" }}>Bunk Hosting is tijdelijk niet bereikbaar</h1>
          <p style={{ fontSize: "0.95rem", lineHeight: 1.55, marginBottom: "1.5rem", color: "#a3a3a3" }}>
            Er is een onverwachte fout opgetreden. Probeer de pagina te
            herladen. Blijft het probleem bestaan, neem contact op met
            support@bunkhosting.nl.
          </p>
          {error.digest && (
            <p style={{ fontFamily: "monospace", fontSize: "0.8rem", color: "#737373", marginBottom: "1.5rem" }}>
              ref: {error.digest}
            </p>
          )}
          <button
            onClick={reset}
            style={{ padding: "0.6rem 1.25rem", borderRadius: "0.5rem", background: "#f97316", color: "#0a0a0a", border: "none", fontWeight: 600, cursor: "pointer" }}
          >
            Pagina herladen
          </button>
        </div>
      </body>
    </html>
  );
}
