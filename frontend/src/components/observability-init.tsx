"use client";

import * as React from "react";
import { installClientObservability } from "@/lib/observability";

/**
 * Mount-zonder-UI component die de globale error-handlers eenmalig
 * installeert. Plaats in RootLayout zodat alle pages dekking hebben.
 * Idempotent — meerdere mounts (bijv. door fast-refresh) doen niets
 * extra dankzij de `installed`-guard in observability.ts.
 */
export function ObservabilityInit() {
  React.useEffect(() => {
    installClientObservability();
  }, []);
  return null;
}
