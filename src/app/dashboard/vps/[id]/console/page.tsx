"use client";

import { useEffect, useState, useCallback } from "react";
import { useParams, useRouter } from "next/navigation";
import { ArrowLeft, Loader2, Terminal } from "lucide-react";
import { Button } from "@/components/ui/button";
import { VpsConsole } from "@/components/vps/vps-console";
import { StatusBadge } from "@/components/vps/status-badge";
import { vpsApi } from "@/lib/api";
import type { Vps } from "@/lib/types";

export default function VpsConsolePage() {
  const params = useParams();
  const router = useRouter();
  const id = Number(params.id);

  const [vps, setVps] = useState<Vps | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

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
        <p className="text-xs text-muted-foreground hidden sm:block">
          Sluit de tab om de verbinding te verbreken
        </p>
      </div>

      {/* Terminal */}
      <div className="flex-1 min-h-0 rounded-lg border border-border overflow-hidden">
        <VpsConsole vpsId={id} />
      </div>
    </div>
  );
}
