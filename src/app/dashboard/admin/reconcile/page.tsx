"use client";

import { useEffect, useState, useCallback } from "react";
import { RefreshCw, CheckCircle2, AlertCircle, Clock, Loader2 } from "lucide-react";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Separator } from "@/components/ui/separator";
import { useToast } from "@/components/ui/use-toast";
import { adminApi } from "@/lib/api";
import { formatDateTime } from "@/lib/utils";
import type { ReconcileResult, ReconcileStatusResponse } from "@/lib/types";

export default function ReconcilePage() {
  const { toast } = useToast();
  const [data, setData] = useState<ReconcileStatusResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [running, setRunning] = useState(false);

  const fetchStatus = useCallback(async () => {
    try {
      const res = await adminApi.reconcile.status();
      setData(res.data);
    } catch {
      toast({ title: "Fout", description: "Kon reconciliatie-status niet laden.", variant: "destructive" });
    } finally {
      setLoading(false);
    }
  }, [toast]);

  useEffect(() => {
    fetchStatus();
  }, [fetchStatus]);

  async function handleTrigger() {
    setRunning(true);
    try {
      await adminApi.reconcile.trigger();
      toast({ title: "Gestart", description: "Reconciliatie wordt uitgevoerd op de achtergrond." });
      // Poll until last_result updates (max ~30s)
      let attempts = 0;
      const poll = setInterval(async () => {
        attempts++;
        const res = await adminApi.reconcile.status();
        setData(res.data);
        if (res.data.last_result?.finished_at || attempts >= 15) {
          clearInterval(poll);
          setRunning(false);
        }
      }, 2000);
    } catch {
      toast({ title: "Fout", description: "Kon reconciliatie niet starten.", variant: "destructive" });
      setRunning(false);
    }
  }

  const result: ReconcileResult | null = data?.last_result ?? null;

  return (
    <div className="space-y-6 max-w-2xl">
      <div>
        <h1 className="text-3xl font-bold">Reconciliatie</h1>
        <p className="text-muted-foreground">
          Vergelijkt de database met vCenter. Verwijderde VMs worden opgespoord en
          hun IP-adressen worden vrijgegeven.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <Clock className="h-5 w-5" />
            Planning
          </CardTitle>
          <CardDescription>
            De reconciliatie draait automatisch elke{" "}
            <strong>{data?.interval_minutes ?? "…"} minuten</strong> via Celery Beat.
            Je kunt het ook handmatig starten.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <Button onClick={handleTrigger} disabled={running || loading}>
            {running ? (
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
            ) : (
              <RefreshCw className="mr-2 h-4 w-4" />
            )}
            {running ? "Bezig…" : "Nu uitvoeren"}
          </Button>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Laatste resultaat</CardTitle>
        </CardHeader>
        <CardContent>
          {loading ? (
            <div className="flex items-center gap-2 text-muted-foreground">
              <Loader2 className="h-4 w-4 animate-spin" />
              Laden…
            </div>
          ) : !result ? (
            <p className="text-muted-foreground text-sm">
              Nog niet uitgevoerd. Start de reconciliatie handmatig of wacht op de automatische run.
            </p>
          ) : (
            <div className="space-y-4">
              <div className="flex items-center gap-2">
                {result.error ? (
                  <AlertCircle className="h-5 w-5 text-destructive" />
                ) : (
                  <CheckCircle2 className="h-5 w-5 text-green-500" />
                )}
                <span className="font-medium">
                  {result.error ? "Mislukt" : "Geslaagd"}
                </span>
              </div>

              <div className="grid gap-1 text-sm">
                <div className="flex justify-between">
                  <span className="text-muted-foreground">Gestart om</span>
                  <span>{formatDateTime(result.started_at)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-muted-foreground">Voltooid om</span>
                  <span>
                    {result.finished_at ? formatDateTime(result.finished_at) : "—"}
                  </span>
                </div>
              </div>

              <Separator />

              <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
                <Stat label="Gecontroleerd" value={result.vms_checked} />
                <Stat label="Verwijderd" value={result.vms_deleted} color={result.vms_deleted > 0 ? "text-orange-500" : undefined} />
                <Stat label="IPs vrijgegeven" value={result.ips_released} color={result.ips_released > 0 ? "text-blue-500" : undefined} />
                <Stat label="Wees-IPs" value={result.orphaned_ips_released} color={result.orphaned_ips_released > 0 ? "text-yellow-500" : undefined} />
              </div>

              {result.error && (
                <div className="rounded-md bg-destructive/10 p-3 text-sm text-destructive">
                  {result.error}
                </div>
              )}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

function Stat({ label, value, color }: { label: string; value: number; color?: string }) {
  return (
    <div className="rounded-md border p-3 text-center">
      <p className={`text-2xl font-bold ${color ?? ""}`}>{value}</p>
      <p className="text-xs text-muted-foreground mt-1">{label}</p>
    </div>
  );
}
