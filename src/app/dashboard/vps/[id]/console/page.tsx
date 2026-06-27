"use client";

import { useEffect, useRef, useState, useCallback } from "react";
import { useParams, useRouter } from "next/navigation";
import { ArrowLeft, Clipboard, Loader2, Terminal } from "lucide-react";
import { Button } from "@/components/ui/button";
import { VpsConsole, type VpsConsoleHandle } from "@/components/vps/vps-console";
import { StatusBadge } from "@/components/vps/status-badge";
import { vpsApi } from "@/lib/api";
import type { Vps } from "@/lib/types";

export default function VpsConsolePage() {
  const params = useParams();
  const router = useRouter();
  const id = params.id as string;

  const consoleRef = useRef<VpsConsoleHandle>(null);
  const [vps, setVps] = useState<Vps | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [pasteHelper, setPasteHelper] = useState(false);
  const [pasteText, setPasteText] = useState("");

  const handlePasteButton = async () => {
    try {
      const text = await navigator.clipboard.readText();
      if (text) consoleRef.current?.sendText(text);
    } catch {
      setPasteHelper(true);
    }
  };

  const sendPasteHelper = () => {
    if (pasteText) consoleRef.current?.sendText(pasteText);
    setPasteText("");
    setPasteHelper(false);
  };

  const fetchVps = useCallback(async () => {
    try {
      const response = await vpsApi.get(id);
      setVps(response.data);
    } catch {
      setError("Kon VPS gegevens niet laden.");
    } finally {
      setLoading(false);
    }
  }, [id]);

  useEffect(() => {
    fetchVps();
  }, [fetchVps]);

  if (loading) {
    return (
      <div className="flex h-full items-center justify-center">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  if (error || !vps) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-4 text-center">
        <p className="text-muted-foreground">{error ?? "VPS niet gevonden."}</p>
        <Button variant="outline" onClick={() => router.push("/dashboard/vps")}>
          Terug naar overzicht
        </Button>
      </div>
    );
  }

  if (vps.status !== "ACTIVE") {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-4 text-center">
        <Terminal className="h-12 w-12 text-muted-foreground" />
        <div>
          <p className="text-lg font-medium">Console niet beschikbaar</p>
          <p className="text-sm text-muted-foreground mt-1">
            De VPS moet actief zijn om de console te openen.
          </p>
        </div>
        <StatusBadge status={vps.status} />
        <Button
          variant="outline"
          onClick={() => router.push(`/dashboard/vps/${id}`)}
        >
          Terug naar VPS
        </Button>
      </div>
    );
  }

  return (
    <div className="flex h-[calc(100vh-4rem)] flex-col gap-3">
      {/* Header */}
      <div className="flex items-center justify-between shrink-0">
        <div className="flex items-center gap-3">
          <Button
            variant="ghost"
            size="sm"
            onClick={() => router.push(`/dashboard/vps/${id}`)}
            className="gap-2"
          >
            <ArrowLeft className="h-4 w-4" />
            Terug
          </Button>
          <div className="flex items-center gap-2">
            <Terminal className="h-5 w-5 text-muted-foreground" />
            <span className="font-semibold">
              {vps.label || `VPS #${vps.id}`}
            </span>
            <StatusBadge status={vps.status} />
          </div>
        </div>
        <div className="relative">
          <Button
            variant="outline"
            size="sm"
            className="gap-2"
            onClick={handlePasteButton}
          >
            <Clipboard className="h-4 w-4" />
            Plakken
          </Button>
          {pasteHelper && (
            <div className="absolute top-full right-0 mt-1 z-20 w-72 rounded-md border bg-card shadow-lg p-3">
              <p className="text-xs text-muted-foreground mb-2">
                Klembord geblokkeerd door browser. Plak hier met Ctrl+V:
              </p>
              <textarea
                autoFocus
                className="w-full h-20 resize-none rounded border bg-background px-2 py-1 font-mono text-sm"
                placeholder="Plak hier…"
                value={pasteText}
                onChange={(e) => setPasteText(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Escape") { setPasteHelper(false); setPasteText(""); }
                }}
              />
              <div className="mt-2 flex justify-end gap-2">
                <Button variant="ghost" size="sm"
                  onClick={() => { setPasteHelper(false); setPasteText(""); }}>
                  Annuleren
                </Button>
                <Button size="sm" onClick={sendPasteHelper}>Stuur</Button>
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Terminal */}
      <div className="flex-1 min-h-0 rounded-lg border border-border overflow-hidden">
        <VpsConsole vpsId={id} ref={consoleRef} />
      </div>
    </div>
  );
}
